import Testing
import Foundation
@testable import scarf

/// Covers `SettingsViewModel.saveFailureMessage(key:output:)` — the banner
/// text a failed `hermes config set/unset` puts in front of the user.
///
/// Pure string handling over fixture CLI output, so no ServerContext, no
/// disk, and no shared state: the suite runs in parallel safely.
@Suite struct SettingsSaveFailureMessageTests {

    @Test func emptyOutputFallsBackToTheGenericMessage() {
        let msg = SettingsViewModel.saveFailureMessage(key: "model.default", output: "")
        #expect(msg == "Failed to save model.default")
    }

    @Test func whitespaceOnlyOutputFallsBackToTheGenericMessage() {
        let msg = SettingsViewModel.saveFailureMessage(key: "model.default", output: "\n  \n\n")
        #expect(msg == "Failed to save model.default")
    }

    /// The managed-scope refusal is the common case and must survive
    /// verbatim — note it contains a colon, which the error-label stripper
    /// must NOT mistake for a Python exception prefix.
    @Test func managedScopeReasonSurvivesVerbatim() {
        let output = "Cannot set 'model.default': it is managed by your administrator"
        let msg = SettingsViewModel.saveFailureMessage(key: "model.default", output: output)
        #expect(msg == "Couldn’t save model.default: Cannot set 'model.default': it is managed by your administrator")
    }

    /// Hermes prefixes its own fail-closed CLI errors with `✗ `.
    @Test func hermesCrossMarkerIsStripped() {
        let output = "✗ Invalid config key: 'agent.' — contains an empty path segment (leading, trailing, or doubled '.')."
        let msg = SettingsViewModel.saveFailureMessage(key: "agent.", output: output)
        #expect(msg == "Couldn’t save agent.: Invalid config key: 'agent.' — contains an empty path segment (leading, trailing, or doubled '.').")
    }

    /// v0.21's phantom-sibling guard raises a bare `ValueError` from
    /// `_set_nested`, and `hermes config set` only catches `RuntimeError` —
    /// so the whole thing reaches Scarf as a Python traceback. The user must
    /// see the sentence, not the plumbing.
    @Test func phantomSiblingTracebackYieldsTheExceptionMessage() {
        let output = """
        Traceback (most recent call last):
          File "/usr/local/bin/hermes", line 8, in <module>
            sys.exit(main())
          File "/opt/hermes/hermes_cli/config.py", line 6110, in handle_config
            set_config_value(key, value, force=force)
          File "/opt/hermes/hermes_cli/config.py", line 1209, in _set_nested
            raise ValueError(
        ValueError: Refusing to create nested key 'v1' in 'quick_commands.v1.2_deploy.type': the mapping already contains a literal key 'v1.2_deploy' that contains a dot. If you meant that key, escape its dots with a backslash (e.g. v1\\.2_deploy).
        """
        let msg = SettingsViewModel.saveFailureMessage(
            key: "quick_commands.v1.2_deploy.type", output: output
        )
        #expect(msg.hasPrefix("Couldn’t save quick_commands.v1.2_deploy.type: Refusing to create nested key"))
        // The exception class label and every traceback frame are gone.
        #expect(!msg.contains("ValueError:"))
        #expect(!msg.contains("Traceback"))
        #expect(!msg.contains("File \""))
        #expect(msg.contains("escape its dots with a backslash"))
    }

    /// Trailing blank lines are common in captured CLI output and must not
    /// swallow the reason.
    @Test func trailingBlankLinesDoNotHideTheReason() {
        let msg = SettingsViewModel.saveFailureMessage(
            key: "terminal.backend", output: "some noise\n✗ Unknown backend 'wat'\n\n  \n"
        )
        #expect(msg == "Couldn’t save terminal.backend: Unknown backend 'wat'")
    }

    /// A label that merely ends in a colon but isn't an exception class is
    /// left alone — only CamelCase `…Error:` / `…Exception:` is stripped.
    @Test func nonExceptionColonPrefixIsNotStripped() {
        let msg = SettingsViewModel.saveFailureMessage(
            key: "k", output: "warning: value looks odd"
        )
        #expect(msg == "Couldn’t save k: warning: value looks odd")
    }
}
