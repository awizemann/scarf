import AppKit
import Foundation
import WebKit
import ScarfCore
import os

/// Host-side `window.scarf` bridge — the `WKScriptMessageHandlerWithReply`
/// that backs the JS shim. Decodes each `{method, args}` message, runs it
/// through `MiniAppBridgeDispatcher.preflight` (the default-deny trust
/// boundary in ScarfCore), and — only if authorized + implemented —
/// executes the handler and replies. A denied call rejects the JS promise
/// with `code: message`; nothing reaches a service before the gate.
///
/// All surfaces are wired: `context`, `store` (sandboxed KV), `ui.*`, the
/// agent channel (`prompt` via a dedicated session, `onEvent` streaming),
/// and the read-only data channel (`file.read`, `query`/`kanban.read` for
/// `kanban.tasks`). Privacy-sensitive query kinds (sessions/messages/…)
/// remain fail-closed pending a deliberate decision.
final class ScarfMiniAppBridge: NSObject, WKScriptMessageHandlerWithReply {
    private static let logger = Logger(subsystem: "com.scarf", category: "ScarfMiniAppBridge")

    /// Largest project file `scarf.file.read` will return.
    private static let maxFileReadBytes = 4 * 1024 * 1024

    /// At most this many `openURL` requests per minute, granted or not.
    /// Lower than the prompt limiter: every one of these is a modal
    /// question aimed at the user, and a human clicks links slowly.
    private static let openURLLimiter = MiniAppRateLimiter(maxEvents: 5, windowSeconds: 60)

    private let projectPath: String
    private let miniAppId: String
    /// The project UUID, for the open-url host consent records (the same
    /// id `scarf.context.projectId` reports).
    private let projectId: String
    /// Per-(project, host) "Always Allow" records for `scarf.openURL`,
    /// HMAC-tagged with the machine key — the mini-app can write the
    /// defaults plist, but it cannot mint a tag, so a planted record is
    /// ignored and the user is asked. Separate `Purpose` from the image
    /// widget's records: allowing an image host does not allow opening
    /// links to it.
    private let openURLConsent = ImageHostConsentStore(purpose: .openURL)
    /// Timestamps of accepted `openURL` calls, for the sliding window.
    /// Main-thread only (every bridge call arrives there).
    private var openURLHistory: [Date] = []
    /// One confirmation at a time. A mini-app that calls `openURL` in a
    /// loop must not be able to stack a wall of modal sheets over the
    /// user's window (each of which is a chance to mis-click "Open"), so a
    /// request that arrives while one is up is REFUSED, not queued.
    private var isOpenURLConfirmationPending = false
    private let serverContext: ServerContext
    private let dispatcher: MiniAppBridgeDispatcher
    private let store: MiniAppStore
    private let contextJSON: String
    /// Dedicated agent session backing `scarf.prompt`. Lazily spawns its
    /// own `hermes acp` on first use; `nil` only in contexts that never
    /// grant `prompt`.
    private let agentSession: MiniAppAgentSession?
    /// Invoked on the main thread for `ui.*` calls. Host wires real UI
    /// (toast/close) later; defaults to logging.
    private let onUIAction: (MiniAppUIAction) -> Void
    /// Set by the host once the webview exists, so streamed agent events can
    /// be pushed into the page. Weak: the userContentController already
    /// retains this handler, so a strong ref back would cycle.
    weak var webView: WKWebView?

