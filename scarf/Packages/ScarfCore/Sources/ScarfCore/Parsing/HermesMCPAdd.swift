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

        public init(arguments: [String], stdin: String) {
            self.arguments = arguments
            self.stdin = stdin
        }
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
    /// (`--` before an ordinary positional — `profile delete -y -- name` —
    /// is unaffected and still correct; only REMAINDER behaves this way.)
    public static func stdioPlan(
        name: String,
        command: String,
        args: [String],
        env: [String: String] = [:],
        connectTimeout: Int? = nil
    ) -> Plan {
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
        // stdio reaches neither auth branch — only the post-probe prompt.
        return Plan(arguments: argv, stdin: defaultsTail)
    }

    /// Builds an `mcp add` invocation for an HTTP (or SSE-to-be) server.
    public static func urlPlan(
        name: String,
        url: String,
        auth: HermesMCPAddAuthMode,
        connectTimeout: Int? = nil
    ) -> Plan {
        var argv = ["mcp", "add", name, "--url", url]
        var stdin = ""

        switch auth {
        case .oauth:
            argv += ["--auth", "oauth"]
            // The oauth branch asks nothing unless the SDK auth module is
            // missing, and that fallback ("Continue without
            // authentication?") defaults to yes — a blank line covers it.
        case .header(let token):
            argv += ["--auth", "header"]
            // y → "Does this server require authentication?"
            // then the token, at the value read. Never a bare `y` here.
            stdin += "y\n\(token)\n"
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
        return Plan(arguments: argv, stdin: stdin + defaultsTail)
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
