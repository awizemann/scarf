import Foundation
import os

/// Manages a `hermes acp` subprocess and communicates via JSON-RPC over stdio.
/// Provides an async event stream for real-time session updates.
actor ACPClient {
    private let logger = Logger(subsystem: "com.scarf", category: "ACPClient")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinFd: Int32 = -1

    private var nextRequestId = 1
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ACPEvent>.Continuation?
    private var _eventStream: AsyncStream<ACPEvent>?

    private(set) var isConnected = false
    private(set) var currentSessionId: String?
    private(set) var statusMessage = ""

    /// Ring buffer of recent stderr lines from `hermes acp` — used to attach
    /// a diagnostic tail to user-visible errors. Capped to avoid unbounded
    /// growth when the subprocess logs heavily.
    private var stderrBuffer: [String] = []
    private static let stderrBufferMaxLines = 50

    /// Returns the last ~`stderrBufferMaxLines` stderr lines captured from the
    /// `hermes acp` subprocess, joined by newlines.
    var recentStderr: String {
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

    /// Check if the underlying process is still alive and connected.
    var isHealthy: Bool {
        guard isConnected, let process else { return false }
        return process.isRunning
    }

    // MARK: - Event Stream

    /// Access the event stream. Must call `start()` first.
    var events: AsyncStream<ACPEvent> {
        guard let stream = _eventStream else {
            // Return an empty stream if not started
            return AsyncStream { $0.finish() }
        }
        return stream
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard process == nil else { return }

        // Ignore SIGPIPE so broken-pipe writes return EPIPE instead of crashing
        signal(SIGPIPE, SIG_IGN)

        // Create the event stream BEFORE anything else so no events are lost
        let (stream, continuation) = AsyncStream.makeStream(of: ACPEvent.self)
        self._eventStream = stream
        self.eventContinuation = continuation

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: HermesPaths.hermesBinary)
        proc.arguments = ["acp"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // ACP uses JSON-RPC over pipes — do NOT set TERM to avoid terminal escape pollution.
        // Use the enriched environment so any tools hermes spawns (MCP servers,
        // shell commands) can find brew/nvm/asdf binaries on PATH.
        var env = HermesFileService.enrichedEnvironment()
        env.removeValue(forKey: "TERM")
        proc.environment = env

        proc.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(exitCode: proc.terminationStatus) }
        }

        statusMessage = "Starting hermes acp..."

        do {
            try proc.run()
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
            logger.error("Failed to start hermes acp: \(error.localizedDescription)")
            continuation.finish()
            throw error
        }

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.stdinFd = stdin.fileHandleForWriting.fileDescriptor
        self.isConnected = true

        // Start reading stdout BEFORE sending initialize (so we catch the response)
        startReadLoop(stdout: stdout, stderr: stderr)
        logger.info("hermes acp process started (pid: \(proc.processIdentifier))")
        statusMessage = "Initializing..."

        // Initialize the ACP connection
        let initParams: [String: AnyCodable] = [
            "protocolVersion": AnyCodable(1),
            "clientCapabilities": AnyCodable([String: Any]()),
            "clientInfo": AnyCodable([
                "name": "Scarf",
                "version": "1.0"
            ] as [String: Any])
        ]
        _ = try await sendRequest(method: "initialize", params: initParams)
        statusMessage = "Connected"
        logger.info("ACP connection initialized")
        startKeepalive()
    }

    func stop() async {
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

        // Close stdin first so the subprocess sees EOF and can shut down gracefully
        stdinPipe?.fileHandleForWriting.closeFile()

        if let process, process.isRunning {
            // SIGINT for graceful Python shutdown (raises KeyboardInterrupt cleanly)
            process.interrupt()
            // Watchdog: force-kill if still running after 2 seconds
            let watchdogProcess = process
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if watchdogProcess.isRunning {
                    watchdogProcess.terminate()
                }
            }
        }
        stdinPipe?.fileHandleForReading.closeFile()
        stdoutPipe?.fileHandleForReading.closeFile()
        stderrPipe?.fileHandleForReading.closeFile()

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinFd = -1
        isConnected = false
        currentSessionId = nil
        statusMessage = "Disconnected"
        logger.info("ACP client stopped")
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

    /// Valid JSON-RPC notification used as a keepalive probe.
    /// Sending bare newlines causes `json.loads("")` errors in the ACP library.
    private static let keepalivePayload: Data = {
        let json = #"{"jsonrpc":"2.0","method":"$/ping"}"# + "\n"
        return Data(json.utf8)
    }()

    private func sendKeepalive() {
        let fd = stdinFd
        guard fd >= 0 else { return }
        Task.detached { [weak self] in
            let ok = Self.safeWrite(fd: fd, data: Self.keepalivePayload)
            if !ok {
                await self?.handleWriteFailed()
            }
        }
    }

    // MARK: - Session Management

    func newSession(cwd: String) async throws -> String {
        statusMessage = "Creating session..."
        let params: [String: AnyCodable] = [
            "cwd": AnyCodable(cwd),
            "mcpServers": AnyCodable([Any]())
        ]
        let result = try await sendRequest(method: "session/new", params: params)
        guard let dict = result?.dictValue,
              let sessionId = dict["sessionId"] as? String else {
            throw ACPClientError.invalidResponse("Missing sessionId in session/new response")
        }
        currentSessionId = sessionId
        statusMessage = "Session ready"
        logger.info("Created new ACP session: \(sessionId)")
        return sessionId
    }

    func loadSession(cwd: String, sessionId: String) async throws -> String {
        statusMessage = "Loading session \(sessionId.prefix(12))..."
        let params: [String: AnyCodable] = [
            "cwd": AnyCodable(cwd),
            "sessionId": AnyCodable(sessionId),
            "mcpServers": AnyCodable([Any]())
        ]
        let result = try await sendRequest(method: "session/load", params: params)
        // ACP returns {} on success (no sessionId echoed), or an error if not found.
        // If we got here without throwing, the session was loaded. Use the ID we sent.
        let loadedId = (result?.dictValue?["sessionId"] as? String) ?? sessionId
        currentSessionId = loadedId
        statusMessage = "Session loaded"
        logger.info("Loaded ACP session: \(loadedId)")
        return loadedId
    }

    func resumeSession(cwd: String, sessionId: String) async throws -> String {
        statusMessage = "Resuming session..."
        let params: [String: AnyCodable] = [
            "cwd": AnyCodable(cwd),
            "sessionId": AnyCodable(sessionId),
            "mcpServers": AnyCodable([Any]())
        ]
        let result = try await sendRequest(method: "session/resume", params: params)
        guard let dict = result?.dictValue,
              let resumedId = dict["sessionId"] as? String else {
            throw ACPClientError.invalidResponse("Missing sessionId in session/resume response")
        }
        currentSessionId = resumedId
        statusMessage = "Session resumed"
        logger.info("Resumed ACP session: \(resumedId)")
        return resumedId
    }

    // MARK: - Messaging

    func sendPrompt(sessionId: String, text: String) async throws -> ACPPromptResult {
        statusMessage = "Sending prompt..."
        let messageId = UUID().uuidString
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "messageId": AnyCodable(messageId),
            "prompt": AnyCodable([
                ["type": "text", "text": text] as [String: Any]
            ] as [Any])
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

    func cancel(sessionId: String) async throws {
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId)
        ]
        _ = try await sendRequest(method: "session/cancel", params: params)
        statusMessage = "Cancelled"
    }

    func respondToPermission(requestId: Int, optionId: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "result": [
                "outcome": [
                    "kind": optionId == "deny" ? "rejected" : "allowed",
                    "optionId": optionId
                ] as [String: Any]
            ] as [String: Any]
        ]
        writeJSON(response)
    }

    // MARK: - JSON-RPC Transport

    private func sendRequest(method: String, params: [String: AnyCodable]) async throws -> AnyCodable? {
        let requestId = nextRequestId
        nextRequestId += 1

        let request = ACPRequest(id: requestId, method: method, params: params)

        guard let data = try? JSONEncoder().encode(request) else {
            throw ACPClientError.encodingFailed
        }

        logger.debug("Sending: \(method) (id: \(requestId))")

        // session/prompt streams events and can run for minutes — no hard timeout.
        // Control messages get a 30s watchdog.
        let timeoutTask: Task<Void, Error>? = if method != "session/prompt" {
            Task { [weak self] in
                try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                await self?.timeoutRequest(id: requestId, method: method)
            }
        } else {
            nil
        }

        defer { timeoutTask?.cancel() }

        let fd = stdinFd
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnyCodable?, Error>) in
            pendingRequests[requestId] = continuation

            guard fd >= 0 else {
                pendingRequests.removeValue(forKey: requestId)
                continuation.resume(throwing: ACPClientError.notConnected)
                return
            }

            var payload = data
            payload.append(contentsOf: "\n".utf8)
            // Write in a detached task to avoid blocking the actor's executor.
            // The continuation is already stored; the response arrives via the read loop.
            Task.detached { [weak self] in
                let ok = Self.safeWrite(fd: fd, data: payload)
                if !ok {
                    await self?.handleWriteFailedForRequest(id: requestId)
                }
            }
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        logger.error("Request timed out: \(method) (id: \(id))")
        statusMessage = "Request timed out"
        continuation.resume(throwing: ACPClientError.requestTimeout(method: method))
    }

    private func writeJSON(_ dict: [String: Any]) {
        let fd = stdinFd
        guard fd >= 0,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        var payload = data
        payload.append(contentsOf: "\n".utf8)
        Task.detached { [weak self] in
            let ok = Self.safeWrite(fd: fd, data: payload)
            if !ok {
                await self?.handleWriteFailed()
            }
        }
    }

    // MARK: - Read Loop

    private func startReadLoop(stdout: Pipe, stderr: Pipe) {
        // Read stdout for JSON-RPC messages
        readTask = Task.detached { [weak self] in
            let handle = stdout.fileHandleForReading
            var buffer = Data()

            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF
                buffer.append(chunk)

                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = Data(buffer[buffer.startIndex..<newlineIndex])
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                    guard !lineData.isEmpty else { continue }

                    if let lineStr = String(data: lineData, encoding: .utf8) {
                        await self?.logger.debug("ACP recv: \(lineStr.prefix(200))")
                    }

                    do {
                        let message = try JSONDecoder().decode(ACPRawMessage.self, from: lineData)
                        await self?.handleMessage(message)
                    } catch {
                        await self?.logger.warning("Failed to decode ACP message: \(error.localizedDescription)")
                    }
                }
            }
            await self?.handleReadLoopEnded()
        }

        // Read stderr in background for diagnostic logging AND ring-buffer
        // capture so we can attach a tail to user-visible errors.
        stderrTask = Task.detached { [weak self] in
            let handle = stderr.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    await self?.logger.info("ACP stderr: \(text.prefix(500))")
                    await self?.appendStderr(text)
                }
            }
        }
    }

    private func handleMessage(_ message: ACPRawMessage) {
        if message.isResponse {
            if let requestId = message.id,
               let continuation = pendingRequests.removeValue(forKey: requestId) {
                if let error = message.error {
                    logger.error("ACP RPC error (id: \(requestId)): \(error.message)")
                    statusMessage = "Error: \(error.message)"
                    continuation.resume(throwing: ACPClientError.rpcError(code: error.code, message: error.message))
                } else {
                    logger.debug("ACP response (id: \(requestId))")
                    continuation.resume(returning: message.result)
                }
            } else {
                logger.warning("ACP response for unknown request id: \(message.id ?? -1)")
            }
        } else if message.isNotification {
            if let event = ACPEventParser.parse(notification: message) {
                logger.debug("ACP event: \(String(describing: event).prefix(100))")
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
    private func performDisconnectCleanup(reason: String) {
        guard isConnected else { return }
        logger.warning("ACP disconnecting: \(reason)")
        isConnected = false
        statusMessage = "Connection lost"
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ACPClientError.processTerminated)
        }
        pendingRequests.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func handleReadLoopEnded() {
        performDisconnectCleanup(reason: "read loop ended (EOF)")
    }

    private func handleTermination(exitCode: Int32) {
        performDisconnectCleanup(reason: "process exited (\(exitCode))")
    }

    private func handleWriteFailed() {
        performDisconnectCleanup(reason: "write failed (broken pipe)")
    }

    private func handleWriteFailedForRequest(id: Int) {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: ACPClientError.processTerminated)
        }
        performDisconnectCleanup(reason: "write failed (broken pipe)")
    }

    // MARK: - Safe POSIX Write

    /// Write data to a file descriptor using POSIX write(), returning false on error.
    /// Handles partial writes and returns false on EPIPE or other errors.
    private static func safeWrite(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            var written = 0
            let total = buf.count
            while written < total {
                let result = Darwin.write(fd, base.advanced(by: written), total - written)
                if result <= 0 { return false }
                written += result
            }
            return true
        }
    }
}

