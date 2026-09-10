import Foundation

/// The verdict on one `hermes` CLI invocation, judged by what the emitter
/// PRINTED rather than by the exit code (charter C5).
///
/// ## Why the exit code is not the truth
///
/// Most `hermes` subcommand handlers are `-> None` functions that `print()` a
/// refusal and `return`. Python turns a `None` return into exit status 0, so a
/// refused install, a not-found session, a failed OAuth flow and an ungranted
/// capability all arrive at Scarf as "exit 0". Verbatim at v2026.9.7:
///
/// - `hermes_cli/skills_hub.py:645-648` — `def do_install(...) -> None`, with
///   nine bare `return`s after printing (`:659`, `:662`, `:667`, `:669`,
///   `:684-685`, `:691`, `:696`, `:711`, `:715`).
/// - `hermes_cli/sessions_cmd.py:46-48` — `_not_found()` prints
///   `Session '<id>' not found.` **to stdout** and returns 1, but its callers
///   (`:319`, `:392`, `:488`) discard that and return `None`.
/// - `hermes_cli/mcp_config.py:709-713` — `cmd_mcp_login` calls
///   `_reauth_oauth_server(...)` and DISCARDS the `bool` it returns.
/// - `hermes_cli/cron.py:661-662` — a manual run that FAILED still returns 0
///   from `_job_action`, printing `  Ran now: failed.` (`_run_outcome`, `:677`).
/// - `hermes_cli/plugins_cmd.py:1092-1098` — `_run_capability_consent` prints
///   `capabilities NOT granted (fail closed).` on a non-TTY and returns False,
///   which `cmd_enable` (`:1033`) discards.
///
/// ## The rule
///
/// A run is a success only when the emitter's own SUCCESS line is present and
/// no refusal line is. Absence of both is a failure, not a success — that is
/// exactly the "unknown verb routed to the agent and 'succeeded'" case C5
/// exists to forbid.
///
/// Every marker used by Scarf's call sites has been walked back to v2026.6.19
/// (v0.17.0) and is byte-identical at every tag since, so this judgement does
/// not change behaviour on a pre-target host (charter C1).
public struct HermesCLIOutcome: Sendable, Equatable {
    /// True only when the emitter printed its own success line.
    public let succeeded: Bool
    /// The emitter's own one-line explanation of a refusal, when it printed
    /// one. `nil` on success, and on a failure with nothing quotable.
    public let detail: String?

    public init(succeeded: Bool, detail: String?) {
        self.succeeded = succeeded
        self.detail = detail
    }
}

