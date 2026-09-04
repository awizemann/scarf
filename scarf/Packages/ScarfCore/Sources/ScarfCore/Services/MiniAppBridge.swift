import Foundation

/// The pure, WebKit-free core of the `window.scarf` bridge: the method
/// registry, the default-deny permission gate, the reply model, and the
/// injected JS shim. The Mac-target `ScarfMiniAppBridge`
/// (`WKScriptMessageHandlerWithReply`) is a thin shell that decodes a
/// message, runs it through `MiniAppBridgeDispatcher.preflight`, and — if
/// authorized — executes the handler and replies.
///
/// Keeping the trust boundary here makes it unit-testable without a
/// `WKWebView`: every bridge call is permission-checked host-side, and
/// **default-deny** is the rule — a surface a mini-app didn't declare AND
/// the user didn't grant is refused before any handler runs.

/// Semver of the bridge contract. Mini-apps check it via `scarf.version`
/// and declare `minBridgeVersion`; the host refuses/degrades on mismatch.
/// 1.1 added `scarf.openURL` (the `open_url` permission). Minors are
/// additive, so a 1.0 mini-app still runs unchanged on a 1.1 host; an app
/// that needs `openURL` declares `"minBridgeVersion": "1.1"` and is refused
/// (with an explanation) by an older Scarf rather than half-working.
public let miniAppBridgeVersion = "1.1"

// MARK: - Methods

/// Every `window.scarf` surface, as a wire method string, with its
/// required permission (nil = ungated baseline surface) and whether this
/// build implements it yet. Adding a method here + handling it in the
/// WebKit layer is the only way to extend the bridge.
public enum MiniAppBridgeMethod: String, CaseIterable, Sendable {
    case contextGet = "context.get"
    case uiToast = "ui.toast"
    case uiSetTitle = "ui.setTitle"
    case uiResize = "ui.resize"
    case uiRequestClose = "ui.requestClose"
    case storeGet = "store.get"
    case storeSet = "store.set"
    case promptSend = "prompt.send"
    case eventsSubscribe = "events.subscribe"
    case query = "query"
    case fileRead = "file.read"
    case kanbanRead = "kanban.read"
    case openURL = "open.url"

    /// Permission this method requires, or `nil` for ungated baseline
    /// surfaces (context + benign UI affordances carry no permission —
    /// they expose no secrets and reach nothing outside the host frame).
    public var requiredPermission: MiniAppPermission? {
        switch self {
        case .contextGet, .uiToast, .uiSetTitle, .uiResize, .uiRequestClose:
            return nil
        case .storeGet, .storeSet:
            return .store
        case .promptSend:
            return .prompt
        case .eventsSubscribe:
            return .events
        case .fileRead:
            return .fileRead
        case .kanbanRead:
            return .query("kanban.tasks")
        case .openURL:
            return .openURL
        case .query:
            // The concrete `query:<kind>` permission depends on the call's
            // `kind` argument, so it's enforced in the handler.
            return nil
        }
    }

    /// Whether the WebKit layer wires this method. All current surfaces are
    /// implemented; this remains as the guard a future surface must satisfy
    /// (and the `not_implemented` reply path is the fail-closed default for
    /// anything added but not yet wired).
    public var isImplemented: Bool {
        switch self {
        case .contextGet, .uiToast, .uiSetTitle, .uiResize, .uiRequestClose,
             .storeGet, .storeSet, .promptSend, .eventsSubscribe,
             .query, .fileRead, .kanbanRead, .openURL:
            return true
        }
        // A future surface added to the enum must decide its status here.
    }
}

// MARK: - Reply

public enum MiniAppBridgeErrorCode: String, Sendable {
    case permissionDenied = "permission_denied"
    case notImplemented = "not_implemented"
    case badRequest = "bad_request"
    case internalError = "internal_error"
    /// The host-side sliding-window limit refused this call (see
    /// `MiniAppRateLimiter`). Distinct from `permission_denied`: the grant
    /// is fine, the pace is not.
    case rateLimited = "rate_limited"
    /// The user was asked and said no — or a confirmation was already on
    /// screen, so this request was dropped rather than queued behind it.
    /// Never retried automatically by the shim.
    case userDenied = "user_denied"
}

/// Host → web reply. `result` is a JSON string (the shim `JSON.parse`s it);
/// a failure rejects the JS promise with `code: message`.
public struct MiniAppBridgeReply: Sendable, Equatable {
    public let ok: Bool
    public let result: String?
    public let errorCode: String?
    public let errorMessage: String?

    public static func success(_ result: String?) -> MiniAppBridgeReply {
        MiniAppBridgeReply(ok: true, result: result, errorCode: nil, errorMessage: nil)
    }

    public static func failure(_ code: MiniAppBridgeErrorCode, _ message: String) -> MiniAppBridgeReply {
        MiniAppBridgeReply(ok: false, result: nil, errorCode: code.rawValue, errorMessage: message)
    }
}

// MARK: - Dispatcher (the trust boundary)

/// Authorizes bridge calls against the user-granted permission set.
/// Default-deny: anything not granted is refused. Construct with the set
/// the user approved at the permission-preview sheet (empty until that
/// sheet ships — so only ungated baseline surfaces work, which is the
/// correct secure default).
public struct MiniAppBridgeDispatcher: Sendable {
    public let grantedPermissions: Set<MiniAppPermission>

    public init(grantedPermissions: Set<MiniAppPermission>) {
        self.grantedPermissions = grantedPermissions
    }

