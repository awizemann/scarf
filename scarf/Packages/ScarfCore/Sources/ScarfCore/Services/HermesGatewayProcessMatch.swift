import Foundation

/// The `pgrep -f` pattern that finds ONE profile's Hermes gateway process.
///
/// `pgrep -f` matches an extended regex (ERE) against the whole command line,
/// arguments joined by single spaces. Three shapes have to be handled
/// (all @ v2026.9.24):
///
/// 1. **The profile flag sits between the entry point and `gateway`.** A named
///    profile's service runs `python -m hermes_cli.main --profile <name>
///    gateway run …` (`hermes_cli/gateway_launchd.py:210-212`, systemd
///    `ExecStart` at `hermes_cli/gateway_service_unit.py:223`, the flag from
///    `_profile_arg`, `hermes_cli/gateway.py:2184-2193`). A foreground
///    `hermes -p <name> gateway run` is the same shape, and Hermes also
///    accepts the flag after the subcommand (`_scan_profile_flag`,
///    `hermes_cli/main.py:484-514`). The old pattern needed `gateway` right
///    after the entry point, so no named-profile gateway ever matched.
/// 2. **The match is scoped to the profile being viewed.** Hermes's own scan
///    (`_scan_gateway_pids`, `hermes_cli/gateway.py:585-660`) accepts a
///    named profile only when `-p`/`--profile` names it, and the default
///    profile only when no profile flag is present. Without that, a default
///    gateway read as "running" for every profile.
/// 3. **The launchd wrappers must not match.** On macOS the job is
///    `/usr/bin/osascript -e 'do shell script "exec … -m hermes_cli.stderr_timestamp
///    … -- … -m hermes_cli.main gateway run …"'` (`gateway_launchd.py:233-235,260`).
///    Both the osascript process and the `stderr_timestamp` wrapper carry the
///    gateway argv inside their own, and both have lower PIDs than the real
///    gateway, so `pgrep`'s first line was the osascript wrapper — shown as
///    the gateway's PID and, on the stop fallback, sent SIGTERM. Hermes skips
///    osascript explicitly (`gateway/status.py:523`). Here the pattern is
///    anchored at the start of the command line and allows no `-`-led
///    argument before `-m hermes_cli.main` (or before the `hermes` script)
///    other than Python's argument-less switches, so
///    `osascript -e …` and `python -m hermes_cli.stderr_timestamp …` can't
///    match while `…/python -m hermes_cli.main …` and `…/python …/bin/hermes
///    …` still do, including paths with spaces.
///
/// Profile names are `[a-z0-9][a-z0-9_-]*` (``HermesProfileScope/isValidName(_:)``),
/// so a name needs no escaping inside the pattern.
public enum HermesGatewayProcessMatch {

    private static let ws = "[[:space:]]"
    /// From the start of the command line: any run of arguments none of
    /// which begins with `-`, except Python's argument-less switches
    /// (`python -u -m …`, `python -I …/bin/hermes …`). `-e` (osascript),
    /// `-c` and `-m` are not among them, which is what keeps the wrappers out.
    private static let plainArgs = "([^[:space:]]|[[:space:]]+[^-[:space:]]|[[:space:]]+-[BEIOSbdiqsuv])*"

    private static func flag(_ name: String) -> String {
        "\(ws)+(-p|--profile)(\(ws)+|=)\(name)"
    }

    /// `pgrep -f` pattern for the gateway of `profile` (`nil`, empty or
    /// `"default"` = the root/default profile).
    ///
    /// The default profile also accepts an explicit `-p default` / `--profile
    /// default` before `gateway`, which starts the same root gateway. A
    /// default-scope match can't see a profile flag written AFTER `gateway
    /// run` (ERE has no negative lookahead); Hermes's own launchers never put
    /// it there.
    public static func pgrepPattern(profile: String?) -> String {
        let named = HermesProfileScope.normalize(profile)
        let before = named.map { flag($0) } ?? "(\(flag("default")))?"
        let run = "\(ws)+gateway\(ws)+run"
        let end = "(\(ws)|$)"
        var forms = [
            "^\(plainArgs)\(ws)+-m\(ws)+hermes_cli\\.main\(before)\(run)\(end)",
            "^(\(plainArgs)[[:space:]/])?hermes\(before)\(run)\(end)",
        ]
        if let named {
            // The flag after the subcommand: `hermes gateway run -p <name>`.
            let after = "\(run)(\(ws)+[^[:space:]]+)*\(flag(named))\(end)"
            forms.append("^\(plainArgs)\(ws)+-m\(ws)+hermes_cli\\.main\(after)")
            forms.append("^(\(plainArgs)[[:space:]/])?hermes\(after)")
        }
        return forms.joined(separator: "|")
    }

