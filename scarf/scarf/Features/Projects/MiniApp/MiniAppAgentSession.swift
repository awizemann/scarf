import Foundation
import ScarfCore
import os

/// Owns a dedicated, project-scoped ACP session for one running mini-app —
/// the backing for `scarf.prompt`.
///
/// **Isolation.** The mini-app gets its OWN `hermes acp` session, spawned
/// lazily on the first prompt and torn down on `shutdown()`. It never
/// shares a chat's session, so web content can't reach into other
/// conversations. The session is reachable only after the user grants the
/// (sensitive) `prompt` permission.
///
/// **Two different cwds — don't conflate them.** Hermes reads a project's
/// context files (AGENTS.md / CLAUDE.md / .cursorrules) from the `hermes
/// acp` PROCESS cwd, but resolves tool directories against the ACP SESSION
/// cwd:
/// - PROCESS cwd: the default `clientFactory` builds the client via
///   `ACPClient.forMacApp(context:)` with NO `projectCwd`, so `hermes acp`
///   inherits its spawner's default cwd (Scarf's own cwd locally; the
///   remote login dir over SSH) — NOT `projectRoot`. The project's
///   AGENTS.md/CLAUDE.md/.cursorrules are therefore **not** loaded into
///   this agent. This is deliberate (see below), unlike chat sessions
///   which DO spawn with `projectCwd` (t-565f8d45 / t-24594c4a).
/// - SESSION cwd: `newSession(cwd: projectRoot)` — so the agent's TOOL
///   directories resolve under the project root.
///
/// **Why no project context here (trust).** A mini-app runs untrusted /
/// agent-generated web content that drives this agent via `scarf.prompt`,
/// unsupervised (permission requests auto-denied, no human watching each
/// turn). Auto-injecting a project's context files into that agent is a
/// bigger prompt-injection surface than an interactive chat the user
/// explicitly opened, for no benefit any mini-app needs today — so we keep
/// the process cwd off the project. Decided in t-0b850b5b; grounded in
/// t-42db11e9 (chats = user-chosen, trusted enough for context-file
/// injection; mini-apps = the gated, less-trusted surface).
///
/// **Request/response.** `prompt(_:)` sends the text and resolves with the
/// agent's full reply, accumulated from the streamed `messageChunk` events
/// and finalized on `promptComplete` (the same completion signal the chat
/// UI relies on). One prompt in flight at a time; a launch/timeout failure
/// from `sendPrompt` fails the pending call.
///
/// **Runaway protection.** A host-side sliding-window rate limit caps how
/// often web content can drive the agent.
actor MiniAppAgentSession {
    private static let logger = Logger(subsystem: "com.scarf", category: "MiniAppAgentSession")

    private let context: ServerContext
    private let projectRoot: String
    /// Builds the per-mini-app `ACPClient`. Injected so tests can supply a
    /// client wired to an in-memory channel; production defaults to the
    /// `ProcessACPChannel`-backed `forMacApp` factory.
    ///
    /// NOTE: the default deliberately omits `projectCwd:` — do NOT add it
    /// reflexively to "match chats." That would move the `hermes acp`
    /// process cwd onto the project and load its AGENTS.md/.cursorrules into
    /// this untrusted, web-driven agent (see the type doc + t-0b850b5b /
    /// t-42db11e9). Tool dirs already resolve to the project via the
    /// session cwd (`newSession(cwd: projectRoot)`).
    private let clientFactory: @Sendable (ServerContext) -> ACPClient
    private let rateLimiter = MiniAppRateLimiter(maxEvents: 8, windowSeconds: 60)
    private var promptHistory: [Date] = []

    private var client: ACPClient?
    private var sessionId: String?
    private var eventLoop: Task<Void, Never>?

    // At most one prompt in flight; the event loop resolves it.
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingBuffer = ""
    // Claimed synchronously before the ensureSession() suspension so two
    // racing cold-start prompts can't both pass the busy guard (actors don't
    // hold isolation across `await`). Cleared whenever the prompt resolves.
    private var promptInFlight = false

    /// End-of-turn handshake state (see `completeTurn` / `drainEventLoop`).
    /// `eventsProcessed` counts every event this session's loop has taken off
    /// `client.events`, in the same units as `ACPClient.eventsEmitted`;
    /// `drainTarget` is the count a suspended `drainEventLoop` is waiting to
    /// reach.
    private var eventsProcessed = 0
    private var drainTarget: Int?
    private var drainContinuation: CheckedContinuation<Void, Never>?

    /// Live event forwarder for `scarf.onEvent`. Set by the bridge when the
    /// mini-app subscribes; receives this session's streamed events.
    private var eventSink: (@Sendable (ACPEvent) -> Void)?

    init(
        context: ServerContext,
        projectRoot: String,
        clientFactory: @escaping @Sendable (ServerContext) -> ACPClient = { ACPClient.forMacApp(context: $0) }
    ) {
        self.context = context
        self.projectRoot = projectRoot
        self.clientFactory = clientFactory
    }

    enum AgentError: LocalizedError {
        case rateLimited
        case busy
        case cancelled
        case connectionLost(String)

        var errorDescription: String? {
            switch self {
            case .rateLimited: return "Mini-app exceeded its prompt rate limit; try again shortly."
            case .busy: return "A prompt is already running for this mini-app."
            case .cancelled: return "The mini-app session was closed."
            case .connectionLost(let r): return "Agent connection lost: \(r)"
            }
        }
    }

    /// Register the live event forwarder for `scarf.onEvent`. Replaces any
    /// prior sink (one subscriber per mini-app instance).
    func setEventSink(_ sink: @escaping @Sendable (ACPEvent) -> Void) {
        eventSink = sink
    }

    /// Send `text` to the mini-app's agent and resolve with the full reply.
    func prompt(_ text: String) async throws -> String {
        // Busy check FIRST (so a rejected prompt doesn't burn a rate-limit
        // slot) and claim the slot BEFORE the ensureSession() suspension —
        // otherwise two cold-start prompts both pass the guard and one
        // continuation leaks (the caller hangs forever).
        guard !promptInFlight else { throw AgentError.busy }
        let (allowed, history) = rateLimiter.decide(now: Date(), history: promptHistory)
        promptHistory = history
        guard allowed else { throw AgentError.rateLimited }
        promptInFlight = true

        let client: ACPClient
        let sid: String
        do {
            (client, sid) = try await ensureSession()
        } catch {
            promptInFlight = false  // no continuation registered yet
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            pendingBuffer = ""
            // Kick off the prompt. `sendPrompt` returns when the turn ends,
            // and ITS return is the completion signal: ACPClient's event
            // stream never carries `.promptComplete` (only `ChatViewModel`
            // synthesizes one for the chat path), so we synthesize one here
            // and route it through `handle()` — that forwards the `onEvent`
            // "complete" AND resolves this continuation with the accumulated
            // reply buffer. By the time the turn-end response arrives, the
            // streamed messageChunk notifications that precede it on the wire
            // have already landed in the buffer. A launch / timeout /
            // transport failure surfaces via the catch.
            Task {
                do {
                    let result = try await client.sendPrompt(sessionId: sid, text: text)
                    await self.completeTurn(sessionId: sid, result: result)
                } catch {
                    self.failPending(error)
                }
            }
        }
    }

    /// Tear down the ACP session + process. Idempotent.
    func shutdown() async {
        eventLoop?.cancel()
        eventLoop = nil
        // Cancelling the loop means nothing will ever satisfy a pending
        // end-of-turn handshake — release it before failing the prompt, or
        // `completeTurn` stays suspended for the process's lifetime.
        releaseDrainIfSatisfied(force: true)
        resumePending(.failure(AgentError.cancelled))
        if let client {
            await client.stop()
        }
        client = nil
        sessionId = nil
    }

    // MARK: - Private

    private func ensureSession() async throws -> (ACPClient, String) {
        if let client, let sessionId { return (client, sessionId) }
        let newClient = clientFactory(context)
        try await newClient.start()
        let sid = try await newClient.newSession(cwd: projectRoot)
        client = newClient
        sessionId = sid
        startEventLoop(client: newClient, sessionId: sid)
        Self.logger.info("mini-app agent session started for \(self.projectRoot, privacy: .public)")
        return (newClient, sid)
    }

    private func startEventLoop(client: ACPClient, sessionId: String) {
        eventLoop = Task { [weak self] in
            let stream = await client.events
            for await event in stream {
                guard let self else { break }
                // Only this session's events (or connection-level ones) are
                // handled, but EVERY consumed event is counted — the count is
                // the handshake's unit and must stay in step with the
                // client's `eventsEmitted`, which counts unfiltered.
                await self.consume(event, sessionId: sessionId)
            }
            // The stream finishes on connection loss / clean shutdown.
            // ACPClient never yields `.connectionLost`, so this is the only
            // signal for a prompt still awaiting `.promptComplete` — without
            // it the JS promise hangs forever and the session stays wedged at
            // busy. `resumePending` is a no-op when nothing is pending.
            await self?.streamEnded()
        }
    }

    /// One event off the stream: count it (handshake bookkeeping), handle it
    /// when it belongs to this session, then release a satisfied drain.
    private func consume(_ event: ACPEvent, sessionId: String) {
        eventsProcessed += 1
        if event.sessionId == sessionId || event.sessionId == nil {
            handle(event)
        }
        releaseDrainIfSatisfied()
    }

    private func streamEnded() {
        // No further event can arrive, so a pending drain must not wait for
        // a target it will never reach.
        releaseDrainIfSatisfied(force: true)
        resumePending(.failure(AgentError.connectionLost("agent session ended")))
    }

    /// Synthesize turn completion AFTER the event loop has folded every
    /// buffered `messageChunk` into the reply.
    ///
    /// `sendPrompt`'s return is the completion signal, but the chunks are
    /// accumulated by a SEPARATE event-loop task, so resolving immediately
    /// could race ahead of an undrained chunk and truncate the reply.
    ///
    /// **This used to be a count-stability poll** (`Task.yield()` until
    /// `pendingBuffer.count` stopped changing). That is not a
    /// synchronization primitive: it infers "drained" from "nothing arrived
    /// during my last yield", so it truncates the reply whenever the event
    /// loop needs one scheduling hop more than that (a loaded executor, a
    /// slower machine, a chunk still in the channel's read buffer), it spins
    /// the CPU while a chunk is genuinely in flight, and it cannot tell a
    /// drained stream from an empty chunk.
    ///
    /// Replaced with an explicit handshake on a COUNT, not on timing:
    /// `ACPClient.eventsEmitted` is how many events the client has yielded,
    /// and `eventsProcessed` is how many this session's loop has consumed.
    /// The client handles one incoming line at a time, so the emitted count
    /// read immediately after the `session/prompt` response provably
    /// includes every `messageChunk` of this turn. Waiting until
    /// `eventsProcessed >= target` is therefore an exact "the loop has seen
    /// everything from my turn" condition with a definite termination — no
    /// polling and no timing assumption. `streamEnded()` and `shutdown()`
    /// release a waiter so a dead stream can't strand it.
    private func completeTurn(sessionId: String, result: ACPPromptResult) async {
        await drainEventLoop()
        handle(.promptComplete(sessionId: sessionId, response: result))
    }

    /// Suspend until the event loop has consumed every event the client had
    /// emitted as of now. Returns immediately when the loop is already
    /// caught up or isn't running.
    private func drainEventLoop() async {
        guard let client, let eventLoop, !eventLoop.isCancelled else { return }
        let target = await client.eventsEmitted
        guard eventsProcessed < target else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainTarget = target
            drainContinuation = continuation
        }
    }

    /// Release a waiting `drainEventLoop` once its target is reached (or
    /// unconditionally, when `force` — the stream ended and no further event
    /// will ever arrive).
    private func releaseDrainIfSatisfied(force: Bool = false) {
        guard let continuation = drainContinuation,
              force || eventsProcessed >= (drainTarget ?? 0) else { return }
        drainContinuation = nil
        drainTarget = nil
        continuation.resume()
    }

    private func handle(_ event: ACPEvent) {
        switch event {
        case .messageChunk(_, let text, _, _):
            if pendingContinuation != nil { pendingBuffer += text }
            eventSink?(event)
        case .thoughtChunk, .toolCallStart, .toolCallUpdate:
            eventSink?(event)
        case .promptComplete:
            eventSink?(event)
            resumePending(.success(pendingBuffer))
        case .permissionRequest(_, let requestId, _):
            // A mini-app session has no human UI to answer ACP permission
            // prompts, so auto-deny — otherwise the agent loop hangs waiting
            // on a permission it can't be granted here. (v1 limitation: a
            // mini-app's agent can't perform permissioned tool actions.)
            if let client {
                Task { await client.cancelPermission(requestId: requestId) }
            }
        case .connectionLost(let reason):
            resumePending(.failure(AgentError.connectionLost(reason)))
        default:
            break
        }
    }

    private func failPending(_ error: Error) {
        resumePending(.failure(error))
    }

    /// Resolve the in-flight prompt exactly once (first signal wins) and
    /// release the busy slot. Honors the passed result.
    ///
    /// The busy slot is cleared UNCONDITIONALLY, outside the
    /// continuation guard. It used to be cleared only when a continuation
    /// was actually resumed, which left `promptInFlight` stuck true — and
    /// the mini-app permanently answering `busy` — on every path that
    /// releases the slot without a registered continuation: `shutdown()`
    /// (or `streamEnded()`) landing in the window between `promptInFlight =
    /// true` and the `withCheckedThrowingContinuation` body running, and a
    /// second terminal signal arriving after the first already consumed the
    /// continuation. Clearing a slot that is already free is harmless;
    /// leaving one held forever wedges the session for its whole lifetime.
    private func resumePending(_ result: Result<String, Error>) {
        promptInFlight = false
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        pendingBuffer = ""
        continuation.resume(with: result)
    }
}
