import Foundation
#if canImport(os)
import os
#endif

/// Per-session edit auto-approval mode advertised by ACP's `session/new`
/// response (`modes` field) and switchable mid-session via the
/// `session/set_mode` JSON-RPC method (Hermes v0.15+).
///
/// Distinct from the global `approvals.mode` config surface (the YOLO
/// chip): this is a per-ACP-session toggle that loosens (or tightens)
/// how often Hermes prompts for file-edit approval. Sensitive paths
/// (`.env*`, `id_rsa`, `.git`, `.ssh`, …) always still prompt regardless
/// of the chosen mode — that's a server-side guardrail Scarf doesn't
/// override.
///
/// Raw values are the wire mode IDs verified against the v2026.5.28
/// Hermes source.
public enum ACPApprovalMode: String, CaseIterable, Sendable {
    /// Default posture — Hermes asks before every edit.
    case `default`
    /// Auto-allow edits inside the workspace + `/tmp`; still asks for
    /// sensitive paths.
    case acceptEdits = "accept_edits"
    /// Auto-allow file edits for the whole session except sensitive
    /// paths.
    case dontAsk = "dont_ask"

    /// Short label for chips / menus — mirrors the ACP `modes` entry
    /// label.
    public var displayName: String {
        switch self {
        case .default: return "Default"
        case .acceptEdits: return "Accept Edits"
        case .dontAsk: return "Don't Ask"
        }
    }

    /// One-line description for tooltips / menu subtitles — mirrors the
    /// ACP `modes` entry description.
    public var summary: String {
        switch self {
        case .default:
            return "Ask before edits"
        case .acceptEdits:
            return "Auto-allow workspace + /tmp edits; still asks for sensitive paths"
        case .dontAsk:
            return "Auto-allow file edits for this session except sensitive paths"
        }
    }
}

