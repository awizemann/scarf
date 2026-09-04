import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Runtime-layer coverage for `MiniAppAgentSession` — the actor backing
/// `scarf.prompt` / `scarf.onEvent`. This is the security-and-correctness
/// half of the mini-app agent channel that shipped "build-verified only";
/// these tests pin the request/response contract and the concurrency
/// guards that previously had no regression net.
///
/// **Harness.** The session takes an injected `clientFactory`, so each
/// test wires a real `ACPClient` over an in-memory `FakeACPChannel`
/// (mirrors `M1ACPTests.MockACPChannel`). Driving the real client +
/// real `ACPEventParser` keeps the tests honest about how the agent
/// session actually completes a turn: `sendPrompt` returning is the
/// completion signal — ACPClient's event stream never carries
/// `.promptComplete` (only `ChatViewModel` synthesizes one for the chat
/// path), which is exactly the gap that left the happy path unresolved
/// before the fix landed.
/// **Why `.serialized`, and why the deadlines are generous (t-05a6bb8b).**
///
/// Every test here is in-memory — a `FakeACPChannel` actor and a real
/// `ACPClient` — so the suite owns no file, no port and no subprocess, and
/// it is green every time it runs alone. What it does own is nine tests that
/// each spin a 10-15 ms polling loop against a 2 s deadline, and the deadline
/// is the only thing that can fail: the assertions are about *whether* a turn
/// resolves, never about how fast. Run in the full `scarfTests` suite, those
/// loops share a machine with suites that spawn real `Process`es (the same
/// cross-suite CPU/scheduler contention behind the flaky
/// `RemoteSQLiteBackend` subprocess race, t-aud32), and a poll that should
/// take 30 ms takes seconds — so the suite failed roughly one run in three
/// on a deadline, never on a behaviour.
///
/// Two changes, addressing the two halves of the contention:
///
/// 1. `.serialized` removes the contention this suite creates FOR ITSELF —
///    nine concurrent polling loops become one. It does not (and cannot)
///    stop sibling suites running alongside: `.serialized` covers a suite and
///    its subgroups, not the rest of the run.
/// 2. The deadlines are scaled for load (`Deadline`). A timeout here is a
///    hang guard, not an assertion, so its only job is to keep a genuinely
///    leaked continuation from hanging CI forever. Two seconds was tuned to
///    an idle machine and had no headroom for a loaded one.
@Suite(.serialized) struct MiniAppAgentSessionTests {

    // MARK: - Fake channel

    /// In-memory `ACPChannel` for tests. Records outgoing lines, optionally
    /// auto-answers the `initialize` + `session/new` handshake (the
    /// mechanical part no test cares about), and exposes scripting hooks for
    /// the parts that ARE under test: replying to `session/prompt`, emitting
    /// `session/update` notifications, raising a permission request, and
    /// killing the transport.
    actor FakeACPChannel: ACPChannel {
        static let defaultSessionId = "mini-1"

        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation

        private let autoHandshake: Bool
        private let sessionId: String
        private(set) var sent: [String] = []
        private(set) var closed = false

        var diagnosticID: String? { "fake-mini-channel" }
        var isClosed: Bool { closed }
        var sentCount: Int { sent.count }
        var promptRequestCount: Int {
            sent.filter { Self.method(of: $0) == "session/prompt" }.count
        }

        init(autoHandshake: Bool = true, sessionId: String = FakeACPChannel.defaultSessionId) {
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            self.incoming = inStream
            self.incomingCont = inCont
            self.stderr = errStream
            self.stderrCont = errCont
            self.autoHandshake = autoHandshake
            self.sessionId = sessionId
        }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            sent.append(line)
            guard autoHandshake,
                  let obj = Self.decode(line),
                  let method = obj["method"] as? String,
                  let id = obj["id"] as? Int
            else { return }
            // Auto-answer only the handshake; `session/prompt` is left for
            // the test to reply to so it can stage chunks first.
            switch method {
            case "initialize":
                yieldJSON(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
            case "session/new":
                yieldJSON(["jsonrpc": "2.0", "id": id, "result": ["sessionId": sessionId]])
            default:
                break
            }
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }

        // MARK: Scripting hooks

        func sentContains(_ needle: String) -> Bool {
            sent.contains { $0.contains(needle) }
        }

        /// The `cwd` carried by the `session/new` request, if one was sent.
        /// This is the ACP SESSION cwd (tool-dir resolution) — distinct from
        /// the spawned `hermes acp` PROCESS cwd (AGENTS.md source), which the
        /// injected-channel harness doesn't model.
        func sessionNewCwd() -> String? {
            for line in sent {
                guard let obj = Self.decode(line),
                      obj["method"] as? String == "session/new",
                      let params = obj["params"] as? [String: Any] else { continue }
                return params["cwd"] as? String
            }
            return nil
        }

        /// Reply to the most recent `session/prompt` request, which makes
        /// `ACPClient.sendPrompt` return — the session's turn-completion
        /// signal.
        func replyToPrompt(stopReason: String = "end_turn") {
            guard let id = lastRequestId(method: "session/prompt") else { return }
            yieldJSON(["jsonrpc": "2.0", "id": id, "result": ["stopReason": stopReason]])
        }

        func emitMessageChunk(sessionId: String, text: String) {
            yieldJSON([
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "sessionId": sessionId,
                    "update": [
                        "sessionUpdate": "agent_message_chunk",
                        "content": ["text": text],
                    ] as [String: Any],
                ] as [String: Any],
            ])
        }

