import Foundation
import Testing
@testable import ScarfCore

/// P39c — the second review of P39's managed-refusal work.
///
/// Round-4 review finding: the shared anchor `Cannot ` is reachable by text
/// Hermes does not author. `plugins update` echoes the raw `git pull` output
/// (`cmd_update` prints `[dim]{out}[/dim]`, `hermes_cli/plugins_cmd.py:829` @
/// v2026.9.7) and a post-pull scan report (`:844`), and
/// ``HermesCLIVerdict/significantLines`` trims leading whitespace — so an
/// indented `Cannot open …` from git arrives at column 0 and matched, on a
/// verdict that runs `failureWins: true`.
@Suite("P39c — the managed anchors are the full action prefixes")
struct HermesManagedRefusalP39cTests {

    /// Exactly the action strings any `managed_error(…)` /
    /// `format_managed_message(…)` caller passes on a path Scarf shells.
    /// Enumerated at v2026.9.7 by grepping both call shapes across
    /// `hermes_cli/`: `save configuration` (`config.py:2317`),
    /// `set configuration values` (`:3451`), `unset configuration values`
    /// (`:3550`), `{action} {key}` with `set`/`remove` (`:2557`, via
    /// `save_env_value` `:2577` and `remove_env_value` `:2612`), plus
    /// `_exit_if_key_managed`'s `Cannot {action} '{key}'` (`:3369`, from
    /// `:3460` and `:3552`).
    @Test func theAnchorsAreTheFullActionPrefixes() {
        #expect(HermesCLIMarkers.managedRefusalAnchored == [
            "Cannot save configuration",
            "Cannot set",
            "Cannot unset",
            "Cannot remove",
        ])
    }

    /// Every refusal line a managed host can print on a verb Scarf shells,
    /// spelled as Hermes spells it at v2026.9.7.
    @Test(arguments: [
        // `format_managed_message` (`config.py:445-450`) under `save_config`
        // (`:2317`) — the door under plugins enable/disable/update, skills
        // trust, memory off and mcp remove.
        "Cannot save configuration: this Hermes installation is managed by nixos.",
        // `set_config_value`'s `is_managed()` arm (`:3451`).
        "Cannot set configuration values: this Hermes installation is managed by Homebrew.",
        // `unset_config_value`'s (`:3550`).
        "Cannot unset configuration values: this Hermes installation is managed by nixos.",
        // `_env_write_blocked`'s managed-scope arm through `save_env_value`
        // (`:2577` → `:2562`).
        "Cannot set TERMINAL_ENV: it is managed by your administrator (/etc/hermes/.env) and cannot be changed.",
        // …and through `remove_env_value` (`:2612` → `:2562`).
        "Cannot remove TERMINAL_ENV: it is managed by your administrator (/etc/hermes/.env) and cannot be changed.",
        // `_exit_if_key_managed` (`:3369`), both actions.
        "Cannot set 'terminal.env': it is managed by your administrator (/etc/hermes/config.yaml) and cannot be changed. Contact your administrator to modify it.",
        "Cannot unset 'terminal.env': it is managed by your administrator (/etc/hermes/config.yaml) and cannot be changed. Contact your administrator to modify it.",
    ])
    func everyManagedRefusalHermesPrintsIsStillAnchored(_ line: String) {
        let out = HermesCLIVerdict.judge(
            output: line,
            exitCode: 0,
            successMarkers: ["nothing prints this"],
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true
        )
        #expect(out.succeeded == false)
        #expect(out.detail == line)
    }

    /// The regression the narrowing exists for. `git pull` indents its own
    /// errors; `significantLines` trims, so under the bare `Cannot ` anchor
    /// this reported a completed update as a managed refusal.
    @Test(arguments: [
        "  Cannot open .git/FETCH_HEAD: Permission denied",
        "  Cannot rebase: You have unstaged changes.",
        "Cannot merge: local changes would be overwritten.",
    ])
    func anEchoedGitLineDoesNotFlipAPluginUpdate(_ gitLine: String) {
        let out = HermesCLIVerdict.judge(
            output: """
            From github.com/example/weather
            \(gitLine)
            ✓ Plugin weather updated.
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.pluginsUpdateSuccess,
            failureMarkers: HermesCLIMarkers.pluginsUpdateFailure,
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true
        )
        #expect(out.succeeded, "\(gitLine) must not read as a managed refusal")
    }

    /// …while the real refusal under the same verb still wins.
    @Test func theRealRefusalUnderAPluginUpdateStillWins() {
        let out = HermesCLIVerdict.judge(
            output: """
            Cannot save configuration: this Hermes installation is managed by nixos.
            ✓ Plugin weather updated.
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.pluginsUpdateSuccess,
            failureMarkers: HermesCLIMarkers.pluginsUpdateFailure,
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true
        )
        #expect(out.succeeded == false)
    }

    /// `_cmd_restart`'s `⚠ Cannot restart gateway as a service — linger is not
    /// enabled.` (`hermes_cli/gateway.py:6047` @ v2026.9.7) is a plain
    /// `return` at exit 0. It used to ride the bare `Cannot ` anchor; now
    /// ``HermesCLIMarkers/gatewayServiceFailureAnchored`` spells it out.
    @Test func theGatewayLingerRefusalIsStillCaught() {
        let line = "⚠ Cannot restart gateway as a service — linger is not enabled."
        let out = HermesGatewayServiceVerdict.judge(verb: .restart, output: line, exitCode: 0)
        #expect(out.succeeded == false)
        #expect(HermesCLIMarkers.gatewayServiceFailureAnchored.contains("Cannot restart gateway as a service"))
    }

    /// …and the `save_config` door under `mcp remove` still is too — the set
    /// that inherits the narrowed anchors must not have lost it.
    @Test func theManagedRefusalUnderMCPRemoveStillWins() {
        let out = HermesCLIVerdict.judge(
            output: """
            Cannot save configuration: this Hermes installation is managed by nixos.
              ✓ Removed 'weather' from config
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.mcpRemoveSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.mcpRemoveFailure,
            failureWins: true,
            successAnchored: true
        )
        #expect(out.succeeded == false)
    }

    // MARK: - The dead constant and the corrected doc

    /// `HermesCLIMarkers.managedRefusal` (the unanchored `is managed by`) was
    /// referenced only from doc comments after P39b. Deleted; this scan is
    /// what keeps it from being re-added by a merge.
    @Test func theUnanchoredManagedRefusalConstantIsGone() throws {
        let source = try Self.coreSource("Services/HermesCLIOutcome.swift")
        #expect(source.contains("let managedRefusal = ") == false)
        #expect(source.contains("``managedRefusal``") == false)
        let install = try Self.coreSource("Services/HermesManagedInstall.swift")
        #expect(install.contains("HermesCLIMarkers/managedRefusal``") == false)
        #expect(install.contains("HermesCLIMarkers/managedRefusalAnchored``"))
    }

    /// ``HermesConfigMirror``'s doc used to assert the `.env` write "was the
    /// ONLY write" on the `_is_env_config_key` arm. True of that arm, but not
    /// of every `.env` writer: `save_provider_env_credential`
    /// (`hermes_cli/credential_lifecycle.py:186-190` @ v2026.9.7) discards
    /// `save_env_value`'s bool and still runs `_scrub_config_yaml_mirrors`,
    /// which writes config.yaml through `atomic_yaml_write` (`:142`), around
    /// `save_config`'s managed guard. Behaviour errs toward failure, so the
    /// correction is the doc.
    @Test func theMirrorDocScopesItsOnlyWriteClaim() throws {
        let source = try Self.coreSource("Services/HermesCLIOutcome.swift")
        #expect(source.contains("where the `.env` write was the ONLY write") == false)
        #expect(source.contains("credential_lifecycle.py:167-193"))
        #expect(source.contains("_scrub_config_yaml_mirrors"))
    }

    static func coreSource(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .appendingPathComponent("Sources/ScarfCore")
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
