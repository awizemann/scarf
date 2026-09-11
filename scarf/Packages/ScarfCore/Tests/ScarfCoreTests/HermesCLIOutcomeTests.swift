import Testing
import Foundation
@testable import ScarfCore

/// Phase P9 of the whole-surface audit (charter C5: "never parse unknown-verb
/// output as success"). Every fixture in this suite is the VERBATIM text a
/// `hermes` emitter prints at tag **v2026.9.7**, with the emitting `file:line`
/// named on the test — captured with
/// `git -C ~/.hermes/hermes-agent show v2026.9.7:<path>`.
///
/// The common defect: a handler declared `-> None` prints its refusal and
/// `return`s, which Python exits **0**. Every one of these fixtures therefore
/// arrives at Scarf with `exitCode == 0`, and every one of these tests fails
/// if the verdict goes back to reading the exit code.
@Suite("Hermes CLI outcome — exit code is not the truth")
struct HermesCLIOutcomeTests {

    // MARK: - The helper itself

    /// The C5 rule in one assertion: exit 0 with no success marker is a
    /// FAILURE. A bare unknown verb routes to the agent, which answers
    /// conversationally and exits 0 — that must never read as success.
    @Test func exitZeroWithoutASuccessMarkerIsAFailure() {
        let agentChatter = """
        I'd be happy to help you install that skill. Could you tell me which \
        registry it lives in?
        """
        let outcome = HermesCLIVerdict.judge(
            output: agentChatter,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.skillsInstallSuccess,
            failureMarkers: HermesCLIMarkers.skillsInstallFailure
        )
        #expect(outcome.succeeded == false)
    }

    /// Hermes colours through `rich` / `hermes_cli.colors.color()`; a
    /// `FORCE_COLOR` in the user's environment puts SGR codes back even on a
    /// pipe, and a marker at the start of a line would then be preceded by
    /// `ESC[32m`. The marker must still match.
    @Test func ansiColouredOutputIsStillJudged() {
        let coloured = "\u{1B}[1;32mInstalled:\u{1B}[0m smart-home/openhue\n"
        let outcome = HermesCLIVerdict.judge(
            output: coloured,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.skillsInstallSuccess,
            failureMarkers: HermesCLIMarkers.skillsInstallFailure
        )
        #expect(outcome.succeeded)
    }

