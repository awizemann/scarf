import Foundation

/// Argv builders + `--json` result parsing for `hermes peer` (Hermes
/// v0.21+; callers gate on `HermesCapabilities.hasPeerRunCommands`).
///
/// Source of truth: `hermes_cli/subcommands/peer.py`. Four verbs are
/// modeled — `dm` (one synchronous remote turn), `run` (the same turn
/// started asynchronously through the peer's Runs API), and
/// `status`/`stop` on the resulting run handle. Registration
/// (`add`/`remove`) is deliberately NOT modeled here: the peer's API key
/// is part of that flow and Scarf never handles keys.
///
/// ## Exit codes (documented in the subcommand's own epilog)
/// - `0` — success; the `--json` payload is on **stdout**.
/// - `1` — delivery/peer error (unreachable, HTTP rejection, unknown
///   peer, missing key). The human-readable reason is on **stderr**.
/// - `2` — usage error (bad target/profile, empty message, malformed
///   idempotency key, missing run id).
///
/// ## Two gotchas this parser exists to encode
/// 1. **`peer run` prints a warning to stderr on the happy path.** When
///    the peer's `/v1/capabilities` doesn't advertise
///    `features.runs_idempotency.durable` — which includes *every* peer
///    too old to expose the endpoint at all — `cmd_peer` writes a
///    "does not advertise restart-durable run replay" line to stderr and
///    then proceeds normally. Treating a non-empty stderr as failure
///    would break `run` against most real peers. Only the **exit code**
///    decides success; the warning is surfaced separately via
///    ``durabilityWarning(inStderr:)``.
/// 2. **An HTTP 400 from the remote Bot Chat lookup becomes a
///    `RuntimeError` whose message tells the user the peer's
///    hermes-agent is too old** (its canonical Bot Chat exists but is
///    hidden, and the peer can't expose hidden sessions to the lookup).
///    That sentence — including the `PATCH /api/sessions/<id>` remedy —
///    is the actionable content, so failures carry the CLI's stderr
///    **verbatim** rather than a Scarf-authored paraphrase.
public enum HermesPeerCLI {

    // MARK: - Targets

    /// `<peer>` or `<peer>/<agent>` — the multiplex mirror on a peer that
    /// runs named profiles (`_parse_target` / `_base_url`).
    public static func target(peer: String, profile: String? = nil) -> String {
        guard let profile, !profile.isEmpty else { return peer }
        return "\(peer)/\(profile)"
    }

    // MARK: - Argv

    public static func dmArgs(target: String, message: String) -> [String] {
        ["peer", "dm", target, message, "--json"]
    }

    /// `--idempotency-key` is optional: omitted, the CLI generates
    /// `peer-<uuid>` and echoes it back in the JSON payload, which is
    /// what Scarf stores. Pass one only to make a retry idempotent.
    public static func runArgs(target: String, message: String, idempotencyKey: String? = nil) -> [String] {
        var args = ["peer", "run", target, message]
        if let idempotencyKey, !idempotencyKey.isEmpty {
            args += ["--idempotency-key", idempotencyKey]
        }
        args.append("--json")
        return args
    }

    public static func statusArgs(target: String, runID: String) -> [String] {
        ["peer", "status", target, runID, "--json"]
    }

    public static func stopArgs(target: String, runID: String) -> [String] {
        ["peer", "stop", target, runID, "--json"]
    }

    /// `hermes peer list` — text only (no `--json`). Scarf reads the
    /// registry straight out of `config.yaml` instead
    /// (``HermesBotPeersYAML``), so this exists only as the "how do I
    /// check?" hint shown in the empty state.
    public static let listCommandHint = "hermes peer list"

    // MARK: - Results

    /// `peer dm --json` → `{peer, profile, session_id, reply}`.
    public struct DMResult: Sendable, Equatable {
        public let peer: String
        public let profile: String?
        public let sessionID: String
        /// The remote agent's reply. Empty when the peer answered with no
        /// message content (the CLI's text mode prints "(no reply)").
        public let reply: String

        public init(peer: String, profile: String?, sessionID: String, reply: String) {
            self.peer = peer
            self.profile = profile
            self.sessionID = sessionID
            self.reply = reply
        }
    }

    /// `peer run --json` → `{peer, profile, session_id, run_id, status,
    /// idempotency_key, replayed}`.
    public struct RunResult: Sendable, Equatable {
        public let peer: String
        public let profile: String?
        public let sessionID: String
        public let runID: String
        /// The peer's reported status, or `"started"` when it didn't say.
        public let status: String
        /// Echo of the key used — generated (`peer-<uuid>`) when the
        /// caller didn't supply one. Worth keeping: it's what makes a
        /// retry replay rather than double-run.
        public let idempotencyKey: String
        /// True when the peer matched an existing run for this key
        /// instead of starting a new one.
        public let replayed: Bool

        public init(
            peer: String,
            profile: String?,
            sessionID: String,
            runID: String,
            status: String,
            idempotencyKey: String,
            replayed: Bool
        ) {
            self.peer = peer
            self.profile = profile
            self.sessionID = sessionID
            self.runID = runID
            self.status = status
            self.idempotencyKey = idempotencyKey
            self.replayed = replayed
        }
    }

