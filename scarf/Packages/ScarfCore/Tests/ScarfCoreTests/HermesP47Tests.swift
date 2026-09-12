import Foundation
import Testing
@testable import ScarfCore

// MARK: - P47 finding 1 (fallthrough half): `plugins install --enable`

/// `cmd_install` (`hermes_cli/plugins_cmd.py:702`) calls `_set_plugin_enabled`
/// (`:754`) → `_write_config_value` (`:115-120`) → `save_config`, whose managed
/// arm prints `Cannot save configuration: …` and bare-`return`s
/// (`hermes_cli/config.py:2315-2318` @ `v2026.9.7`) — and `:755` then prints
/// `✓ Plugin <name> enabled.` regardless, at exit 0. The sixth `save_config`
/// door, and the parser read only the success line.
@Suite("P47 · plugins install is a save_config door")
struct PluginInstallRefusalP47Tests {

    /// Hermes's own two lines, in the order it prints them.
    private static let refusedEnable = """
    Cloning https://github.com/acme/widget...
    ✓ Installed widget
    Cannot save configuration: this Hermes Agent installation is managed by NixOS.
    ✓ Plugin widget enabled.
    """

    /// The bug. Without the fix, `enabled` is true and the pane says
    /// "Installed and enabled" over a plugin that is still off.
    @Test func aRefusedEnableIsNotEnabled() {
        let outcome = HermesPluginInstallOutcome.parse(Self.refusedEnable)
        #expect(outcome.enabled == false)
        #expect(outcome.configWriteRefusal != nil)
    }

    /// The refusal is carried verbatim, so the banner can quote Hermes's own
    /// sentence rather than inventing a reason.
    @Test func theRefusalLineIsCarried() throws {
        let refusal = try #require(HermesPluginInstallOutcome.parse(Self.refusedEnable).configWriteRefusal)
        #expect(refusal.contains("Cannot save configuration"))
        #expect(refusal.contains("NixOS"))
    }

    /// A clean enable on an unmanaged host is unchanged — charter C1.
    @Test func aCleanEnableIsStillEnabled() {
        let outcome = HermesPluginInstallOutcome.parse("""
        ✓ Installed widget
        ✓ Plugin widget enabled.
        """)
        #expect(outcome.enabled)
        #expect(outcome.configWriteRefusal == nil)
    }

    /// `--no-enable` is untouched by the new field.
    @Test func anUnenabledInstallIsUnchanged() {
        let outcome = HermesPluginInstallOutcome.parse("""
        ✓ Installed widget
        Plugin installed but not enabled. Run `hermes plugins enable widget` to activate.
        """)
        #expect(outcome.enabled == false)
        #expect(outcome.installedDisabled)
        #expect(outcome.configWriteRefusal == nil)
    }

    /// The P39b/P39c rule: the marker is ANCHORED. `cmd_install` prints text
    /// Hermes does not author at column 0 — the `[dim]` community-index lines
    /// echo the entry's own `ref` and `install_identifier`
    /// (`plugins_cmd.py:694-697` @ `v2026.9.7`) — so a line that says "Cannot
    /// set the key yourself" mid-sentence must not read as a refusal. (The
    /// plugin's `after-install.md` reaches stdout inside a rich `Panel`,
    /// `_display_after_install` `:391-404`, so it is already behind a `│`;
    /// P47b review, finding 4.)
    @Test func aMidSentenceCannotIsNotARefusal() {
        let outcome = HermesPluginInstallOutcome.parse("""
        ✓ Installed widget
        Note: you Cannot set WIDGET_KEY from the plugin itself — put it in .env.
        ✓ Plugin widget enabled.
        """)
        #expect(outcome.enabled)
        #expect(outcome.configWriteRefusal == nil)
    }

    /// Breadth by CHOICE, not a reachability claim. The only managed line
    /// `cmd_install` can actually print is `Cannot save configuration: …` —
    /// `save_config`'s arm (`hermes_cli/config.py:2317`) calling
    /// `managed_error("save configuration")` (`:453-455`) →
    /// `format_managed_message` (`:445-450`). The `set`/`unset` spellings come
    /// from other verbs' calls to the same formatter and are pinned here
    /// because ``HermesCLIMarkers/managedRefusalAnchored`` is one SHARED
    /// marker list: a door added to it later must land on this path too. What
    /// this test guarantees is the shared list's behaviour and that the
    /// leading `✗`/`⚠` glyph never hides a marker
    /// (`HermesCLIVerdict.unglyphed`) — not that Hermes emits all three here
    /// (P47b review, finding 4).
    @Test(arguments: [
        "Cannot save configuration: managed by home-manager.",
        "✗ Cannot set plugins.enabled: it is managed by your administrator.",
        "⚠ Cannot unset plugins.disabled: managed install.",
    ])
    func everySharedRefusalMarkerLandsOnThisDoor(_ line: String) {
        let outcome = HermesPluginInstallOutcome.parse("""
        ✓ Installed widget
        \(line)
        ✓ Plugin widget enabled.
        """)
        #expect(outcome.enabled == false)
        #expect(outcome.configWriteRefusal != nil)
    }
}

// MARK: - P47 finding 2: `auth logout` (round-5 decision 2)

/// `logout_command` (`hermes_cli/auth.py:2173-2196` @ `v2026.9.7`) has two
/// exit-0 arms that clear nothing. Walked at `v2026.6.19`, `v2026.7.30`,
/// `v2026.8.19` and `v2026.9.7`: all three lines are byte-identical at every
/// tag, so this judgement changes nothing on a pre-target host (C1).
@Suite("P47 · auth logout")
struct AuthLogoutVerdictP47Tests {

