import Foundation

/// One allowlist proposal mined by `hermes approvals suggest --json`
/// (v0.20+, caller gates on `HermesCapabilities.hasApprovalsSuggest`).
///
/// Mirrors the CLI's JSON payload exactly:
/// `{"n": 1, "pattern": "git push *", "kind": "glob", "count": 4,
///   "classes": ["git force push"], "examples": ["git push --force"]}`
/// `kind` is `"glob"` (a command glob) or `"class"` (a dangerous-class
/// description — the same key an interactive `[a]lways` answer persists).
public struct HermesApprovalProposal: Sendable, Equatable, Identifiable {
    /// 1-based index from the CLI output — this is the value `--apply N`
    /// consumes, so it must round-trip untouched.
    public let n: Int
    public let pattern: String
    public let kind: String
    public let count: Int
    public let classes: [String]
    public let examples: [String]

    public var id: Int { n }

    public init(n: Int, pattern: String, kind: String, count: Int, classes: [String], examples: [String]) {
        self.n = n
        self.pattern = pattern
        self.kind = kind
        self.count = count
        self.classes = classes
        self.examples = examples
    }
}

/// Parser + argv builder for `hermes approvals suggest` (Hermes v0.20+).
///
/// The suggest run is read-only (mines the session DB); only an explicit
/// `--apply N[,M...]` writes to `command_allowlist` in config.yaml —
/// Scarf therefore only ever emits `--apply` from a per-proposal user
/// click, never as a bulk default.
public enum HermesApprovalsSuggestParser {

    // MARK: - Argv builders

    /// `["approvals", "suggest", "--json", ("--days", N), ("--min-count", N)]`.
    /// Optional knobs are omitted (not sent as defaults) so the CLI's own
    /// defaults stay authoritative.
    public static func suggestArgs(days: Int? = nil, minCount: Int? = nil) -> [String] {
        var args = ["approvals", "suggest", "--json"]
        if let days { args += ["--days", String(days)] }
        if let minCount { args += ["--min-count", String(minCount)] }
        return args
    }

    /// `["approvals", "suggest", "--apply", "N[,M...]", "--json"]`.
    /// Indices are de-duplicated and sorted so the argv is deterministic.
    /// Returns nil for an empty selection — never emit a bare `--apply`.
    public static func applyArgs(indices: [Int]) -> [String]? {
        let cleaned = Array(Set(indices.filter { $0 >= 1 })).sorted()
        guard !cleaned.isEmpty else { return nil }
        let list = cleaned.map(String.init).joined(separator: ",")
        return ["approvals", "suggest", "--apply", list, "--json"]
    }

    // MARK: - Parsers

    private struct Payload: Decodable {
        struct RawProposal: Decodable {
            let n: Int
            let pattern: String
            let kind: String
            let count: Int
            let classes: [String]?
            let examples: [String]?
        }
        let proposals: [RawProposal]
    }

    /// Parse the dry-run JSON payload. Returns nil when stdout isn't the
    /// expected JSON shape (transport noise, pre-0.20 host, error text);
    /// an empty `proposals` array parses to `[]`.
    public static func parse(json: String) -> [HermesApprovalProposal]? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        return payload.proposals.map {
            HermesApprovalProposal(
                n: $0.n,
                pattern: $0.pattern,
                kind: $0.kind,
                count: $0.count,
                classes: $0.classes ?? [],
                examples: $0.examples ?? []
            )
        }
    }

    /// Result of `--apply … --json`: `{"applied": [...], "allowlist_size": N}`.
    public struct ApplyResult: Sendable, Equatable {
        public let applied: [String]
        public let allowlistSize: Int

        public init(applied: [String], allowlistSize: Int) {
            self.applied = applied
            self.allowlistSize = allowlistSize
        }
    }

    public static func parseApplyResult(json: String) -> ApplyResult? {
        struct Raw: Decodable {
            let applied: [String]
            let allowlist_size: Int
        }
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return nil
        }
        return ApplyResult(applied: raw.applied, allowlistSize: raw.allowlist_size)
    }
}