        /// Emit an agent→client `session/request_permission` request. A
        /// mini-app session must auto-cancel these (no UI to answer them).
        func emitPermissionRequest(sessionId: String, requestId: Int) {
            yieldJSON([
                "jsonrpc": "2.0",
                "id": requestId,
                "method": "session/request_permission",
                "params": [
                    "sessionId": sessionId,
                    "toolCall": ["title": "rm -rf /", "kind": "execute"] as [String: Any],
                    "options": [
                        ["optionId": "allow", "name": "Allow"],
                        ["optionId": "reject_once", "name": "Reject"],
                    ],
                ] as [String: Any],
            ])
        }

        func simulateEOF() { incomingCont.finish() }
        func simulateError(_ error: Error) { incomingCont.finish(throwing: error) }

        // MARK: Internals

        private func lastRequestId(method: String) -> Int? {
            for line in sent.reversed() {
                if let obj = Self.decode(line),
                   obj["method"] as? String == method,
                   let id = obj["id"] as? Int {
                    return id
                }
            }
            return nil
        }

        private func yieldJSON(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }

        private static func decode(_ line: String) -> [String: Any]? {
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        private static func method(of line: String) -> String? {
            decode(line)?["method"] as? String
        }
    }

    /// Thread-safe collector for `scarf.onEvent` forwarding. The session's
    /// sink is a synchronous `@Sendable` closure, so this uses a lock rather
    /// than actor hops — once a chunk shows up here, `handle()` has already
    /// folded its text into the reply buffer.
    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ACPEvent] = []

        func append(_ event: ACPEvent) {
            lock.lock(); events.append(event); lock.unlock()
        }

        var messageChunkCount: Int {
            lock.lock(); defer { lock.unlock() }
            return events.filter {
                if case .messageChunk = $0 { return true } else { return false }
            }.count
        }

        var hasPromptComplete: Bool {
            lock.lock(); defer { lock.unlock() }
            return events.contains {
                if case .promptComplete = $0 { return true } else { return false }
            }
        }
    }

    // MARK: - Tests

    /// The fix this work landed: a normal turn must accumulate the streamed
    /// `messageChunk` text and resolve `prompt()` with the full reply when
    /// the turn ends. Before the fix, `sendPrompt`'s return was discarded
    /// and the continuation waited on a `.promptComplete` event the stream
    /// never delivers — so this would hang (caught here by `withTimeout`).
    @Test func promptAccumulatesChunksAndResolvesOnCompletion() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)
        let sink = EventBox()
        await session.setEventSink { sink.append($0) }

        let prompt = Task { try await session.prompt("hi") }
        // Handshake auto-completes; wait until the prompt RPC is on the wire.
        try await waitFor { await fake.promptRequestCount >= 1 }

        await fake.emitMessageChunk(sessionId: FakeACPChannel.defaultSessionId, text: "Hello ")
        await fake.emitMessageChunk(sessionId: FakeACPChannel.defaultSessionId, text: "world")
        // Both chunks must be folded into the buffer before we signal the
        // turn end, otherwise completion could race ahead of a chunk.
        try await waitFor { sink.messageChunkCount == 2 }

        await fake.replyToPrompt()

        let reply = try await withTimeout { try await prompt.value }
        #expect(reply == "Hello world")
        // The fix also routes a synthesized `.promptComplete` through the
        // sink, so `scarf.onEvent` still sees the "complete" signal.
        #expect(sink.hasPromptComplete)
    }

    /// Ordering guarantee: a chunk emitted immediately before the turn-end
    /// reply must still land in the resolved text, even though completion is
    /// signaled by `sendPrompt`'s return on a different task than the
    /// chunk-draining event loop. We do NOT wait for the sink here (unlike
    /// the test above), so completion races the drain — `completeTurn` must
    /// wait for the buffer to quiesce. Flaky/truncating before the drain fix.
    @Test func promptResolvesFullReplyWhenCompletionRacesTheChunkDrain() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)

        let prompt = Task { try await session.prompt("hi") }
        try await waitFor { await fake.promptRequestCount >= 1 }

        // Emit the chunk and the turn-end reply back-to-back; no sink wait.
        await fake.emitMessageChunk(sessionId: FakeACPChannel.defaultSessionId, text: "deterministic")
        await fake.replyToPrompt()

        let reply = try await withTimeout { try await prompt.value }
        #expect(reply == "deterministic")
    }

    /// The agent session must resolve TOOL directories against the project:
    /// it opens `session/new` with `cwd = projectRoot`. Pins the SESSION-cwd
    /// half of the type's two-cwd contract (the half the docstring asserts
    /// "tool dirs resolve there"). The PROCESS cwd — the AGENTS.md source —
    /// is a separate, deliberately-not-the-project choice (t-0b850b5b) that
    /// lives in the default `forMacApp` factory and isn't observable through
    /// the injected in-memory channel, so it isn't asserted here.
    @Test func sessionIsOpenedWithProjectRootAsSessionCwd() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)

        let prompt = Task { try await session.prompt("hi") }
        // session/new is part of the handshake that precedes the prompt RPC,
        // so by the time a prompt is on the wire it has already been sent.
        try await waitFor { await fake.promptRequestCount >= 1 }
        await fake.replyToPrompt()
        _ = try await withTimeout { try await prompt.value }

        let cwd = await fake.sessionNewCwd()
        #expect(cwd == "/tmp/miniapp-agent-tests")
    }

    /// Regression for the non-atomic busy guard (commit 350c3bd). `prompt()`
    /// claims `promptInFlight` BEFORE the `await ensureSession()`
    /// suspension; a second cold-start prompt racing in while the first is
    /// parked inside `ensureSession()` must be rejected as `.busy` (the old
    /// code let both pass the guard, leaking a continuation).
    @Test func concurrentColdStartPromptsRejectSecondAsBusy() async throws {
        // No auto-handshake → the first prompt stalls awaiting the
        // initialize reply, i.e. suspended INSIDE ensureSession().
        let fake = FakeACPChannel(autoHandshake: false)
        let session = makeSession(fake)

        let first = Task { try await session.prompt("first") }
        // Once initialize is on the wire, the first prompt has already
        // claimed the slot and is parked in ensureSession().
        try await waitFor { await fake.sentContains("initialize") }

        let secondError = await captureError { _ = try await session.prompt("second") }
        #expect(isBusy(secondError))

        // Kill the stalled handshake so the first prompt resolves rather
        // than leaking (no hang).
        await fake.simulateEOF()
        let firstError = await captureError {
            _ = try await self.withTimeout { try await first.value }
        }
        #expect(firstError != nil)
        #expect(!(firstError is TimeoutError))
    }

    /// Bug #1's invariant: when the transport dies mid-turn, `prompt()` must
    /// resolve rather than hang. ACPClient never emits `.connectionLost` on
    /// its event stream, so the session has to surface the failure itself
    /// (via the failed `sendPrompt` and/or the `streamEnded()` fallback).
    @Test func disconnectMidPromptResolvesWithoutHang() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)

        let prompt = Task { try await session.prompt("hi") }
        try await waitFor { await fake.promptRequestCount >= 1 }

        await fake.simulateError(ACPChannelError.closed(exitCode: 1))

        do {
            _ = try await withTimeout { try await prompt.value }
            Issue.record("expected the prompt to throw after the channel died")
        } catch is TimeoutError {
            Issue.record("prompt hung after disconnect — continuation leaked")
        } catch {
            // Expected: a transport/agent error, not a hang.
        }
    }

    /// The sliding-window limiter (8 / 60s) allows eight prompts in the
    /// window and denies the ninth before it ever touches a session.
    @Test func rateLimitDeniesNinthPrompt() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)

        for i in 1...8 {
            let reply = try await completeOnePrompt(session, fake, text: "p\(i)")
            #expect(reply == "")   // no chunks staged → empty but resolved
        }

        let before = await fake.promptRequestCount
        let ninthError = await captureError { _ = try await session.prompt("p9") }
        #expect(isRateLimited(ninthError))
        // Denied before `sendPrompt` — no new prompt RPC went out.
        let after = await fake.promptRequestCount
        #expect(after == before)
    }

    /// The busy guard is checked BEFORE the rate limiter, so a busy
    /// rejection must not consume a rate-limit slot. With one prompt parked
    /// in flight, far more than the 8/window budget of further attempts all
    /// come back `.busy` and none `.rateLimited`.
    @Test func busyRejectionDoesNotConsumeRateLimitSlot() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)

        let inFlight = Task { try await session.prompt("hold") }
        try await waitFor { await fake.promptRequestCount >= 1 }

        for i in 1...20 {
            let err = await captureError { _ = try await session.prompt("spam\(i)") }
            #expect(isBusy(err), "attempt \(i) should be .busy, got \(String(describing: err))")
            #expect(!isRateLimited(err), "attempt \(i) burned a rate-limit slot")
        }

        await fake.replyToPrompt()
        _ = try await withTimeout { try await inFlight.value }
    }

    /// A mini-app session has no UI to answer ACP permission prompts, so an
    /// agent `session/request_permission` mid-turn must be auto-cancelled —
    /// otherwise the agent loop blocks and the prompt hangs. The turn then
    /// completes normally.
    @Test func permissionRequestIsAutoCancelledAndPromptCompletes() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)

        let prompt = Task { try await session.prompt("do something") }
        try await waitFor { await fake.promptRequestCount >= 1 }

        await fake.emitPermissionRequest(sessionId: FakeACPChannel.defaultSessionId, requestId: 9001)
        // The session writes a cancelled-outcome response back to the agent.
        try await waitFor { await fake.sentContains("cancelled") }

        await fake.replyToPrompt()
        let reply = try await withTimeout { try await prompt.value }
        #expect(reply == "")
    }

    /// `shutdown()` resolves an in-flight prompt with `.cancelled` (so the
    /// JS promise rejects instead of hanging) and stops the ACP client
    /// (closing the channel).
    @Test func shutdownResumesPendingPromptAsCancelledAndStopsClient() async throws {
        let fake = FakeACPChannel()
        let session = makeSession(fake)

        let prompt = Task { try await session.prompt("hi") }
        try await waitFor { await fake.promptRequestCount >= 1 }

        await session.shutdown()

        let err = await captureError {
            _ = try await self.withTimeout { try await prompt.value }
        }
        #expect(isCancelled(err))
        try await waitFor { await fake.isClosed }
    }

    // MARK: - Helpers

    private func makeSession(_ fake: FakeACPChannel) -> MiniAppAgentSession {
        MiniAppAgentSession(context: .local, projectRoot: "/tmp/miniapp-agent-tests") { ctx in
            ACPClient(context: ctx) { _ in fake }
        }
    }

    /// Drive one prompt all the way to completion against an established
    /// session. The first call also triggers the auto-handshake; later
    /// calls reuse the cached session.
    @discardableResult
    private func completeOnePrompt(
        _ session: MiniAppAgentSession,
        _ fake: FakeACPChannel,
        text: String
    ) async throws -> String {
        let before = await fake.promptRequestCount
        let prompt = Task { try await session.prompt(text) }
        try await waitFor { await fake.promptRequestCount > before }
        await fake.replyToPrompt()
        return try await withTimeout { try await prompt.value }
    }

    private func captureError(_ op: () async throws -> Void) async -> Error? {
        do { try await op(); return nil } catch { return error }
    }

    private func isBusy(_ error: Error?) -> Bool {
        guard let e = error as? MiniAppAgentSession.AgentError else { return false }
        if case .busy = e { return true }
        return false
    }

    private func isRateLimited(_ error: Error?) -> Bool {
        guard let e = error as? MiniAppAgentSession.AgentError else { return false }
        if case .rateLimited = e { return true }
        return false
    }

    private func isCancelled(_ error: Error?) -> Bool {
        guard let e = error as? MiniAppAgentSession.AgentError else { return false }
        if case .cancelled = e { return true }
        return false
    }

    struct TimeoutError: Error {}

    /// One-shot, lock-guarded result slot. Lets `withTimeout` observe a
    /// task's outcome by polling rather than structurally awaiting it.
    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<T, Error>?
        func set(_ result: Result<T, Error>) {
            lock.lock(); if stored == nil { stored = result }; lock.unlock()
        }
        var value: Result<T, Error>? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    /// Hang-guard deadlines, scaled for a loaded machine.
    ///
    /// These bound how long a *stuck* test waits before reporting; nothing
    /// here asserts on latency. Under the full parallel suite this process is
    /// sharing cores with suites that spawn real subprocesses, and a 15 ms
    /// poll can be descheduled for far longer than its own period — which is
    /// what turned a 2 s deadline into an intermittent failure. The factor is
    /// derived from the machine rather than hard-coded so a small CI box
    /// (where oversubscription bites hardest) waits longest.
    enum Deadline {
        /// 1x on an 8-core-or-better machine, rising to 4x on a single core.
        static let loadFactor: Double = {
            let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
            return min(4, max(1, 8 / cores))
        }()

        /// A precondition that should be reached in tens of milliseconds.
        static var precondition: TimeInterval { 15 * loadFactor }
        /// An operation that should resolve as soon as the fake replies.
        static var operation: TimeInterval { 20 * loadFactor }
    }

    /// Poll `predicate` until true or `timeout` elapses; throws on timeout
    /// so a stalled precondition fails instead of hanging CI.
    private func waitFor(
        timeout: TimeInterval = Deadline.precondition,
        _ predicate: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        Issue.record("waitFor timed out after \(timeout)s")
        throw TimeoutError()
    }

    /// Run `op` and return its result, throwing `TimeoutError` if it doesn't
    /// finish within `seconds`. Crucially this POLLS a result box instead of
    /// structurally awaiting the work task: `prompt()` resolves a
    /// `withCheckedThrowingContinuation`, which is not cancellation-aware, so
    /// a genuinely leaked continuation can never be unblocked. Awaiting it
    /// (e.g. via a task group) would hang the timeout helper itself —
    /// exactly the failure mode these tests guard against. Polling lets the
    /// helper return cleanly and orphan the stuck task (harmless: a
    /// suspended task burns no CPU and dies with the test process).
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval = Deadline.operation,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ResultBox<T>()
        let work = Task {
            do { box.set(.success(try await op())) }
            catch { box.set(.failure(error)) }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let result = box.value {
                work.cancel()
                return try result.get()
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        work.cancel()
        throw TimeoutError()
    }
}
