import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P7b (t-409ec2da) — Mac `ChatViewModel` lifecycle fixes, driven over the
/// scripted ACP channel from `ChatViewModelStartLifecycleTests`:
///  - a reconnect ladder whose `start()`/`loadSession` outlives a session
///    switch must not install the dead session over the new one;
///  - a Live Voice barge-in cancel (Hermes answers the held prompt with
///    `stopReason: "cancelled"`) ends the turn without a failure bubble or
///    banner.
@Suite struct ChatViewModelP7bTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias ScriptedACPChannel = Lifecycle.ScriptedACPChannel

    // MARK: - (1) Reconnect currency

    /// The connection dies; the reconnect attempt wedges inside its spawn
    /// (nothing can interrupt `client.start()`); the user starts a new chat
    /// B meanwhile. When the stale attempt finally completes its
    /// `session/load`, it must stop its own client and leave B attached.
    /// Pre-fix it installed itself: `acpClient` and the transcript flipped
    /// back to the dead session A, and B's client was orphaned.
    @Test @MainActor func staleReconnectDoesNotReplaceANewerSession() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)

        let chA = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let chReconnect = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            switch calls.next() {
            case 1:
                return ACPClient(context: ctx) { _ in chA }
            case 2:
                return ACPClient(context: ctx) { _ in
                    for await _ in gate { break } // wedged spawn
                    return chReconnect
                }
            default:
                return ACPClient(context: ctx) { _ in chB }
            }
        }

        vm.startNewSession()
        let aReady = await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == "sess-A"
        }
        #expect(aReady)

        await chA.close() // transport dies → reconnect ladder
        let ladderSpawning = await Lifecycle.waitUntil { calls.count >= 2 }
        #expect(ladderSpawning, "reconnect never reached its spawn")

        vm.startNewSession() // B supersedes while the ladder is wedged
        let bReady = await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == "sess-B"
        }
        #expect(bReady)

        gateCont.yield(())
        gateCont.finish()
        // The stale attempt completes `session/load`, then must bow out.
        let loaded = await Lifecycle.waitUntil { await chReconnect.sentMethods.contains("session/load") }
        #expect(loaded, "the wedged attempt never resumed")
        let stopped = await Lifecycle.waitUntil { await chReconnect.closed }
        #expect(stopped, "the stale reconnect's client was installed (or leaked) instead of stopped")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.richChatViewModel.sessionId == "sess-B", "stale reconnect re-attached the dead session")
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.ready)
        let bOpen = await chB.closed
        #expect(bOpen == false, "the newer session's client was disturbed")
        #expect(vm.hasActiveProcess)
    }

    // MARK: - (6) Deliberate cancel

    /// Holds `session/prompt` until a `session/cancel` arrives — as a JSON-RPC
    /// request (today's ACPClient) or a notification (ACP's own shape) —
    /// then answers the held prompt with `stopReason: "cancelled"`, as
    /// Hermes's `_finish_turn` does (acp_adapter/server.py:965,999 @
    /// v2026.9.24).
    actor CancellableChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private var heldPrompt: Int?
        private(set) var sentMethods: [String] = []
        /// "cancel", "answered", "closed" in the order they happened.
        private(set) var timeline: [String] = []
        /// How long Hermes takes to wind the turn down after the cancel.
        private let answerDelayNanos: UInt64

        var diagnosticID: String? { "p7b-cancellable-channel" }

        init(answerDelayNanos: UInt64 = 0) {
            self.answerDelayNanos = answerDelayNanos
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = inStream
            incomingCont = inCont
            stderr = errStream
            stderrCont = errCont
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            sentMethods.append(method)
            let id = obj["id"] as? Int
            switch method {
            case "session/cancel":
                timeline.append("cancel")
                if let id { reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()]) }
                if let held = heldPrompt {
                    heldPrompt = nil
                    if answerDelayNanos > 0 {
                        Task { [answerDelayNanos] in
                            try? await Task.sleep(nanoseconds: answerDelayNanos)
                            await self.answerCancelled(held)
                        }
                    } else {
                        answerCancelled(held)
                    }
                }
            case "session/prompt":
                heldPrompt = id
            case "session/new", "session/load":
                guard let id else { return }
                reply(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": "sess-v", "modes": ["currentModeId": "default"]]])
            default:
                guard let id else { return }
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }

        private func answerCancelled(_ id: Int) {
            guard timeline.last != "closed" else { return } // process already gone
            timeline.append("answered")
            reply(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "cancelled"]])
        }

        func close() async {
            timeline.append("closed")
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    /// Mid-turn teardown (a session switch) must let the cancelled turn
    /// END before killing the process: the cancel is a notification that
    /// returns once written (P7a), and closing stdin right after it makes
    /// the acp lib's `Connection.close()` cancel Hermes's in-flight
    /// handlers — the cancel is cut short and the turn left unfinalized
    /// (S4's duplicated row). Here Hermes takes 300 ms to answer the
    /// prompt with `cancelled`; pre-fix the channel closed first.
    @Test @MainActor func midTurnTeardownWaitsForTheCancelledTurnToEnd() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let channel = CancellableChannel(answerDelayNanos: 300_000_000)
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        _ = await Lifecycle.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        vm.sendText("long job")
        _ = await Lifecycle.waitUntil { await channel.sentMethods.contains("session/prompt") }

        vm.stopACP()

        let closed = await Lifecycle.waitUntil { await channel.timeline.contains("closed") }
        #expect(closed)
        let timeline = await channel.timeline
        #expect(timeline == ["cancel", "answered", "closed"],
                "process killed before the cancelled turn ended: \(timeline)")
    }

    /// A voice barge-in cancels the running voice turn before any reply
    /// text streamed. Pre-fix Hermes's `cancelled` answer painted "The
    /// prompt ended without a response (stopReason: cancelled)." and an
    /// error banner — for a request the user deliberately talked over.
    @Test @MainActor func voiceBargeInCancelShowsNoFailure() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let channel = CancellableChannel()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        let ready = await Lifecycle.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        #expect(ready)

        try await vm.submitVoiceTurn(VoiceTurnRequest(id: "v1", prompt: "book the dentist", context: ""))
        let inFlight = await Lifecycle.waitUntil { await channel.sentMethods.contains("session/prompt") }
        #expect(inFlight)

        await vm.cancelActiveVoiceTurn()
        let settled = await Lifecycle.waitUntil { vm.richChatViewModel.isAgentWorking == false }
        #expect(settled, "the cancelled turn never returned")
        try? await Task.sleep(nanoseconds: 200_000_000) // let a stray banner task land

        let failureBubble = vm.richChatViewModel.messages.contains { $0.role == "system" }
        #expect(failureBubble == false, "deliberate cancel painted a failure bubble")
        #expect(vm.richChatViewModel.acpError == nil, "deliberate cancel raised an error banner")
        #expect(vm.acpError == nil)
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.ready)
    }
}
