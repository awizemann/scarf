#if canImport(WebKit)
import Foundation
import SwiftUI
import WebKit

/// The production ``VoiceMediaBridge``: a hidden `WKWebView` running WebRTC
/// (microphone, peer connection, `oai-events` data channel, remote audio),
/// shared by the macOS app and ScarfGo.
///
/// Requirements measured in the P3 spike (macOS 27 + iOS 26.2 simulator; see
/// the memory "GPT-Live voice in WKWebView: origin, permission and hosting
/// requirements"):
/// - The page is served from a custom scheme (`scarf-voice://live/index.html`)
///   by ``VoiceLivePageSchemeHandler``: a secure context with a stable origin
///   and no listener or file on disk. (`loadHTMLString(baseURL: nil)` has no
///   `navigator.mediaDevices`.)
/// - Microphone capture is granted to that origin only, in the main frame;
///   everything else is denied. The OS microphone prompt still follows on
///   first use (macOS: `audio-input` entitlement + `NSMicrophoneUsageDescription`;
///   iOS: `NSMicrophoneUsageDescription`).
/// - Remote audio autoplays (`mediaTypesRequiringUserActionForPlayback = []`,
///   plus inline playback on iOS).
/// - **The web view must be in a window's view hierarchy** or remote audio
///   never plays: embed ``VoiceLiveMediaHostView`` (1×1, alpha 0) in the
///   voice panel and keep it mounted for the whole session.
///
/// Swift → JS calls use `callAsyncJavaScript` with ARGUMENTS (never string
/// interpolation). Fire-and-forget calls (`send`, mute, teardown) use the
/// completion-handler form so they reach the page in call order. Page →
/// Swift messages are accepted only from the main frame of the
/// `scarf-voice://live` origin. The SDP offer and answer are never logged.
@MainActor
public final class WebViewVoiceMediaBridge: NSObject, VoiceMediaBridge {
    public static let scheme = "scarf-voice"
    public static let host = "live"
    public static let pageURL = URL(string: "scarf-voice://live/index.html")!
    static let messageHandlerName = "scarfVoiceLive"
    /// How long the page may take to load and report `ready`.
    static let pageLoadTimeout: Duration = .seconds(10)

    public enum BridgeError: Error, LocalizedError, Equatable {
        case pageUnavailable
        case insecureContext
        case script(String)

        public var errorDescription: String? {
            switch self {
            case .pageUnavailable: return String(localized: "The Live Voice page didn't load.")
            case .insecureContext: return String(localized: "Live Voice can't use the microphone in this web view.")
            case .script(let message): return message
            }
        }
    }

    public var onEvent: (@MainActor @Sendable (VoiceMediaEvent) -> Void)?

    /// Embed through ``VoiceLiveMediaHostView``; don't size or show it.
    public let webView: WKWebView

    private var loadRequested = false
    /// The page's navigation, while it loads. Only ITS failure means the
    /// page is gone; a later navigation that fails (or that the policy
    /// cancels) leaves the loaded page, and any live session, running.
    private var pageNavigation: WKNavigation?
    private(set) var secureContext: Bool?
    /// Bumped by every `startMedia()` and `teardown()`. The page stamps each
    /// message with the generation that started it, so a message from a
    /// torn-down session can never reach a newer one, and a start that was
    /// torn down while the page loaded never opens the microphone.
    private var generation = 0
    private var readyWaiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(VoiceLivePageSchemeHandler(), forURLScheme: Self.scheme)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        let proxy = WeakScriptMessageProxy()
        configuration.userContentController.add(proxy, name: Self.messageHandlerName)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        proxy.target = self
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    // MARK: - VoiceMediaBridge

    public func startMedia() async throws {
        generation += 1
        let mine = generation
        guard let secure = await loadPage() else { throw BridgeError.pageUnavailable }
        guard secure else { throw BridgeError.insecureContext }
        guard mine == generation else { throw CancellationError() }   // torn down while loading
        try await call("await scarfVoiceLive.start(token); return true", arguments: ["token": mine])
    }

    public func applyAnswer(sdp: String) async throws {
        try await call("await scarfVoiceLive.applyAnswer(sdp); return true", arguments: ["sdp": sdp])
    }

    public func send(_ json: String) {
        fire("return scarfVoiceLive.send(json)", arguments: ["json": json])
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        fire("scarfVoiceLive.setMicrophoneEnabled(enabled); return true", arguments: ["enabled": enabled])
    }

    public func teardown(onReleased: (@MainActor @Sendable () -> Void)?) {
        generation += 1
        // Never gated on the page's ready state: a page that loaded may
        // still hold the microphone whatever the navigation delegate saw
        // since. With no page at all the call just fails, which counts as
        // released.
        guard loadRequested || secureContext != nil else {
            onReleased?()
            return
        }
        // The completion holds the bridge (and so the web view and its page)
        // until the page has flushed and closed the peer: a host that drops
        // the bridge right after ending must not cut the flush short.
        webView.callAsyncJavaScript(
            "return await scarfVoiceLive.teardown()", arguments: [:], in: nil, in: .page
        ) { [self] _ in
            withExtendedLifetime(self) { onReleased?() }
        }
    }

    // MARK: - Page