// MARK: - Errors

enum ACPClientError: Error, LocalizedError {
    case notConnected
    case encodingFailed
    case invalidResponse(String)
    case rpcError(code: Int, message: String)
    case processTerminated
    case requestTimeout(method: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "ACP client is not connected"
        case .encodingFailed: return "Failed to encode JSON-RPC request"
        case .invalidResponse(let msg): return "Invalid ACP response: \(msg)"
        case .rpcError(let code, let msg): return "ACP error \(code): \(msg)"
        case .processTerminated: return "ACP process terminated unexpectedly"
        case .requestTimeout(let method): return "ACP request '\(method)' timed out"
        }
    }
}

/// Maps a raw error message (RPC message or captured stderr) to a short
/// human-readable hint for the chat UI. Pattern-matches the most common
/// fresh-install failure modes. Returns nil when no known pattern matches.
enum ACPErrorHint {
    static func classify(errorMessage: String, stderrTail: String) -> String? {
        let haystack = errorMessage + "\n" + stderrTail
        if haystack.range(of: #"No\s+(Anthropic|OpenAI|OpenRouter|Gemini|Google|Groq|Mistral|XAI)?\s*credentials\s+found"#,
                          options: .regularExpression) != nil
            || haystack.contains("ANTHROPIC_API_KEY")
            || haystack.contains("ANTHROPIC_TOKEN")
            || haystack.contains("claude setup-token")
            || haystack.contains("claude /login") {
            return "Hermes can't find your AI provider credentials. Set `ANTHROPIC_API_KEY` (or similar) in `~/.hermes/.env` or your shell profile, then restart Scarf."
        }
        if let match = haystack.range(of: #"No such file or directory:\s*'([^']+)'"#,
                                      options: .regularExpression) {
            let matched = String(haystack[match])
            if let nameStart = matched.range(of: "'"),
               let nameEnd = matched.range(of: "'", range: nameStart.upperBound..<matched.endIndex) {
                let name = String(matched[nameStart.upperBound..<nameEnd.lowerBound])
                return "Hermes couldn't find `\(name)` on PATH. If you use nvm/asdf/mise, make sure it's exported in `~/.zprofile` (not only `~/.zshrc`), then restart Scarf."
            }
            return "Hermes couldn't find a required binary on PATH. Check that your shell's PATH is exported in `~/.zprofile`, then restart Scarf."
        }
        if haystack.localizedCaseInsensitiveContains("rate limit")
            || haystack.localizedCaseInsensitiveContains("429") {
            return "Your AI provider returned a rate-limit error. Try again in a moment."
        }
        return nil
    }
}
