import Foundation
import AppKit
import SwiftTerm
import os

@Observable
final class ChatViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ChatViewModel")
    private let dataService = HermesDataService()
    private let fileService = HermesFileService()

    var recentSessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]
    var terminalView: LocalProcessTerminalView?
    var hasActiveProcess = false
    var voiceEnabled = false
    var ttsEnabled = false
    var isRecording = false
    var displayMode: ChatDisplayMode = .richChat
    let richChatViewModel = RichChatViewModel()
    private var coordinator: Coordinator?

    // ACP state
    private var acpClient: ACPClient?
    private var acpEventTask: Task<Void, Never>?
    private var acpPromptTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isHandlingDisconnect = false
    var isACPConnected: Bool { acpClient != nil && hasActiveProcess }
    var acpStatus: String = ""
    var acpError: String?

    private static let maxReconnectAttempts = 5
    private static let reconnectBaseDelay: UInt64 = 1_000_000_000 // 1 second
    private static let maxReconnectDelay: UInt64 = 16_000_000_000 // 16 seconds

    var hermesBinaryExists: Bool {
        FileManager.default.fileExists(atPath: HermesPaths.hermesBinary)
    }

    // MARK: - Session Lifecycle

    func startNewSession() {
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            startACPSession(resume: nil)
        } else {
            launchTerminal(arguments: ["chat"])
        }
    }

    func resumeSession(_ sessionId: String) {
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            startACPSession(resume: sessionId)
        } else {
            richChatViewModel.setSessionId(sessionId)
            launchTerminal(arguments: ["chat", "--resume", sessionId])
        }
    }

    func continueLastSession() {
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            // Find most recent session and resume via ACP
            Task { @MainActor in
                let opened = await dataService.open()
                guard opened else { return }
                let sessionId = await dataService.fetchMostRecentlyActiveSessionId()
                await dataService.close()
                if let sessionId {
                    startACPSession(resume: sessionId)
                } else {
                    startACPSession(resume: nil)
                }
            }
        } else {
            launchTerminal(arguments: ["chat", "--continue"])
        }
    }

    // MARK: - Send Message

    func sendText(_ text: String) {
        if displayMode == .richChat {
            if let client = acpClient {
                sendViaACP(client: client, text: text)
            } else {
                // Auto-start ACP and send the queued message
                autoStartACPAndSend(text: text)
            }
        } else if let tv = terminalView {
            sendToTerminal(tv, text: text + "\r")
        }
    }

    /// Start ACP for the current or most recent session, then send the queued prompt.
    private func autoStartACPAndSend(text: String) {
        // Show the user message immediately
        richChatViewModel.addUserMessage(text: text)

        Task { @MainActor in
            // Find a session to resume: prefer current sessionId, then most recent
            var sessionToResume = richChatViewModel.sessionId
            if sessionToResume == nil {
                let opened = await dataService.open()
                if opened {
                    sessionToResume = await dataService.fetchMostRecentlyActiveSessionId()
                    await dataService.close()
                }
            }

            let client = ACPClient()
            self.acpClient = client

            do {
                try await client.start()
                acpStatus = await client.statusMessage
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                let cwd = NSHomeDirectory()

                hasActiveProcess = true

                let resolvedSessionId: String
                if let existing = sessionToResume {
                    acpStatus = "Loading session..."
                    do {
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: existing)
                    } catch {
                        logger.info("Session \(existing) not found in ACP, creating new session")
                        acpStatus = "Creating new session..."
                        resolvedSessionId = try await client.newSession(cwd: cwd)
                    }
                } else {
                    acpStatus = "Creating session..."
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                }

                richChatViewModel.setSessionId(resolvedSessionId)
                acpStatus = "Connected (\(resolvedSessionId.prefix(12)))"

                // Now send the queued prompt
                sendViaACP(client: client, text: text)
            } catch {
                let msg = error.localizedDescription
                logger.error("Auto-start ACP failed: \(msg)")
                acpStatus = "Failed"
                acpError = msg
                hasActiveProcess = false
                acpClient = nil
            }
        }
    }

    private func sendViaACP(client: ACPClient, text: String) {
        guard let sessionId = richChatViewModel.sessionId else {
            acpError = "No session ID — cannot send"
            return
        }

        // Don't duplicate user message if autoStartACPAndSend already added it
        if richChatViewModel.messages.last?.isUser != true
            || richChatViewModel.messages.last?.content != text {
            richChatViewModel.addUserMessage(text: text)
        }

        acpStatus = "Agent working..."
        acpPromptTask = Task { @MainActor in
            do {
                let result = try await client.sendPrompt(sessionId: sessionId, text: text)
                acpStatus = "Ready"
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: result)
                )
                // Re-fetch session from DB to pick up cost/token data Hermes may have written
                await richChatViewModel.refreshSessionFromDB()
            } catch is CancellationError {
                acpStatus = "Cancelled"
            } catch {
                let msg = error.localizedDescription
                logger.error("ACP prompt failed: \(msg)")
                acpStatus = "Error"
                acpError = msg
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: ACPPromptResult(
                        stopReason: "error",
                        inputTokens: 0, outputTokens: 0,
                        thoughtTokens: 0, cachedReadTokens: 0
                    ))
                )
            }
        }
    }

    // MARK: - ACP Session Management

    private func startACPSession(resume sessionId: String?) {
        stopACP()
        acpError = nil
        acpStatus = "Starting..."

        let client = ACPClient()
        self.acpClient = client

        Task { @MainActor in
            do {
                // Start ACP process and event loop FIRST
                try await client.start()
                acpStatus = await client.statusMessage
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                let cwd = NSHomeDirectory()

                // Mark active BEFORE setting session ID so .task(id:) sees isACPMode=true
                // and doesn't wipe messages with a DB refresh
                hasActiveProcess = true

                let resolvedSessionId: String
                if let sessionId {
                    acpStatus = "Loading session..."
                    do {
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: sessionId)
                    } catch {
                        logger.info("Session \(sessionId) not found in ACP, creating new session with history")
                        acpStatus = "Creating new session..."
                        resolvedSessionId = try await client.newSession(cwd: cwd)
                    }
                    // Load messages from both origin CLI session and ACP session
                    await richChatViewModel.loadSessionHistory(
                        sessionId: sessionId,
                        acpSessionId: resolvedSessionId
                    )
                } else {
                    acpStatus = "Creating session..."
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                }

                richChatViewModel.setSessionId(resolvedSessionId)
                acpStatus = "Connected (\(resolvedSessionId.prefix(12)))"

                // Refresh session list so the new ACP session appears in the Resume menu
                await loadRecentSessions()

                logger.info("ACP session ready: \(resolvedSessionId)")
            } catch {
                let msg = error.localizedDescription
                logger.error("Failed to start ACP session: \(msg)")
                acpStatus = "Failed"
                acpError = msg
                hasActiveProcess = false
                acpClient = nil
            }
        }
    }

    private func startACPEventLoop(client: ACPClient) {
        acpEventTask = Task { @MainActor [weak self] in
            let eventStream = await client.events
            for await event in eventStream {
                guard !Task.isCancelled else { break }
                self?.richChatViewModel.handleACPEvent(event)
                self?.acpStatus = await client.statusMessage
            }
            // Stream ended — if we weren't cancelled, the connection died
            if !Task.isCancelled {
                self?.handleConnectionDied()
            }
        }
    }

    private func startHealthMonitor(client: ACPClient) {
        healthMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                let healthy = await client.isHealthy
                if !healthy {
                    self?.handleConnectionDied()
                    break
                }
            }
        }
    }

    private func handleConnectionDied() {
        guard acpClient != nil, !isHandlingDisconnect else { return }
        isHandlingDisconnect = true
        logger.warning("ACP connection died")

        // Finalize any in-progress streaming message before reconnection
        richChatViewModel.finalizeOnDisconnect()

        // Save session ID for reconnection before cleaning up
        let savedSessionId = richChatViewModel.sessionId

        // Clean up the dead client
        acpPromptTask?.cancel()
        acpPromptTask = nil
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        if let client = acpClient {
            Task { await client.stop() }
        }
        acpClient = nil
        hasActiveProcess = false

        // Attempt auto-reconnect if we have a session to restore
        guard let savedSessionId else {
            showConnectionFailure()
            isHandlingDisconnect = false
            return
        }
        attemptReconnect(sessionId: savedSessionId)
    }

    private func attemptReconnect(sessionId: String) {
        reconnectTask?.cancel()
        acpError = nil

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...Self.maxReconnectAttempts {
                guard !Task.isCancelled else { return }

                acpStatus = "Reconnecting (\(attempt)/\(Self.maxReconnectAttempts))..."
                logger.info("Reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) for session \(sessionId)")

                // Backoff delay (skip on first attempt for fast recovery)
                if attempt > 1 {
                    let delay = min(
                        Self.reconnectBaseDelay * UInt64(1 << (attempt - 1)),
                        Self.maxReconnectDelay
                    )
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                }

                let client = ACPClient()
                do {
                    try await client.start()

                    let cwd = NSHomeDirectory()
                    let resolvedSessionId: String

                    // Try resumeSession first (designed for reconnection), then loadSession.
                    // NEVER fall back to newSession — that loses all conversation context.
                    do {
                        resolvedSessionId = try await client.resumeSession(cwd: cwd, sessionId: sessionId)
                    } catch {
                        logger.info("session/resume failed, trying session/load: \(error.localizedDescription)")
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: sessionId)
                    }

                    // Success — wire up the new client
                    self.acpClient = client
                    self.hasActiveProcess = true
                    richChatViewModel.setSessionId(resolvedSessionId)

                    // Reconcile in-memory messages with what Hermes persisted to DB
                    await richChatViewModel.reconcileWithDB(sessionId: resolvedSessionId)

                    acpStatus = "Reconnected (\(resolvedSessionId.prefix(12)))"
                    acpError = nil

                    startACPEventLoop(client: client)
                    startHealthMonitor(client: client)

                    isHandlingDisconnect = false
                    logger.info("Reconnected successfully on attempt \(attempt)")
                    return
                } catch {
                    logger.warning("Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    await client.stop()
                    continue
                }
            }

            // All attempts exhausted
            guard !Task.isCancelled else { return }
            showConnectionFailure()
            isHandlingDisconnect = false
        }
    }

    private func showConnectionFailure() {
        richChatViewModel.handleACPEvent(.connectionLost(reason: "The ACP process terminated unexpectedly"))
        acpStatus = "Connection lost"
        acpError = "Connection lost. Use the Session menu to reconnect."
    }

    func stopACP() {
        reconnectTask?.cancel()
        reconnectTask = nil
        acpPromptTask?.cancel()
        acpPromptTask = nil
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        if let client = acpClient {
            Task { await client.stop() }
        }
        acpClient = nil
        hasActiveProcess = false
        isHandlingDisconnect = false
    }

    /// Respond to a permission request from the ACP agent.
    func respondToPermission(optionId: String) {
        guard let client = acpClient,
              let permission = richChatViewModel.pendingPermission else { return }
        Task {
            await client.respondToPermission(requestId: permission.requestId, optionId: optionId)
        }
        richChatViewModel.pendingPermission = nil
    }

    // MARK: - Recent Sessions

    func loadRecentSessions() async {
        let opened = await dataService.open()
        guard opened else { return }
        recentSessions = await dataService.fetchSessions(limit: 10)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 10)
        await dataService.close()
    }

    func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    // MARK: - Voice (terminal mode only)

    func toggleVoice() {
        guard let tv = terminalView else { return }
        if voiceEnabled {
            sendToTerminal(tv, text: "/voice off\r")
            voiceEnabled = false
            isRecording = false
        } else {
            sendToTerminal(tv, text: "/voice on\r")
            voiceEnabled = true
            ttsEnabled = fileService.loadConfig().autoTTS
        }
    }

    func toggleTTS() {
        guard let tv = terminalView, voiceEnabled else { return }
        sendToTerminal(tv, text: "/voice tts\r")
        ttsEnabled.toggle()
    }

    func pushToTalk() {
        guard let tv = terminalView, voiceEnabled else { return }
        let ctrlB: [UInt8] = [0x02]
        tv.send(source: tv, data: ctrlB[0..<1])
        isRecording.toggle()
    }

    // MARK: - Terminal Mode

    private func sendToTerminal(_ tv: LocalProcessTerminalView, text: String) {
        let bytes = Array(text.utf8)
        tv.send(source: tv, data: bytes[0..<bytes.count])
    }

    private func launchTerminal(arguments: [String]) {
        stopACP()

        if let existing = terminalView {
            existing.terminate()
            existing.removeFromSuperview()
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)

        let coord = Coordinator(onTerminated: { [weak self] in
            self?.hasActiveProcess = false
            self?.voiceEnabled = false
            self?.isRecording = false
            Task { await self?.richChatViewModel.refreshMessages() }
        })
        terminal.processDelegate = coord
        self.coordinator = coord

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: HermesPaths.hermesBinary,
            args: arguments,
            environment: envArray,
            execName: nil
        )

        self.terminalView = terminal
        self.hasActiveProcess = true
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTerminated: () -> Void

        init(onTerminated: @escaping () -> Void) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let terminal = source.getTerminal()
            terminal.feed(text: "\r\n[Process exited with code \(exitCode ?? -1). Use the toolbar to start or resume a session.]\r\n")
            DispatchQueue.main.async { self.onTerminated() }
        }
    }
}
