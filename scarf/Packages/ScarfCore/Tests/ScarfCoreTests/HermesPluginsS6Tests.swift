import Testing
import Foundation
@testable import ScarfCore

/// S6 (Hermes v0.22.5 parity): `plugins enable|disable` lost their
/// `Takes effect on next session.` tail at v0.22.3, `plugins install` can
/// leave a plugin disabled for want of dependency consent (v0.21.6+), and
/// `plugins update` refuses a flagged update before applying it (v0.22.3+).
@Suite("Hermes plugins S6")
struct HermesPluginsS6Tests {

    private func enableVerdict(_ output: String, exitCode: Int32 = 0) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.pluginsEnableSuccess,
            failureMarkers: HermesCLIMarkers.pluginsEnableFailure,
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true,
            successLine: HermesCLIMarkers.isPluginsEnabledLine
        )
    }

    private func disableVerdict(_ output: String, exitCode: Int32 = 0) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.pluginsDisableSuccess,
            failureMarkers: HermesCLIMarkers.pluginsDisableFailure,
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true,
            successLine: HermesCLIMarkers.isPluginsDisabledLine
        )
    }

    // MARK: - enable / disable verdict

    /// `plugins_cmd.py:729` / `:765` @ v0.22.3 and v0.22.5.
    @Test func v0223ToggleLinesAreSuccess() {
        #expect(enableVerdict("✓ Plugin weather enabled.\nRestart the gateway to load it.\n").succeeded)
        #expect(enableVerdict("✓ Plugin acme/weather enabled.\n").succeeded)
        #expect(disableVerdict("⊘ Plugin weather disabled.\nThe running gateway was reloaded.\n").succeeded)
    }

    /// `:729` / `:765` @ v0.22.2 — the old hosts' lines are still success.
    @Test func preV0223ToggleLinesStillSucceed() {
        #expect(enableVerdict("✓ Plugin weather enabled. Takes effect on next session.\n").succeeded)
        #expect(disableVerdict("⊘ Plugin weather disabled. Takes effect on next session.\n").succeeded)
        #expect(enableVerdict("Plugin 'weather' is already enabled.\n").succeeded)
        #expect(disableVerdict("Plugin 'weather' is already disabled.\n").succeeded)
    }

    @Test func toggleLineShapeIsAnchored() {
        #expect(!HermesCLIMarkers.isPluginsEnabledLine("docs: plugin weather enabled."))
        #expect(!HermesCLIMarkers.isPluginsEnabledLine("Plugin 'weather' is not enabled."))
        #expect(!HermesCLIMarkers.isPluginsEnabledLine("Plugin  enabled."))
        #expect(!HermesCLIMarkers.isPluginsDisabledLine("✓ Plugin weather enabled."))
        // Unknown output is never success (C5).
        #expect(!enableVerdict("something else entirely\n").succeeded)
    }

    @Test func toggleRefusalsStillWin() {
        let consent = """
        ✓ Plugin weather enabled.
        Non-interactive session: capabilities NOT granted (fail closed).
        """
        #expect(!enableVerdict(consent).succeeded)
        #expect(!enableVerdict("Plugin 'nope' is not installed or bundled.\n", exitCode: 1).succeeded)
    }

    // MARK: - install dependency consent

    /// `plugins_cmd_install.py:150`, `:675-683` @ v0.22.5.
    @Test func cannotEnableForDependencyConsentIsParsed() {
        let output = """
        Cloning https://github.com/acme/weather...

        weather declares Python dependencies:
          - requests>=2
        Non-interactive install — skipping dependency install. Run `hermes plugins enable` when ready to prepare them.

        ✗ Cannot enable weather: dependency install skipped (non-interactive)
        The plugin stays installed but disabled; re-enable after resolving the conflict.
        Plugin installed but not enabled. Run `hermes plugins enable weather` to activate.
        """
        let outcome = HermesPluginInstallOutcome.parse(output)
        #expect(outcome.enableRefusal == "dependency install skipped (non-interactive)")
        #expect(outcome.needsDependencyConsent)
        #expect(!outcome.enabled)
    }

    @Test func otherEnableRefusalsDoNotOfferConsent() {
        let declined = HermesPluginInstallOutcome.parse("✗ Cannot enable weather: dependency install declined\n")
        #expect(declined.enableRefusal == "dependency install declined")
        #expect(!declined.needsDependencyConsent)
        let enabled = HermesPluginInstallOutcome.parse("✓ Plugin weather enabled.\n")
        #expect(enabled.enableRefusal == nil)
        #expect(!enabled.needsDependencyConsent)
        #expect(enabled.enabled)
    }

    // MARK: - update refused before applying

    /// `plugins_cmd_update.py:140,142` @ v0.22.5 — exit 1, the reason is
    /// the first line of a multi-line message.
    @Test func refusedUpdateQuotesTheReasonNotTheHint() {
        let blocked = """
        Updating weather...
        Blocked: Security scan blocked plugin install: dangerous verdict

        findings report
        Review the findings above. Install only plugins from sources you trust. (Scanning can be configured via plugins.scan_on_install in config.yaml.)
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: blocked, exitCode: 1)
        #expect(!outcome.succeeded)
        #expect(outcome.detail == "Blocked: Security scan blocked plugin install: dangerous verdict")

        let notApplied = "Update of weather not applied: new capabilities need consent\n"
        let refused = HermesPluginsUpdateVerdict.judge(output: notApplied, exitCode: 1)
        #expect(!refused.succeeded)
        #expect(refused.detail == "Update of weather not applied: new capabilities need consent")
    }

    @Test func refusalShapeNeverDecidesAnExitZeroRun() {
        // A pulled commit message quoting the shape cannot fail a real update.
        let output = "✓ Plugin weather updated.\nBlocked: nothing, this is a commit subject\n"
        #expect(HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0).succeeded)
    }
}