    /// `failureWins: false` (the default) matches the usual emitter shape —
    /// every refusal arm `return`s before the success line — so a failure
    /// phrase inside a report BODY must not flip a real success.
    @Test func aSuccessMarkerBeatsIncidentalFailureTextByDefault() {
        let output = """
        Running security scan...
          MEDIUM  Error: handling in bundled script is unaudited
        Installed: smart-home/openhue
        """
        #expect(HermesCLIVerdict.judge(
            output: output, exitCode: 0,
            successMarkers: HermesCLIMarkers.skillsInstallSuccess,
            failureMarkers: HermesCLIMarkers.skillsInstallFailure
        ).succeeded)
    }

    // MARK: - skills install — hermes_cli/skills_hub.py

    /// `do_install(...) -> None` (hermes_cli/skills_hub.py:645-648) with nine bare
    /// `return`s. Verbatim refusals, each at exit 0:
    ///  - `_pinned_sources` → `_print_error` (:582, :134-135)
    ///  - `_print_fetch_failure` (:592)
    ///  - already installed (:683-686)
    ///  - `_install_blocked` from the scan verdict (:707, :498)
    ///  - `_invalid_path` (:506)
    ///  - `_resolve_url_bundle_name` non-interactive URL (:525-532)
    ///  - `_confirm_install` declined (:642)
    @Test(arguments: [
        // hermes_cli/skills_hub.py:582 via _print_error (:134-135)
        "Error: no source adapter for 'nous'. Refusing to resolve 'reddit' against other registries (that would change the skill's provenance).\n",
        // hermes_cli/skills_hub.py:592
        "\nFetching: community/reddit\nError: Could not fetch 'community/reddit' from any source.\n",
        // hermes_cli/skills_hub.py:683-686
        "\nFetching: smart-home/openhue\n" +
            "Warning: 'openhue' is already installed at smart-home/openhue\n" +
            "Use --force to reinstall.\n",
        // hermes_cli/skills_hub.py:707 via _install_blocked (:498)
        "Running security scan...\nInstallation blocked: dangerous verdict: 3 finding(s)\n",
        // hermes_cli/skills_hub.py:506 via _invalid_path → _install_blocked (:498)
        "Installation blocked: bundle path escapes the quarantine root\n",
        // hermes_cli/skills_hub.py:525-532
        "Cannot install from URL: https://example.com/SKILL.md\n" +
            "The SKILL.md has no `name:` in its frontmatter, and the URL path doesn't produce a valid identifier.\n",
        // hermes_cli/skills_hub.py:642 via _confirm_or_cancel
        "Installation cancelled.\n",
    ])
    func skillsInstallRefusalsAtExitZeroAreFailures(fixture: String) {
        let outcome = SkillsViewModel.installOutcome(exitCode: 0, output: fixture)
        #expect(outcome.succeeded == false)
        // The banner quotes the CLI's own line, so the user learns WHY.
        #expect(outcome.detail?.isEmpty == false)
    }

    /// The only success line: `c.print(f"[bold green]Installed:[/] {…}")`
    /// (hermes_cli/skills_hub.py:720). `[/]`-style rich markup is rendered away before it
    /// reaches a pipe, so the plain form is what Scarf sees.
    @Test func skillsInstallSuccessLineIsTheSuccessLine() {
        let fixture = """
        Fetching: smart-home/openhue
        Quarantined to quarantine/openhue-8f21
        Running security scan...
        Installed: smart-home/openhue
        Files: SKILL.md, scripts/run.py
        """
        #expect(SkillsViewModel.installOutcome(exitCode: 0, output: fixture).succeeded)
    }

    /// `do_uninstall` (hermes_cli/skills_hub.py:909-918) is `-> None` too; `_report_pair`
    /// (:144-150) prints `uninstall_skill`'s refusal
    /// (tools/skills_hub_install.py:209) through `_print_error`, at exit 0.
    @Test func skillsUninstallRefusalAtExitZeroIsAFailure() {
        let refusal = "Error: 'openhue' is not a hub-installed skill (may be a builtin)\n"
        #expect(SkillsViewModel.uninstallOutcome(exitCode: 0, output: refusal).succeeded == false)
        // tools/skills_hub_install.py:220
        let removed = "Uninstalled 'openhue' from smart-home/openhue\n"
        #expect(SkillsViewModel.uninstallOutcome(exitCode: 0, output: removed).succeeded)
    }

    /// A declined confirmation (`_confirm_or_cancel` at hermes_cli/skills_hub.py:915)
    /// prints NOTHING and returns — the "no success marker" rule is the only
    /// thing that catches it.
    @Test func skillsUninstallSilentDeclineIsAFailure() {
        #expect(SkillsViewModel.uninstallOutcome(exitCode: 0, output: "").succeeded == false)
    }

    // MARK: - security audit — hermes_cli/security_audit.py

    /// `cmd_security_audit` (security_audit.py:286-312) returns
    /// `int(any(severity >= threshold))` (:311-312) — so **1 means findings**,
    /// not a broken scan. 2 is the only real failure (:293 bad `--fail-on`,
    /// :307 OSV `RuntimeError`). `hermes_cli/main.py:2074-2075` passes it
    /// straight to `sys.exit`. Identical contract at v2026.6.19:562-576.
    @Test func securityAuditExitOneMeansFindingsNotFailure() {
        #expect(HermesSecurityAuditVerdict(exitCode: 0) == .clean)
        #expect(HermesSecurityAuditVerdict(exitCode: 1) == .findings)
        #expect(HermesSecurityAuditVerdict(exitCode: 2) == .failed(2))
    }
}
