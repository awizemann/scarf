import Foundation

/// How Scarf should authenticate a new HTTP/SSE MCP server.
///
/// The mode decides **which prompts `hermes mcp add` will ask**, which is
/// why it has to be explicit rather than inferred: the answers are fed on
/// stdin positionally, so one wrong branch shifts every later answer onto
/// the wrong question.
public enum HermesMCPAddAuthMode: Sendable, Equatable {
    /// No authentication. Passes no `--auth` and answers the CLI's
    /// "Does this server require authentication? [Y/n]" with an explicit
    /// **n** — the prompt defaults to *yes*, so silence would walk into
    /// the bearer-token read.
    case none
    /// OAuth 2.1 (`--auth oauth`). The CLI runs its own OAuth manager and
    /// asks no credential question.
    case oauth
    /// Bearer/header auth with a token the user typed in Scarf.
    case header(token: String)
    /// stdio servers: `hermes mcp add` reaches neither auth branch.
    case stdio
}

/// What `hermes mcp add` actually did, read out of its stdout.
///
/// **`cmd_mcp_add` never exits nonzero.** Every failure path — bad
/// transport flags, a config the validator rejects, a failed probe, an
/// explicit cancel — ends in a bare `return`, so the process exits 0.
/// Verified line-by-line against `hermes_cli/mcp_config.py::cmd_mcp_add`
/// at v2026.8.31. Trusting the exit code (as Scarf did) reported
/// "Added <name>" for servers that were never written to config.yaml.
public enum HermesMCPAddOutcome: Sendable, Equatable {
    /// Probe connected, tools discovered, `enabled: true` written.
    case savedEnabled(toolsEnabled: Int, toolsTotal: Int)
    /// Server connected but advertised no tools. The CLI saves the entry
    /// **without** writing an `enabled` key at all — and the reader
    /// treats a missing key as enabled — so this is live, but worth
    /// telling the user about.
    case savedWithoutTools
    /// The probe failed and the entry was written with `enabled: false`.
    /// Scarf should never reach this: it answers that prompt "no".
    case savedDisabled
    /// Nothing was written. `reason` is the CLI's own message.
    case notSaved(reason: String)

    public var didSave: Bool {
        if case .notSaved = self { return false }
        return true
    }

    /// True only when the server is in config.yaml *and* will load.
    public var isLive: Bool {
        switch self {
        case .savedEnabled, .savedWithoutTools: return true
        case .savedDisabled, .notSaved: return false
        }
    }
}

/// Builds the argv and the stdin answer script for one `hermes mcp add`
/// invocation, and reads the outcome back out of stdout.
///
/// ## Why there is a script at all
///
/// `hermes mcp add` has no `--yes` / `--non-interactive` / `--skip-probe`
/// flag at any shipped version (checked against the `mcp add` subparser
/// at v2026.8.31: it accepts only `name`, `--url`, `--command`, `--args`,
/// `--auth`, `--preset`, `--connect-timeout`, `--env`). So the prompts
/// that remain **must** be answered, and answered by position.
///
/// Scarf previously piped a blanket `"y\ny\ny\n"` at every add. For a
/// plain HTTP server that is actively harmful: the first `y` accepts
/// "Does this server require authentication?", and the second `y` is
/// then read as the **API key** and written to `~/.hermes/.env` as
/// `MCP_<NAME>_API_KEY`, with `Authorization: Bearer ${MCP_<NAME>_API_KEY}`
/// stamped into config.yaml. (The read goes through `masked_secret_prompt`,
/// which falls back to `getpass` on a non-tty stdin, and `getpass` falls
/// back to reading stdin when there is no controlling terminal — which is
/// exactly a GUI-launched app.) The rules below follow from that:
///
/// 1. Never send a bare `y` where the CLI reads a *value*.
/// 2. Prefer an empty line: every prompt's default is the outcome Scarf
///    wants, except the auth question, whose default is *yes*.
/// 3. Answer only the prompts the chosen mode actually triggers.
public enum HermesMCPAdd {

    /// One `hermes mcp add` invocation: argv after `mcp add`, plus the
    /// stdin to feed it.
    public struct Plan: Sendable, Equatable {
        public let arguments: [String]
        public let stdin: String
        /// Set when the plan deliberately did NOT send a token the caller
        /// supplied, because the CLI will not ask for one. The caller must
        /// tell the user — otherwise a typed token is silently discarded and
        /// the server quietly keeps authenticating with the old key. (F9)
        public let discardedSuppliedToken: Bool