    @Test func theSuccessLineIsASuccessWithNoNote() {
        let outcome = HermesAuthLogoutVerdict.judge(
            output: "Logged out of Anthropic.\nModel provider configuration was unchanged.",
            exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    /// The bug: exit 0, nothing cleared, and the pane said
    /// "Removed OAuth provider …".
    @Test(arguments: [
        "No provider is currently logged in.",
        "No auth state found for Anthropic.",
    ])
    func anIdleArmIsASuccessCarryingTheNeutralNote(_ line: String) {
        let outcome = HermesAuthLogoutVerdict.judge(output: line, exitCode: 0)
        // Decision 2: the provider IS logged out, so this is not a failure…
        #expect(outcome.succeeded)
        // …but nothing was removed, and the note is what says so.
        #expect(outcome.warning == HermesAuthLogoutVerdict.nothingToClearNote)
    }

    /// The unknown-provider guard raises `SystemExit(1)` (`auth.py:2177-2179`),
    /// so the exit code still covers it.
    @Test func anUnknownProviderIsStillAFailure() {
        let outcome = HermesAuthLogoutVerdict.judge(output: "Unknown provider: nope", exitCode: 1)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail == "Unknown provider: nope")
    }

    /// C5: exit 0 with neither a success line nor a known arm is never a
    /// success — and it is `.unconfirmed`, not a positive failure.
    @Test func silenceIsUnconfirmedAndNotASuccess() {
        let outcome = HermesAuthLogoutVerdict.judge(output: "", exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
    }

    /// The `--` the round-5 finding asked for. `provider` is the subparser's
    /// only positional (`hermes_cli/subcommands/auth.py:59-61` @ `v2026.9.7`).
    @Test func theArgvSeparatesItsPositional() {
        #expect(HermesAuthLogoutVerdict.argv(provider: "anthropic")
            == ["auth", "logout", "--", "anthropic"])
    }
}

// MARK: - P47 finding 3: `memory reset --yes` (round-5 decision 3)

/// `_cmd_memory_reset` (`hermes_cli/main_agent_cmds.py:21-56` @ `v2026.9.7`)
/// prints `Nothing to reset — no memory files found in …` and RETURNS at
/// exit 0 (`:32-33`). Both Mac and iOS judged that by exit code.
@Suite("P47 · memory reset")
struct MemoryResetVerdictP47Tests {

    /// Hermes indents every line of this handler by two spaces;
    /// `significantLines` trims, which is what makes the prefixes anchored.
    @Test func aRealResetIsASuccessWithNoNote() {
        let outcome = HermesMemoryResetVerdict.judge(output: """

          ✓ Deleted MEMORY.md (agent notes)
          ✓ Deleted USER.md (user profile)

          Memory reset complete. New sessions will start with a blank slate.
          Files were in: ~/.hermes/memories/

        """, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    /// The bug.
    @Test func nothingToResetIsASuccessCarryingTheNeutralNote() {
        let outcome = HermesMemoryResetVerdict.judge(
            output: "\n  Nothing to reset — no memory files found in ~/.hermes/memories/\n",
            exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(outcome.warning == HermesMemoryResetVerdict.nothingToResetNote)
    }

    @Test func silenceIsUnconfirmedAndNotASuccess() {
        let outcome = HermesMemoryResetVerdict.judge(output: "", exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
    }

    @Test func aNonZeroExitIsStillAFailure() {
        let outcome = HermesMemoryResetVerdict.judge(output: "Traceback…", exitCode: 1)
        #expect(outcome.succeeded == false)
    }

    /// `--yes` is what makes the `Cancelled.` arms unreachable (`:43`).
    @Test func theArgvPassesYes() {
        #expect(HermesMemoryResetVerdict.argv == ["memory", "reset", "--yes"])
    }
}

// MARK: - P47 finding 4: `sessions optimize`

/// `_cmd_optimize` (`hermes_cli/sessions_cmd.py:809-819` @ `v2026.9.7`)
/// catches every exception from `db.vacuum()`, prints
/// `Error: optimization failed: {e}` (`:815`) and returns — exit 0.
@Suite("P47 · sessions optimize")
struct SessionsOptimizeVerdictP47Tests {

    @Test func theSuccessLineIsASuccess() {
        let outcome = HermesSessionsOptimizeVerdict.judge(output: """
        Optimizing session store (FTS merge + VACUUM)…
        Optimized 3 FTS index(es).
        Database size: 41.2 MB -> 28.7 MB (-12.5 MB)
        """, exitCode: 0)
        #expect(outcome.succeeded)
    }

    /// The bug: the Health pane rendered this tail as its optimisation
    /// summary.
    @Test func theExitZeroFailureArmIsAFailure() throws {
        let outcome = HermesSessionsOptimizeVerdict.judge(output: """
        Optimizing session store (FTS merge + VACUUM)…
        Error: optimization failed: database is locked
        """, exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(try #require(outcome.detail).contains("database is locked"))
    }

    /// The in-progress line (`:811`) starts with "Optimiz" too, which is why
    /// the success marker carries its trailing space. A run that printed ONLY
    /// the in-progress line is not a success.
    @Test func theInProgressLineIsNotASuccess() {
        let outcome = HermesSessionsOptimizeVerdict.judge(
            output: "Optimizing session store (FTS merge + VACUUM)…", exitCode: 0
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
    }

    @Test func aNonZeroExitIsStillAFailure() {
        #expect(HermesSessionsOptimizeVerdict.judge(output: "boom", exitCode: 2).succeeded == false)
    }
}