/// Manages an ACP (Agent Client Protocol) session with a backing Hermes
/// agent. Talks JSON-RPC over an `ACPChannel` — the channel itself owns
/// the transport (subprocess for macOS, SSH exec session for iOS via
/// Citadel in M4+). This actor is transport-agnostic.
///
/// **Channel factory injection.** Construction takes a closure that
/// builds a channel on demand. The Mac target wires this at app launch
/// to produce a `ProcessACPChannel` configured with the enriched
/// shell env (PATH, credentials). iOS will wire a `SSHExecACPChannel`
/// factory at app launch.
///
/// Under iOS the `ProcessACPChannel` implementation is skipped at
/// compile time (`#if !os(iOS)`) — an iOS `ACPClient` that tried to
/// spawn a subprocess would be a build error, not a runtime bug.
public actor ACPClient {
    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "ACPClient")
    #endif

    /// Returns a fresh ACPChannel connected to `hermes acp` for this
    /// context. Mac wires this to spawn a `ProcessACPChannel` with the
    /// enriched env (so `hermes` can find Homebrew/nvm/asdf binaries
    /// on PATH). iOS wires a Citadel-backed channel in M4+.
    public typealias ChannelFactory = @Sendable (ServerContext) async throws -> any ACPChannel

    private var channel: (any ACPChannel)?
    private let channelFactory: ChannelFactory

    private var nextRequestId = 1
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ACPEvent>.Continuation?
    private var _eventStream: AsyncStream<ACPEvent>?

    public private(set) var isConnected = false
    public private(set) var currentSessionId: String?
    public private(set) var statusMessage = ""

    public let context: ServerContext

    public init(
        context: ServerContext = .local,
        channelFactory: @escaping ChannelFactory
    ) {
        self.context = context
        self.channelFactory = channelFactory
    }

    /// Ring buffer of recent stderr lines from the ACP channel — used to
    /// attach a diagnostic tail to user-visible errors. Capped to avoid
    /// unbounded growth when the subprocess logs heavily.
    private var stderrBuffer: [String] = []
    private static let stderrBufferMaxLines = 50

    /// Returns the last ~`stderrBufferMaxLines` stderr lines captured
    /// from the ACP channel, joined by newlines.
    public var recentStderr: String {
        stderrBuffer.joined(separator: "\n")
    }

    /// Wall-clock timestamp of the last byte read from the ACP channel
    /// (stdout JSON-RPC OR stderr). Used by callers (iOS health monitor)
    /// to detect a silently-stalled channel — Citadel's `withExec`
    /// stream doesn't EOF when the underlying TCP socket stops
    /// transferring (e.g., a Tailscale link with no keepalive on the
    /// device side), so we expose a read-side liveness signal here for
    /// the monitor to gate against. Updated on every incoming line.
    /// Nil until `start()` initializes the channel.
    private var lastIncomingAt: Date?

    /// Seconds since the last byte arrived from the channel. Returns
    /// `.infinity` when no activity has been observed yet. Read-side
    /// liveness signal for stall detection — see `lastIncomingAt`.
    public var secondsSinceLastIncoming: TimeInterval {
        guard let last = lastIncomingAt else { return .infinity }
        return Date().timeIntervalSince(last)
    }

    fileprivate func appendStderr(_ text: String) {
        lastIncomingAt = Date()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            stderrBuffer.append(String(line))
        }
        if stderrBuffer.count > Self.stderrBufferMaxLines {
            stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrBufferMaxLines)
        }
    }

    fileprivate func touchLastIncoming() {
        lastIncomingAt = Date()
    }

    /// True while the underlying channel is alive. Equivalent to the
    /// old `process.isRunning` check. Read-side stall detection is
    /// orthogonal (see `secondsSinceLastIncoming`) so callers that care
    /// can layer their own threshold on top.
    public var isHealthy: Bool {
        isConnected && channel != nil
    }

    // MARK: - Event Stream

    /// Access the event stream. Must call `start()` first. Before start,
    /// returns an immediately-finished stream so callers can iterate
    /// without a nil check.
    public var events: AsyncStream<ACPEvent> {
        _eventStream ?? AsyncStream { $0.finish() }
    }

    // MARK: - Lifecycle

    /// Coarse lifecycle of the client, exposed so callers (and tests)
    /// can reason about a half-open start.
    ///
    /// `idle` → `starting` → `running` → `stopped`. A failed start
    /// returns to `idle` (the client is reusable — nothing was left
    /// half-connected). `stop()` always lands on `stopped`, and a
    /// subsequent `start()` is allowed: the reconnect paths build a
    /// FRESH client per attempt today, but nothing about this state
    /// machine forbids restarting an instance.
    public enum State: String, Sendable, Equatable {
        case idle, starting, running, stopped
    }

    public private(set) var state: State = .idle

    /// The in-flight `start()`, if any. This is the fix for the
    /// half-open double-connect: `start()`'s old `guard channel == nil`
    /// was evaluated BEFORE the `await channelFactory(context)`
    /// suspension, and the actor is reentrant — so a second `start()`
    /// arriving while the factory was spawning still saw `channel ==
    /// nil`, spawned a SECOND `hermes acp` subprocess, and clobbered
    /// `self.channel` / `self._eventStream`, orphaning the first
    /// process and leaving the first event stream permanently
    /// unfinished.
    /// Holding the task lets a concurrent caller JOIN the in-flight
    /// start instead of racing it.
    private var startTask: Task<Void, Error>?

    /// Bumped by `stop()`. A `performStart` whose captured generation
    /// no longer matches was superseded mid-flight and closes the
    /// channel it just spawned rather than publishing it.
    private var startGeneration = 0

    /// Idempotent. Concurrent or repeated calls never spawn a second
    /// channel:
    /// - a start already in flight is joined (same success/failure);
    /// - an already-running client returns immediately;
    /// - a failed start resets to `idle` so a retry is still possible.
    public func start() async throws {
        if let inFlight = startTask {
            try await inFlight.value
            return
        }
        guard channel == nil else {
            // Already connected — nothing to do. Keep `state` honest in
            // case a caller reached `running` through an older path.
            state = .running
            return
        }
        state = .starting
        let generation = startGeneration
        let task = Task<Void, Error> { try await self.performStart() }
        startTask = task
        do {
            try await task.value
            // Only clear OUR task: a `stop()` + `start()` pair that
            // landed while we awaited owns `startTask` now (the
            // generation bump in `stop()` is the tell).
            if startGeneration == generation { startTask = nil }
            // A `stop()` that landed while we were starting owns the
            // final state — don't stomp `.stopped` back to `.running`.
            if state == .starting { state = .running }
        } catch {
            if startGeneration == generation { startTask = nil }
            if state == .starting { state = .idle }
            throw error
        }
    }

    private func performStart() async throws {
        guard channel == nil else { return }
        let generation = startGeneration

        // Create the event stream BEFORE anything else so no events are
        // lost while the channel is handshaking.
        let (stream, continuation) = AsyncStream.makeStream(of: ACPEvent.self)
        self._eventStream = stream
        self.eventContinuation = continuation

        statusMessage = "Starting hermes acp..."

        let ch: any ACPChannel
        do {
            ch = try await channelFactory(context)
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
            #if canImport(os)
            logger.error("Failed to open ACP channel: \(error.localizedDescription)")
            #endif
            continuation.finish()
            throw error
        }

        // A `stop()` (or another supersede) landed while the factory was
        // spawning. Publishing `ch` now would resurrect a client the
        // caller already tore down and leak the process, so close what
        // we just opened and bail.
        guard generation == startGeneration else {
            await ch.close()
            continuation.finish()
            throw CancellationError()
        }

        self.channel = ch
        self.isConnected = true
        // Prime the read-side liveness clock so a freshly-opened channel
        // doesn't read as instantly stalled before the first event.
        self.lastIncomingAt = Date()

        // Start reading incoming JSON-RPC BEFORE sending initialize so
        // we catch the response.
        startReadLoops(channel: ch)
        #if canImport(os)
        if let id = await ch.diagnosticID {
            logger.info("ACP channel opened (\(id, privacy: .public))")
        } else {
            logger.info("ACP channel opened")
        }
        #endif
        statusMessage = "Initializing..."

        // Initialize the ACP connection.
        let initParams: [String: AnyCodable] = [
            "protocolVersion": AnyCodable(1),
            "clientCapabilities": AnyCodable([String: Any]()),
            "clientInfo": AnyCodable([
                "name": "Scarf",
                "version": "1.0",
            ] as [String: Any]),
        ]
        _ = try await sendRequest(method: "initialize", params: initParams)
        statusMessage = "Connected"
        #if canImport(os)
        logger.info("ACP connection initialized")
        #endif
        startKeepalive()
    }

    public func stop() async {
        // Supersede a half-open start. We deliberately do NOT await it:
        // `initialize` carries a 60s watchdog and `stop()` is on the
        // user's cancel path, so blocking here could freeze teardown
        // for a minute. Bumping the generation makes the in-flight
        // `performStart` close the channel IT spawned as soon as the
        // factory returns, so nothing is orphaned.
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        readTask?.cancel()
        readTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _eventStream = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: CancellationError())
        }
        pendingRequests.removeAll()

        if let ch = channel {
            await ch.close()
        }
        channel = nil
        isConnected = false
        currentSessionId = nil
        state = .stopped
        statusMessage = "Disconnected"
        #if canImport(os)
        logger.info("ACP client stopped")
        #endif
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                guard !Task.isCancelled else { break }
                await self?.sendKeepalive()
            }
        }
    }

    /// Valid JSON-RPC notification used as a keepalive probe. Plain
    /// newlines upstream produce `json.loads("")` errors in the ACP
    /// server so we send a real method.
    private static let keepalivePayload: String = #"{"jsonrpc":"2.0","method":"$/ping"}"#

    private func sendKeepalive() async {
        guard let ch = channel else { return }
        do {
            try await ch.send(Self.keepalivePayload)
        } catch {
            await handleWriteFailed()
        }
    }

    // MARK: - Session Management

    public func newSession(cwd: String) async throws -> String {
        statusMessage = "Creating session..."
        let params: [String: AnyCodable] = [
            "cwd": AnyCodable(cwd),
            "mcpServers": AnyCodable([Any]()),
        ]
        let result = try await sendRequest(method: "session/new", params: params)
        guard let dict = result?.dictValue,
              let sessionId = dict["sessionId"] as? String
        else {
            throw ACPClientError.invalidResponse("Missing sessionId in session/new response")
        }
        currentSessionId = sessionId
        statusMessage = "Session ready"
        #if canImport(os)
        logger.info("Created new ACP session: \(sessionId)")
        #endif
        return sessionId
    }

    public func loadSession(cwd: String, sessionId: String) async throws -> String {
        statusMessage = "Loading session \(sessionId.prefix(12))..."
        let params: [String: AnyCodable] = [
            "cwd": AnyCodable(cwd),
            "sessionId": AnyCodable(sessionId),
            "mcpServers": AnyCodable([Any]()),
        ]
        let result = try await sendRequest(method: "session/load", params: params)
        // #99 / t-891c321a — Hermes's `load_session` returns a
        // `LoadSessionResponse` dict on success, but `None` — NOT a
        // JSON-RPC error — when the session can't be restored into the
        // ACP runtime (`update_cwd` returned None, e.g. a session that
        // isn't ACP-persisted). How that `None` reaches the wire depends
        // on the framework: some paths surface `result: null`, but the
        // acp lib Hermes ships (0.17 AND 0.18.2) routes `session/load`
        // through `normalize_result` (acp/utils.py:59-65), which turns
        // `None` into an EMPTY DICT — the wire frame is `"result": {}`
        // (live-probed against hermes-agent 0.17.0, 2026-07-13). The old
        // nil-only guard passed `{}` through and fell through to
        // `?? sessionId`, silently returning the requested id as if
        // loaded — the chat then ran against a phantom session and every
        // prompt came back `stopReason=refusal`.
        //
        // A real success is provably a NON-empty dict on every Hermes
        // that emits `{}` for failure: `load_session` builds
        // `LoadSessionResponse(models=…, modes=…, field_meta=…)` and
        // `_session_modes` unconditionally constructs a mode state
        // (v2026.5.28 / Hermes 0.15 onward, verified in 0.17 working
        // tree and the v2026.7.7.2 / 0.18.2 tag), so `modes` survives
        // the `exclude_none`/`exclude_defaults` dump. (Pre-0.15 hosts
        // could in theory return a success `{}` when the session had no
        // model name; for them the fallback — fresh session + DB
        // transcript replay — is still strictly better than attaching
        // to a session with no restorable model state.) Treat null AND
        // empty-dict results as not-restorable so the caller's fallback
        // runs cleanly.
        guard let dict = result?.dictValue, !dict.isEmpty else {
            #if canImport(os)
            logger.warning("session/load returned null/empty for \(sessionId) — not restorable; caller should fall back to a new session")
            #endif
            throw ACPClientError.invalidResponse("session/load returned null/empty — session \(sessionId) is not restorable")
        }
        let loadedId = (dict["sessionId"] as? String) ?? sessionId
        currentSessionId = loadedId
        statusMessage = "Session loaded"
        #if canImport(os)
        logger.info("Loaded ACP session: \(loadedId)")
        #endif
        return loadedId
    }

    // NOTE: There is deliberately NO `session/resume` wrapper here
    // (t-217da62b). Hermes's `resume_session` shares the exact same
    // restore path as `load_session` (`SessionManager.update_cwd` →
    // `get_session`, memory-then-DB — verified in the 0.17 working
    // tree and the v2026.7.7.2 / 0.18.2 tag of acp_adapter/server.py),
    // so resume adds no capability over load. Its ONLY behavioral
    // difference is harmful: on an unknown id it silently CREATES a
    // fresh server-side session (orphan) and returns a response whose
    // top level is indistinguishable from success — the real id hides
    // in best-effort `_meta.hermes.sessionProvenance`, which can be
    // absent. `session/load` instead fails detectably (`{}` result,
    // caught above), which is the semantics a reconnect ladder needs.
    // The old `resumeSession` was also dead code in practice: it
    // required a top-level `sessionId` the ACP schema's
    // `ResumeSessionResponse` never carries, so it always threw and
    // fell through to `loadSession` — orphaning one server session per
    // attempt along the way. Don't re-add it.

    // MARK: - Messaging

    public func sendPrompt(sessionId: String, text: String) async throws -> ACPPromptResult {
        try await sendPrompt(sessionId: sessionId, text: text, images: [])
    }

    /// v0.12+ overload: forward zero or more image attachments alongside
    /// the user's text. Each attachment becomes a separate
    /// `ImageContentBlock` in the ACP `prompt` content array — matches
    /// the shape Hermes' `acp_adapter/server.py` expects (text first,
    /// then image blocks). Hermes routes the resulting payload to a
    /// vision-capable model automatically; the producer side only has
    /// to deliver the bytes.
    ///
    /// Pre-v0.12 Hermes installs accepted only a single `text` block.
    /// Callers gate this overload on
    /// `HermesCapabilitiesStore.capabilities.hasACPImagePrompts` so we
    /// don't send blocks an older agent would silently drop.
    public func sendPrompt(
        sessionId: String,
        text: String,
        images: [ChatImageAttachment]
    ) async throws -> ACPPromptResult {
        statusMessage = "Sending prompt..."
        let messageId = UUID().uuidString

        // Always include the text block, even when empty — keeps the
        // server-side text-extraction path stable regardless of whether
        // the user sent text alongside the image(s).
        var promptBlocks: [[String: Any]] = [
            ["type": "text", "text": text] as [String: Any],
        ]
        for image in images {
            promptBlocks.append([
                "type": "image",
                "data": image.base64Data,
                "mimeType": image.mimeType,
            ] as [String: Any])
        }

        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "messageId": AnyCodable(messageId),
            "prompt": AnyCodable(promptBlocks as [Any]),
        ]
        let result = try await sendRequest(method: "session/prompt", params: params)
        let dict = result?.dictValue ?? [:]
        let usage = dict["usage"] as? [String: Any] ?? [:]
        // TODO(WS-8-Q1): Confirm wire field name once v0.13 Hermes is
        // available. We tolerate camelCase + snake_case to match the rest
        // of the ACP payload's mixed conventions; if Hermes routes the
        // count through a `session/update` notification instead, this
        // decode is a no-op and the ACPEvent path takes over.
        let compression = (usage["compressionCount"] as? Int)
            ?? (usage["compression_count"] as? Int)
            ?? 0

        statusMessage = "Ready"
        return ACPPromptResult(
            stopReason: dict["stopReason"] as? String ?? "end_turn",
            inputTokens: usage["inputTokens"] as? Int ?? 0,
            outputTokens: usage["outputTokens"] as? Int ?? 0,
            thoughtTokens: usage["thoughtTokens"] as? Int ?? 0,
            cachedReadTokens: usage["cachedReadTokens"] as? Int ?? 0,
            compressionCount: compression
        )
    }

    public func cancel(sessionId: String) async throws {
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
        ]
        _ = try await sendRequest(method: "session/cancel", params: params)
        statusMessage = "Cancelled"
    }

    /// Switch the per-session edit auto-approval mode on a live ACP
    /// session via the `session/set_mode` JSON-RPC method (Hermes v0.15+).
    /// `modeId` is one of the wire IDs ACP advertised in the `session/new`
    /// response's `modes` field — `default` / `accept_edits` / `dont_ask`
    /// (see `ACPApprovalMode`).
    ///
    /// Sensitive paths (`.env*`, `id_rsa`, `.git`, `.ssh`, …) always still
    /// prompt server-side regardless of the chosen mode — Scarf doesn't
    /// override that guardrail.
    ///
    /// The caller is responsible for capability-gating on
    /// `HermesCapabilities.hasSessionEditAutoApproval` — calling this
    /// against a pre-v0.15 host throws because the method doesn't exist.
    public func setSessionMode(
        sessionId: String,
        modeId: String
    ) async throws {
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "modeId": AnyCodable(modeId),
        ]
        _ = try await sendRequest(method: "session/set_mode", params: params)
    }

    /// Switch the model on a live ACP session via the `session/set_model`
    /// JSON-RPC method. The `modelID` wire value follows Hermes's ACP
    /// model-choice encoding: `"<provider>:<model>"` when the caller
    /// knows the provider, or the bare model name when it doesn't.
    /// Hermes's `_resolve_model_selection` (acp_adapter/server.py:583)
    /// parses the colon prefix explicitly; when absent, it falls back
    /// to `detect_provider_for_model` which infers from the model name
    /// only — and infers wrong for less-obvious IDs (e.g.
    /// `inclusionai/ring-2.6-1t` won't reliably route to openrouter
    /// without the prefix, per [#97](https://github.com/awizemann/scarf/issues/97)).
    ///
    /// **Pass the provider when you have it.** Every `ModelPreset`
    /// carries `providerID` alongside `modelID`; both call sites in
    /// `ChatViewModel` thread it through. Passing `providerID: nil`
    /// keeps the old bare-model wire shape for callers that genuinely
    /// don't know the provider.
    ///
    /// Used both at session boot (immediately after `newSession` to apply
    /// a project's bound preset before the user's first prompt) and at
    /// user-tap time from the chat header to swap mid-conversation. The
    /// caller is responsible for capability-gating on
    /// `HermesCapabilities.hasACPSetSessionModel` — calling this against
    /// a pre-v0.13 host throws because the method doesn't exist.
    public func setSessionModel(
        sessionId: String,
        modelID: String,
        providerID: String? = nil
    ) async throws {
        let wireModelID = Self.encodeModelChoice(modelID: modelID, providerID: providerID)
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "modelId": AnyCodable(wireModelID),
        ]
        _ = try await sendRequest(method: "session/set_model", params: params)
    }

    /// Encode a model selection in Hermes's ACP wire format
    /// (`<provider>:<model>`). Exposed as `static` for unit testing
    /// and so call sites that need the encoded form without firing the
    /// RPC (e.g. logging) can build it themselves.
    ///
    /// Rules (matching `acp_adapter/server.py`'s `_encode_model_choice`):
    /// - Empty model → empty string (Hermes treats as "leave alone").
    /// - Model present, provider absent or empty → bare model name
    ///   (preserves backward compatibility with the bare-modelID call
    ///   sites that worked before [#97](https://github.com/awizemann/scarf/issues/97)
    ///   for models Hermes can auto-detect).
    /// - Both present → `"<provider>:<model>"` (lower-cased provider to
    ///   match Hermes's normalization).
    public static func encodeModelChoice(modelID: String, providerID: String?) -> String {
        let model = modelID.trimmingCharacters(in: .whitespaces)
        if model.isEmpty { return "" }
        guard let raw = providerID?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return model
        }
        return "\(raw.lowercased()):\(model)"
    }

    /// Respond to a `session/request_permission` from the agent.
    ///
    /// Wire format MUST match Zed's Agent Client Protocol
    /// `RequestPermissionOutcome`:
    ///
    ///     { "outcome": { "outcome": "selected", "optionId": "<id>" } }
    ///
    /// The inner discriminator field is literally named `outcome` —
    /// NOT `kind` and NOT `type`. Values are `"selected"` (a user
    /// pick — whether allow OR reject, since reject options are still
    /// SELECTED options the agent reads as "reject_once" / "reject_always"
    /// via their own optionId) or `"cancelled"` (the prompt was
    /// dismissed without a pick). See:
    /// https://agentclientprotocol.com/protocol/schema —
    /// `RequestPermissionOutcome`.
    ///
    /// We previously sent `{"kind":"allowed"|"rejected"}` here, which
    /// Hermes (correctly per spec) didn't recognize: with no valid
    /// discriminator the response fell through to the cancelled-style
    /// default and every Allow tap was reported as "blocked from
    /// executing". Reported via TestFlight feedback on ScarfGo
    /// 2.9.0(36), Jun 5 2026 — sudo prompts on a remote SSH host.
    public func respondToPermission(requestId: Int, optionId: String) async {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "result": [
                "outcome": [
                    "outcome": "selected",
                    "optionId": optionId,
                ] as [String: Any],
            ] as [String: Any],
        ]
        await writeJSON(response)
    }

    /// Respond to a `session/request_permission` by cancelling — i.e.,
    /// the user dismissed the prompt without picking any option. Per
    /// ACP spec, `optionId` is omitted in this case.
    public func cancelPermission(requestId: Int) async {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "result": [
                "outcome": [
                    "outcome": "cancelled",
                ] as [String: Any],
            ] as [String: Any],
        ]
        await writeJSON(response)
    }

    // MARK: - JSON-RPC Transport

    private func sendRequest(method: String, params: [String: AnyCodable]) async throws -> AnyCodable? {
        let requestId = nextRequestId
        nextRequestId += 1

        let request = ACPRequest(id: requestId, method: method, params: params)
        guard let data = try? JSONEncoder().encode(request),
              let line = String(data: data, encoding: .utf8)
        else {
            throw ACPClientError.encodingFailed
        }

        #if canImport(os)
        logger.debug("Sending: \(method) (id: \(requestId))")
        #endif

        // session/prompt streams events and can run for minutes — no hard
        // timeout. Control messages get a 60s watchdog. Older versions
        // capped at 30s, which the field reported (#61) was tripping
        // under realistic gateway+ACP concurrency: the gateway holds
        // state.db locks for Discord sync / skill registration / cron
        // scheduling, and ACP's `initialize` / `session/new` /
        // `session/load` stall waiting for the lock. SQLite contention
        // on a healthy host clears in seconds; 60s gives that headroom
        // while still surfacing genuinely broken transports promptly.
        let timeoutTask: Task<Void, Error>? = if method != "session/prompt" {
            Task { [weak self] in
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.timeoutRequest(id: requestId, method: method)
            }
        } else {
            nil
        }
        defer { timeoutTask?.cancel() }

        guard let ch = channel else {
            throw ACPClientError.notConnected
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnyCodable?, Error>) in
            pendingRequests[requestId] = continuation

            // Write in a detached task so the actor can process incoming
            // response messages while we're awaiting the send. The
            // continuation is already stored; the response arrives via
            // the read loop.
            Task.detached { [weak self] in
                do {
                    try await ch.send(line)
                } catch {
                    await self?.handleWriteFailedForRequest(id: requestId)
                }
            }
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        #if canImport(os)
        logger.error("Request timed out: \(method) (id: \(id))")
        #endif
        statusMessage = "Request timed out"
        continuation.resume(throwing: ACPClientError.requestTimeout(method: method))
    }

    private func writeJSON(_ dict: [String: Any]) async {
        guard let ch = channel,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8)
        else { return }
        do {
            try await ch.send(line)
        } catch {
            await handleWriteFailed()
        }
    }

    // MARK: - Read Loops

    private func startReadLoops(channel ch: any ACPChannel) {
        // Consume incoming JSON-RPC lines from the channel.
        readTask = Task { [weak self] in
            do {
                for try await line in ch.incoming {
                    await self?.touchLastIncoming()
                    guard let data = line.data(using: .utf8) else { continue }
                    do {
                        let message = try JSONDecoder().decode(ACPRawMessage.self, from: data)
                        await self?.handleMessage(message)
                    } catch {
                        #if canImport(os)
                        await self?.logParseFailure(error, line: line)
                        #endif
                    }
                }
                await self?.handleReadLoopEnded(cleanly: true)
            } catch {
                await self?.handleReadLoopEnded(cleanly: false, error: error)
            }
        }

        // Mirror stderr into the diagnostic ring buffer.
        stderrTask = Task { [weak self] in
            do {
                for try await text in ch.stderr {
                    await self?.appendStderr(text)
                    #if canImport(os)
                    await self?.logStderrLine(text)
                    #endif
                }
            } catch {
                // Stderr errors don't matter — we already handle EOF on
                // the incoming stream.
            }
        }
    }

    #if canImport(os)
    private func logParseFailure(_ error: Error, line: String) {
        logger.warning("Failed to decode ACP message: \(error.localizedDescription)")
    }

    private func logStderrLine(_ text: String) {
        logger.info("ACP stderr: \(text.prefix(500))")
    }
    #endif

    private func handleMessage(_ message: ACPRawMessage) {
        if message.isResponse {
            if let requestId = message.id,
               let continuation = pendingRequests.removeValue(forKey: requestId) {
                if let error = message.error {
                    #if canImport(os)
                    // Log the FULL details payload — the user-facing
                    // string truncates it defensively, so the Logger
                    // line is where the whole story lives. Default
                    // (private) redaction, NOT `privacy: .public`:
                    // details is arbitrary server-side exception text
                    // (same trust class as the stderr mirror below,
                    // also default-private) and can echo config values
                    // or provider credentials; the actionable headline
                    // already reaches the user via detailsLead.
                    if let details = error.details {
                        logger.error("ACP RPC error (id: \(requestId)): \(error.message) — details: \(details)")
                    } else {
                        logger.error("ACP RPC error (id: \(requestId)): \(error.message)")
                    }
                    #endif
                    statusMessage = "Error: \(error.message)"
                    continuation.resume(throwing: ACPClientError.rpcError(
                        code: error.code,
                        message: error.message,
                        details: error.details
                    ))
                } else {
                    #if canImport(os)
                    logger.debug("ACP response (id: \(requestId))")
                    #endif
                    continuation.resume(returning: message.result)
                }
            } else {
                #if canImport(os)
                logger.warning("ACP response for unknown request id: \(message.id ?? -1)")
                #endif
            }
        } else if message.isNotification {
            if let event = ACPEventParser.parse(notification: message) {
                eventContinuation?.yield(event)
            }
        } else if message.isRequest {
            if message.method == "session/request_permission",
               let event = ACPEventParser.parsePermissionRequest(message) {
                statusMessage = "Permission required"
                eventContinuation?.yield(event)
            }
        }
    }

    // MARK: - Disconnect Cleanup

    /// Single idempotent cleanup path for all disconnect scenarios.
    /// Captures the channel's exit code + recent stderr BEFORE we drop
    /// the reference, so the `processTerminated` error rides with
    /// diagnostics — the user banner shows "exit 255 — ssh: connect to
    /// host …: Connection refused" instead of a bare opaque timeout.
    private func performDisconnectCleanup(reason: String) async {
        guard isConnected else { return }
        #if canImport(os)
        logger.warning("ACP disconnecting: \(reason)")
        #endif
        let exitCode = await channel?.lastExitCode
        let tail = recentStderr
        isConnected = false
        statusMessage = "Connection lost"
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ACPClientError.processTerminated(
                exitCode: exitCode,
                stderrTail: tail
            ))
        }
        pendingRequests.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func handleReadLoopEnded(cleanly: Bool, error: Error? = nil) async {
        let reason = cleanly ? "read loop ended (EOF)" : "read loop failed: \(error?.localizedDescription ?? "unknown")"
        await performDisconnectCleanup(reason: reason)
    }

    private func handleWriteFailed() async {
        await performDisconnectCleanup(reason: "write failed (broken pipe)")
    }

    private func handleWriteFailedForRequest(id: Int) async {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            let exitCode = await channel?.lastExitCode
            continuation.resume(throwing: ACPClientError.processTerminated(
                exitCode: exitCode,
                stderrTail: recentStderr
            ))
        }
        await performDisconnectCleanup(reason: "write failed (broken pipe)")
    }
}