        public init(arguments: [String], stdin: String, discardedSuppliedToken: Bool = false) {
            self.arguments = arguments
            self.stdin = stdin
            self.discardedSuppliedToken = discardedSuppliedToken
        }
    }

    /// Why a plan could not be built. Building a plan is **refused** rather
    /// than guessed whenever the prompt sequence isn't fully determined —
    /// a misaligned stdin plan writes a bearer token into the wrong prompt,
    /// which is how a token once landed in `~/.hermes/.env` as a literal
    /// `y`. Refusing costs the user a dialog; guessing costs them a leaked
    /// secret. (F9)
    public enum PlanError: Error, Equatable, Sendable {
        /// `name` is already in config.yaml. `cmd_mcp_add` will ask
        /// "Server '<name>' already exists. Overwrite?" **before** the auth
        /// stage, and that prompt eats the first stdin line — shifting every
        /// later answer onto the wrong question. The caller must resolve the
        /// user's intent (an explicit overwrite confirmation, or a different
        /// name) and rebuild.
        case serverAlreadyExists(name: String)
        /// The caller could not determine whether `MCP_<NAME>_API_KEY` is
        /// already set, so we cannot know whether the CLI will ask for a
        /// token at all.
        case apiKeyStateUnknown(envKey: String)
    }

    /// The state of the host that changes which prompts `mcp add` asks.
    ///
    /// **Why this has to be passed in.** `cmd_mcp_add`'s prompt sequence is
    /// not a function of the flags alone — it depends on what already exists
    /// on the host, and the answers are fed positionally on stdin:
    ///
    /// * `mcp_config.py:483-487` — if `name` is already in
    ///   `_get_mcp_servers()`, an extra `Overwrite? [y/N]` prompt is asked
    ///   **before** the auth stage. One extra prompt, and the `n`/`y` meant
    ///   for "Does this server require authentication?" answers *it*
    ///   instead, and the token line then answers the auth question.
    /// * `mcp_config.py:545-548` — inside the header-auth branch, if
    ///   `get_env_value(MCP_<NAME>_API_KEY)` already returns a value, the
    ///   CLI prints "already configured" and **never prompts for the key**.
    ///   The token line Scarf queued is then read by the *next* prompt
    ///   ("Enable all N tools?"), and the token itself is echoed into a
    ///   prompt whose answer we never intended.
    ///
    /// Both were verified against `hermes_cli/mcp_config.py` at v2026.8.31.
    public struct HostState: Sendable, Equatable {
        /// `name` is already a key under `mcp_servers:` in config.yaml.
        public let serverNameExists: Bool
        /// The user has explicitly confirmed, in Scarf's UI, that they want
        /// to overwrite the existing entry. Only meaningful when
        /// `serverNameExists` is true.
        public let overwriteConfirmed: Bool
        /// Whether `MCP_<NAME>_API_KEY` already resolves for the CLI —
        /// `nil` means "couldn't determine", which is a refusal, not a
        /// default.
        public let apiKeyAlreadyConfigured: Bool?

        public init(
            serverNameExists: Bool,
            overwriteConfirmed: Bool = false,
            apiKeyAlreadyConfigured: Bool? = false
        ) {
            self.serverNameExists = serverNameExists
            self.overwriteConfirmed = overwriteConfirmed
            self.apiKeyAlreadyConfigured = apiKeyAlreadyConfigured
        }

        /// A pristine host: no such server, no pre-existing key. The shape
        /// every add took before F9 — correct only when it happens to be
        /// true, which is why it is now stated rather than assumed.
        public static let fresh = HostState(serverNameExists: false)
    }

    /// `_env_key_for_server` — mirrors `mcp_config.py:153-156` exactly:
    /// upper-case, every non-`[A-Za-z0-9_]` run mapped to `_`, leading and
    /// trailing `_` stripped, wrapped as `MCP_<suffix>_API_KEY`.
    ///
    /// Note the Python is `re.sub` per-character (not per-run), so `a-b`
    /// becomes `A_B` and `a--b` becomes `A__B`; the double underscore is
    /// preserved here for the same reason.
    public static func envKeyForServer(_ name: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let mapped = String(name.uppercased().map { allowed.contains($0) ? $0 : "_" })
        var suffix = Substring(mapped)
        while suffix.hasPrefix("_") { suffix = suffix.dropFirst() }
        while suffix.hasSuffix("_") { suffix = suffix.dropLast() }
        return "MCP_\(suffix)_API_KEY"
    }

