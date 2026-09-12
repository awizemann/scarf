import Foundation
import Testing
import ScarfCore
@testable import scarf

// MARK: - Round-5 decision 15: pairing is a local-only gesture

/// `EmbeddedSetupTerminal` is a `LocalProcessTerminalView` — it spawns on THIS
/// Mac, always, with no transport in the path. On a remote context that made
/// WhatsApp's "Start Pairing" run the REMOTE `hermesBinary` path as a local
/// executable, and Signal's "Link Device" write a link into the LOCAL
/// `~/.hermes` that the remote gateway never reads. Both appeared to work.
///
/// The posture is `SettingsViewModel.runBackup`'s: a local-only affordance
/// says plainly where the work has to happen instead of failing in the pane.
@Suite("P51 · remote pairing is refused with a sentence naming the host")
struct RemotePairingNoticeP51Tests {

    private static func remote(_ host: String) -> ServerContext {
        ServerContext(
            id: UUID(),
            displayName: host,
            kind: .ssh(SSHConfig(host: host, hermesBinaryHint: "/usr/local/bin/hermes"))
        )
    }

    @Test("a local context has no notice")
    @MainActor
    func localIsSilent() {
        #expect(WhatsAppSetupViewModel(context: .local).remotePairingNotice == nil)
        #expect(SignalSetupViewModel(context: .local).remotePairingNotice == nil)
    }

    /// The sentence must NAME the host — that is the whole difference between
    /// "this is disabled" and "do it over there".
    @Test("a remote context names its host")
    @MainActor
    func remoteNamesTheHost() throws {
        let notice = try #require(
            WhatsAppSetupViewModel(context: Self.remote("prod-box")).remotePairingNotice
        )
        #expect(notice.contains("prod-box"))
        let signal = try #require(
            SignalSetupViewModel(context: Self.remote("prod-box")).remotePairingNotice
        )
        #expect(signal.contains("prod-box"))
    }

    /// The guard is in the view MODEL as well as on the button, so the
    /// refusal does not depend on one view remembering to disable a control.
    @Test("startPairing does not launch on a remote context")
    @MainActor
    func whatsAppStartPairingIsInert() {
        let vm = WhatsAppSetupViewModel(context: Self.remote("box"))
        vm.startPairing()
        #expect(vm.pairingInProgress == false)
        #expect(vm.terminalController.isRunning == false)
    }

    @Test("the signal-cli steps do not launch on a remote context")
    @MainActor
    func signalStepsAreInert() {
        let vm = SignalSetupViewModel(context: Self.remote("box"))
        // Both preconditions the LOCAL path checks are satisfied, so a
        // failure here is the remote guard's and nothing else's.
        vm.signalCLIInstalled = true
        vm.account = "+15551234567"
        vm.startLink()
        #expect(vm.activeTask == .none)
        vm.startDaemon()
        #expect(vm.activeTask == .none)
        #expect(vm.terminalController.isRunning == false)
    }

    /// And the local path still works — the clamp, so "refuse everything" is
    /// not a passing implementation.
    @Test("a local context still reaches the terminal")
    @MainActor
    func localStillStarts() {
        let vm = WhatsAppSetupViewModel(context: .local)
        vm.startPairing()
        // The controller has no container in a test host, so nothing spawns;
        // what this pins is that the VM did NOT take the remote early return.
        #expect(vm.pairingInProgress == true)
    }
}

// MARK: - Round-5 decision 16: override keys match exactly

/// Hermes's per-model override lookup is a plain dict membership test —
/// `variant in overrides` in `resolve_per_model_reasoning_effort`
/// (`hermes_constants.py:929-941` @ `v2026.9.7`) over the variants
/// `_canonical_model_variants` derives (`:892-926`), which recover dots↔dashes
/// and add/strip provider prefixes but NEVER change case. So two casings are
/// two live entries, and the editor's case-insensitive replace-on-add was
/// deleting one of them: `setReasoningOverrides` rewrites the whole block from
/// what the editor holds, so the row left the FILE too.
@Suite("P51 · reasoning-override keys are deduped exactly")
struct ReasoningOverrideExactDedupeP51Tests {