/// Judges `hermes` CLI runs by their printed output.
public enum HermesCLIVerdict {
    /// Strips SGR/CSI escape sequences. Hermes colours its output through
    /// `rich` and `hermes_cli.colors.color()`; a `Process` pipe is not a TTY so
    /// they are normally suppressed, but `FORCE_COLOR`/`CLICOLOR_FORCE` in the
    /// user's environment (and some SSH wrappers) put them back, and a marker
    /// that starts a line would then be preceded by `ESC[32m`.
    /// NB the pattern is NOT a raw string: `\u{1B}` is a **Swift** escape for
    /// ESC, and ICU's regex dialect has no `\u{…}` form — inside a `#"…"#`
    /// literal it reached the engine verbatim and matched nothing, so this
    /// stripped no colour at all. Anchored markers depend on it.
    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )
    }

    /// The output's non-empty lines, ANSI-stripped and whitespace-trimmed.
    public static func significantLines(_ output: String) -> [String] {
        stripANSI(output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One already-trimmed line with any leading status glyph removed, so an
    /// anchored marker can be tested with `hasPrefix`. Hermes prefixes its
    /// success/refusal lines through small helpers — `  ✓ ` / `  ✗ ` / `  ⚠ `
    /// (`hermes_cli/mcp_config.py:34-36`), `⊘` (`plugins_cmd.py:1198`) — and
    /// the marker text starts immediately after.
    public static func unglyphed(_ line: String) -> String {
        var head = Substring(line)
        while let first = head.first, Self.statusGlyphs.contains(first) || first == " " {
            head = head.dropFirst()
        }
        return String(head)
    }

    private static let statusGlyphs: Set<Character> = ["\u{2713}", "\u{2717}", "\u{26A0}", "\u{2298}", "\u{2022}"]

    /// - Parameters:
    ///   - output: combined stdout+stderr (or stdout alone — both work; the
    ///     markers are line-scoped, not offset-scoped).
    ///   - exitCode: used only to fail fast; a zero exit never *implies*
    ///     success.
    ///   - successMarkers: verbatim substrings the emitter prints ONLY on the
    ///     success path.
    ///   - failureMarkers: verbatim substrings the emitter prints ONLY on a
    ///     refusal path.
    ///   - failureWins: what to do when BOTH a success and a failure marker are
    ///     present. Default `false`, which matches the usual emitter shape: the
    ///     refusal arms all `return` before the success line is reached, so a
    ///     success marker is proof and a stray failure phrase inside a report
    ///     body (a scan finding quoting "Error:", say) must not flip a real
    ///     success. `true` is for the emitters that print BOTH by design — the
    ///     one in this group is `cron run`, whose `_job_action` prints the green
    ///     `Triggered job:` line (cron.py:658) and then `  Ran now: failed.`
    ///     (`:662`, `:677`).
    ///   - fallbackDetail: quote the last significant line when no failure
    ///     marker matched. On for commands whose every refusal is a single
    ///     terminal line; off where trailing chatter (hints, next-step
    ///     instructions) would be quoted instead of the reason.
    ///   - successAnchored: require the success marker to START its line
    ///     (after ANSI stripping, trimming and any leading status glyph)
    ///     rather than appear anywhere in it. On for every emitter that
    ///     prints its success line at column 0, which is all of them except
    ///     the `plugins` ones — there the marker is a mid-sentence clause.
    ///     A bare substring is not safe there: with the usual
    ///     `failureWins: false`, a success PHRASE quoted inside a report body
    ///     outranks a real refusal. `do_install` is the live case —
    ///     `_print_tier1_advisory` (skills_hub.py:704, 726-747) prints
    ///     SKILL.md-derived findings BEFORE `install_from_quarantine` can
    ///     raise (:714-720), so a skill whose own text contains
    ///     `Installed: …` used to be reported installed after it was refused.
    public static func judge(
        output: String,
        exitCode: Int32,
        successMarkers: [String],
        failureMarkers: [String] = [],
        failureWins: Bool = false,
        fallbackDetail: Bool = true,
        successAnchored: Bool = false
    ) -> HermesCLIOutcome {
        let lines = significantLines(output)
        let refusal = lines.first { line in failureMarkers.contains { line.contains($0) } }
        func failed(_ detail: String?) -> HermesCLIOutcome {
            HermesCLIOutcome(succeeded: false, detail: detail ?? (fallbackDetail ? lines.last : nil))
        }
        func matchesSuccess(_ line: String) -> Bool {
            guard successAnchored else { return successMarkers.contains { line.contains($0) } }
            let head = unglyphed(line)
            return successMarkers.contains { head.hasPrefix($0) }
        }
        guard exitCode == 0 else { return failed(refusal) }
        if failureWins, refusal != nil { return failed(refusal) }
        if lines.contains(where: matchesSuccess) {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        // Exit 0 with no success line: a `None`-returning refusal we have no
        // marker for, or an unknown verb whose output the agent wrote. Never a
        // success (C5).
        return failed(refusal)
    }
}

/// The markers each Scarf call site judges by, captured verbatim from the
/// Hermes source at tag v2026.9.7 (charter C2). Each entry cites the emitting
/// `file:line`. Substrings only — the surrounding text interpolates a name, a
/// path or a count.
public enum HermesCLIMarkers {
    // MARK: skills install / uninstall — hermes_cli/skills_hub.py

    /// `c.print(f"[bold green]Installed:[/] {…}")` — skills_hub.py:720.
    /// (Same line, same prefix, at v2026.6.19:691 through v2026.8.31:799.)
    public static let skillsInstallSuccess = ["Installed:"]

    /// Every refusal `do_install` can print, in source order:
    /// - `Error:` — `_print_error` (skills_hub.py:134-135), reached from
    ///   `_pinned_sources` (:582) and `_print_fetch_failure` (:592).
    /// - `Installation blocked:` — `_install_blocked` (:498), reached from the
    ///   scan verdict (:707) and `_invalid_path` (:506).
    /// - `is already installed at` / `Use --force to reinstall.` — :683-686.
    /// - `Cannot install from URL:` / `Invalid --name:` —
    ///   `_resolve_url_bundle_name` (:520, :525).
    /// - `Installation cancelled.` — `_confirm_install` (:642) and :537.
    public static let skillsInstallFailure = [
        "Error:",
        "Installation blocked:",
        "is already installed at",
        "Use --force to reinstall.",
        "Cannot install from URL:",
        "Invalid --name:",
        "Installation cancelled.",
    ]

    /// `_report_pair` prints `uninstall_skill`'s message green on success —
    /// `Uninstalled '<name>' from <path>` (tools/skills_hub_install.py:220),
    /// via skills_hub.py:917,144-150.
    public static let skillsUninstallSuccess = ["Uninstalled"]

    /// `_report_pair`'s failure arm is `_print_error` → `Error: …`
    /// (skills_hub.py:149, 134-135). `Uninstall '<name>'?` cancelled prints
    /// nothing at all, which the "no success marker" rule already catches.
    public static let skillsUninstallFailure = ["Error:"]

    // MARK: sessions export — hermes_cli/sessions_cmd.py

    /// Every file-writing export path ends in an `Exported …` summary:
    /// `_write_output` (:83) printing `_render_only` (:344), `_render_html`
    /// (:352) or `_render_jsonl` (:357); plus `:424`, `:434`, `:480`, `:508`.
    /// Stable since v2026.6.19 (main.py:12279).
    ///
    /// NB this marker only applies to a real `--output <path>` run.
    /// `_write_output` (:78-80) prints NO summary when the output is `-`; that
    /// path is judged by validating the payload instead.
    public static let sessionsExportSuccess = ["Exported "]

    /// The refusals `_cmd_export` and its renderers print, all to stdout:
    /// - `not found.` — `_not_found` (:47).
    /// - `Error:` — the filter-parse arm (:302).
    /// - the `_FLAT_EXPORTERS` usage messages (:363, :365, :366).
    /// - the markdown/QMD usage refusals (:443, :456, :459, :465-466).
    /// - `Refusing to export unredacted trace content.` (:436) and the trace
    ///   usage refusals (:389, :398, :422).
    /// - `Pass --force to overwrite.` (:476, :500).
    public static let sessionsExportFailure = [
        "not found.",
        "Error:",
        "--only user-prompts supports",
        "HTML export requires an output file path.",
        "JSONL export requires an output path",
        "Markdown/QMD export writes files;",
        "--delete-after-verified requires --yes.",
        "--delete-after-verified is only supported with --session-id.",
        "Refusing bulk export without a filter.",
        "Pass --force to overwrite.",
        "refusing to export unredacted trace content.",
        "No session found to export.",
        "--upload exports one session:",
        "No transcript to export for session",
        "--dry-run requires at least one filter.",
    ]

    // MARK: mcp login — hermes_cli/mcp_config.py

    /// `_success(f"Authenticated — {len(tools)} tool(s) available")` (:695)
    /// and `_success("Authenticated (server reported no tools)")` (:697),
    /// both `  ✓ ` -prefixed by `_success` (:34). Stable since v2026.6.19:746.
    public static let mcpLoginSuccess = ["Authenticated"]

    /// The refusals on the login path, all `_error`/`_warning` -prefixed
    /// (`  ✗ ` / `  ⚠ `, mcp_config.py:35-36):
    /// - `Server '<name>' not found in config.` — `_lookup_server` (:104);
    ///   `cmd_mcp_login` (:711-713) then does nothing at all.
    /// - `has no URL — not an OAuth-capable server` (:631).
    /// - `is not configured for OAuth` (:634).
    /// - `oauth.flow must be browser or device` (:641).
    /// - `no OAuth token was obtained — authentication did not complete.`
    ///   (:677) — the case where the probe SUCCEEDS but the flow did not.
    /// - `Authentication failed:` (:705).
    public static let mcpLoginFailure = [
        "not found in config.",
        "not an OAuth-capable server",
        "is not configured for OAuth",
        "oauth.flow must be browser or device",
        "no OAuth token was obtained",
        "Authentication failed:",
    ]

    // MARK: cron run — hermes_cli/cron.py

    /// `_job_action` prints `{success_verb} job: <name> (<id>)` (:658). The
    /// `run` action's verb is `"Triggered"` (`_JOB_ACTIONS`, cron.py:763), so
    /// the line reads `Triggered job: <name> (<id>)`. Stable since
    /// v2026.6.19:350.
    public static let cronRunSuccess = ["Triggered job:"]

    /// - `Failed to run job:` — `_job_action` (:655), the only nonzero arm.
    /// - `Ran now: failed.` — `_run_outcome` (:677), printed at :662 AFTER the
    ///   green `Triggered job:` line and still returning 0. This is the marker
    ///   that must beat the success marker, which is why a failure match wins.
    ///   A v0.17 host prints no `Ran now:` line at all (it first appears at
    ///   v2026.7.1:411), so this marker simply never fires there — the pre-
    ///   target verdict is unchanged (charter C1).
    public static let cronRunFailure = [
        "Failed to run job:",
        "Ran now: failed.",
    ]

    // MARK: plugins enable / disable — hermes_cli/plugins_cmd.py

    /// `✓ Plugin <key> enabled. Takes effect on next session.` (:1023), or
    /// `Plugin '<key>' is already enabled.` (:1012) when it was already on.
    /// Stable since v2026.6.19:801.
    public static let pluginsEnableSuccess = [
        "Takes effect on next session.",
        "is already enabled.",
    ]

    /// `capabilities NOT granted (fail closed).` —
    /// `_run_capability_consent`'s non-TTY arm (:1092-1098), which
    /// `cmd_enable` (:1033) calls and discards. Scarf has no TTY, so this is
    /// the arm it ALWAYS takes for a capability-declaring plugin.
    /// `_fail` (:1005, :999) prints `Plugin '<name>' is not installed or
    /// bundled.` / `was removed.` and exits nonzero.
    public static let pluginsEnableFailure = [
        "capabilities NOT granted",
        "is not installed or bundled.",
        "was removed.",
    ]

    /// `⊘ Plugin <key> disabled. Takes effect on next session.` (:1198), or
    /// the already-disabled line.
    public static let pluginsDisableSuccess = [
        "Takes effect on next session.",
        "is already disabled.",
    ]

    /// Same `_fail` refusal as enable, minus one: `disable` runs no consent
    /// screen and no legacy-relay refusal.
    ///
    /// `was removed.` was a DEAD marker here. The phrase is printed only by
    /// `_refuse_legacy_relay` (plugins_cmd.py:996-1002 at v2026.9.7), which is
    /// defined inside — and called only from — `cmd_enable` (`:1002`, `:1007`).
    /// Floor walk over every `v2026.*` tag carrying `hermes_cli/plugins_cmd.py`
    /// (v2026.3.23 … v2026.9.7): the string first appears at **v2026.8.19**, at
    /// lines 1424 and 1439, both inside `cmd_enable` (`:1405`) and well above
    /// `cmd_disable` (`:1710`); identical at v2026.8.27 and v2026.8.31. So no
    /// supported host has ever printed it from `plugins disable`, and carrying
    /// it here only risked flipping a real disable into a failure.
    public static let pluginsDisableFailure = [
        "is not installed or bundled.",
    ]

    /// `✓ Plugin <name> updated.` (:828) or
    /// `✓ Plugin <name> is already up to date.` (:826) — `cmd_update`'s two
    /// success lines, both printed AFTER the capability consent screen, which
    /// is why `update` judges with `failureWins: true` like `enable`.
    public static let pluginsUpdateSuccess = [
        "updated.",
        "is already up to date.",
    ]

    /// `cmd_update` (plugins_cmd.py:822) calls `_run_capability_consent(...)`
    /// and DISCARDS its bool exactly as `cmd_enable` does, so the non-TTY arm
    /// (:1092-1098) fires and the update still announces success. Its other
    /// refusals go through `_fail` (`[red]Error:[/red] …`, :809, :80-83) and
    /// exit 1, so they are caught by the exit code too. (`Error:` is also what
    /// `cmd_remove` prints on its only refusal, :895.)
    public static let pluginsUpdateFailure = [
        "capabilities NOT granted",
        "Error:",
    ]

    /// `cmd_install` (plugins_cmd.py:764) discards the same bool. Unlike
    /// `enable`/`update`, `install` reports through `HermesPluginInstallOutcome`,
    /// so this is the one marker that path needs.
    public static let pluginsConsentRefusal = "capabilities NOT granted"

    // MARK: skills audit / update — hermes_cli/skills_hub.py

    /// `do_audit` is `-> None` (skills_hub.py:878) and exits 0 on its refusal
    /// too. `Auditing <n> skill(s)...` (:891) is the only line that says the
    /// scan actually ran; `No hub-installed skills to audit.` (:886) is a
    /// legitimate empty run, not a failure. Both byte-identical back to
    /// v2026.6.19.
    public static let skillsAuditSuccess = [
        "Auditing ",
        "No hub-installed skills to audit.",
    ]

    /// `_print_error` (skills_hub.py:134-135) via the unknown-name arm (:890).
    public static let skillsAuditFailure = ["Error:"]

    /// `do_update`'s nothing-to-do line (skills_hub.py:831), verbatim and
    /// byte-identical back to v2026.6.19.
    public static let skillsUpdateNoUpdates = "No updates available."

    /// `do_update`'s per-skill ATTEMPT line (skills_hub.py:834). It is printed
    /// before `do_install` runs, so it proves an attempt and nothing more.
    public static let skillsUpdateAttempt = "Updating:"
}

/// `hermes security audit`'s three-way exit contract — the one site in this
/// group that does NOT return `None` on failure, and whose exit code IS
/// meaningful (in three states, not two).
///
/// `hermes_cli/security_audit.py::cmd_security_audit` (v2026.9.7:286-312):
/// - `return 2` on an unusable `--fail-on` (:293) or an OSV `RuntimeError`
///   (:307), both after printing to **stderr**;
/// - otherwise it prints the report to stdout (:309) and returns
///   `int(any(severity >= threshold))` (:311-312) — so **1 means findings at
///   or above the threshold**, not a failed run.
///
/// `hermes_cli/main.py::cmd_security` (:2074-2075) passes that straight to
/// `sys.exit`. Rendering exit 1 as "Audit failed" told the user the scan broke
/// when in fact it worked and found something.
public enum HermesSecurityAuditVerdict: Equatable, Sendable {
    /// Exit 0 — the scan ran, nothing met the threshold.
    case clean
    /// Exit 1 — the scan ran and found advisories at or above `--fail-on`.
    case findings
    /// Exit 2 (or anything else) — the scan itself failed.
    case failed(Int32)

    public init(exitCode: Int32) {
        switch exitCode {
        case 0: self = .clean
        case 1: self = .findings
        default: self = .failed(exitCode)
        }
    }
}

/// The `hermes security audit` human report, parsed just enough to tell the
/// two exit-0 cases apart.
///
/// `--fail-on critical` (Scarf's explicit threshold, and Hermes's default)
/// makes the exit code answer only "was anything CRITICAL?". Exit 0 therefore
/// covers both "nothing found at all" and "high/moderate/low advisories
/// found" — and the `.clean` arm was printing the tail of a report that was
/// listing real vulnerabilities, with no label saying so.
///
/// `_render_human` (`hermes_cli/security_audit.py:254-268` at v2026.9.7) emits
/// exactly one of two heads —
/// `No known vulnerabilities found across <n> component(s).` (:255) or
/// `Found <n> known vulnerability finding(s) across <m> component(s):` (:257) —
/// then one `  {severity.ljust(8)}  {name}=={version}  {osv-id}` row per
/// finding (:264). Both heads and the row shape are byte-identical back to
/// **v2026.5.29** — the release `security audit` shipped in and the floor of
/// `hasHermesAudit` — so this parse changes nothing on a pre-target host (C1).
///
/// A third exit-0 shape has no findings section at all:
/// `No components discovered (everything skipped, or empty environment).`
/// (`cmd_security_audit`, :299-301).
public struct HermesSecurityAuditReport: Sendable, Equatable {
    /// `n` from the `Found n known vulnerability finding(s)` head; 0 when the
    /// report's head is the clean one.
    public let findingCount: Int
    /// Severity tier → number of rows, using the emitter's own uppercase
    /// spellings (`SEVERITY_ORDER`, :29 — UNKNOWN/LOW/MODERATE/MEDIUM/HIGH/
    /// CRITICAL).
    public let severityCounts: [String: Int]

    public init(findingCount: Int, severityCounts: [String: Int]) {
        self.findingCount = findingCount
        self.severityCounts = severityCounts
    }

    /// Highest-first summary of the tiers present, e.g. `2 high · 1 moderate`.
    public var severitySummary: String {
        Self.severityOrder.compactMap { tier -> String? in
            guard let n = severityCounts[tier], n > 0 else { return nil }
            return "\(n) \(tier.lowercased())"
        }.joined(separator: " · ")
    }

    /// `SEVERITY_ORDER`'s keys, highest first. `MEDIUM` is OSV's alias for
    /// `MODERATE` (same rank, :29) and both can appear in a report.
    static let severityOrder = ["CRITICAL", "HIGH", "MODERATE", "MEDIUM", "LOW", "UNKNOWN"]

    public static func parse(_ output: String) -> HermesSecurityAuditReport {
        var count = 0
        var counts: [String: Int] = [:]
        for line in HermesCLIVerdict.significantLines(output) {
            if count == 0, line.hasPrefix(Self.foundPrefix), line.contains("known vulnerability finding(s)") {
                let digits = line.dropFirst(Self.foundPrefix.count).prefix { $0.isNumber }
                count = Int(digits) ?? 0
                continue
            }
            // A finding row: `<SEVERITY>  <name>==<version>  <OSV-ID>`. The
            // trimmed line starts with the tier word, and the `==` pins it to
            // a row rather than any prose that happens to open with one.
            guard let tier = line.split(separator: " ").first.map(String.init),
                  Self.severityOrder.contains(tier),
                  line.contains("==")
            else { continue }
            counts[tier, default: 0] += 1
        }
        return HermesSecurityAuditReport(findingCount: count, severityCounts: counts)
    }

    private static let foundPrefix = "Found "
}