    /// The stdin line that answers the pre-auth `Overwrite? [y/N]` prompt,
    /// or `nil` when that prompt will not be asked. Throws when the server
    /// exists and the user has not confirmed.
    private static func overwritePrefix(name: String, state: HostState) throws -> String {
        guard state.serverNameExists else { return "" }
        guard state.overwriteConfirmed else {
            throw PlanError.serverAlreadyExists(name: name)
        }
        // `_confirm(..., default=False)` — the default is NO, so this `y`
        // is load-bearing; a blank line would cancel the add outright.
        return "y\n"
    }

    /// Blank lines that accept the default at every prompt still pending
    /// after the auth stage: the post-probe "Enable all N tools?"
    /// ([Y/n/select] → enable all), plus the "Save config anyway?"
    /// variants, whose defaults are the honest answers (No on a probe
    /// failure, Yes on a connected-but-toolless server).
    private static let defaultsTail = "\n\n"

    /// Builds an `mcp add` invocation for a stdio server.
    ///
    /// The args are passed **at add time** via `--args`. Scarf used to
    /// deliberately withhold them and patch them into config.yaml
    /// afterwards, which meant the CLI probed a bare `npx` with no server
    /// script — the probe always failed, the "Save config anyway?" prompt
    /// took the piped `y`, and the entry landed with `enabled: false`.
    /// That is the whole reason stdio servers arrived disabled; there is
    /// no probe-skipping flag to reach for.
    ///
    /// `--args` is `nargs=argparse.REMAINDER` and must come last.
    ///
    /// **No `--` separator.** `cmd_mcp_add` strips a leading `--` from
    /// what it captures (`if cmd_args and cmd_args[0] == "--": cmd_args =
    /// cmd_args[1:]`), which reads like an invitation to pass one — but
    /// on current CPython (checked on 3.14) argparse consumes the first
    /// `--` as its *own* separator before REMAINDER ever sees it, and the
    /// rest of the line then fails as `unrecognized arguments`. That
    /// defensive branch is dead code on modern hosts. REMAINDER already
    /// captures leading-dash tokens verbatim, so `--args -y <pkg>` is both
    /// correct and the only form that parses.
    ///
    /// **And no `--` before the `name` positional either.** The F2/F3 rule
    /// ("guard a user-supplied positional with `--`") does NOT generalise to
    /// this subparser, and F9 checked rather than assumed. `mcp add`'s only
    /// positional is `name`, and it is declared *after* `--command` /
    /// `--url` / `--env` / `--args` on the command line in every form we
    /// emit. Python's argparse treats everything following the first `--`
    /// as positional, so `mcp add -- srv --command npx` fails with
    /// `unrecognized arguments: --command npx` — verified by execution
    /// against the real subparser shape at v2026.8.31, for the stdio, url,
    /// `--env` and leading-dash-name forms alike. There is therefore no
    /// safe `--` placement here; a leading-dash server name is instead
    /// rejected upstream by the name validator before it reaches argv.
    ///
    /// (`--` before an ordinary positional in a *flagless tail* —
    /// `profile delete -y -- name` — is unaffected and still correct; both
    /// REMAINDER and "flags after the positional" defeat it.)
    public static func stdioPlan(
        name: String,
        command: String,
        args: [String],
        env: [String: String] = [:],
        connectTimeout: Int? = nil,
        state: HostState = .fresh
    ) throws -> Plan {
        let overwrite = try overwritePrefix(name: name, state: state)
        var argv = ["mcp", "add", name, "--command", command]
        if let connectTimeout {
            argv += ["--connect-timeout", String(connectTimeout)]
        }
        if !env.isEmpty {
            // `--env` is nargs="*", so it must not be the last option
            // before `--args` REMAINDER swallows the rest.
            argv += ["--env"] + env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
        }
        if !args.isEmpty {
            argv += ["--args"] + args
        }
        // stdio reaches neither auth branch — only the overwrite prompt (if
        // the name is taken) and the post-probe prompts.
        return Plan(arguments: argv, stdin: overwrite + defaultsTail)
    }

