import SwiftUI
import WebKit

struct HelpWindowView: View {
    var body: some View {
        Group {
            if let url = AudioConverterHelp.helpURL {
                HelpWebView(url: url)
            } else {
                HelpMissingView()
            }
        }
        .frame(minWidth: 520, minHeight: 600)
    }
}

private struct HelpWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

private struct HelpMissingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Help file not found")
                .font(.headline)
            Text("Expected Help.html in the app bundle Resources.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