    // MARK: - `gateway.pid` fallback

    /// The PID a `<HERMES_HOME>/gateway.pid` names, if the record is usable
    /// for `profile`.
    ///
    /// Hermes writes `{"pid", "kind": "hermes-gateway", "argv", "start_time",
    /// "hermes_home"}` there (`_build_pid_record`, `gateway/status.py:677-684`
    /// @ v2026.9.24; the same record since v2026.3.30), and its reader also
    /// accepts a bare PID (`_read_pid_record`, `:752-753`, `bare_pid_ok`). A
    /// record whose `kind` is not the gateway's, or whose `hermes_home` is not
    /// this profile's home, is refused — a stale file must not lend the
    /// profile somebody else's process.
    public static func pid(fromPidFile data: Data, profile: String?) -> Int32? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let bare = Int32(text) { return bare > 0 ? bare : nil }
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let kind = record["kind"] as? String, kind != "hermes-gateway" { return nil }
        if let home = record["hermes_home"] as? String {
            let recorded = HermesProfileScope.profileName(forHome: home)
            if recorded != HermesProfileScope.normalize(profile) { return nil }
        }
        let pid = (record["pid"] as? NSNumber)?.int32Value ?? Int32((record["pid"] as? String) ?? "")
        guard let pid, pid > 0 else { return nil }
        return pid
    }

    /// Is `commandLine` (as `ps -o command=` prints it) a `gateway run` that
    /// can belong to `profile`? For a named profile that is its own flagged
    /// form OR the unflagged form — a gateway started with `HERMES_HOME`
    /// set in its environment carries no `-p` at all, which is exactly why
    /// `pgrep` cannot find it. Same anchored patterns, so the launchd
    /// wrappers are refused here too.
    ///
    /// The unflagged form is STRICT for a named profile: no `-p`/`--profile`
    /// anywhere on the line (so neither `-p default` nor a trailing `-p ops`
    /// passes as this profile's gateway).
    public static func commandLineIsGateway(_ commandLine: String, profile: String?) -> Bool {
        if ereMatches(pgrepPattern(profile: profile), commandLine) { return true }
        guard HermesProfileScope.normalize(profile) != nil else { return false }
        let tokens = commandLine.split(whereSeparator: \.isWhitespace)
        let flagged = tokens.contains { $0 == "-p" || $0 == "--profile"
            || $0.hasPrefix("--profile=") || $0.hasPrefix("-p=") }
        return !flagged && ereMatches(pgrepPattern(profile: nil), commandLine)
    }

    /// The `start_time` a pid record carries — Hermes's PID-reuse
    /// fingerprint (`_get_process_start_time`, `gateway/status.py:458-468`:
    /// `/proc/<pid>/stat` field 22 on Linux, psutil centiseconds elsewhere).
    public static func startTime(fromPidFile data: Data) -> Int? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (record["start_time"] as? NSNumber)?.intValue
    }

    /// Field 22 (`starttime`) of a Linux `/proc/<pid>/stat`. Parsed after the
    /// LAST `)` because the command name in field 2 may contain spaces or
    /// parentheses.
    public static func procStatStartTime(_ stat: String) -> Int? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let rest = stat[stat.index(after: close)...].split(whereSeparator: \.isWhitespace)
        // `rest[0]` is field 3 (state), so field 22 is rest[19].
        guard rest.count > 19 else { return nil }
        return Int(rest[19])
    }

    /// POSIX `regcomp(REG_EXTENDED)` — the engine `pgrep -f` uses.
    static func ereMatches(_ pattern: String, _ line: String) -> Bool {
        var re = regex_t()
        guard regcomp(&re, pattern, REG_EXTENDED | REG_NOSUB) == 0 else { return false }
        defer { regfree(&re) }
        return regexec(&re, line, 0, nil, 0) == 0
    }

    /// The PID on the first non-empty line of `pgrep` output.
    public static func firstPID(inPgrepOutput output: String) -> Int32? {
        output.components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