// MARK: - Errors

public enum ACPClientError: Error, LocalizedError {
    case notConnected
    case encodingFailed
    case invalidResponse(String)
    /// `details` is the server's real failure text when the JSON-RPC
    /// error carried one (Hermes's acp lib wraps unexpected exceptions
    /// into `-32603 Internal error` with the actual exception string in
    /// `error.data.details` — the generic `message` alone is useless to
    /// the user). Lead copy when present; `code`/`message` stay for
    /// programmatic paths.
    case rpcError(code: Int, message: String, details: String? = nil)
    case processTerminated(exitCode: Int32?, stderrTail: String)
    case requestTimeout(method: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "ACP client is not connected"
        case .encodingFailed: return "Failed to encode JSON-RPC request"
        case .invalidResponse(let msg): return "Invalid ACP response: \(msg)"
        case .rpcError(let code, let msg, let details):
            // The wrapped server-side details are the real story
            // ("Model context floor exceeded …"), the generic message
            // ("Internal error") is noise — lead with the details and
            // demote the code to a suffix. Details can be arbitrarily
            // long (tracebacks); truncate defensively — the full text
            // was already logged by ACPClient at throw time.
            if let details, let lead = Self.detailsLead(fromDetails: details) {
                return "\(lead) (ACP error \(code))"
            }
            return "ACP error \(code): \(msg)"
        case .processTerminated(let exit, let tail):
            let exitPart = exit.map { "exit \($0)" } ?? "no exit code"
            let tailPart = Self.summaryLine(fromStderrTail: tail).map { " — \($0)" } ?? ""
            return "ACP process terminated unexpectedly (\(exitPart))\(tailPart)"
        case .requestTimeout(let method): return "ACP request '\(method)' timed out"
        }
    }

    /// Pick the most signal-rich line from a stderr tail for the
    /// user-facing error summary.
    ///
    /// Hermes ACP adapter emits `[INFO]` / `[DEBUG]` startup logs
    /// ("Loaded env", "Starting hermes-agent ACP adapter") BEFORE the
    /// real work begins. If the process dies right after, the full
    /// stderr ring buffer can be entirely benign INFO chatter — picking
    /// the *first* line surfaces a misleading "Loaded env from …" tail
    /// next to "process terminated unexpectedly" (TestFlight feedback
    /// AGTvQ, 2026-05-10).
    ///
    /// Strategy:
    ///   1. Skip blank lines, `[INFO]`, `[DEBUG]`, `[NOTICE]`.
    ///   2. From the remainder, pick the *last* line — it's closest in
    ///      time to the actual termination (Python tracebacks put the
    ///      most useful exception on the last line; ssh failures emit
    ///      a single terminal line).
    ///   3. If nothing remains, return `nil` so the description doesn't
    ///      append a noisy/misleading suffix at all.
    ///
    /// `internal` so the test suite can pin the behavior without
    /// reaching through `errorDescription` string contains-checks.
    static func summaryLine(fromStderrTail s: String) -> String? {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let signal = lines.filter { line in
            let lower = line.lowercased()
            return !lower.contains("[info]")
                && !lower.contains("[debug]")
                && !lower.contains("[notice]")
        }
        return signal.last
    }

    /// Compress a server-side `error.data.details` payload into a lead
    /// line short enough for the chat banner / toast: first line, cut
    /// at the first sentence boundary, hard-capped at ~200 chars with
    /// an ellipsis. Returns `nil` for empty/whitespace details so the
    /// caller falls back to the generic `code: message` copy. The FULL
    /// details were already written to the os Logger by `ACPClient`
    /// when the error frame arrived.
    ///
    /// `internal` so the test suite can pin the truncation behavior
    /// directly.
    static func detailsLead(fromDetails details: String, maxLength: Int = 200) -> String? {
        // First non-empty line — multi-line details are usually a
        // traceback or a wrapped JSON blob; the first line carries the
        // headline. Split on the `.newlines` character set, NOT on the
        // Character "\n": Swift treats "\r\n" as a single grapheme
        // cluster that does not match "\n", so a Character-based split
        // would pass CRLF payloads through whole and the "first line"
        // would be the entire traceback, embedded newlines and all
        // (audit t-217da62b).
        guard let firstLine = details
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        // Cut at the first sentence boundary (". " requires the space,
        // so decimals and version strings like "0.17" survive).
        var lead = firstLine
        if let dot = firstLine.range(of: ". ") {
            lead = String(firstLine[..<dot.upperBound]).trimmingCharacters(in: .whitespaces)
        }

        if lead.count > maxLength {
            lead = String(lead.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return lead
    }
}

/// Maps a raw error message (RPC message or captured stderr) to a short
/// human-readable hint for the chat UI. Pattern-matches the most common
/// fresh-install failure modes. Returns nil when no known pattern matches.
public enum ACPErrorHint {
    /// Result of a classifier hit. `hint` is the user-facing copy; when
    /// the failure is an OAuth refresh-revocation, `oauthProvider` names
    /// the affected provider (lowercase, matching `auth.json` keys) so
    /// the UI can offer a one-click re-authenticate affordance. `nil`
    /// `oauthProvider` means "we matched a non-OAuth failure mode, or
    /// we matched OAuth but couldn't identify which provider."
    public struct Classification: Sendable, Equatable {
        public let hint: String
        public let oauthProvider: String?

        public init(hint: String, oauthProvider: String? = nil) {
            self.hint = hint
            self.oauthProvider = oauthProvider
        }
    }

    /// Known OAuth-authed providers Hermes ships. Listed lowercase to
    /// match `auth.json.providers.<key>` and the values
    /// `OAuthFlowController.start(provider:)` accepts.
    private static let oauthProviders = [
        "nous", "claude", "anthropic", "qwen", "gemini", "google", "copilot", "github",
    ]

    public static func classify(errorMessage: String, stderrTail: String) -> Classification? {
        let haystack = errorMessage + "\n" + stderrTail

        // SSH-level failures come first — they apply only to remote
        // contexts and the patterns are unambiguous (system ssh prints
        // them verbatim to stderr). Without these classifications a
        // vanished droplet, a wrong key, or a missing remote `hermes`
        // all surface as opaque "ACP process terminated" / "request
        // timed out", and the user has no idea where to look.
        if haystack.contains("Connection refused") {
            return Classification(hint: "Couldn't reach the remote host — the SSH port is closed or the droplet is down. Check the host is running and reachable.")
        }
        if haystack.localizedCaseInsensitiveContains("Operation timed out")
            || haystack.localizedCaseInsensitiveContains("Connection timed out")
            || haystack.contains("Network is unreachable")
            || haystack.contains("No route to host") {
            return Classification(hint: "Couldn't reach the remote host — the network connection timed out. Check the host is running and your network is up.")
        }
        if haystack.contains("Permission denied (publickey")
            || haystack.contains("Permission denied, please try again") {
            return Classification(hint: "SSH rejected the key. Make sure the right identity file is selected and that ssh-agent has the key loaded — open Terminal and run `ssh-add -l`.")
        }
        if haystack.contains("Host key verification failed")
            || haystack.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return Classification(hint: "The remote host's SSH key changed. If you just rebuilt the droplet, remove the old entry with `ssh-keygen -R <host>`, then try again.")
        }
        if haystack.contains("Could not resolve hostname")
            || haystack.contains("Name or service not known") {
            return Classification(hint: "Couldn't resolve the host name. Check the host in this server's settings.")
        }
        if haystack.localizedCaseInsensitiveContains("command not found")
            || haystack.contains("hermes: not found")
            || haystack.contains("exit 127") {
            return Classification(hint: "The remote shell couldn't find `hermes`. Either install Hermes on the remote (`pipx install hermes-agent`) or set an absolute binary path in this server's settings.")
        }

        // OAuth refresh-token revocation. Hermes prints
        // "Refresh session has been revoked. Run `hermes model` to
        // re-authenticate." to stderr/stdout when an OAuth-authed
        // provider's refresh token can no longer mint access tokens
        // (user revoked, server rotated keys, etc.). We can't drive
        // `hermes model` interactively, but `hermes auth add <provider>
        // --type oauth` is the same code path Scarf already drives via
        // `OAuthFlowController` for first-time setup, so we surface a
        // re-authenticate affordance instead. Checked BEFORE the
        // generic "no credentials found" path because the message
        // contains the word "credentials" via the surrounding context.
        if haystack.localizedCaseInsensitiveContains("refresh session has been revoked")
            || haystack.range(of: #"refresh.*revoked"#, options: [.regularExpression, .caseInsensitive]) != nil
            || haystack.localizedCaseInsensitiveContains("re-authenticate")
            || haystack.localizedCaseInsensitiveContains("reauthenticate")
            || (haystack.contains("401") && oauthProvider(in: haystack) != nil)
            || (haystack.localizedCaseInsensitiveContains("unauthorized") && oauthProvider(in: haystack) != nil) {
            let provider = oauthProvider(in: haystack)
            let suffix = provider.map { " (affected provider: \($0))." } ?? "."
            return Classification(
                hint: "Your OAuth session has expired or been revoked\(suffix) Click Re-authenticate below to sign in again.",
                oauthProvider: provider
            )
        }

        // Auxiliary task references a provider that isn't authenticated.
        // Hermes prints `resolve_provider_client: <name> requested but
        // <Display Name> not configured` when an aux task (compression,
        // summarization, memory_flush, curator, vision, web_extract,
        // session_search, skills_hub) has `provider: <name>` set in
        // config.yaml but that provider's credentials aren't loaded.
        // Common after a user removes one OAuth provider while their
        // existing config.yaml still names it for an aux task. The
        // chat banner used to surface this as `-32603 Internal error`
        // with no actionable detail; surface a clear path now.
        if let match = haystack.range(
            of: #"resolve_provider_client:\s*([a-zA-Z0-9_-]+)\s+requested\s+but"#,
            options: .regularExpression
        ) {
            let line = String(haystack[match])
            // Pull the captured provider name out of the matched line.
            // First word after "resolve_provider_client:" is the value.
            let provider: String = {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if let idx = parts.firstIndex(where: { $0.contains("resolve_provider_client") }),
                   parts.index(after: idx) < parts.endIndex {
                    let candidate = parts[parts.index(after: idx)]
                    return String(candidate)
                }
                return "an unauthenticated provider"
            }()
            return Classification(
                hint: "An auxiliary task is configured to use `\(provider)` but that provider isn't authenticated. Open Settings → Aux Models, or check `~/.hermes/config.yaml` for `auxiliary.<task>.provider: \(provider)` and switch it to your active provider (or set it to `auto`)."
            )
        }

        if haystack.range(of: #"No\s+(Anthropic|OpenAI|OpenRouter|Gemini|Google|Groq|Mistral|XAI)?\s*credentials\s+found"#,
                          options: .regularExpression) != nil
            || haystack.contains("ANTHROPIC_API_KEY")
            || haystack.contains("ANTHROPIC_TOKEN")
            || haystack.contains("claude setup-token")
            || haystack.contains("claude /login") {
            return Classification(hint: "Hermes can't find your AI provider credentials. Set `ANTHROPIC_API_KEY` (or similar) in `~/.hermes/.env` or your shell profile, then restart Scarf.")
        }
        if let match = haystack.range(of: #"No such file or directory:\s*'([^']+)'"#,
                                      options: .regularExpression) {
            let matched = String(haystack[match])
            if let nameStart = matched.range(of: "'"),
               let nameEnd = matched.range(of: "'", range: nameStart.upperBound..<matched.endIndex) {
                let name = String(matched[nameStart.upperBound..<nameEnd.lowerBound])
                return Classification(hint: "Hermes couldn't find `\(name)` on PATH. If you use nvm/asdf/mise, make sure it's exported in `~/.zprofile` (not only `~/.zshrc`), then restart Scarf.")
            }
            return Classification(hint: "Hermes couldn't find a required binary on PATH. Check that your shell's PATH is exported in `~/.zprofile`, then restart Scarf.")
        }
        if haystack.localizedCaseInsensitiveContains("rate limit")
            || haystack.localizedCaseInsensitiveContains("429") {
            return Classification(hint: "Your AI provider returned a rate-limit error. Try again in a moment.")
        }
        // Model-availability failure. Hermes pins each session to the
        // model that opened it, so resuming an old session whose model
        // is no longer available (provider deprecation, OAuth swapped
        // to a different provider, model name changed) returns a 404
        // / model_not_found from the upstream provider — surfaced as
        // an opaque "-32603 Internal error" in chat. v2.8 surfaces a
        // clear "session is pinned" hint with the recovery path.
        if haystack.localizedCaseInsensitiveContains("model_not_found")
            || haystack.localizedCaseInsensitiveContains("model not found")
            || haystack.localizedCaseInsensitiveContains("invalid_model")
            || haystack.localizedCaseInsensitiveContains("model is not available")
            || haystack.localizedCaseInsensitiveContains("unknown model")
            || (haystack.contains("404") && (haystack.localizedCaseInsensitiveContains("model")
                                              || haystack.localizedCaseInsensitiveContains("messages"))) {
            return Classification(hint: "This session was created with a model the provider no longer offers. Hermes pins each session to its original model — start a new chat to use your current model, or run `hermes sessions clone` in Terminal to copy this conversation onto the new model.")
        }
        return nil
    }

    /// Best-effort extraction of an OAuth provider name from raw error
    /// text. Returns the lowercase provider key (`"nous"`, `"claude"`,
    /// etc.) when one of the known OAuth providers appears as a whole
    /// word. The first match wins — Hermes typically logs the active
    /// provider name once, near the failure.
    private static func oauthProvider(in haystack: String) -> String? {
        let lowered = haystack.lowercased()
        for provider in oauthProviders {
            // Whole-word match so substrings like "anthropicapi" don't
            // false-trigger on "anthropic".
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: provider) + "\\b"
            if lowered.range(of: pattern, options: .regularExpression) != nil {
                return provider
            }
        }
        return nil
    }
}
