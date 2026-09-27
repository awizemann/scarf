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

    /// The autostart's client dies while a second send is held behind its
    /// undrained load: the reconnect ladder reloads the same session and the
    /// held send goes out on its client instead of vanishing (review
    /// follow-up; the ladder used to clear the hold).
    @Test @MainActor func aSendHeldForADyingClientIsCarriedIntoTheLadder() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let dying = Gated()
        let calls = Lifecycle.CallCounter()
        let reconnects = GatedRecorder()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in dying } }
            let ch = Gated()
            reconnects.record(ch)
            return ACPClient(context: ctx) { _ in ch }
        }
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("first")
        #expect(await Lifecycle.waitUntil { await dying.hasPendingLoad })
        vm.sendText("second") // held behind the undrained load
        await dying.close()   // the process dies: event stream ends → ladder

        let loading = await Lifecycle.waitUntil(timeoutSeconds: 10) {
            guard let ch = reconnects.all.first else { return false }
            return await ch.hasPendingLoad
        }
        #expect(loading, "the reconnect ladder never reached session/load")
        let ch = try #require(reconnects.all.first)
        await ch.releaseLoad()
        let sent = await Lifecycle.waitUntil(timeoutSeconds: 10) {
            await ch.promptTexts.contains("second")
        }
        #expect(sent, "the send held for the dying client was dropped")
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

    /// The defensive follow: a load that names a head the transcript does not
    /// cover is followed. v2026.9.24 does not send this at load (it restores
    /// under the requested id, acp_adapter/session.py:444-446); the test pins
    /// that Scarf would follow rather than drop it.
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

    // MARK: - Bot Chat: an undelivered message is kept

    /// The reconnect gave up, the user typed, and the re-resolve found no
    /// Bot Chat any more (renamed or deleted in Hermes). The message was
    /// cleared from the composer with no bubble and simply vanished; now it
    /// is kept for the view to show, and the next send clears it.
    @Test @MainActor func aMessageTheReopenCannotDeliverIsKept() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r17-bot-\(UUID().uuidString)")
        let profileHome = home.appendingPathComponent("profiles/scout")
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        let config = "model:\n  default: anthropic/claude-x\n  provider: anthropic\n"
        try config.write(to: home.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try config.write(to: profileHome.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let lookups = ChatSessionsR16bMacTests.Box<Int>()
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: .local(home: home),
            locator: { _ in
                lookups.append(1)
                // Found on open, gone by the time the send re-resolves.
                return lookups.all.count == 1
                    ? HermesDataService.CanonicalBotChat(registryId: "bot-chat-1", liveId: "bot-chat-1", liveSource: "acp")
                    : nil
            },
            creator: { _, _, _ in nil },
            acpClientMaker: { ctx, _, _ in
                let ch = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "bot-chat-1"))
                return ACPClient(context: ctx) { _ in ch }
            }
        )
        vm.open()
        #expect(await Lifecycle.waitUntil {
            vm.phase == .live && vm.chat.richChatViewModel.sessionId == "bot-chat-1" && vm.chat.isACPConnected
        })
        vm.chat.stopACP()
        _ = await Lifecycle.waitUntil { !vm.chat.isACPConnected }

        vm.chat.sendText("are you there?")
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { vm.phase == .noConversationYet })
        #expect(vm.unsentMessage == "are you there?")

        // The next send (which starts a new Bot Chat here) clears it.
        vm.send("second try")
        #expect(vm.unsentMessage == nil)
        vm.close()
    }
}
