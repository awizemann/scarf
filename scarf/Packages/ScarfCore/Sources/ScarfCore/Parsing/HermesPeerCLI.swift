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
///   Exception, v0.21.4+: a `dm` timeout after the peer ACCEPTED the
///   message also exits 1 — ``parseDM(exitCode:stdout:stderr:)`` reads that
///   one as ``DMResult/Delivery/stillRunning(notice:)``, never a failure.
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

    /// ## The `--` in `dm`/`run`
    /// `target` and `message` are argparse **positionals**
    /// (`dm_p.add_argument("message", nargs="?")`), so a message the user
    /// legitimately starts with a dash — "-v is broken", "--help me
    /// debug this" — gets claimed as an option and the invocation dies at
    /// exit 2, or worse, silently flips a flag. `--` is argparse's own
    /// end-of-options marker: everything after it is a positional, no
    /// parser change needed on the Hermes side.
    ///
    /// It has to come **last**, after `--json` and any `--idempotency-key`
    /// — argparse treats every token after the first `--` as positional,
    /// so a flag placed behind it would be consumed as a third positional
    /// and rejected as "unrecognized arguments".
    public static func dmArgs(target: String, message: String) -> [String] {
        ["peer", "dm", "--json", "--", target, message]
    }

    /// `--idempotency-key` is optional: omitted, the CLI generates
    /// `peer-<uuid>` and echoes it back in the JSON payload, which is
    /// what Scarf stores. Pass one only to make a retry idempotent.
    public static func runArgs(target: String, message: String, idempotencyKey: String? = nil) -> [String] {
        var args = ["peer", "run"]
        if let idempotencyKey, !idempotencyKey.isEmpty {
            args += ["--idempotency-key", idempotencyKey]
        }
        args.append("--json")
        // End of options — see `dmArgs`. Must stay last.
        args += ["--", target, message]
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

    /// `peer dm --json` → `{peer, profile, session_id, reply}`, or — v0.21.4+
    /// — the queued shape `{peer, profile, session_id, status, delivery_id}`.
    public struct DMResult: Sendable, Equatable {
        /// How the message landed. Only ``replied`` carries a reply; the
        /// other two mean the peer HAS the message and will answer it in its
        /// own Bot Chat — a resend would run the turn twice.
        public enum Delivery: Sendable, Equatable {
            /// The synchronous turn finished (the pre-v0.21.4 shape, always).
            case replied
            /// v0.21.4 `hermes.session.chat.queued`: the peer's Bot Chat is
            /// open in its Desktop, so the message went into that chat
            /// (`hermes_cli/subcommands/peer.py:368-375` @ v2026.9.21). The
            /// payload's `status` (normally `queued`) is carried verbatim.
            case queued(status: String)
            /// v0.21.4: the turn outlasted `DM_TIMEOUT_S` AFTER the peer took
            /// the message (`peer.py:356-365` @ v2026.9.21) — exit 1, but
            /// Hermes says "Do NOT resend". `notice` is its sentence.
            case stillRunning(notice: String)
        }

        public let peer: String
        public let profile: String?
        public let sessionID: String
        /// The remote agent's reply. Empty when the peer answered with no
        /// message content (the CLI's text mode prints "(no reply)"), and
        /// always empty unless ``delivery`` is ``Delivery/replied``.
        public let reply: String
        public let delivery: Delivery

        public init(
            peer: String, profile: String?, sessionID: String, reply: String,
            delivery: Delivery = .replied
        ) {
            self.peer = peer
            self.profile = profile
            self.sessionID = sessionID
            self.reply = reply
            self.delivery = delivery
        }
    }

    /// Scarf's process timeout for one `peer dm`. The CLI's own read timeout
    /// is `DM_TIMEOUT_S = 600` (`peer.py:28`) and it starts only after the
    /// Bot Chat lookup and Python startup, so a 600 s kill always landed
    /// first — before v0.21.4's "accepted … Do NOT resend" line could be
    /// printed, turning an accepted message into "no output" and inviting
    /// exactly the resend it warns against.
    ///
    /// v0.21.4+ (``HermesCapabilities/hasPeerDMNoResendOutcomes``) gets the
    /// CLI's whole worst case plus a margin: `_ensure_bot_chat` is a
    /// `_find_bot_chat` GET and, when none exists, a create POST, each bounded
    /// by `LIST_TIMEOUT_S = 30` (`peer.py:29`, `:65-67`, `:111`, `:123-125` @
    /// v2026.9.21), and only then does the 600 s chat POST start (`:348-351`)
    /// — 660 s before Python/SSH startup, so a 660 s cap could still land
    /// first. 600 + 2 × 30 + 60 s margin. Even that is not a guarantee
    /// (urllib's timeout is per socket operation), which is why a Scarf-side
    /// kill on such a host reads as "may already be delivered", never as a
    /// failure (``isLocalDMTimeout(exitCode:stderr:timeout:)``). Older hosts
    /// keep the 600 s they always had.
    public static func dmProcessTimeout(capabilities: HermesCapabilities) -> TimeInterval {
        capabilities.hasPeerDMNoResendOutcomes ? 720 : 600
    }

    /// True when a `peer dm` result is Scarf's OWN process timeout firing —
    /// not anything the CLI said. `runHermesCLISplit` turns a
    /// ``TransportError/timeout(seconds:partialStdout:)`` (thrown by both the
    /// local and the SSH transport with the cap they were given) into exit
    /// `-1` with the error's description as stderr, so the match is against
    /// that exact sentence for this exact cap, never a substring a real
    /// CLI line could contain.
    ///
    /// The distinction matters on v0.21.4+: by the time Scarf gives up, the
    /// peer may already hold the message in its Bot Chat and be running the
    /// turn (`peer.py:356-365` @ v2026.9.21), so a resend would deliver it
    /// twice.
    public static func isLocalDMTimeout(exitCode: Int32, stderr: String, timeout: TimeInterval) -> Bool {
        guard exitCode == -1 else { return false }
        let expected = TransportError.timeout(seconds: timeout, partialStdout: Data()).errorDescription
        return stderr.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    /// The distinctive tail of the accepted-but-still-running line
    /// (`peer.py:362-364` @ v2026.9.21).
    static let acceptedStillRunningMarkers = [
        "accepted the message but its turn is still running",
        "Do NOT resend",
    ]

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
        // v0.21.4: exit 1 AFTER the peer took the message. Not a delivery
        // failure — reporting it as one is what makes a user resend and the
        // peer run the turn twice. No older host prints this line.
        if exitCode == 1,
           let notice = stderr
               .split(separator: "\n", omittingEmptySubsequences: true)
               .map({ $0.trimmingCharacters(in: .whitespaces) })
               .first(where: { line in acceptedStillRunningMarkers.allSatisfy { line.contains($0) } }) {
            return .success(DMResult(
                peer: "", profile: nil, sessionID: "", reply: "",
                delivery: .stillRunning(notice: notice)
            ))
        }
        return decode(exitCode: exitCode, stdout: stdout, stderr: stderr) { object in
            guard let peer = string(object["peer"]) else { return nil }
            // The queued payload carries `status` and no `reply`
            // (`peer.py:372-373` @ v2026.9.21); a replied payload never has
            // `status`, so its presence is the discriminator.
            let delivery: DMResult.Delivery = object["reply"] == nil
                ? string(object["status"]).map { .queued(status: $0) } ?? .replied
                : .replied
            return DMResult(
                peer: peer,
                profile: string(object["profile"]),
                sessionID: string(object["session_id"]) ?? "",
                reply: string(object["reply"]) ?? "",
                delivery: delivery
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
                output: nonEmpty(stringOrJSON(object["output"])),
                error: nonEmpty(stringOrJSON(object["error"]))
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

    /// Like `string`, but keeps structured values instead of discarding
    /// them. `status`/`stop` merge the peer's own `/v1/runs/<id>` body, and
    /// a peer is free to answer with `output: {...}` or `error: [...]` —
    /// the CLI's text mode just `print`s whatever is there. Returning nil
    /// for those would show "no output" for a run that produced plenty, so
    /// non-scalars are re-serialized as compact JSON (sorted keys, so the
    /// same payload always renders the same way).
    private static func stringOrJSON(_ value: Any?) -> String? {
        if let scalar = string(value) { return scalar }
        guard let value, !(value is NSNull) else { return nil }
        if let b = value as? Bool { return b ? "true" : "false" }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        // A JSON bool arrives as a real `Bool`; the string arm is tolerance
        // for a field Python stringified on the way out (`str(True)` is
        // `"True"`, which the literal compare missed). Same one helper as
        // every other boolish read (P18).
        if let s = value as? String { return HermesYAML.boolishValue(s) ?? false }
        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