    /// Returns `nil` when the call is authorized AND implemented (caller
    /// proceeds to run it); otherwise a failure reply to send back. Order
    /// matters: permission is checked BEFORE implementation status so an
    /// ungranted call to a future surface still reads as denied, never
    /// leaking which surfaces exist.
    public func preflight(_ method: MiniAppBridgeMethod) -> MiniAppBridgeReply? {
        if let required = method.requiredPermission, !grantedPermissions.contains(required) {
            return .failure(.permissionDenied, "Permission '\(required.rawValue)' is not granted to this mini-app.")
        }
        if !method.isImplemented {
            return .failure(.notImplemented, "\(method.rawValue) is not available in this build yet.")
        }
        return nil
    }
}

// MARK: - Readonly context

/// The readonly `scarf.context` object injected at document start. No
/// secrets — project identity + provenance only. (`sessionId`,
/// `capabilities`, `locale`, `theme` arrive with later increments.)
public struct MiniAppContext: Codable, Sendable, Equatable {
    public var bridgeVersion: String
    public var projectId: String
    public var projectName: String
    public var projectRoot: String
    public var serverId: String
    public var miniAppId: String
    public var generated: Bool

    public init(
        bridgeVersion: String = miniAppBridgeVersion,
        projectId: String,
        projectName: String,
        projectRoot: String,
        serverId: String,
        miniAppId: String,
        generated: Bool
    ) {
        self.bridgeVersion = bridgeVersion
        self.projectId = projectId
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.serverId = serverId
        self.miniAppId = miniAppId
        self.generated = generated
    }
}

// MARK: - JS shim

public enum MiniAppBridge {
    /// `WKScriptMessageHandler` name the shim posts to.
    public static let messageHandlerName = "scarfbridge"

    /// Whether this host's bridge satisfies a manifest's `minBridgeVersion`
    /// — checked at mount so a mini-app built against a newer contract is
    /// refused rather than silently half-working. The host must be at least
    /// the required `major.minor` (within a major, minors are additive, so
    /// a higher host minor still satisfies a lower required one).
    public static func satisfiesMinBridgeVersion(_ required: String) -> Bool {
        func tuple(_ s: String) -> (Int, Int) {
            let parts = s.split(separator: ".", maxSplits: 1).map { Int($0.prefix(while: \.isNumber)) ?? 0 }
            return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
        }
        let host = tuple(miniAppBridgeVersion)
        let req = tuple(required)
        return host.0 > req.0 || (host.0 == req.0 && host.1 >= req.1)
    }

    /// The `window.scarf` shim, injected at document start with the
    /// frozen `context` baked in. Async methods post `{method, args}` to
    /// the native handler and return its reply promise; `args` are strings
    /// (complex values are `JSON.stringify`-ed by the shim and re-parsed
    /// native-side / here), so the native wire stays string-typed.
    public static func javaScriptSource(context: MiniAppContext) -> String {
        let contextJSON: String
        if let data = try? JSONEncoder().encode(context),
           let json = String(data: data, encoding: .utf8) {
            contextJSON = json
        } else {
            contextJSON = "{}"
        }
        return """
        (function () {
          "use strict";
          const post = (method, args) =>
            window.webkit.messageHandlers.\(messageHandlerName).postMessage({ method: method, args: args || [] });
          // Live agent-event fan-out for scarf.onEvent. The host pushes
          // events by calling window.__scarfEmit via evaluateJavaScript.
          const __listeners = [];
          window.__scarfEmit = function (ev) {
            for (let i = 0; i < __listeners.length; i++) {
              try { __listeners[i](ev); } catch (e) { /* a listener throwing is the mini-app's concern */ }
            }
          };
          const api = {
            version: "\(miniAppBridgeVersion)",
            context: Object.freeze(\(contextJSON)),
            store: Object.freeze({
              get: async (key) => {
                const r = await post("store.get", [String(key)]);
                return (r === null || r === undefined || r === "") ? null : JSON.parse(r);
              },
              set: async (key, value) => {
                await post("store.set", [String(key), JSON.stringify(value === undefined ? null : value)]);
                return true;
              }
            }),
            ui: Object.freeze({
              toast: (msg) => post("ui.toast", [String(msg)]),
              setTitle: (title) => post("ui.setTitle", [String(title)]),
              resize: (w, h) => post("ui.resize", [String(w), String(h)]),
              requestClose: () => post("ui.requestClose", [])
            }),
            prompt: async (text, opts) => post("prompt.send", [String(text), JSON.stringify(opts || {})]),
            // Hand one https URL to the user's default browser. Requires
            // the `open_url` permission AND the user's confirmation of the
            // destination host; resolves only once something actually
            // opened, and rejects (user_denied / rate_limited /
            // bad_request) otherwise. Call it FROM A CLICK — a burst is
            // rate-limited and a second call while a confirmation is on
            // screen is dropped, not queued.
            openURL: async (url) => post("open.url", [String(url)]),
            query: async (kind, params) => {
              const r = await post("query", [String(kind), JSON.stringify(params || {})]);
              return (r === null || r === undefined || r === "") ? null : JSON.parse(r);
            },
            file: Object.freeze({
              read: async (path) => post("file.read", [String(path)])
            }),
            kanban: Object.freeze({
              read: async () => {
                const r = await post("kanban.read", []);
                return (r === null || r === undefined || r === "") ? [] : JSON.parse(r);
              }
            }),
            onEvent: (cb) => {
              if (typeof cb === "function") {
                __listeners.push(cb);
                // onEvent has no return value to hand the caller, so the
                // subscribe promise is ours to settle: without this catch a
                // denied `events` permission surfaces as an unhandled
                // rejection in every mini-app that calls onEvent.
                post("events.subscribe", []).catch((e) => {
                  console.warn("scarf.onEvent: " + (e && e.message ? e.message : e));
                });
              }
            }
          };
          Object.defineProperty(window, "scarf", { value: Object.freeze(api), writable: false, configurable: false });
        })();
        """
    }
}
