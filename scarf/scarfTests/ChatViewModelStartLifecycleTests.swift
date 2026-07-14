import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Coverage for `ChatViewModel`'s start-pipeline lifecycle fixes
/// (S3/S4, t-5451bd1b):
///
/// - the session-start watchdog clears a wedged start (a pipeline
///   await that never resumes) into a retryable error instead of a
///   permanently-stuck "Loading session…" pane;
/// - a fresh start SUPERSEDES a wedged/slow one via
///   `sessionStartGeneration` — the abandoned pipeline exits silently
///   and stops its client rather than leaking the spawn or clobbering
///   the newer start's state;
/// - both start-failure catch paths call `client.stop()` (pre-fix each
///   failure leaked the `hermes acp` process + 2 pipe readers);
/// - `stopACP` on a mid-turn session sends a best-effort
///   `session/cancel` before killing the process and paints
///   cancellation feedback.
///
/// All ACP plumbing is scripted through the injected
/// `acpClientFactory` seam — no subprocess, no real Hermes.
@Suite struct ChatViewModelStartLifecycleTests {

    // MARK: - Scripted channel

    /// In-memory `ACPChannel` that auto-replies to JSON-RPC requests so
    /// `ACPClient.start()` / `session/new` complete without a process.
    /// `session/prompt` is deliberately never answered — the turn stays
    /// in flight until the client is stopped. Records sent method names
    /// and whether `close()` ran (the observable effect of
    /// `client.stop()`, used to assert no-leak behavior).
    actor ScriptedACPChannel: ACPChannel {
        enum Behavior: Sendable {
            /// Answer initialize/session ops successfully; hold prompts.
            case happy(sessionId: String)
            /// Reject `initialize` with a JSON-RPC error so
            /// `client.start()` throws (the catch-path trigger).
            case failInitialize
        }

        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let behavior: Behavior

        private(set) var closed = false
        private(set) var sentMethods: [String] = []

        var diagnosticID: String? { "scripted-channel" }

        init(behavior: Behavior) {
            self.behavior = behavior
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            self.incoming = inStream
            self.incomingCont = inCont
            self.stderr = errStream
            self.stderrCont = errCont
        }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String
            else { return }
            sentMethods.append(method)
            guard let id = obj["id"] as? Int else { return } // notification — no reply
            switch behavior {
            case .failInitialize:
                reply(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32603, "message": "scripted initialize failure"]])
            case .happy(let sessionId):
                switch method {
                case "session/new", "session/load", "session/resume":
                    reply(["jsonrpc": "2.0", "id": id,
                           "result": ["sessionId": sessionId,
                                      "modes": ["currentModeId": "default"]]])
                case "session/prompt":
                    break // hold — the turn stays in flight
                default: // initialize, session/cancel, session/set_model, …
                    reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
                }
            }
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            incomingCont.yield(line)
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    /// Thread-safe factory-invocation counter (the factory closure
    /// isn't isolated, so a plain captured var would be unsound).
    final class CallCounter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            n += 1
            return n
        }
    }

    // MARK: - Helpers

    /// A temp Hermes home whose config.yaml passes the model preflight
    /// (startACPSession bails into the picker sheet otherwise).
    static func configuredHome() throws -> TempHermesHome {
        let home = try TempHermesHome()
        try "model:\n  default: test-model\n  provider: anthropic\n"
            .write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        return home
    }

    /// Poll `condition` until true or `timeoutSeconds` elapses.
    @MainActor
    static func waitUntil(
        timeoutSeconds: Double = 5,
        _ condition: @MainActor @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    // MARK: - (a) Watchdog

    /// A start whose channel factory never completes (the wedge: a
    /// pre-`initialize` await that never resumes, so not even
    /// ACPClient's 60s RPC watchdog can fire) must be torn down by the
    /// session-start watchdog: preparing state cleared, retryable
    /// error banner painted. Pre-fix nothing bounded the pipeline —
    /// `isStartingSession` stuck forever and the pane self-locked.
    @Test @MainActor func watchdogClearsWedgedStartIntoRetryableError() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        vm.sessionStartWatchdogNanos = 150_000_000 // 150ms for the test
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in
                // Hangable seam: never produces a channel.
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                throw CancellationError()
            }
        }

        vm.startNewSession()
        #expect(vm.isPreparingSession)

        let fired = await Self.waitUntil { vm.acpError != nil }
        #expect(fired, "watchdog never fired")
        #expect(vm.isStartingSession == false)
        #expect(vm.isPreparingSession == false)
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.failed)
        #expect(vm.acpError?.contains("timed out") == true)
        #expect(vm.acpErrorHint?.contains("retry") == true)
    }

    // MARK: - (a) Supersede

    /// While start A is wedged inside its channel factory, a second
    /// click must supersede it: B boots to Ready normally, and when
    /// A's factory finally resumes, A's pipeline abandons silently
    /// (B's session stays attached) and A's client is stopped — the
    /// abandoned spawn's channel gets closed, not leaked.
    @Test @MainActor func newClickSupersedesWedgedStartAndStopsItsClient() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)

        let chA = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 {
                return ACPClient(context: ctx) { _ in
                    // Wedge until the test releases the gate.
                    for await _ in gate { break }
                    return chA
                }
            }
            return ACPClient(context: ctx) { _ in chB }
        }

        vm.startNewSession() // A — wedges in the channel factory
        try? await Task.sleep(nanoseconds: 50_000_000)
        vm.startNewSession() // B — supersedes A

        let bReady = await Self.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.sessionId == "sess-B"
        }
        #expect(bReady, "superseding start B never reached Ready")

        // Un-wedge A: its pipeline resumes, must notice it was
        // superseded, stop its own client, and leave B untouched.
        gateCont.yield(())
        gateCont.finish()

        let aStopped = await Self.waitUntil { await chA.closed }
        #expect(aStopped, "superseded start's client was not stopped (leak)")
        #expect(vm.richChatViewModel.sessionId == "sess-B")
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.ready)
        #expect(vm.isPreparingSession == false)
        let bStillOpen = await chB.closed
        #expect(bStillOpen == false, "supersede cleanup must not touch the newer start's client")
    }

    // MARK: - (b) Catch-path client.stop()

    /// `startACPSession`'s catch path must stop the client when the
    /// boot throws — observable as the channel being closed. Pre-fix
    /// the client (and its spawned process + 2 pipe readers) leaked on
    /// every start failure.
    @Test @MainActor func startFailureStopsTheClient() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .failInitialize)
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in ch }
        }

        vm.startNewSession()

        let failed = await Self.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.failed }
        #expect(failed)
        let stopped = await Self.waitUntil { await ch.closed }
        #expect(stopped, "start-failure catch path leaked the client (channel never closed)")
        #expect(vm.isStartingSession == false)
        #expect(vm.isPreparingSession == false)
    }

    /// Same guarantee for `autoStartACPAndSend`'s catch path (typing
    /// into a blank chat).
    @Test @MainActor func autoStartFailureStopsTheClient() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .failInitialize)
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in ch }
        }

        vm.sendText("hello") // no acpClient → auto-start path

        let failed = await Self.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.failed }
        #expect(failed)
        let stopped = await Self.waitUntil { await ch.closed }
        #expect(stopped, "auto-start catch path leaked the client (channel never closed)")
        #expect(vm.isStartingSession == false)
    }

    // MARK: - (b) Mid-turn teardown hygiene

    /// Stopping ACP while a turn is in flight must send a best-effort
    /// `session/cancel` BEFORE the process is killed (S4: killing
    /// mid-turn without cancel left Hermes with an unfinalized turn
    /// that later merged into a duplicated DB row) and paint
    /// cancellation feedback through the existing mechanisms.
    @Test @MainActor func stopACPMidTurnCancelsAndPaintsFeedback() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-1"))
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in ch }
        }

        vm.startNewSession()
        let ready = await Self.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        #expect(ready)

        vm.sendText("do something") // scripted channel holds session/prompt
        let promptInFlight = await Self.waitUntil {
            await ch.sentMethods.contains("session/prompt")
        }
        #expect(promptInFlight)
        #expect(vm.richChatViewModel.isAgentWorking)

        vm.stopACP()

        let cancelSent = await Self.waitUntil {
            await ch.sentMethods.contains("session/cancel")
        }
        #expect(cancelSent, "stopACP killed a mid-turn process without session/cancel")
        let closedAfterCancel = await Self.waitUntil { await ch.closed }
        #expect(closedAfterCancel)
        // Cancel must precede the kill.
        let methods = await ch.sentMethods
        #expect(methods.lastIndex(of: "session/cancel") != nil)

        // Feedback: composer toast + system bubble via the synthesized
        // promptComplete (transcript still attached to sess-1 here).
        #expect(vm.richChatViewModel.transientHint == "Turn cancelled — switched sessions.")
        let paintedBubble = vm.richChatViewModel.messages.contains {
            $0.role == "system" && $0.content.contains("cancelled")
        }
        #expect(paintedBubble)
        #expect(vm.richChatViewModel.isAgentWorking == false)
    }
}