    init(
        projectPath: String,
        miniAppId: String,
        serverContext: ServerContext,
        dispatcher: MiniAppBridgeDispatcher,
        store: MiniAppStore,
        context: MiniAppContext,
        agentSession: MiniAppAgentSession?,
        onUIAction: @escaping (MiniAppUIAction) -> Void
    ) {
        self.projectPath = projectPath
        self.miniAppId = miniAppId
        self.projectId = context.projectId
        self.serverContext = serverContext
        self.dispatcher = dispatcher
        self.store = store
        self.agentSession = agentSession
        self.onUIAction = onUIAction
        if let data = try? JSONEncoder().encode(context), let json = String(data: data, encoding: .utf8) {
            self.contextJSON = json
        } else {
            self.contextJSON = "{}"
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // Called on the main thread by WebKit. Decode the wire envelope,
        // then hand off to `dispatch` — the WebKit-free seam that owns the
        // trust boundary + handler routing (and is what the tests drive,
        // since a `WKScriptMessage` can't be constructed in a test).

        // MAIN FRAME ONLY. The user script is injected with
        // `forMainFrameOnly: true`, but a message handler is registered on
        // the whole content world: any subframe the mini-app manages to
        // create can still `postMessage` this handler directly and reach
        // the granted surfaces (file.read, prompt, …) without the shim. The
        // grant was reviewed for the mini-app's own document, so refuse
        // anything that isn't it.
        guard message.frameInfo.isMainFrame else {
            Self.logger.warning("rejected bridge call from a non-main frame")
            replyHandler(nil, "permission_denied: bridge is main-frame only")
            return
        }

        guard let body = message.body as? [String: Any],
              let methodString = body["method"] as? String,
              let method = MiniAppBridgeMethod(rawValue: methodString) else {
            replyHandler(nil, "bad_request: malformed bridge message")
            return
        }
        // Args are strictly `[String]`. The previous `compactMap { $0 as?
        // String }` silently DROPPED non-string entries, which SHIFTS every
        // later argument left — `store.set(null, secret)` arrived as
        // `store.set(secret)`, i.e. a positional-argument confusion the
        // page controls. Reject the whole call instead.
        let rawArgs = body["args"]
        let args: [String]
        if rawArgs == nil || rawArgs is NSNull {
            args = []
        } else if let strings = rawArgs as? [String] {
            args = strings
        } else {
            replyHandler(nil, "bad_request: args must be an array of strings")
            return
        }
        dispatch(method: method, args: args, reply: replyHandler)
    }

    /// Run one decoded bridge call: enforce the permission gate, then — only
    /// if authorized + implemented — execute the handler and `reply`. The
    /// `reply` closure is invoked exactly once (`reply(result, nil)` for
    /// success, `reply(nil, "code: message")` for failure). Expects to be
    /// called on the main thread (`ui.*` and the synchronous reply paths
    /// assume it); async surfaces hop back to main before replying.
    func dispatch(
        method: MiniAppBridgeMethod,
        args: [String],
        reply: @escaping (Any?, String?) -> Void
    ) {
        // The trust boundary: deny anything not granted / not implemented.
        if let denial = dispatcher.preflight(method) {
            reply(nil, "\(denial.errorCode ?? "error"): \(denial.errorMessage ?? "")")
            return
        }

        switch method {
        case .contextGet:
            reply(contextJSON, nil)

        case .storeGet:
            guard let key = args.first else { reply(nil, "bad_request: store.get needs a key"); return }
            let store = store, projectPath = projectPath, id = miniAppId
            DispatchQueue.global(qos: .userInitiated).async {
                let value = store.get(projectPath: projectPath, miniAppId: id, key: key)
                DispatchQueue.main.async { reply(value, nil) }
            }

        case .storeSet:
            guard args.count >= 2 else { reply(nil, "bad_request: store.set needs key and value"); return }
            let key = args[0], value = args[1]
            let store = store, projectPath = projectPath, id = miniAppId
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try store.set(projectPath: projectPath, miniAppId: id, key: key, value: value)
                    DispatchQueue.main.async { reply(nil, nil) }
                } catch {
                    DispatchQueue.main.async { reply(nil, "internal_error: \(error.localizedDescription)") }
                }
            }

        case .uiToast:
            onUIAction(.toast(args.first ?? ""))
            reply(nil, nil)
        case .uiSetTitle:
            onUIAction(.setTitle(args.first ?? ""))
            reply(nil, nil)
        case .uiResize:
            onUIAction(.resize(width: args.count > 0 ? Double(args[0]) : nil,
                               height: args.count > 1 ? Double(args[1]) : nil))
            reply(nil, nil)
        case .uiRequestClose:
            onUIAction(.requestClose)
            reply(nil, nil)

        case .promptSend:
            guard let agentSession else {
                reply(nil, "internal_error: no agent session bound")
                return
            }
            let text = args.first ?? ""
            Task {
                do {
                    let result = try await agentSession.prompt(text)
                    await MainActor.run { reply(result, nil) }
                } catch {
                    await MainActor.run { reply(nil, "error: \(error.localizedDescription)") }
                }
            }

        case .eventsSubscribe:
            guard let agentSession else {
                reply(nil, "internal_error: no agent session bound")
                return
            }
            Task { [self] in
                await agentSession.setEventSink { [weak self] event in
                    // Deliver to main in FIFO order. The actor emits events
                    // serially in wire order; a per-event `Task { @MainActor }`
                    // does NOT preserve that order (independent jobs race onto
                    // the main executor) and would garble streamed output.
                    // `DispatchQueue.main` IS FIFO; `assumeIsolated` lets us
                    // call MainActor-isolated `emitToWeb` once we're on main.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.emitToWeb(event) } }
                }
                await MainActor.run { reply(nil, nil) }
            }

        case .fileRead:
            // Read-only, contained to the project root via the same
            // symlink-hardened resolver the asset server uses.
            guard let rel = args.first else {
                reply(nil, "bad_request: file.read needs a path"); return
            }
            let projectPath = projectPath
            // Locality is a PRECONDITION, not a detail. The read below is
            // `open(2)` on this Mac; for a project whose files live on an
            // SSH host, `projectPath` would name a local file of the same
            // name — a different file entirely — so a remote project must
            // refuse rather than answer with the wrong machine's bytes.
            let isLocal: Bool
            switch serverContext.kind {
            case .local: isLocal = true
            case .ssh: isLocal = false
            }
            guard isLocal else {
                reply(nil, "not_supported: file.read is only available for projects on this Mac")
                return
            }
            // Time-of-use anchor. `projectPath` came from a registry row and
            // `projects.json` is agent-writable, so a row rewritten to
            // `/Users/me` would make "contained by the project root" mean
            // "anywhere in the user's home" — and a project root that is
            // ITSELF a symlink would relocate containment the same way. The
            // anchor re-runs `ProjectRootPolicy` AND freezes the resolved
            // base, so the `F_GETPATH` check below compares against a base
            // that can't be moved between the check and the read. Refuse and
            // say why — the project itself stays in the sidebar.
            let anchored = MiniAppAssetResolver.anchor(
                baseDirectory: projectPath, context: serverContext
            )
            guard case .success(let anchor) = anchored else {
                let message: String
                if case .failure(let refusal) = anchored { message = refusal.message } else { message = "" }
                Self.logger.error("refusing file.read: \(message, privacy: .public)")
                reply(nil, "permission_denied: \(message)")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                // Single fd: contained, `O_NOFOLLOW`, fstat-validated,
                // `F_GETPATH`-rechecked against the FROZEN anchor, then
                // read. Closes the symlink-flip window the old
                // check-path-then-open-path shape left open.
                guard case .success(let file) = MiniAppAssetResolver.readContainedFile(
                    requestPath: rel,
                    anchor: anchor,
                    maxBytes: Self.maxFileReadBytes
                ), let text = String(data: file.data, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        reply(nil, "not_found: file is missing, too large, outside the project, or not UTF-8 text")
                    }
                    return
                }
                DispatchQueue.main.async { reply(text, nil) }
            }

