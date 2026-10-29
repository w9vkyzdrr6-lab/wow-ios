import SwiftUI
import WebKit

@main
struct AzerothSurvivorsApp: App {
    var body: some Scene {
        WindowGroup {
            WebView()
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}

struct WebView: UIViewRepresentable {
    let url = URL(string: "https://wow.aethus.pl")!

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
