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

    /// The PID on the first non-empty line of `pgrep` output.
    public static func firstPID(inPgrepOutput output: String) -> Int32? {
        output.components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