        case .query:
            // query's permission is the kind-specific query:<kind>, so it's
            // gated here (preflight passes it through with a nil static perm).
            guard let kind = args.first else {
                reply(nil, "bad_request: query needs a kind"); return
            }
            guard dispatcher.grantedPermissions.contains(.query(kind)) else {
                reply(nil, "permission_denied: query:\(kind) is not granted")
                return
            }
            handleQuery(kind: kind, replyHandler: reply)

        case .kanbanRead:
            // Gated by preflight on query:kanban.tasks.
            handleQuery(kind: "kanban.tasks", replyHandler: reply)

        case .openURL:
            // Gated by preflight on `open_url`. The grant only buys the
            // right to ASK; the destination is confirmed below.
            handleOpenURL(raw: args.first ?? "", reply: reply)
        }
    }

    // MARK: - scarf.openURL

    /// Ask to hand one https URL to the user's default browser.
    ///
    /// Three gates, in this order, and all three must pass:
    /// 1. **The grant.** `open_url`, checked in `preflight` before we get
    ///    here, like every other surface.
    /// 2. **The shape.** `MiniAppOpenURLPolicy` — https only, real ASCII
    ///    host, no embedded credentials, capped, no control characters. A
    ///    URL that doesn't fit is refused, never repaired.
    /// 3. **The destination.** The user confirms the host, with the URL in
    ///    front of them, unless they previously chose "Always Allow" for
    ///    that host in this project.
    ///
    /// Plus a pace limit and a one-at-a-time rule, because this is the one
    /// bridge surface that puts a modal question on the user's screen: a
    /// mini-app calling it in a loop would otherwise be a dialog cannon.
    ///
    /// It cannot fire on its own. Nothing here runs except from a bridge
    /// call the page makes, and the page only makes one because something
    /// in it ran — so a load-time `scarf.openURL` is possible and lands on
    /// exactly the same confirmation, with the same host named, that a
    /// clicked one does. The user's answer is the gate, not the gesture.
    private func handleOpenURL(raw: String, reply: @escaping (Any?, String?) -> Void) {
        let approved: MiniAppOpenURLPolicy.Approved
        switch MiniAppOpenURLPolicy.validate(raw) {
        case .failure(let refusal):
            Self.logger.warning("refused mini-app openURL: \(refusal.rawValue, privacy: .public)")
            reply(nil, "\(MiniAppBridgeErrorCode.badRequest.rawValue): \(refusal.message)")
            return
        case .success(let ok):
            approved = ok
        }

        // Pace limit BEFORE anything is shown or opened, and it counts the
        // already-allowed hosts too — "Always Allow example.com" is not a
        // licence to open fifty tabs.
        let (allowed, history) = Self.openURLLimiter.decide(now: Date(), history: openURLHistory)
        openURLHistory = history
        guard allowed else {
            reply(nil, "\(MiniAppBridgeErrorCode.rateLimited.rawValue): too many link requests; try again in a moment")
            return
        }

        if openURLConsent.isAllowed(url: approved.url, projectId: projectId) {
            open(approved.url, reply: reply)
            return
        }

        guard !isOpenURLConfirmationPending else {
            reply(nil, "\(MiniAppBridgeErrorCode.userDenied.rawValue): a link confirmation is already open")
            return
        }
        isOpenURLConfirmationPending = true
        confirm(approved) { [weak self] decision in
            // The reply MUST be settled even if the mini-app was torn down
            // while its sheet was up — an unanswered promise is a hung
            // `await` in the page, and "we're going away" is a no.
            guard let self else {
                reply(nil, "\(MiniAppBridgeErrorCode.userDenied.rawValue): the mini-app closed")
                return
            }
            self.isOpenURLConfirmationPending = false
            switch decision {
            case .cancel:
                reply(nil, "\(MiniAppBridgeErrorCode.userDenied.rawValue): the user declined to open this link")
            case .once:
                self.open(approved.url, reply: reply)
            case .always:
                // A failed record is not a failed open: the user said yes
                // to THIS link either way; they will just be asked again
                // next time (the same direction the grant store takes when
                // it can't sign).
                if self.openURLConsent.allow(url: approved.url, projectId: self.projectId) == nil {
                    Self.logger.warning("couldn't record the open-url host consent; it will be asked again")
                }
                self.open(approved.url, reply: reply)
            }
        }
    }

    private enum OpenURLDecision { case cancel, once, always }

    /// "Open example.com in your browser?" — host first (it is the decision),
    /// full URL below it (it is what actually travels: the path and query go
    /// to that host on the click, and the user is entitled to see them).
    ///
    /// Presented as a sheet on the mini-app's own window when there is one,
    /// so it is unmistakably attached to the app that asked. `completion`
    /// runs on the main thread, exactly once.
    private func confirm(
        _ approved: MiniAppOpenURLPolicy.Approved,
        completion: @escaping (OpenURLDecision) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Open \(approved.host) in your browser?")
        // The mini-app id is a DIRECTORY NAME in an agent-writable folder,
        // so it is sanitized (control characters, bidi overrides, length)
        // before it goes anywhere near this sentence — same treatment the
        // permission sheet gives an unknown permission string. Without it,
        // an app could name itself into a second sentence and reframe the
        // question the user is answering.
        alert.informativeText = String(
            localized: "“\(MiniAppPermission.displaySafe(miniAppId))” wants to open this link:\n\(MiniAppOpenURLPolicy.displayString(approved.url))"
        )
        alert.addButton(withTitle: String(localized: "Open Once"))
        alert.addButton(withTitle: String(localized: "Always Allow \(approved.host)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        // Cancel is the escape key AND the safe answer; Open Once is first
        // (the default) because the user got here by asking for a link.
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        let decide: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: completion(.once)
            case .alertSecondButtonReturn: completion(.always)
            default: completion(.cancel)
            }
        }
        if let window = webView?.window {
            alert.beginSheetModal(for: window) { decide($0) }
        } else {
            decide(alert.runModal())
        }
    }

    /// Hand the URL to Launch Services. `NSWorkspace.open` is asynchronous
    /// internally (it returns as soon as the request is dispatched), so
    /// this is fine on the main actor — the browser launch does not block
    /// the window (charter C10).
    private func open(_ url: URL, reply: @escaping (Any?, String?) -> Void) {
        // The URL itself is `.private`: it is page-authored and may carry a
        // query the mini-app composed, which must not be laundered into the
        // system log.
        Self.logger.info("opening mini-app link in the default browser: \(url.absoluteString, privacy: .private)")
        guard NSWorkspace.shared.open(url) else {
            reply(nil, "\(MiniAppBridgeErrorCode.internalError.rawValue): no application could open this link")
            return
        }
        reply(nil, nil)
    }

    // MARK: - Event streaming (scarf.onEvent)

    /// Push one streamed agent event into the page. Always called ON the main
    /// actor — the event sink hops via `DispatchQueue.main` + `assumeIsolated`,
    /// which preserves FIFO order across the serial event stream. A closed
    /// mini-app (weak webview) silently drops late events.
    private func emitToWeb(_ event: ACPEvent) {
        guard let json = Self.eventJSON(event) else { return }
        webView?.evaluateJavaScript("window.__scarfEmit(\(json))", completionHandler: nil)
    }

    /// Serialize the subset of agent events a mini-app renders into a JSON
    /// literal. Returns `nil` for events that aren't forwarded (e.g.
    /// permission requests, which are auto-handled host-side).
    private static func eventJSON(_ event: ACPEvent) -> String? {
        let obj: [String: Any]
        switch event {
        case .messageChunk(_, let text, _, _): obj = ["type": "message", "text": text]
        case .thoughtChunk(_, let text): obj = ["type": "thought", "text": text]
        case .toolCallStart(_, let call): obj = ["type": "tool", "title": call.title, "status": call.status]
        case .toolCallUpdate: obj = ["type": "tool_update"]
        case .promptComplete: obj = ["type": "complete"]
        default: return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    // MARK: - Data channel (scarf.query / scarf.kanban)

    /// Resolve a whitelisted, read-only data `kind` to a JSON array string.
    /// v1 serves `kanban.tasks` (project-scoped, Codable). Sensitive kinds
    /// (sessions/messages/insights) are deferred pending a privacy review —
    /// chat content must not be exposed to untrusted web content lightly.
    private func handleQuery(kind: String, replyHandler: @escaping (Any?, String?) -> Void) {
        switch kind {
        case "kanban.tasks":
            let ctx = serverContext
            let projectPath = projectPath
            Task {
                do {
                    // Scope to the project's kanban tenant; no tenant → no
                    // project board yet → empty result.
                    guard let tenant = KanbanTenantReader(context: ctx).tenant(forProjectPath: projectPath) else {
                        await MainActor.run { replyHandler("[]", nil) }
                        return
                    }
                    let tasks = try await KanbanService(context: ctx).list(KanbanListFilter(tenant: tenant))
                    let json = String(data: try JSONEncoder().encode(tasks), encoding: .utf8) ?? "[]"
                    await MainActor.run { replyHandler(json, nil) }
                } catch {
                    await MainActor.run { replyHandler(nil, "internal_error: \(error.localizedDescription)") }
                }
            }
        default:
            replyHandler(nil, "not_implemented: query:\(kind) is not available in this build")
        }
    }
}

/// A `ui.*` action a mini-app requested. The host decides how to surface
/// each (toast banner, window title, panel resize, close request).
enum MiniAppUIAction: Sendable {
    case toast(String)
    case setTitle(String)
    case resize(width: Double?, height: Double?)
    case requestClose

    /// The action's KIND, with no page-supplied payload in it — safe to log
    /// at `privacy: .public`. The payloads (toast text, window title) are
    /// authored by untrusted web content and must never be interpolated
    /// publicly into the system log.
    var kind: String {
        switch self {
        case .toast: return "toast"
        case .setTitle: return "setTitle"
        case .resize: return "resize"
        case .requestClose: return "requestClose"
        }
    }

    /// The page-controlled payload, for `privacy: .private` logging only.
    var payloadDescription: String {
        switch self {
        case .toast(let text): return text
        case .setTitle(let title): return title
        case .resize(let w, let h):
            let width = w.map { String($0) } ?? "nil"
            let height = h.map { String($0) } ?? "nil"
            return "w=\(width) h=\(height)"
        case .requestClose: return ""
        }
    }
}
