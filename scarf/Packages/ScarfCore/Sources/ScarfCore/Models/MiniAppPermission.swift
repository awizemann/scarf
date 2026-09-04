import Foundation

/// One bridge surface a mini-app declares in `miniapp.json.permissions`.
///
/// The trust boundary for Cowork-style mini-apps (untrusted web content,
/// *especially* agent-generated) is **default-deny**: every `window.scarf`
/// surface a mini-app touches must be declared here and approved by the
/// user before first run. Web content can never reach secrets,
/// `config.yaml`, `auth.json`, arbitrary filesystem, or Hermes tools —
/// regardless of what it declares.
///
/// Wire form is a flat string (e.g. `"prompt"`, `"query:kanban.tasks"`,
/// `"kanban:write"`), so the enum is `Codable` as a single value via
/// `rawValue`/`init(rawValue:)`. Unrecognized strings decode to
/// `.unknown(raw)` rather than being dropped — an unknown permission is
/// surfaced (and denied) at the preview sheet, never silently swallowed.
public enum MiniAppPermission: Codable, Sendable, Hashable {
    /// Send a prompt to the bound ACP session (`scarf.prompt`). Rate-limited host-side.
    case prompt
    /// Subscribe to the bound session's streamed ACP events (`scarf.onEvent`).
    case events
    /// Read a whitelisted data `kind` (`scarf.query(kind, …)`) — never arbitrary SQL.
    /// The associated value is the raw kind string (e.g. `sessions`,
    /// `messages`, `kanban.tasks`, `cron.jobs`, `insights.tokens`).
    case query(String)
    /// Mutate kanban (move/create). Deferred behind this explicit grant —
    /// read-only is the v1 default (see Mini-App Bridge Contract decisions).
    case kanbanWrite
    /// Read a file under the project root (`scarf.file.read`), read-only.
    case fileRead
    /// Write a file under the project root (`scarf.file.write`). Sensitive.
    case fileWrite
    /// Per-(project, mini-app) persisted KV (`scarf.store.get/set`).
    case store
    /// Outbound network — only honored with an allowlist. Sensitive.
    case net
    /// A permission string this build doesn't recognize. Preserved verbatim
    /// so the preview sheet can show it and the host can hard-deny it.
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .prompt: return "prompt"
        case .events: return "events"
        case .query(let kind): return "query:\(kind)"
        case .kanbanWrite: return "kanban:write"
        case .fileRead: return "file:read"
        case .fileWrite: return "file:write"
        case .store: return "store"
        case .net: return "net"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "prompt": self = .prompt
        case "events": self = .events
        case "kanban:write": self = .kanbanWrite
        case "file:read": self = .fileRead
        case "file:write": self = .fileWrite
        case "store": self = .store
        case "net": self = .net
        default:
            if trimmed.hasPrefix("query:") {
                let kind = String(trimmed.dropFirst("query:".count))
                // CONSENT-SURFACE CHARSET GATE (P8 SEC-L4). The kind is a
                // free string out of an agent-written `miniapp.json`, and
                // the permission sheet renders it VERBATIM: "Read <kind>
                // (read-only)". Without a charset it can carry newlines,
                // RTL overrides, or a sentence of its own — a spoofing
                // surface on the one screen where the user is being asked
                // to trust something. It also used to be able to carry the
                // comma that broke the grant tag's injectivity (SEC-M2).
                // An out-of-shape kind is not repaired, it is demoted to
                // `.unknown`, which the sheet already renders as "will be
                // denied", counts as sensitive, and never pre-checks.
                self = Self.isValidQueryKind(kind) ? .query(kind) : .unknown(trimmed)
            } else {
                self = .unknown(trimmed)
            }
        }
    }

    /// The shape a query kind may take: lowercase letters, digits, `.`,
    /// `_` and `-`, starting with a letter, at most 64 characters. Covers
    /// every kind Scarf implements or has documented (`kanban.tasks`,
    /// `sessions`, `insights.tokens`, `cron.jobs`) and nothing that can
    /// misrepresent itself in a consent line.
    public static func isValidQueryKind(_ kind: String) -> Bool {
        guard !kind.isEmpty, kind.count <= 64,
              let first = kind.first, first.isASCII, first.isLowercase
        else { return false }
        return kind.allSatisfy { c in
            guard c.isASCII else { return false }
            return c.isLowercase || c.isNumber || c == "." || c == "_" || c == "-"
        }
    }

    /// A raw permission string rendered into UI, with anything that could
    /// misrepresent it removed: control characters and bidi/format
    /// overrides go, and the result is capped. Used for `.unknown`, whose
    /// whole point is preserving bytes we don't understand — preserving
    /// them for the ROUND-TRIP is right, showing them raw on the consent
    /// sheet is not.
    public static func displaySafe(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .filter { !(0x200B...0x200F).contains($0.value) && !(0x202A...0x202E).contains($0.value)
                && !(0x2066...0x2069).contains($0.value) }
        var out = String(String.UnicodeScalarView(cleaned))
        if out.count > 64 { out = String(out.prefix(64)) + "…" }
        return out
    }

    /// Query kind when this is a `.query`, else `nil`.
    public var queryKind: String? {
        if case .query(let kind) = self { return kind }
        return nil
    }

    /// Query kinds low-risk enough to stay non-sensitive (default-ON for
    /// agent-generated apps). Everything else — `sessions`, `messages`,
    /// `insights.*`, `cron.*`, or any unknown kind — is treated as sensitive
    /// so a privacy-relevant kind can never be granted-by-default to
    /// untrusted web the moment it's wired host-side. Today only
    /// `kanban.tasks` is implemented, and it's read-only board data.
    public static let nonSensitiveQueryKinds: Set<String> = ["kanban.tasks"]

    /// Surfaces that reach beyond a mini-app's own, structured, read-only
    /// data: outbound network, filesystem reads/writes, kanban mutation, and
    /// any non-allowlisted query kind. The preview sheet flags these with a
    /// warning and — for agent-generated mini-apps — leaves them UNCHECKED,
    /// so running such an app never silently grants one (`defaultChecked()`).
    public var isSensitive: Bool {
        switch self {
        // `prompt` drives a tool-enabled agent with web-supplied text — the
        // biggest escalation, so agent-generated apps don't get it by default.
        case .prompt, .net, .fileWrite, .kanbanWrite: return true
        // `file:read` is read-only and project-scoped, but "the project" is
        // not a low-value blast radius: `.env`, `*.pem`, `config.yaml`, and
        // credential-bearing dotfiles routinely live under the project root,
        // and a mini-app that can read them can also render them into a page
        // (or, with `prompt`, feed them to an agent). Whole-project read is
        // therefore a deliberate elevation, never a pre-ticked default for
        // agent-generated web content.
        case .fileRead: return true
        case .unknown: return true  // unrecognized → treat as sensitive (deny-by-default)
        // A query is non-sensitive only for an allow-listed read-only kind;
        // any other (or future privacy-relevant) kind defaults to sensitive.
        case .query(let kind): return !Self.nonSensitiveQueryKinds.contains(kind)
        case .events, .store: return false
        }
    }

    /// Short human description for the permission-preview sheet.
    /// ⚠️ ENGLISH TOKEN copy. ScarfCore has no string catalog, so nothing
    /// returned here is extractable. The consent sheet localizes per case —
    /// see `MiniAppPermission.localizedSummary` in `MiniAppLaunchView.swift`.
    /// Keep this for logs and tests; never bind it to a `Text`.
    public var summary: String {
        switch self {
        case .prompt: return "Send prompts to this chat's agent"
        case .events: return "Read this chat's streamed agent output"
        case .query(let kind): return "Read \(kind.isEmpty ? "data" : kind) (read-only)"
        case .kanbanWrite: return "Create and move kanban tasks"
        case .fileRead: return "Read any file inside the project"
        case .fileWrite: return "Write files inside the project"
        case .store: return "Save its own settings"
        case .net: return "Make outbound network requests"
        case .unknown(let raw): return "Unknown permission \"\(Self.displaySafe(raw))\" (will be denied)"
        }
    }

    // MARK: - Codable (single string)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(rawValue: try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
