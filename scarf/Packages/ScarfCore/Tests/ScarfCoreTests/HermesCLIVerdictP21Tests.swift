import Testing
import Foundation
@testable import ScarfCore

/// Phase P21 of the round-2 whole-surface audit: verdicts that judge the wrong
/// thing. Every fixture is VERBATIM emitter text at tag **v2026.9.7**
/// (`git -C ~/.hermes/hermes-agent show v2026.9.7:<path>`) and every test fails
/// if the fix it pins is reverted.
@Suite("Hermes CLI verdicts — P21 output correctness")
struct HermesCLIVerdictP21Tests {

    // MARK: - Anchored success markers

    /// `do_install` runs `_print_tier1_advisory` (hermes_cli/skills_hub.py:704) BEFORE
    /// `install_from_quarantine` can raise (:714-720), and that advisory
    /// quotes the skill's OWN SKILL.md text into the report. With the default
    /// `failureWins: false`, a bare-substring success marker let that quoted
    /// text outrank the refusal that followed it.
    ///
    /// The real `Installed:` line is printed at column 0 (:720), so anchoring
    /// keeps the quote from matching while keeping the genuine line matched.
    @Test func quotedSuccessPhraseInsideTheAdvisoryDoesNotBeatARefusal() {
        let output = """
        Quarantined to quarantine/reddit-a1b2c3
        ╭─ SkillEvaluator Tier 1 (advisory) ─╮
        │ scripts/setup.sh:12  Installed: /usr/local/bin/reddit-helper
        ╰────────────────────────────────────╯
        Installation blocked: quarantine path escapes the hub root
        """
        let outcome = HermesCLIVerdict.judge(
            output: output,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.skillsInstallSuccess,
            failureMarkers: HermesCLIMarkers.skillsInstallFailure,
            successAnchored: true
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.detail?.contains("Installation blocked:") == true)

        // …and the un-anchored judgement is exactly the bug: same fixture,
        // reported as a successful install.
        let unanchored = HermesCLIVerdict.judge(
            output: output,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.skillsInstallSuccess,
            failureMarkers: HermesCLIMarkers.skillsInstallFailure
        )
        #expect(unanchored.succeeded == true)
    }

    /// Anchoring must not cost a real success. `Installed:` is at column 0;
    /// `mcp_config.py::_success` prefixes `  ✓ ` (:34), which `unglyphed`
    /// strips.
    @Test(arguments: [
        ("Installed: research/reddit\n", HermesCLIMarkers.skillsInstallSuccess),
        ("  ✓ Authenticated — 3 tool(s) available\n", HermesCLIMarkers.mcpLoginSuccess),
        ("  ✓ Authenticated (server reported no tools)\n", HermesCLIMarkers.mcpLoginSuccess),
        ("Uninstalled 'reddit' from research/reddit\n", HermesCLIMarkers.skillsUninstallSuccess),
        ("Exported 4 session(s) to /tmp/out.jsonl\n", HermesCLIMarkers.sessionsExportSuccess),
        ("Triggered job: nightly (job-1)\n", HermesCLIMarkers.cronRunSuccess),
    ])
    func genuineSuccessLinesStillMatchWhenAnchored(fixture: (String, [String])) {
        let outcome = HermesCLIVerdict.judge(
            output: fixture.0, exitCode: 0, successMarkers: fixture.1, successAnchored: true
        )
        #expect(outcome.succeeded)
    }

    /// `hermes_cli/colors.py::should_use_color()` is `sys.stdout.isatty()`, so
    /// a piped run carries no ANSI — but `FORCE_COLOR` in the user's
    /// environment puts it back, and an anchored marker would then start at
    /// `ESC[32m`. The strip runs before the anchor test.
    @Test func anchoringSurvivesForcedANSIColour() {
        let outcome = HermesCLIVerdict.judge(
            output: "\u{1B}[1;32mInstalled:\u{1B}[0m research/reddit\n",
            exitCode: 0,
            successMarkers: HermesCLIMarkers.skillsInstallSuccess,
            successAnchored: true
        )
        #expect(outcome.succeeded)
    }

    // MARK: - The dead `was removed.` disable marker

