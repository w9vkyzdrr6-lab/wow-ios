import SwiftUI
import UIKit
import WebKit
import Network
import Foundation
import Combine

// MARK: - 诊断信息收集（显示在屏幕左上角，点击可隐藏/显示）

final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    @Published var lines: [String] = []
    @Published var okCount = 0
    @Published var missCount = 0
    private let lock = NSLock()

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async {
            self.lines.append(String(trimmed.prefix(220)))
            if self.lines.count > 60 { self.lines.removeFirst(self.lines.count - 60) }
        }
    }

    func count(ok: Bool) {
        DispatchQueue.main.async {
            if ok { self.okCount += 1 } else { self.missCount += 1 }
        }
    }
}

// MARK: - 内置本地 HTTP 服务器（避免 file:// 的 CORS 限制，同时满足 WebGPU 的 secure context 要求）

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
            if case .ready = state { self?.port = listener.port?.rawValue ?? 0 }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        for _ in 0..<200 where port == 0 { usleep(10_000) }
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
            Diagnostics.shared.count(ok: false)
            Diagnostics.shared.add("404 \(decoded)")
            send(conn, status: "404 Not Found", type: "text/plain", length: 9, head: true)
            return
        }

        Diagnostics.shared.count(ok: true)
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

// MARK: - 捕获网页 console 输出

final class ConsoleHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        if let text = message.body as? String {
            Diagnostics.shared.add(text)
        }
    }
}

private let consoleHookJS = """
(function () {
  function send(level, args) {
    try {
      var text = level + ' ' + Array.prototype.map.call(args, function (a) {
        if (a instanceof Error) return a.message;
        if (typeof a === 'object') { try { return JSON.stringify(a); } catch (e) { return String(a); } }
        return String(a);
      }).join(' ');
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.diag) {
        window.webkit.messageHandlers.diag.postMessage(text);
      }
    } catch (e) {}
  }
  ['error', 'warn'].forEach(function (k) {
    var orig = console[k];
    console[k] = function () { send(k.toUpperCase(), arguments); if (orig) orig.apply(console, arguments); };
  });
  window.addEventListener('error', function (e) { send('ERROR', [e.message + ' @' + e.filename + ':' + e.lineno]); });
  window.addEventListener('unhandledrejection', function (e) { send('REJECT', [String(e.reason)]); });
})();
"""

// MARK: - 全屏 WebView

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.add(ConsoleHandler(), name: "diag")
        controller.addUserScript(WKUserScript(source: consoleHookJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 诊断浮层：点击可隐藏

struct DiagOverlay: View {
    @ObservedObject var diag = Diagnostics.shared
    @State private var visible = true

    var body: some View {
        Group {
            if visible {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HTTP ok \(diag.okCount) / 404 \(diag.missCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(diag.missCount > 0 ? .orange : .green)
                    ForEach(Array(diag.lines.suffix(28).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
                .padding(6)
                .frame(width: 560, alignment: .leading)
                .background(Color.black.opacity(0.75))
                .overlay(Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .position(x: 290, y: 150)
                .onTapGesture { visible = false }
            } else {
                Color.clear
                    .frame(width: 70, height: 70)
                    .contentShape(Rectangle())
                    .position(x: 35, y: 35)
                    .onTapGesture { visible = true }
            }
        }
    }
}

// MARK: - 强制横屏

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
            ZStack {
                WebView(url: startURL)
                    .ignoresSafeArea()
                DiagOverlay()
            }
            .statusBarHidden(true)
            .background(Color.black)
        }
    }
}