    /// The function `AgentTab.addNew` ACTUALLY calls (P51b). This used to be
    /// a private re-implementation of the rule with a comment claiming it was
    /// the extracted one; it could not fail when the view drifted.
    private func afterAdding(_ pattern: String, to existing: [String]) -> [String] {
        HermesReasoningEffort.overridesAfterAdding(
            pattern: pattern,
            effort: "low",
            to: existing.map { (key: $0, value: "high") }
        ).map(\.key)
    }

    /// The bug: adding `Claude-Opus` used to remove `claude-opus`.
    @Test("a different casing does not evict the existing row")
    func differentCasingCoexists() {
        #expect(afterAdding("Claude-Opus", to: ["claude-opus"]) == ["claude-opus", "Claude-Opus"])
    }

    /// The clamp: an EXACT match is still replaced, so adding a pattern twice
    /// does not duplicate the row.
    @Test("an exact match is still replaced")
    func exactMatchReplaces() {
        #expect(afterAdding("claude-opus", to: ["claude-opus"]) == ["claude-opus"])
    }

    /// The source rule this suite exists to keep true: the view must not
    /// reintroduce a case-insensitive comparison on the override block.
    @Test("AgentTab carries no case-insensitive override dedupe")
    func sourceHasNoCaseInsensitiveCompare() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // scarfTests
            .deletingLastPathComponent()          // scarf
            .appendingPathComponent("scarf/Features/Settings/Views/Tabs/AgentTab.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("caseInsensitiveCompare"))
        #expect(!source.contains("sortedOverrides.filter { $0.key.lowercased()"))
    }
}

// MARK: - The platform forms' control-character refusal

/// Round-4 decision 9's refusal, reaching the setup forms (P51). A form's
/// config keys go out through `hermes config set`, so HERMES writes them with
/// PyYAML's own emitter (`hermes_cli/config.py:2307` `save_config` →
/// `utils.py:262` `atomic_yaml_write` = `yaml.dump` @ `v2026.9.7`) — the file
/// stays loadable and the damage is INVISIBLE: a `reply_prefix` with a pasted
/// ESC in it, a channel id that belongs to no channel.
@Suite("P51 · setup forms refuse a control character in a config scalar")
struct PlatformFormControlCharacterP51Tests {

    @Test("a clean batch is accepted")
    @MainActor
    func cleanBatchPasses() {
        #expect(PlatformSetupHelpers.controlCharacterFieldLabel([
            ("whatsapp.reply_prefix", "[bot] "),
            ("discord.free_response_channels", "123,456")
        ]) == nil)
    }

    @Test("an escape character is refused, and the key is named")
    @MainActor
    func escapeIsRefused() {
        #expect(PlatformSetupHelpers.controlCharacterFieldLabel([
            ("whatsapp.reply_prefix", "a\u{1B}b")
        ]) == "whatsapp.reply_prefix")
    }

    /// The three forms the finding named, each through the scalar it writes.
    @Test("the named forms' own keys are covered", arguments: [
        "whatsapp.reply_prefix",
        "discord.free_response_channels",
        "platforms.ntfy.extra.topic"
    ])
    @MainActor
    func namedFormKeysCovered(key: String) {
        #expect(PlatformSetupHelpers.controlCharacterFieldLabel([(key, "x\u{7F}y")]) == key)
    }

    /// The over-refusal clamp (P19's lesson): an ordinary space, an emoji and
    /// a non-breaking space are NOT control characters and must pass.
    @Test("ordinary text is not refused", arguments: ["a b", "🎉", "a\u{00A0}b", "", "ünïcødé"])
    @MainActor
    func ordinaryTextPasses(value: String) {
        #expect(PlatformSetupHelpers.controlCharacterFieldLabel([("k", value)]) == nil)
    }

    /// Deterministic naming: with two bad fields the refusal names the same
    /// one every time, or the message flickers between saves.
    @Test("the refusal is deterministic across two bad fields")
    @MainActor
    func refusalIsDeterministic() {
        let batch = [("zzz.key", "a\u{01}"), ("aaa.key", "b\u{01}")]
        #expect(PlatformSetupHelpers.controlCharacterFieldLabel(batch) == "aaa.key")
    }
}

// MARK: - Discord writes only the keys whose row it renders