    /// `was removed.` is printed only by `_refuse_legacy_relay`
    /// (plugins_cmd.py:996-1002), which is defined inside and called only from
    /// `cmd_enable` (:1002, :1007). Floor walk over every `v2026.*` tag that
    /// carries `hermes_cli/plugins_cmd.py`: the string first appears at
    /// v2026.8.19 (lines 1424, 1439 — both inside `cmd_enable` at :1405, above
    /// `cmd_disable` at :1710) and is unchanged at v2026.8.27 / v2026.8.31.
    /// `cmd_disable` has never printed it, so carrying it as a disable failure
    /// marker could only produce a false negative.
    @Test func pluginsDisableCarriesNoLegacyRelayMarker() {
        #expect(HermesCLIMarkers.pluginsDisableFailure.contains("was removed.") == false)
        // It is still enable's, where the emitter really can print it.
        #expect(HermesCLIMarkers.pluginsEnableFailure.contains("was removed."))
    }

    // MARK: - security audit: exit 0 is not "clean"

    /// `--fail-on critical` makes exit 0 mean "nothing CRITICAL", not "nothing
    /// found" (`int(any(severity >= threshold))`, security_audit.py:311-312).
    /// The report's own head (:255 / :257) is what tells the two apart.
    @Test func exitZeroWithHighSeverityAdvisoriesIsNotAnEmptyReport() {
        let report = HermesSecurityAuditReport.parse("""
        Found 3 known vulnerability finding(s) across 214 component(s):

        [venv]
          HIGH      requests==2.19.1  GHSA-x84v-xcm2-53pg
                    Unintended leak of Proxy-Authorization header
                    fixed in: 2.31.0
          MODERATE  jinja2==3.1.2  GHSA-h5c8-rqwp-cp95
                    Jinja2 sandbox escape
        [mcp]
          LOW       idna==3.3  GHSA-jjg7-2v4v-x38h
        """)
        #expect(report.findingCount == 3)
        #expect(report.severityCounts == ["HIGH": 1, "MODERATE": 1, "LOW": 1])
        #expect(report.severitySummary == "1 high · 1 moderate · 1 low")
    }

    /// The genuinely clean report (`_render_human`, :255) and the
    /// nothing-to-scan case (`cmd_security_audit`, :299-301) both parse to
    /// zero findings, so the label stays what it always was.
    @Test(arguments: [
        "No known vulnerabilities found across 214 component(s).",
        "No components discovered (everything skipped, or empty environment).",
    ])
    func cleanReportsParseToNoFindings(output: String) {
        let report = HermesSecurityAuditReport.parse(output)
        #expect(report.findingCount == 0)
        #expect(report.severitySummary.isEmpty)
    }

    /// A summary line quoting a severity word is not a finding row — the `==`
    /// (from `{name}=={version}`, :264) is what makes a row a row.
    @Test func proseIsNotCountedAsAFindingRow() {
        let report = HermesSecurityAuditReport.parse("""
        Found 1 known vulnerability finding(s) across 3 component(s):

        HIGH severity findings should be triaged first.
        [venv]
          HIGH      urllib3==1.26.4  GHSA-q2q7-5pp4-w6pg
        """)
        #expect(report.severityCounts == ["HIGH": 1])
    }

    // MARK: - skills update: `Updated N skill(s).` counts attempts

    /// `do_update` (hermes_cli/skills_hub.py:848-872) prints
    /// `Updated {len(updates) - len(skipped_local)} skill(s).` after the loop
    /// no matter what each nested `do_install` did — and `do_install` is
    /// itself `-> None`, so a blocked scan prints its refusal and returns at
    /// exit 0. The honest per-skill signal is `Installed:` (:720).
    @Test func attemptedUpdateThatInstalledNothingIsNotAnUpdate() {
        let report = HermesSkillsHubParser.parseUpdateReport("""
        Updating: reddit
        Quarantined to quarantine/reddit-a1b2c3
        Installation blocked: dangerous verdict (3 findings)
        Updated 1 skill(s).
        """)
        // What Hermes claimed…
        #expect(report.updatedCount == 1)
        // …and what actually happened.
        #expect(report.attemptedCount == 1)
        #expect(report.installedCount == 0)
        #expect(report.failureDetail?.contains("Installation blocked:") == true)
    }

    /// A real update: one attempt, one `Installed:` line.
    @Test func aRealUpdateCountsTheInstalledLine() {
        let report = HermesSkillsHubParser.parseUpdateReport("""
        Updating: reddit
        Installed: research/reddit
        Files: SKILL.md, scripts/fetch.py

        Updated 1 skill(s).
        """)
        #expect(report.attemptedCount == 1)
        #expect(report.installedCount == 1)
        #expect(report.failureDetail == nil)
        #expect(report.noUpdatesAvailable == false)
    }

