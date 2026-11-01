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
}
