import SwiftUI
import WebKit

struct WebviewWidgetView: View {
    let widget: DashboardWidget

    private var webURL: URL? {
        guard let urlString = widget.url else { return nil }
        return URL(string: urlString)
    }

    private var viewHeight: CGFloat {
        CGFloat(widget.height ?? 400)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let icon = widget.icon {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text(widget.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let urlString = widget.url {
                    Text(urlString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let url = webURL {
                WebViewRepresentable(url: url)
                    .frame(height: viewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ContentUnavailableView {
                    Label("Invalid URL", systemImage: "globe")
                } description: {
                    Text(widget.url ?? "No URL provided")
                }
                .frame(height: viewHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - WKWebView Wrapper

private struct WebViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[Scarf] WebView navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[Scarf] WebView failed to load: \(error.localizedDescription)")
        }
    }
}
