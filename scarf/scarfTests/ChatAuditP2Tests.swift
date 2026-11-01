import Testing
import Foundation
import ScarfCore
@testable import scarf

/// The v3.8.0 audit's chat-lifecycle findings, each driven through a real
/// `ChatViewModel` over a scripted channel.
@Suite struct ChatAuditP2Tests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Rows = ParallelChatsRowsNotificationsTests
    typealias Gated = ChatSessionsR16bMacTests.GatedReplayChannel

    // MARK: - Stuck on "Agent working" (#1)

    /// Holds the first turn's post-processing open until the test releases it.
    @MainActor
    final class PostProcessingHold {
        private(set) var reached = false
        private var calls = 0
        private let gate: AsyncStream<Void>
        private let gateContinuation: AsyncStream<Void>.Continuation

        init() {
            (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        }

        func hook(_ text: String) async {
            calls += 1
            guard calls == 1 else { return }
            reached = true
            for await _ in gate { break }
        }

        func release() { gateContinuation.finish() }
    }

    /// Runs "first" to its end by `finish`, holds its post-processing open,
    /// then runs a second turn to its end: its completion has to land.
    @MainActor
    private static func aLaterTurnCompletes(
        finishFirst finish: (Rows.ControlledChannel) async -> Void
    ) async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Rows.ControlledChannel(sessionId: "sess-A")
        Rows.install([channel], on: vm)
        let hold = PostProcessingHold()
        vm.focusedChat.afterTurnClosedForTesting = { await hold.hook($0) }
        defer { hold.release() }

        #expect(await Rows.startWorking(vm, channel, "first"))
        await finish(channel)
        #expect(await Lifecycle.waitUntil { hold.reached })
        #expect(!vm.richChatViewModel.isAgentWorking)
        #expect(!vm.focusedChat.hasTurnInFlight, "a closed turn still counted as in flight")

        vm.sendText("/second")
        #expect(await Lifecycle.waitUntil { await channel.hasHeldPrompt })
        #expect(vm.richChatViewModel.isAgentWorking)
        await channel.completePrompts()
        #expect(await Lifecycle.waitUntil { !vm.richChatViewModel.isAgentWorking },
                "the later turn skipped its completion: stuck on Agent working")
        #expect(await Lifecycle.waitUntil { !vm.focusedChat.hasTurnInFlight })
        vm.leaveChat()
    }

    @Test @MainActor func aTurnReturningDuringAnEarlierTurnsPostProcessingCompletes() async throws {
        try await Self.aLaterTurnCompletes { await $0.completePrompts() }
    }

    @Test @MainActor func aTurnReturningAfterAnEarlierTurnFailedCompletes() async throws {
        try await Self.aLaterTurnCompletes { await $0.failPrompts() }
    }

    // MARK: - Held sends survive stop() (#4)

    /// A send held behind an autostart's undrained load, then a deliberate
    /// stop: `holdingForPendingClient` is false by then, and the held send
    /// used to survive, so the chat counted as working for good.
    @Test @MainActor func stopDropsSendsHeldForAClient() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Gated()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("first")
        #expect(await Lifecycle.waitUntil { await channel.hasPendingLoad })
        vm.sendText("second")
        #expect(vm.focusedChat.hasHeldSends)

        vm.focusedChat.stop()
        #expect(!vm.focusedChat.hasHeldSends, "stop() left a held send behind")
        #expect(!vm.focusedChat.isBusyForBudget)
        #expect(vm.workingChats.isEmpty, "a stopped chat still counted as working")
        #expect(!vm.richChatViewModel.isAgentWorking, "a stopped chat still showed Agent working")
        await channel.releaseLoad()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await channel.promptTexts.isEmpty, "a stopped start still sent")
    }

    /// A caller that wants a hint still gets one: the budget's release says
    /// what was lost where it was typed.
    @Test @MainActor func releaseStillSaysWhatItDropped() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Gated()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("first")
        #expect(await Lifecycle.waitUntil { await channel.hasPendingLoad })
        vm.sendText("second")

        vm.focusedChat.releaseProcess(stoppingTurn: true)
        #expect(!vm.focusedChat.hasHeldSends)
        #expect(vm.richChatViewModel.transientHint?.contains("couldn't be sent") == true)
        #expect(!vm.richChatViewModel.isAgentWorking)
    }

    // MARK: - Spawn after close or delete (#5)

    /// `resumeSession` is in its off-main attribution read when these run
    /// (same actor, no suspension yet), so the pipeline resumes afterwards:
    /// it must abandon rather than spawn `hermes acp` for a gone window.
    @MainActor
    private static func expectNoSpawn(afterStop stop: (ChatViewModel) -> Void) async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            _ = calls.next()
            let channel = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "sess-R"))
            return ACPClient(context: ctx) { _ in channel }
        }

        vm.resumeSession("sess-R")
        stop(vm)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(calls.count == 0, "a stopped chat's pending start spawned hermes acp")
        #expect(!vm.isPreparingSession)
    }

    @Test @MainActor func stopAllChatsAbandonsTheFocusedChatsPendingStart() async throws {
        try await Self.expectNoSpawn { _ = $0.stopAllChats() }
    }

    @Test @MainActor func stopForDeletionAbandonsAPendingStart() async throws {
        try await Self.expectNoSpawn { _ = $0.focusedChat.stopForDeletion() }
    }

    /// Stop semantics stay: the focused chat is kept, and can start again.
    @Test @MainActor func aChatStoppedByStopAllChatsCanStartAgain() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Rows.ControlledChannel(sessionId: "sess-A")
        Rows.install([channel], on: vm)
        let focused = vm.focusedChat

        _ = vm.stopAllChats()
        #expect(vm.chats.count == 1 && vm.focusedChat === focused)
        vm.startNewSession()
        #expect(await ParallelChatsRegistryTests.readyOn(vm, "sess-A"))
        vm.leaveChat()
    }

    // MARK: - Project accept_edits vs the user's pick (#8)

    typealias Budget = ParallelChatsBudgetTests
    typealias ModeChannel = ParallelChatsBudgetTests.ModeChannel

    /// A chat in an opted-in project, on `first`, then `second` for the next
    /// spawn; the user has picked `pick` in it.
    @MainActor
    private static func projectChat(
        _ home: TempHermesHome, first: ModeChannel, second: ModeChannel, pick: ACPApprovalMode
    ) async throws -> ChatViewModel {
        let suite = "audit-mode-\(UUID().uuidString)"
        let vm = try await Budget.modeVM(home, suite: suite)
        let store = ProjectAutoAcceptEditsStore(suiteName: suite, testServiceSuffix: "aae-\(UUID().uuidString)")
        #expect(store.setEnabled(true, projectId: "/p/opted-in"))
        vm.autoAcceptEditsStore = store
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let channel = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in channel }
        }
        vm.startNewSession(projectPath: "/p/opted-in")
        #expect(await ParallelChatsRegistryTests.readyOn(vm, "sess-A"))
        #expect(await Lifecycle.waitUntil { await first.modeIds == ["accept_edits"] })
        vm.switchApprovalMode(pick)
        #expect(await Lifecycle.waitUntil { vm.focusedChat.userPickedApprovalMode == pick })
        return vm
    }

    @MainActor
    private static func releaseAndReattach(_ vm: ChatViewModel, on second: ModeChannel) async {
        let chat = vm.focusedChat
        await chat.releaseProcess()?.value
        vm.focus(chat)
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 15) {
            let loaded = await second.sentMethods.contains("session/load")
            return loaded && vm.acpStatus == ChatViewModel.ACPPhase.ready
        })
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// A Default pick stands: the project's accept_edits is not applied on
    /// the way back, not even for a moment.
    @Test @MainActor func aReattachDoesNotApplyTheProjectsAcceptEditsOverAPick() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "default")
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(await second.modeIds.isEmpty, "a mode was set over the user's Default pick")
        #expect(vm.richChatViewModel.activeApprovalMode == .default)
    }

    /// The session came back looser than the pick and the re-send failed: say so.
    @Test @MainActor func aFailedReattachResendThatLeavesMoreAllowedRaisesAnError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits", rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(await second.modeIds == ["default"])
        #expect(vm.acpError?.contains("Default") == true, "a failed re-send was only logged")
    }

    /// A host that doesn't report its mode might be in anything.
    @Test @MainActor func aFailedResendOnAnUnreportedModeRaisesAnError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: nil, rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(vm.acpError != nil)
    }

    /// Failing to restore a looser pick only means more prompts: no alert.
    @Test @MainActor func aFailedResendThatCanOnlyAskMoreStaysQuiet() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "default", rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .dontAsk)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(await second.modeIds == ["dont_ask"])
        #expect(vm.acpError == nil)
    }

    /// The reconnect ladder too, whose own clean-up must not wipe the banner.
    @Test @MainActor func aFailedResendOnTheReconnectLadderKeepsItsError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits", rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await first.close()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { await second.modeIds == ["default"] })
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { vm.acpStatus == ChatViewModel.ACPPhase.ready })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.acpError?.contains("Default") == true, "the ladder wiped the failed re-send's error")
    }
}
