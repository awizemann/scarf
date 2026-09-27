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

    // MARK: - session/load provenance

    /// Answers every request; `session/load` carries the provenance Hermes
    /// builds for a chain rotated once (root `sess-A` → head `sess-A-tip`,
    /// shape from `acp_adapter/provenance.py` @ v2026.9.24). Prompts held.
    actor RotatedLoadChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        var diagnosticID: String? { "rotated-load" }

        init() {
            let (i, ic) = AsyncThrowingStream<String, Error>.makeStream()
            let (e, ec) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = i; incomingCont = ic; stderr = e; stderrCont = ec
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            var result: [String: Any] = [:]
            switch method {
            case "session/prompt": return
            case "session/load":
                result = [
                    "modes": ["currentModeId": "default"],
                    "_meta": ["hermes": ["sessionProvenance": [
                        "acpSessionId": "sess-A", "currentHermesSessionId": "sess-A-tip",
                        "rootHermesSessionId": "sess-A", "parentHermesSessionId": "sess-A",
                        "sessionKind": "continuation", "compressionDepth": 1,
                    ] as [String: Any]]],
                ]
            case "session/new":
                result = ["sessionId": "sess-A", "modes": ["currentModeId": "default"]]
            default: break
            }
            guard let out = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]),
                  let text = String(data: out, encoding: .utf8) else { return }
            incomingCont.yield(text)
        }

        func close() async {
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    /// A chain that rotated while the chat was disconnected: the reconnect's
    /// `session/load` names the new head, and the transcript follows it.
    @Test @MainActor func aReconnectFollowsTheHeadTheLoadReports() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let first = RotatedLoadChannel()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in first } }
            return ACPClient(context: ctx) { _ in RotatedLoadChannel() }
        }
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == "sess-A"
        })
        #expect(vm.richChatViewModel.transcriptSessionIds == ["sess-A"])

        await first.close()
        let followed = await Lifecycle.waitUntil(timeoutSeconds: 10) {
            calls.count >= 2 && vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.transcriptSessionIds == ["sess-A", "sess-A-tip"]
        }
        #expect(followed, "the reconnect ignored the head its load reported")
        #expect(vm.richChatViewModel.sessionId == "sess-A", "the ACP id stays the handle")
        vm.stopACP()
    }
}