    /// Load the page once and wait for its `ready` message. Returns its
    /// `isSecureContext`, or `nil` if it didn't load in time.
    func loadPage() async -> Bool? {
        if let secureContext { return secureContext }
        if !loadRequested {
            loadRequested = true
            pageNavigation = webView.load(URLRequest(url: Self.pageURL))
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            readyWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.pageLoadTimeout)
                self?.loadTimedOut(id)
            }
        }
    }

    /// A load that never answered: give up on it so the next start loads
    /// afresh instead of waiting on the same dead navigation.
    private func loadTimedOut(_ id: UUID) {
        guard let continuation = readyWaiters.removeValue(forKey: id) else { return }
        if secureContext == nil {
            webView.stopLoading()
            loadRequested = false
            pageNavigation = nil
        }
        continuation.resume(returning: secureContext)
    }

    private func resolveAllWaiters(_ value: Bool?) {
        let waiters = readyWaiters
        readyWaiters = [:]
        for continuation in waiters.values { continuation.resume(returning: value) }
    }

    /// The page is gone (web content process died, or its load failed
    /// before it was ready): forget it so the next start loads it again.
    private func pageLost() {
        loadRequested = false
        pageNavigation = nil
        secureContext = nil
        resolveAllWaiters(nil)
    }

    /// A navigation failed. Only the page's own load failing before `ready`
    /// loses the page; anything else (a navigation the policy cancelled, a
    /// failure after the page was up) leaves it, and its microphone, alive,
    /// so teardown must still reach it.
    func navigationFailed(_ navigation: WKNavigation?) {
        guard secureContext == nil, navigation == nil || navigation === pageNavigation else { return }
        pageLost()
    }

    // MARK: - JavaScript

    func call(_ body: String, arguments: [String: Any] = [:]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: Self.scriptError(error))
                }
            }
        }
    }

    private func fire(_ body: String, arguments: [String: Any] = [:]) {
        guard secureContext != nil else { return }   // no page ready, nothing to tell
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    /// A JS exception's message (e.g. `NotAllowedError: …` from
    /// getUserMedia), never the arguments.
    static func scriptError(_ error: Error) -> BridgeError {
        let info = (error as NSError).userInfo
        let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        return .script(message)
    }

    // MARK: - Messages from the page

    fileprivate func receive(_ message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard Self.acceptsMessage(isMainFrame: message.frameInfo.isMainFrame,
                                  originProtocol: origin.protocol, originHost: origin.host),
              Self.isCurrent(messageBody: message.body, generation: generation),
              let event = VoiceMediaEvent.decode(messageBody: message.body) else { return }
        if case .pageReady(let secure) = event {
            secureContext = secure
            pageNavigation = nil
            resolveAllWaiters(secure)
        }
        onEvent?(event)
    }

    /// Session messages carry the generation that started them; `ready`
    /// (and anything else sent outside a session) carries none.
    static func isCurrent(messageBody body: Any, generation: Int) -> Bool {
        guard let token = (body as? [String: Any])?["token"] else { return true }
        return (token as? NSNumber)?.intValue == generation
    }

    static func acceptsMessage(isMainFrame: Bool, originProtocol: String, originHost: String) -> Bool {
        isMainFrame && originProtocol == scheme && originHost == host
    }

    /// The media-capture rule: the microphone, for our own page's main frame.
    static func grantsCapture(isMainFrame: Bool, originProtocol: String, originHost: String, type: WKMediaCaptureType) -> Bool {
        isMainFrame && originProtocol == scheme && originHost == host && type == .microphone
    }
}

// MARK: - WKUIDelegate (microphone permission)

extension WebViewVoiceMediaBridge: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let grant = Self.grantsCapture(isMainFrame: frame.isMainFrame, originProtocol: origin.protocol,
                                       originHost: origin.host, type: type)
        decisionHandler(grant ? .grant : .deny)
    }
}

// MARK: - WKNavigationDelegate (our page only; process death)

extension WebViewVoiceMediaBridge: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let ours = url?.scheme == Self.scheme && url?.host == Self.host
        decisionHandler(ours ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLost()
        onEvent?(.transportClosed(reason: "web_process_terminated"))
    }
}

/// `WKUserContentController` retains its handlers strongly; this proxy keeps
/// the bridge free to deallocate.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebViewVoiceMediaBridge?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.receive(message)
        }
    }
}

// MARK: - The page

/// Serves the bundled `voice-live.html` at `scarf-voice://live/index.html`
/// and nothing else.
final class VoiceLivePageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, Self.serves(url), let page = VoiceLivePage.html,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": "text/html; charset=utf-8",
                  "Cache-Control": "no-store",
              ]) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(page)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    static func serves(_ url: URL) -> Bool {
        url.scheme == WebViewVoiceMediaBridge.scheme && url.host == WebViewVoiceMediaBridge.host
            && (url.path == "/index.html" || url.path == "/" || url.path.isEmpty)
    }
}

/// The bundled media page (`VoiceLive/Resources/voice-live.html`).
enum VoiceLivePage {
    static let html: Data? = {
        guard let url = Bundle.module.url(forResource: "voice-live", withExtension: "html") else { return nil }
        return try? Data(contentsOf: url)
    }()
}

// MARK: - Hosting view

/// Put this inside the voice panel (anywhere in the window) for the whole
/// session: it keeps the bridge's web view in the view hierarchy at 1×1,
/// alpha 0, which WebKit needs to play the remote audio. It draws nothing
/// and takes no input or accessibility focus.
public struct VoiceLiveMediaHostView: View {
    private let bridge: WebViewVoiceMediaBridge

    public init(bridge: WebViewVoiceMediaBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        WebViewHost(webView: bridge.webView)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if os(macOS)
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.alphaValue = 0
        container.addSubview(webView)
    }
}
#elseif os(iOS)
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.isUserInteractionEnabled = false
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.alpha = 0
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        container.addSubview(webView)
    }
}
#endif
#endif
