import SwiftUI
import UIKit
import WebKit
import Network
import Foundation

// MARK: - Minimal localhost HTTP server (serves the bundled site)
// WKWebView cannot run ES modules / WASM over file:// (CORS), so we serve the
// game over http://127.0.0.1 — which is also a secure context, so WebGPU works.
final class LocalHTTPServer {
    private var listener: NWListener?
    private let root: URL
    private let queue = DispatchQueue(label: "local.http", attributes: .concurrent)
    private(set) var port: UInt16 = 0

    init(root: URL) { self.root = root }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        for _ in 0..<200 where port == 0 { usleep(10_000) } // wait up to 2 s
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, headers: buf.subdata(in: 0..<range.lowerBound))
            } else if error != nil || complete || buf.count > 1_048_576 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, headers: Data) {
        guard let text = String(data: headers, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else {
            conn.cancel(); return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0].uppercased()
        var path = parts[1]
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        let decoded = path.removingPercentEncoding ?? path
        let segments = decoded.split(separator: "/").map(String.init)
            .filter { $0 != "." && $0 != ".." }
        var file = root
        for s in segments { file.appendPathComponent(s) }
        if segments.isEmpty || decoded.hasSuffix("/") {
            file.appendPathComponent("index.html")
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
        guard exists, !isDir.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64,
              let handle = try? FileHandle(forReadingFrom: file) else {
            send(conn, status: "404 Not Found", type: "text/plain", length: 9, head: true)
            return
        }

        send(conn, status: "200 OK", type: mimeType(file.pathExtension),
             length: size, head: method == "HEAD", body: handle)
    }

    private func send(_ conn: NWConnection, status: String, type: String,
                      length: Int64, head: Bool, body: FileHandle? = nil) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(length)\r\nCache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self = self, !head, let body = body else {
                try? body?.close(); conn.cancel(); return
            }
            self.stream(conn, handle: body)
        })
    }

    private func stream(_ conn: NWConnection, handle: FileHandle) {
        let chunk = handle.readData(ofLength: 262_144)
        if chunk.isEmpty {
            try? handle.close(); conn.cancel(); return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); conn.cancel(); return }
            self?.stream(conn, handle: handle)
        })
    }

    private func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "ttf", "otf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "lua", "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Fullscreen WebView

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 强制横屏：游戏本身就是横屏设计，进入即锁定，不再跟随手机陀螺仪

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
}

@main
struct AzerothSurvivorsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let server: LocalHTTPServer
    private let startURL: URL

    init() {
        let root = Bundle.main.resourceURL!.appendingPathComponent("www", isDirectory: true)
        let server = LocalHTTPServer(root: root)
        try! server.start()
        self.server = server
        self.startURL = URL(string: "http://127.0.0.1:\(server.port)/index.html")!
    }

    var body: some Scene {
        WindowGroup {
            WebView(url: startURL)
                .ignoresSafeArea()
                .statusBarHidden(true)
                .background(Color.black)
        }
    }
}
