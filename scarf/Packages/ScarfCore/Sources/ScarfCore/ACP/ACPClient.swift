import Foundation
#if canImport(os)
import os
#endif

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

    fileprivate func appendStderr(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            stderrBuffer.append(String(line))
        }
        if stderrBuffer.count > Self.stderrBufferMaxLines {
            stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrBufferMaxLines)
        }
    }

    /// True while the underlying channel is alive. Equivalent to the
    /// old `process.isRunning` check.
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

    public func start() async throws {
        guard channel == nil else { return }

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

        self.channel = ch
        self.isConnected = true

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
        // ACP returns {} on success (no sessionId echoed), or an error if
        // not found. If we got here without throwing, the session was
        // loaded — use the ID we sent.
        let loadedId = (result?.dictValue?["sessionId"] as? String) ?? sessionId
        currentSessionId = loadedId
        statusMessage = "Session loaded"
        #if canImport(os)
        logger.info("Loaded ACP session: \(loadedId)")
        #endif
        return loadedId
    }

    public func resumeSession(cwd: String, sessionId: String) async throws -> String {
        statusMessage = "Resuming session..."
        let params: [String: AnyCodable] = [
            "cwd": AnyCodable(cwd),
            "sessionId": AnyCodable(sessionId),
            "mcpServers": AnyCodable([Any]()),
        ]
        let result = try await sendRequest(method: "session/resume", params: params)
        guard let dict = result?.dictValue,
              let resumedId = dict["sessionId"] as? String
        else {
            throw ACPClientError.invalidResponse("Missing sessionId in session/resume response")
        }
        currentSessionId = resumedId
        statusMessage = "Session resumed"
        #if canImport(os)
        logger.info("Resumed ACP session: \(resumedId)")
        #endif
        return resumedId
    }

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

        statusMessage = "Ready"
        return ACPPromptResult(
            stopReason: dict["stopReason"] as? String ?? "end_turn",
            inputTokens: usage["inputTokens"] as? Int ?? 0,
            outputTokens: usage["outputTokens"] as? Int ?? 0,
            thoughtTokens: usage["thoughtTokens"] as? Int ?? 0,
            cachedReadTokens: usage["cachedReadTokens"] as? Int ?? 0
        )
    }

    public func cancel(sessionId: String) async throws {
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
        ]
        _ = try await sendRequest(method: "session/cancel", params: params)
        statusMessage = "Cancelled"
    }

    public func respondToPermission(requestId: Int, optionId: String) async {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "result": [
                "outcome": [
                    "kind": optionId == "deny" ? "rejected" : "allowed",
                    "optionId": optionId,
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
                    logger.error("ACP RPC error (id: \(requestId)): \(error.message)")
                    #endif
                    statusMessage = "Error: \(error.message)"
                    continuation.resume(throwing: ACPClientError.rpcError(code: error.code, message: error.message))
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
    case rpcError(code: Int, message: String)
    case processTerminated(exitCode: Int32?, stderrTail: String)
    case requestTimeout(method: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "ACP client is not connected"
        case .encodingFailed: return "Failed to encode JSON-RPC request"
        case .invalidResponse(let msg): return "Invalid ACP response: \(msg)"
        case .rpcError(let code, let msg): return "ACP error \(code): \(msg)"
        case .processTerminated(let exit, let tail):
            let exitPart = exit.map { "exit \($0)" } ?? "no exit code"
            let tailPart = Self.firstNonEmptyLine(in: tail).map { " — \($0)" } ?? ""
            return "ACP process terminated unexpectedly (\(exitPart))\(tailPart)"
        case .requestTimeout(let method): return "ACP request '\(method)' timed out"
        }
    }

    /// Pluck the first non-empty stderr line for the user-facing
    /// summary. Full tail still rides through on `acpErrorDetails`,
    /// but the description itself stays single-line.
    private static func firstNonEmptyLine(in s: String) -> String? {
        for raw in s.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return nil
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