    /// `No updates available.` (:831) is a legitimate no-op, not "nothing
    /// recognised".
    @Test func noUpdatesAvailableIsItsOwnOutcome() {
        let report = HermesSkillsHubParser.parseUpdateReport("No updates available.\n")
        #expect(report.noUpdatesAvailable)
        #expect(report.attemptedCount == 0)
        #expect(report.installedCount == 0)
        #expect(report.updatedCount == 0)
    }

    /// The v0.20.4 local-edits skip (:838-841, :872-875) must keep working —
    /// this is the pre-existing behaviour the new counters sit beside.
    @Test func localEditSkipsAreStillReported() {
        let report = HermesSkillsHubParser.parseUpdateReport("""
        Skipping: reddit — you have local edits (update would overwrite them).
        Updating: hn
        Installed: research/hn
        Updated 1 skill(s).
        1 skill(s) kept your local edits: reddit.
        Overwrite with: hermes skills update <name> --force
        """)
        #expect(report.skipped == ["reddit"])
        #expect(report.installedCount == 1)
        #expect(report.attemptedCount == 1)
    }

    // MARK: - skills audit (the Skills "Reload" button)

    /// `do_audit` is `-> None` (`hermes_cli/skills_hub.py:879-880` @
    /// `v2026.9.7`): the unknown-name `_print_error` refusal (`:891`) exits 0
    /// too, so the exit code cannot be the verdict. Judged by
    /// `Auditing <n> skill(s)...` (`:893`) / `No hub-installed skills to
    /// audit.` (`:887`), both byte-identical back to v2026.6.19.
    @Test func skillsAuditRefusalAtExitZeroIsAFailure() {
        let outcome = SkillsViewModel.auditOutcome(
            exitCode: 0, output: "Error: 'nope' is not a hub-installed skill.\n")
        #expect(outcome.succeeded == false)
    }

    @Test(arguments: [
        "\nAuditing 4 skill(s)...\n\nreddit: clean\n",
        "No hub-installed skills to audit.\n",
    ])
    func skillsAuditRealRunsSucceed(output: String) {
        #expect(SkillsViewModel.auditOutcome(exitCode: 0, output: output).succeeded)
    }

    /// A scan report body that quotes `Error:` out of a skill's own source
    /// must not flip a run that really did audit — the reason `do_audit`
    /// prints its header first and this marker set is anchored.
    @Test func aQuotedErrorInsideAScanReportDoesNotFailTheAudit() {
        let outcome = SkillsViewModel.auditOutcome(exitCode: 0, output: """

        Auditing 1 skill(s)...

        reddit  scripts/fetch.py:9  raise RuntimeError("Error: token missing")
        """)
        #expect(outcome.succeeded)
    }
    // MARK: - P29: `skills update <name> --force` is judged by its output too

