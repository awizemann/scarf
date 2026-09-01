import Foundation
import Testing
import ScarfCore
@testable import scarf

/// App-target cover for the pre-release fixup package
/// (documents/reports/2026-09-01-pre-release-go-no-go-board.md).
@Suite("Pre-release fixups")
@MainActor
struct PreReleaseFixupTests {

    // MARK: - Condition 1: routine failures are not painted green

    /// `CronViewModel.message` is one string channel carrying both "Resumed"
    /// and "Failed: …". `BotRoutinesView` painted all of it
    /// `ScarfColor.success` and let it auto-clear, so a routine that failed
    /// announced itself in green and then vanished. The outcome is now typed
    /// and forwarded; failures also stay put.
    @Test("a failure posts .failure and does not auto-clear")
    func failureOutcomeIsStickyAndTyped() async throws {
        let cron = CronViewModel(context: .local)
        cron.post("Failed: boom", outcome: .failure)
        #expect(cron.message == "Failed: boom")
        #expect(cron.messageOutcome == .failure)

        // The success path's auto-clear timer is 3s; give the run loop more
        // than that and confirm a failure is still on screen.
        try await Task.sleep(for: .milliseconds(3400))
        #expect(cron.message == "Failed: boom", "a failure must not auto-clear")
        #expect(cron.messageOutcome == .failure)

        cron.dismissMessage()
        #expect(cron.message == nil)
        #expect(cron.messageOutcome == .success)
    }

    @Test("a success posts .success and clears itself")
    func successOutcomeStillAutoClears() async throws {
        let cron = CronViewModel(context: .local)
        cron.post("Resumed", outcome: .success, autoClearAfter: 0.05)
        #expect(cron.messageOutcome == .success)
        try await Task.sleep(for: .milliseconds(400))
        #expect(cron.message == nil)
    }

    /// A newer message owns the channel: the previous post's pending timer
    /// must not wipe it.
    @Test("a stale auto-clear timer never clears a newer message")
    func staleTimerDoesNotClearNewerMessage() async throws {
        let cron = CronViewModel(context: .local)
        cron.post("Resumed", outcome: .success, autoClearAfter: 0.05)
        cron.post("Failed: boom", outcome: .failure)
        try await Task.sleep(for: .milliseconds(400))
        #expect(cron.message == "Failed: boom")
    }

    /// The Bots pane reads the outcome through its wrapper rather than
    /// sniffing the string.
    @Test("BotRoutinesViewModel forwards the outcome to the view")
    func botRoutinesForwardsTheOutcome() {
        let cron = CronViewModel(context: .local)
        let vm = BotRoutinesViewModel(context: .local, botName: "scout", cron: cron)
        #expect(!vm.messageIsFailure)
        cron.post("Failed: boom", outcome: .failure)
        #expect(vm.message == "Failed: boom")
        #expect(vm.messageIsFailure)
        vm.dismissMessage()
        #expect(vm.message == nil)
        #expect(!vm.messageIsFailure)
    }

    // MARK: - Condition 5: bot conversations get the capabilities store

    /// Every bot chat's slash menu was permanently degraded because nothing
    /// ever handed the bot's `ChatViewModel` a capability snapshot — the
    /// `attachCapabilitiesStore` call `ChatView` makes for main Chat had no
    /// counterpart in `BotConversationView`.
    @Test("a bot conversation's RichChatViewModel sees non-empty capabilities")
    func botConversationReceivesCapabilities() async throws {
        let conversation = BotConversationViewModel(
            profileName: "scout",
            context: .local,
            locator: { _ in nil },
            creator: { _, _, _ in nil }
        )
        // Baseline: nothing attached yet.
        #expect(conversation.chat.richChatViewModel.capabilitiesGate.versionLine.isEmpty)

        // A store whose probe is stubbed, so this needs no `hermes` binary.
        let defaults = try! #require(UserDefaults(suiteName: "scarf.tests.\(UUID().uuidString)"))
        let cache = HermesVersionCache(defaults: defaults, probe: { _ in
            HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        })
        let store = HermesCapabilitiesStore(context: .local, cache: cache)
        await store.refresh()
        #expect(store.capabilities.isV021OrLater)

        // Exactly what the view's `.task(id:)` does.
        conversation.chat.attachCapabilitiesStore(store)

        let published = conversation.chat.richChatViewModel.capabilitiesGate
        #expect(!published.versionLine.isEmpty)
        #expect(published.isV021OrLater)
        #expect(published.hasBotMode)
    }

    // MARK: - Condition 7: the restart-notification key path

    /// Hermes reads TOP-LEVEL `<platform>.gateway_restart_notification`, and
    /// so does Scarf's own parser (`HermesConfig+YAML` composes
    /// `"\(platform)."` + the key). The old `gateway.platforms.<p>.…` form
    /// was a silent no-op the reader immediately contradicted.
    @Test("the restart-notification toggle writes the top-level key")
    func restartNotificationWritesTheTopLevelKey() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        let key = GatewayBehaviorViewModel.restartNotificationKey(platform: "slack", capabilities: caps)
        #expect(key == "slack.gateway_restart_notification")
        #expect(!key.hasPrefix("gateway.platforms."))
    }

    /// The platform segment goes through `ConfigDottedKeySegment` like every
    /// other dotted-key writer, so a segment needing escaping can't split the
    /// path.
    @Test("the platform segment is escaped like every other dotted key")
    func platformSegmentIsEscaped() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        let expected = ConfigDottedKeySegment.escaped("what.sapp", capabilities: caps)
        let key = GatewayBehaviorViewModel.restartNotificationKey(platform: "what.sapp", capabilities: caps)
        #expect(key == "\(expected).gateway_restart_notification")
    }
}
