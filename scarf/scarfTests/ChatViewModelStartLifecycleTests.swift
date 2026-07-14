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
            /// Like `happy`, but ALSO never answers `session/cancel` —
            /// a wedged mid-turn process. Pins `boundedSessionCancel`'s
            /// deadline: teardown must proceed anyway.
            case happyHoldingCancel(sessionId: String)
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
            case .happy(let sessionId), .happyHoldingCancel(let sessionId):
                let holdCancel: Bool = if case .happyHoldingCancel = behavior { true } else { false }
                switch method {
                case "session/new", "session/load", "session/resume":
                    reply(["jsonrpc": "2.0", "id": id,
                           "result": ["sessionId": sessionId,
                                      "modes": ["currentModeId": "default"]]])
                case "session/prompt":
                    break // hold — the turn stays in flight
                case "session/cancel" where holdCancel:
                    break // hold — a wedged process never acks the cancel
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
        let chW = ScriptedACPChannel(behavior: .happy(sessionId: "sess-W"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in
                // Wedge until the test releases the gate (after the
                // watchdog has fired) — then hand back a WORKING
                // channel, modeling a wedge that eventually unsticks.
                for await _ in gate { break }
                return chW
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

        // Un-wedge the abandoned pipeline. The watchdog SELF-SUPERSEDED
        // the generation when it fired, so the resumed pipeline must
        // abandon silently (stopping its client) — NOT boot the stale
        // session over the freshly-painted error state.
        gateCont.yield(())
        gateCont.finish()
        let abandoned = await Self.waitUntil { await chW.closed }
        #expect(abandoned, "post-watchdog resume didn't stop its client")
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.failed,
                "post-watchdog resume clobbered the error state (self-supersede missing)")
        #expect(vm.acpError != nil)
        #expect(vm.richChatViewModel.sessionId == nil)
        #expect(vm.isPreparingSession == false)
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

    /// The flagship S4 trigger: SWITCHING SESSIONS mid-turn. Every
    /// sidebar-click path (`startNewSession` / `resumeSession` /
    /// `continueLastSession`) runs `richChatViewModel.reset()` at the
    /// click — which wipes `isAgentWorking` and `sessionId` — BEFORE
    /// `startACPSession` reaches `stopACP()`. The mid-turn teardown
    /// must therefore key off ChatViewModel-owned turn state, not the
    /// already-reset transcript VM, or the `session/cancel` is never
    /// sent on exactly the path S4 was diagnosed from (the duplicated
    /// DB row came from switching away and re-sending later).
    @Test @MainActor func switchingSessionsMidTurnSendsSessionCancel() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        let calls = CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let first = calls.next() == 1
            return ACPClient(context: ctx) { _ in first ? chA : chB }
        }

        vm.startNewSession()
        let ready = await Self.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.sessionId == "sess-A"
        }
        #expect(ready)

        vm.sendText("long-running turn") // held open by the scripted channel
        let promptInFlight = await Self.waitUntil {
            await chA.sentMethods.contains("session/prompt")
        }
        #expect(promptInFlight)
        #expect(vm.richChatViewModel.isAgentWorking)

        // Sidebar click mid-turn: reset() runs first, then stopACP.
        vm.startNewSession()

        let cancelSent = await Self.waitUntil {
            await chA.sentMethods.contains("session/cancel")
        }
        #expect(cancelSent, "mid-turn session switch killed the old process without session/cancel (S4's flagship path)")
        let aClosed = await Self.waitUntil { await chA.closed }
        #expect(aClosed)

        let bReady = await Self.waitUntil {
            vm.richChatViewModel.sessionId == "sess-B"
                && vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(bReady)
        // Composer feedback for the cancelled turn survives the swap…
        #expect(vm.richChatViewModel.transientHint == "Turn cancelled — switched sessions.")
        // …but the old turn's synthesized "cancelled" bubble must NOT
        // leak into the fresh transcript (it belongs to sess-A, which
        // is no longer attached).
        let strayBubble = vm.richChatViewModel.messages.contains {
            $0.role == "system" && $0.content.contains("cancelled")
        }
        #expect(strayBubble == false, "old session's cancellation bubble leaked into the new transcript")
    }

    /// A stale prompt task resuming AFTER its client was superseded
    /// must not clobber shared state: the old turn's send task is
    /// resumed with `CancellationError` by `client.stop()` (or
    /// completes/fails late), and unguarded its catch branches write
    /// `acpStatus = "Cancelled"` / `"Error"` straight over the newer
    /// session's status pill.
    ///
    /// Deterministic ordering: session A's channel never answers
    /// `session/cancel`, so `boundedSessionCancel` holds A's
    /// `client.stop()` until the 2s deadline — the stale
    /// `CancellationError` resume is therefore GUARANTEED to land
    /// well after B reached Ready, which is exactly the window where
    /// the clobber bites.
    @Test @MainActor func stalePromptTaskDoesNotClobberSupersedingSessionStatus() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .happyHoldingCancel(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        let calls = CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let first = calls.next() == 1
            return ACPClient(context: ctx) { _ in first ? chA : chB }
        }

        vm.startNewSession()
        _ = await Self.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        vm.sendText("held turn")
        _ = await Self.waitUntil { await chA.sentMethods.contains("session/prompt") }

        vm.startNewSession() // supersede mid-turn

        let bReady = await Self.waitUntil {
            vm.richChatViewModel.sessionId == "sess-B"
                && vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(bReady)

        // A's client.stop() fires at the 2s cancel bound and resumes
        // the held session/prompt with CancellationError. Wait for the
        // channel to actually close, let the stale catch branch run,
        // then B's status must still read Ready.
        let aClosed = await Self.waitUntil(timeoutSeconds: 6) { await chA.closed }
        #expect(aClosed)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(
            vm.acpStatus == ChatViewModel.ACPPhase.ready,
            "stale prompt task clobbered the superseding session's status with \(vm.acpStatus)"
        )
    }

    /// A wedged process that never acknowledges `session/cancel` must
    /// not stall teardown: `boundedSessionCancel`'s 2s deadline lets
    /// `client.stop()` (and the channel close) proceed anyway. Pins
    /// the timeout arm — remove it and this hangs past the deadline.
    @Test @MainActor func unansweredSessionCancelDoesNotStallTeardown() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .happyHoldingCancel(sessionId: "sess-1"))
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in ch }
        }

        vm.startNewSession()
        _ = await Self.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        vm.sendText("held turn")
        _ = await Self.waitUntil { await ch.sentMethods.contains("session/prompt") }

        let start = Date()
        vm.stopACP()

        // The cancel is attempted…
        let cancelSent = await Self.waitUntil { await ch.sentMethods.contains("session/cancel") }
        #expect(cancelSent)
        // …never answered, and teardown still completes within the 2s
        // bound (+ scheduling slack), instead of hanging on the ack.
        let closed = await Self.waitUntil(timeoutSeconds: 6) { await ch.closed }
        #expect(closed, "unanswered session/cancel stalled teardown — the 2s bound is broken")
        #expect(Date().timeIntervalSince(start) < 5.5)
    }

    // MARK: - deleteSession teardown (t-01bd55ec)

    /// Thread-safe recorder for the injected `sessionDeleteRunner` —
    /// captures which session ids the CLI stub was asked to delete.
    final class DeleteRecorder: @unchecked Sendable {
        private var ids: [String] = []
        private let lock = NSLock()
        func record(_ id: String) {
            lock.lock(); defer { lock.unlock() }
            ids.append(id)
        }
        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }
            return ids
        }
    }

    /// Deleting the ACTIVE session while a turn is in flight must route
    /// through the full teardown machinery: best-effort `session/cancel`
    /// BEFORE the process is killed, `client.stop()` (channel closed —
    /// pre-fix the `hermes acp` process + dispatch sources leaked until
    /// app quit while the orphaned turn kept running server-side),
    /// transcript detached, and no stuck preparing state.
    @Test @MainActor func deleteActiveSessionMidTurnCancelsAndStopsClient() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in ch }
        }
        let deletes = DeleteRecorder()
        vm.sessionDeleteRunner = { _, sid in
            deletes.record(sid)
            return 0
        }

        vm.startNewSession()
        let ready = await Self.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.sessionId == "sess-A"
        }
        #expect(ready)

        vm.sendText("long-running turn") // held open by the scripted channel
        let promptInFlight = await Self.waitUntil {
            await ch.sentMethods.contains("session/prompt")
        }
        #expect(promptInFlight)
        #expect(vm.richChatViewModel.isAgentWorking)

        vm.deleteSession("sess-A")
        #expect(deletes.recorded == ["sess-A"])

        // The orphaned turn gets a bounded best-effort cancel…
        let cancelSent = await Self.waitUntil {
            await ch.sentMethods.contains("session/cancel")
        }
        #expect(cancelSent, "deleting the active session mid-turn killed no turn: session/cancel never sent (pre-fix leak)")
        // …and the client is actually stopped (channel closed), not
        // left running until app quit.
        let closed = await Self.waitUntil { await ch.closed }
        #expect(closed, "deleting the active session leaked the ACP client (channel never closed)")

        // Transcript + preparing state sane: blank idle chat.
        #expect(vm.richChatViewModel.sessionId == nil)
        #expect(vm.richChatViewModel.messages.isEmpty)
        #expect(vm.richChatViewModel.isAgentWorking == false)
        #expect(vm.isPreparingSession == false)
        #expect(vm.isStartingSession == false)
        #expect(vm.hasActiveProcess == false)
        #expect(vm.acpStatus.isEmpty)
        // Composer-level feedback names the delete, not a session switch.
        #expect(vm.richChatViewModel.transientHint == "Turn cancelled — session deleted.")
    }

    /// Deleting the ACTIVE session while IDLE (no turn in flight) must
    /// stop the client without issuing a `session/cancel` — there is no
    /// turn to finalize, and a spurious cancel RPC against an idle
    /// session is wire noise.
    @Test @MainActor func deleteActiveSessionIdleStopsClientWithoutCancel() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in ch }
        }
        let deletes = DeleteRecorder()
        vm.sessionDeleteRunner = { _, sid in
            deletes.record(sid)
            return 0
        }

        vm.startNewSession()
        let ready = await Self.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.sessionId == "sess-A"
        }
        #expect(ready)

        vm.deleteSession("sess-A")
        #expect(deletes.recorded == ["sess-A"])

        let closed = await Self.waitUntil { await ch.closed }
        #expect(closed, "deleting the active idle session leaked the ACP client (channel never closed)")
        let methods = await ch.sentMethods
        #expect(!methods.contains("session/cancel"),
                "idle delete issued a spurious session/cancel")
        #expect(vm.richChatViewModel.sessionId == nil)
        #expect(vm.isPreparingSession == false)
        #expect(vm.hasActiveProcess == false)
        #expect(vm.acpStatus.isEmpty)
        // No turn was cancelled — no cancellation toast.
        #expect(vm.richChatViewModel.transientHint == nil)
    }

    /// Deleting a NON-active session must not disturb the live one:
    /// client stays up, the in-flight turn keeps running, no cancel RPC,
    /// transcript untouched. Only the sidebar caches drop the row.
    @Test @MainActor func deleteInactiveSessionLeavesActiveClientUntouched() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in ch }
        }
        let deletes = DeleteRecorder()
        vm.sessionDeleteRunner = { _, sid in
            deletes.record(sid)
            return 0
        }

        vm.startNewSession()
        let ready = await Self.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.sessionId == "sess-A"
        }
        #expect(ready)

        vm.sendText("keep me running") // held open by the scripted channel
        let promptInFlight = await Self.waitUntil {
            await ch.sentMethods.contains("session/prompt")
        }
        #expect(promptInFlight)

        vm.deleteSession("sess-other")
        #expect(deletes.recorded == ["sess-other"])

        // Give any erroneous teardown time to surface before asserting
        // the live session is untouched.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let stillOpen = await ch.closed
        #expect(stillOpen == false, "deleting a non-active session stopped the live client")
        let methods = await ch.sentMethods
        #expect(!methods.contains("session/cancel"),
                "deleting a non-active session cancelled the live turn")
        #expect(vm.richChatViewModel.sessionId == "sess-A")
        #expect(vm.richChatViewModel.isAgentWorking)
        #expect(vm.hasActiveProcess)
    }

    // MARK: - Interactive send echo (Fix-2 audit pin)

    /// A typed message must ALWAYS produce a user bubble: the
    /// interactive send call site (`sendText` → `sendViaACP`) relies on
    /// `localEchoAlreadyAdded` defaulting to false. A mutation flipping
    /// that call site to `true` (or defaulting the parameter to true)
    /// silently swallows every typed message's echo — S2's invisible
    /// turn, resurrected.
    @Test @MainActor func typedMessageAlwaysProducesUserBubble() async throws {
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

        vm.sendText("a perfectly ordinary typed message")
        let echoed = await Self.waitUntil {
            vm.richChatViewModel.messages.contains {
                $0.role == "user" && $0.content == "a perfectly ordinary typed message"
            }
        }
        #expect(echoed, "interactive send produced no user bubble — localEchoAlreadyAdded flag regressed")
    }
}