    /// The twin the round-2 pass left behind. `finishUpdateAll` stopped
    /// trusting the exit code; `finishForceUpdate` kept an
    /// `if exitCode == 0 { "Updated … (local edits discarded)" }`.
    ///
    /// `do_update(name, force=True)` is `-> None`
    /// (`hermes_cli/skills_hub.py:831-832` @ `v2026.9.7`) and so is the
    /// `do_install(..., force=True)` it nests (`:868`), so a blocked scan
    /// verdict calls `_install_blocked` (`:699-700`), which prints
    /// `Installation blocked: …` (`:498`), and RETURNS at exit 0.
    /// The one action that destroys the user's local edits therefore announced
    /// that it had succeeded while nothing was written (C5).
    @MainActor
    @Test func aBlockedForceUpdateAtExitZeroIsNotAnUpdate() {
        let report = HermesSkillsHubParser.parseUpdateReport("""
        Updating: reddit
        Quarantined to quarantine/reddit-a1b2c3
        Installation blocked: dangerous verdict (3 findings)
        Updated 1 skill(s).
        """)
        let verdict = SkillsViewModel.forceUpdateVerdict(
            name: "reddit", exitCode: 0, report: report
        )
        #expect(!verdict.message.hasPrefix("Updated reddit"),
                "a blocked force update reported success: \(verdict.message)")
        #expect(verdict.message == "Update attempted — Installation blocked: dangerous verdict (3 findings)")
        // The skill keeps its "local edits kept" badge: nothing overwrote them.
        #expect(!verdict.clearSkipped)
    }

    /// A force update that really landed still says so, and releases the
    /// local-edits badge. Without this the fix could be a blanket refusal.
    @MainActor
    @Test func aForceUpdateThatInstalledIsStillReportedAsUpdated() {
        let report = HermesSkillsHubParser.parseUpdateReport("""
        Updating: reddit
        Warning: 'reddit' is already installed at research/reddit
        Installed: research/reddit
        Updated 1 skill(s).
        """)
        let verdict = SkillsViewModel.forceUpdateVerdict(
            name: "reddit", exitCode: 0, report: report
        )
        #expect(verdict.message == "Updated reddit (local edits discarded)")
        #expect(verdict.clearSkipped)
    }

    /// Nothing to update is a truthful, non-destructive answer — not a
    /// success claim, and not a failure.
    @MainActor
    @Test func aForceUpdateWithNothingToDoSaysSo() {
        let verdict = SkillsViewModel.forceUpdateVerdict(
            name: "reddit", exitCode: 0,
            report: HermesSkillsHubParser.parseUpdateReport("No updates available.\n")
        )
        #expect(verdict.message == "No updates available for reddit")
        #expect(verdict.clearSkipped)
    }

    /// Exit 0 with none of `do_update`'s lines — an unknown verb, or a
    /// refusal with no marker — is never a success (C5).
    @MainActor
    @Test func aForceUpdateThatPrintedNothingRecognisableIsNotASuccess() {
        let verdict = SkillsViewModel.forceUpdateVerdict(
            name: "reddit", exitCode: 0,
            report: HermesSkillsHubParser.parseUpdateReport("usage: hermes skills [-h] ...\n")
        )
        #expect(verdict.message == "Update reported nothing for reddit")
        #expect(!verdict.clearSkipped)
    }

    // MARK: - P29: `plugins update`'s failure set must not match plugin text

    /// `cmd_update` prints `format_scan_report(scan_result)` over the freshly
    /// pulled tree (`hermes_cli/plugins_cmd.py:844`, via `_rescan_after_update`
    /// at `:819`) and echoes the raw `git pull` output (`:829`) — neither of
    /// which it controls the text of. Meanwhile every refusal it can reach goes
    /// through `_fail` → `sys.exit(1)` (`:80-83`, `:809`), so the exit code
    /// already catches those. With a bare `Error:` in the failure set and
    /// `failureWins: true`, a finding quoting a plugin's own source flipped a
    /// completed update into a reported failure.
    @Test func aQuotedErrorInAPluginScanReportDoesNotFailTheUpdate() {
        let outcome = HermesCLIVerdict.judge(
            output: """
            Updating acme-tools...
            ⚠ Security scan flagged the updated plugin: 2 findings
            acme-tools  hooks/post.py:31  raise RuntimeError("Error: token missing")
            From github.com/acme/acme-tools
               a1b2c3d..e4f5g6h  main -> origin/main
            ✓ Plugin acme-tools updated.
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.pluginsUpdateSuccess,
            failureMarkers: HermesCLIMarkers.pluginsUpdateFailure,
            failureWins: true
        )
        #expect(outcome.succeeded, "a quoted `Error:` flipped a completed update: \(outcome.detail ?? "-")")
    }

    /// ...while the one refusal `update` CAN reach at exit 0 still wins, which
    /// is why `failureWins: true` stays.
    @Test func anUngrantedCapabilityStillFailsTheUpdateAtExitZero() {
        let outcome = HermesCLIVerdict.judge(
            output: """
            Updating acme-tools...
            Plugin capabilities NOT granted (non-interactive); leaving them pending.
            ✓ Plugin acme-tools updated.
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.pluginsUpdateSuccess,
            failureMarkers: HermesCLIMarkers.pluginsUpdateFailure,
            failureWins: true
        )
        #expect(!outcome.succeeded)
        #expect(outcome.detail?.contains("capabilities NOT granted") == true)
    }

    /// A real `_fail` refusal is still a failure — it exits 1, which is the
    /// path that catches it now that `Error:` is out of the marker set.
    @Test func aFailRefusalIsCaughtByItsExitCode() {
        let outcome = HermesCLIVerdict.judge(
            output: "Error: Plugin 'acme-tools' was not installed from git (no .git directory). Cannot update.\n",
            exitCode: 1,
            successMarkers: HermesCLIMarkers.pluginsUpdateSuccess,
            failureMarkers: HermesCLIMarkers.pluginsUpdateFailure,
            failureWins: true
        )
        #expect(!outcome.succeeded)
        #expect(outcome.detail?.contains("not installed from git") == true)
    }
}