/// `DiscordSetupViewModel.save()` wrote `discord.history_backfill` and
/// `platforms.discord.extra.allow_any_attachment` unconditionally while the
/// VIEW gated both rows — so a pre-v0.14 host got a `history_backfill` it
/// never showed the user, and every v0.18+ host got an
/// `allow_any_attachment` nothing reads, stamped over whatever the file held
/// from a toggle that was never on screen. Telegram's `load(capabilities:)`
/// shape (`TelegramSetupViewModel.swift:108-118`) is the fix.
@Suite("P51 · Discord writes only its rendered keys")
struct DiscordCapabilityScopedWriteP51Tests {

    /// The VM's captured capabilities decide the batch, so the assertion is
    /// on `capabilities`, which `load(capabilities:)` is the only setter for.
    @Test("load is the only way capabilities reach the form")
    @MainActor
    func loadSetsCapabilities() {
        let vm = DiscordSetupViewModel(context: .local)
        #expect(vm.capabilities.hasDiscordHistoryBackfill == false)
        vm.load(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))
        #expect(vm.capabilities.hasDiscordHistoryBackfill == true)
        // The window flag: v0.21.1 is PAST it.
        #expect(vm.capabilities.hasDiscordAllowAnyAttachment == false)
    }

    /// A pre-v0.14 host renders neither row and must write neither key.
    @Test("an old host's captured capabilities gate both keys off")
    @MainActor
    func oldHostGatesBoth() {
        let vm = DiscordSetupViewModel(context: .local)
        vm.load(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.13.0"))
        #expect(vm.capabilities.hasDiscordHistoryBackfill == false)
        #expect(vm.capabilities.hasDiscordAllowAnyAttachment == false)
    }

    /// The window's inside: a v0.16 host renders BOTH rows.
    @Test("a v0.16 host gates both keys on")
    @MainActor
    func windowHostGatesBothOn() {
        let vm = DiscordSetupViewModel(context: .local)
        vm.load(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.16.0"))
        #expect(vm.capabilities.hasDiscordHistoryBackfill == true)
        #expect(vm.capabilities.hasDiscordAllowAnyAttachment == true)
    }

    /// The source rule: `save()` must not carry an ungated write of either
    /// key. A future edit that drops the `if` is what this catches.
    @Test("save gates both windowed keys")
    func saveGatesBothKeys() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "scarf/Features/Platforms/ViewModels/PlatformSetup/DiscordSetupViewModel.swift"
            )
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("if capabilities.hasDiscordHistoryBackfill {"))
        #expect(source.contains("if capabilities.hasDiscordAllowAnyAttachment {"))
        // And no defaulted `load()` overload, which would silently reset the
        // captured set to `.empty` from the Reload button.
        #expect(!source.contains("func load() {"))
    }
}

// MARK: - Mattermost require_mention lives on ONE side

/// The form READ `mattermost.require_mention` from config.yaml and WROTE
/// `MATTERMOST_REQUIRE_MENTION` to `.env`, so the toggle appeared to snap back
/// on the next load — and on a config that carries the key at all the `.env`
/// write was inert, because `_extra_or_env` consults `config.extra` FIRST
/// (`plugins/platforms/mattermost/adapter.py:491-494`, `:504` @ `v2026.9.7`).
@Suite("P51 · Mattermost require_mention writes the side Hermes prefers")
struct MattermostRequireMentionSideP51Tests {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "scarf/Features/Platforms/ViewModels/PlatformSetup/MattermostSetupViewModel.swift"
            )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the write goes to config.yaml, not .env")
    func writeGoesToConfig() throws {
        let s = try source()
        #expect(s.contains("\"mattermost.require_mention\": PlatformSetupHelpers.envBool(requireMention)"))
        #expect(!s.contains("\"MATTERMOST_REQUIRE_MENTION\": PlatformSetupHelpers.envBool"))
    }

    /// Nothing is migrated silently: the `.env` half stays READABLE as the
    /// fallback for an absent config key, which is exactly when Hermes uses
    /// it. Removing the fallback would show config's resolved default over a
    /// live `.env` value.
    @Test("the .env half is still read as the fallback")
    func envIsStillTheFallback() throws {
        let s = try source()
        #expect(s.contains("snapshot.config?.mattermost.requireMentionIsSet"))
        #expect(s.contains("env[\"MATTERMOST_REQUIRE_MENTION\"]"))
    }
}