    /// `peer status` / `peer stop --json` → `{peer, profile}` merged with
    /// the peer's raw `/v1/runs/<id>` body, so the exact key set depends
    /// on the peer's own Runs API. Only the fields the CLI's own text
    /// mode prints are modeled; anything else is ignored rather than
    /// guessed at.
    public struct RunStatusResult: Sendable, Equatable {
        public let peer: String
        public let profile: String?
        /// Present only when the peer echoes it — the CLI itself doesn't
        /// inject the run id into the status payload.
        public let runID: String?
        /// `"unknown"` when the peer omitted it (mirrors the text mode's
        /// `result.get('status', 'unknown')`).
        public let status: String
        /// Final output of a completed run, when the peer includes it.
        public let output: String?
        /// Failure detail from the peer — a *run* that failed, which is
        /// distinct from the CLI failing to talk to the peer.
        public let error: String?

        public init(
            peer: String,
            profile: String?,
            runID: String?,
            status: String,
            output: String?,
            error: String?
        ) {
            self.peer = peer
            self.profile = profile
            self.runID = runID
            self.status = status
            self.output = output
            self.error = error
        }
    }

    // MARK: - Failure

    /// A `hermes peer` invocation that didn't exit 0.
    public struct Failure: Error, Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Exit 2 — Scarf built a bad invocation, or the user typed a
            /// malformed target/message.
            case usage
            /// Exit 1 — unknown peer, no key, unreachable host, HTTP
            /// rejection, or the "peer's hermes-agent is too old" case.
            case delivery
            /// Anything else: transport failure (`runHermesCLISplit`
            /// returns -1), a missing binary, or output Scarf couldn't
            /// parse despite a clean exit.
            case local
        }

        public let kind: Kind
        /// The CLI's own stderr, verbatim (whitespace-trimmed only).
        /// Falls back to stdout, then to a generic sentence — never to a
        /// paraphrase, because the useful failures here (peer too old,
        /// missing key with the exact `.env` variable to set) already
        /// carry their own remedy.
        public let message: String

        public init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    // MARK: - Parsing

    /// The non-fatal warning `peer run` writes to stderr when the peer
    /// can't promise restart-durable run replay. Returns the line
    /// verbatim, or nil when absent. **Not** an error — see the type doc.
    public static func durabilityWarning(inStderr stderr: String) -> String? {
        let line = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("warning:") && $0.lowercased().contains("durable") }
        return line?.isEmpty == false ? line : nil
    }

    public static func parseDM(
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) -> Result<DMResult, Failure> {
        decode(exitCode: exitCode, stdout: stdout, stderr: stderr) { object in
            guard let peer = string(object["peer"]) else { return nil }
            return DMResult(
                peer: peer,
                profile: string(object["profile"]),
                sessionID: string(object["session_id"]) ?? "",
                reply: string(object["reply"]) ?? ""
            )
        }
    }

    public static func parseRun(
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) -> Result<RunResult, Failure> {
        decode(exitCode: exitCode, stdout: stdout, stderr: stderr) { object in
            guard let peer = string(object["peer"]),
                  let runID = string(object["run_id"]), !runID.isEmpty
            else { return nil }
            return RunResult(
                peer: peer,
                profile: string(object["profile"]),
                sessionID: string(object["session_id"]) ?? "",
                runID: runID,
                status: string(object["status"]) ?? "started",
                idempotencyKey: string(object["idempotency_key"]) ?? "",
                replayed: bool(object["replayed"])
            )
        }
    }

    /// Shared by `status` and `stop` — the CLI emits the same shape for
    /// both (a `{peer, profile}` header merged over the peer's run body).
    public static func parseRunStatus(
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) -> Result<RunStatusResult, Failure> {
        decode(exitCode: exitCode, stdout: stdout, stderr: stderr) { object in
            guard let peer = string(object["peer"]) else { return nil }
            return RunStatusResult(
                peer: peer,
                profile: string(object["profile"]),
                runID: string(object["run_id"]),
                status: string(object["status"]) ?? "unknown",
                output: nonEmpty(string(object["output"])),
                error: nonEmpty(string(object["error"]))
            )
        }
    }

    // MARK: - Internals

    private static func decode<T>(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        _ build: ([String: Any]) -> T?
    ) -> Result<T, Failure> {
        guard exitCode == 0 else {
            return .failure(Failure(kind: kind(for: exitCode), message: failureMessage(stdout: stdout, stderr: stderr)))
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = build(object)
        else {
            return .failure(Failure(
                kind: .local,
                message: trimmed.isEmpty
                    ? "hermes peer returned no output."
                    : "Couldn't read the peer response: \(trimmed.prefix(300))"
            ))
        }
        return .success(value)
    }

    private static func kind(for exitCode: Int32) -> Failure.Kind {
        switch exitCode {
        case 2: return .usage
        case 1: return .delivery
        default: return .local
        }
    }

    /// stderr verbatim; stdout as the fallback (the CLI prints a few
    /// refusals there), minus the durability warning — that line is
    /// noise on a path that already failed for another reason.
    private static func failureMessage(stdout: String, stderr: String) -> String {
        let warning = durabilityWarning(inStderr: stderr)
        let cleaned = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != warning }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "hermes peer failed without a message."
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" }
        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
