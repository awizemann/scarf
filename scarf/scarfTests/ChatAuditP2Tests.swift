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
}