    /// Builds an `mcp add` invocation for an HTTP (or SSE-to-be) server.
    ///
    /// Throws `PlanError` when the host state leaves the prompt sequence
    /// undetermined — see ``HostState``. Never guess here: every stdin line
    /// is positional, and the header-auth plan carries a bearer token.
    public static func urlPlan(
        name: String,
        url: String,
        auth: HermesMCPAddAuthMode,
        connectTimeout: Int? = nil,
        state: HostState = .fresh
    ) throws -> Plan {
        var argv = ["mcp", "add", name, "--url", url]
        var stdin = try overwritePrefix(name: name, state: state)
        var discardedToken = false

        switch auth {
        case .oauth:
            argv += ["--auth", "oauth"]
            // The oauth branch asks nothing unless the SDK auth module is
            // missing, and that fallback ("Continue without
            // authentication?") defaults to yes — a blank line covers it.
        case .header(let token):
            argv += ["--auth", "header"]
            // y → "Does this server require authentication?"
            let envKey = envKeyForServer(name)
            switch state.apiKeyAlreadyConfigured {
            case .some(true):
                // `mcp_config.py:545-548` — `get_env_value(env_key)` hits, so
                // the CLI prints "<KEY>: already configured" and NEVER asks
                // for a token. Queueing the token line here would feed it to
                // the next prompt entirely ("Enable all N tools?"), which
                // both mis-answers that prompt and echoes the secret into a
                // question we didn't intend to answer. The existing key is
                // reused via `_bearer_auth_headers`, which is the outcome
                // the user wants anyway — but the token the user just typed
                // is NOT what will be used, and they have to be told.
                stdin += "y\n"
                discardedToken = !token.isEmpty
            case .some(false):
                // No existing key → the value read happens. Never a bare `y`
                // at a value read.
                stdin += "y\n\(token)\n"
            case .none:
                throw PlanError.apiKeyStateUnknown(envKey: envKey)
            }
        case .none:
            // No `--auth`: same branch as header, but decline. The
            // prompt's default is YES, so this `n` is load-bearing.
            stdin += "n\n"
        case .stdio:
            // Caller error — a stdio server has no URL. Fall through with
            // defaults only rather than answering a question that will
            // not be asked.
            break
        }

        if let connectTimeout {
            argv += ["--connect-timeout", String(connectTimeout)]
        }
        return Plan(
            arguments: argv,
            stdin: stdin + defaultsTail,
            discardedSuppliedToken: discardedToken
        )
    }

    /// Reads the real outcome out of `hermes mcp add` stdout.
    ///
    /// Sentinels verified against `mcp_config.py` at v2026.8.31 — the
    /// `_success` / `_warning` / `_error` helpers prefix `✓ ` / `⚠ ` /
    /// `✗ ` and two spaces of indent, and ANSI colour codes may wrap the
    /// whole line, so every match is a substring test on the payload.
    public static func parseOutcome(_ output: String, name: String) -> HermesMCPAddOutcome {
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        // Order matters: the disabled-save line is a *prefix-sibling* of
        // the plain save line, so check the specific forms first.
        for line in lines where line.contains("Saved '\(name)'") {
            if line.contains("(disabled)") { return .savedDisabled }
            if let counts = toolCounts(in: line) {
                return .savedEnabled(toolsEnabled: counts.0, toolsTotal: counts.1)
            }
            return .savedWithoutTools
        }

        // Nothing was saved — surface the CLI's own reason verbatim so the
        // user sees the actual failure, not "Add failed" over empty text.
        let failureMarkers = [
            "Failed to connect:",
            "was NOT saved",
            "Must specify",
            "--env is only supported",
            "Cancelled",
            "No tools selected",
        ]
        for line in lines {
            for marker in failureMarkers where line.contains(marker) {
                return .notSaved(reason: strippedGlyphs(line))
            }
        }
        let tail = lines.last(where: { !$0.isEmpty }) ?? ""
        return .notSaved(reason: tail.isEmpty ? "`hermes mcp add` wrote no server entry and gave no reason." : strippedGlyphs(tail))
    }

    /// Pulls `(3/7 tools enabled)` out of the success line.
    private static func toolCounts(in line: String) -> (Int, Int)? {
        guard let match = line.range(of: "\\(\\d+/\\d+ tools enabled\\)", options: .regularExpression) else { return nil }
        let inner = line[match].dropFirst().prefix(while: { $0 != " " })
        let parts = inner.split(separator: "/")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    private static func strippedGlyphs(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "✓⚠✗ ")).trimmingCharacters(in: .whitespaces)
    }
}
