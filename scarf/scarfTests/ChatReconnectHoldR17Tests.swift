import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R17 — the send holds R16b added, carried to the two paths that went
/// around them:
///
/// - a send typed while the reconnect ladder runs (no client installed yet)
///   used to auto-start a SECOND `hermes acp` for the same session, racing
///   the ladder. It is now held for the client the ladder installs;
/// - a Live Voice turn submitted while an autostart's `session/load` replay
///   has not drained called `markPromptSent`, opening the replay gate
///   mid-replay. It now answers busy and sends nothing.
@Suite struct ChatReconnectHoldR17Tests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Gated = ChatSessionsR16bMacTests.GatedReplayChannel

    /// Records the gated channels the reconnect factory hands out.
    final class GatedRecorder: @unchecked Sendable {
        private var channels: [Gated] = []
        private let lock = NSLock()
        func record(_ ch: Gated) { lock.withLock { channels.append(ch) } }
        var all: [Gated] { lock.withLock { channels } }
    }

    @Test @MainActor func aSendDuringTheReconnectLadderIsHeldNotAutoStarted() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let first = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let calls = Lifecycle.CallCounter()
        let reconnects = GatedRecorder()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in first } }
            let ch = Gated()
            reconnects.record(ch)
            return ACPClient(context: ctx) { _ in ch }
        }

        vm.startNewSession()
        #expect(await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == "sess-A"
        })

        // The process dies; the ladder spawns its client and waits in
        // `session/load` (held by the gated channel).
        await first.close()
        let loading = await Lifecycle.waitUntil(timeoutSeconds: 10) {
            guard let ch = reconnects.all.first else { return false }
            return await ch.hasPendingLoad
        }
        #expect(loading, "the reconnect ladder never reached session/load")

        vm.sendText("typed while reconnecting")
        // Echoed at once, but no second client: the pre-fix code
        // auto-started here, which is a third factory call.
        #expect(vm.richChatViewModel.messages.filter(\.isUser).map(\.content).last == "typed while reconnecting")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(calls.count == 2, "a send during the ladder spawned another hermes acp")

        let ch = try #require(reconnects.all.first)
        await ch.releaseLoad()
        let sent = await Lifecycle.waitUntil(timeoutSeconds: 10) {
            await ch.promptTexts == ["typed while reconnecting"]
        }
        #expect(sent, "the held send never went out on the ladder's client")
        #expect(calls.count == 2)
        // The load's replay did not paint as new content.
        let leaked = vm.richChatViewModel.messages.filter { $0.content.contains("REPLAYED") }
        #expect(leaked.isEmpty)
        vm.stopACP()
    }

    @Test @MainActor func aVoiceTurnDuringAnUndrainedReplayAnswersBusy() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Gated()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("first")
        #expect(await Lifecycle.waitUntil { await ch.hasPendingLoad })
        // The client is installed and live, its replay not handled.
        #expect(vm.canHostVoiceTurns)

        try await vm.submitVoiceTurn(VoiceTurnRequest(id: "v1", prompt: "spoken", context: ""))
        #expect(vm.voiceTurnReply(for: "v1")?.text == ChatViewModel.voiceBusyReply)
        #expect(await ch.sentMethods.contains("session/prompt") == false,
                "the voice turn went out before the load's replay drained")
        #expect(!vm.richChatViewModel.messages.contains { $0.isUser && $0.content == "spoken" })

        // After the drain the typed send goes out and voice works again.
        await ch.releaseLoad()
        #expect(await Lifecycle.waitUntil { await ch.promptTexts == ["first"] })
        let leaked = vm.richChatViewModel.messages.filter { $0.content.contains("REPLAYED") }
        #expect(leaked.isEmpty)
        vm.stopACP()
    }
}
