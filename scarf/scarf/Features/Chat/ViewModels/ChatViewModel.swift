import Foundation
import ScarfCore
import AppKit
import SwiftTerm
import os

@Observable
final class ChatViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ChatViewModel")
    let context: ServerContext
    private let dataService: HermesDataService
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
        self.fileService = HermesFileService(context: context)
        self.richChatViewModel = RichChatViewModel(context: context)
        // Probe hermes binary existence once off-main, then cache. Doing
        // this synchronously inside `hermesBinaryExists`'s getter would
        // block main on every chat-body re-evaluation — for a remote
        // context that's a SSH `test -e` round-trip on every streaming
        // chunk, which manifests as the chat screen flashing or going
        // blank during prompts.
        Task.detached(priority: .userInitiated) { [context] in
            let exists = context.fileExists(context.paths.hermesBinary)
            await MainActor.run { [weak self] in
                self?.hermesBinaryExists = exists
            }
        }
    }


    var recentSessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]
    var terminalView: LocalProcessTerminalView?
    var hasActiveProcess = false
    var voiceEnabled = false
    var ttsEnabled = false
    var isRecording = false
    var displayMode: ChatDisplayMode = .richChat
    let richChatViewModel: RichChatViewModel
    private var coordinator: Coordinator?

    /// Absolute project path for the current session, when the chat is
    /// project-scoped (either started via a project's "New Chat" button
    /// or resumed from a session that was previously attributed via the
    /// v2.3 sidecar). Nil for plain global chats. Drives the project
    /// indicator in SessionInfoBar + the `Chat · <Name>` nav title.
    private(set) var currentProjectPath: String?

    /// Human-readable name of the active project, resolved from the
    /// projects registry at session-start time. Stored alongside the
    /// path so the view renders without hitting disk on every update.
    /// Nil when `currentProjectPath` is nil OR the path isn't in the
    /// registry (project was removed after the session was attributed).
    private(set) var currentProjectName: String?

    // ACP state
    private var acpClient: ACPClient?
    private var acpEventTask: Task<Void, Never>?
    private var acpPromptTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isHandlingDisconnect = false
    var isACPConnected: Bool { acpClient != nil && hasActiveProcess }
    var acpStatus: String = ""

    /// True while a session is being established or restored — from the user
    /// kicking off "start chat" or "resume session" until the ACP session is
    /// ready for messages. The chat pane uses this to show a loader in place
    /// of the empty-state placeholder.
    var isPreparingSession: Bool {
        guard hasActiveProcess else { return false }
        switch acpStatus {
        case "Starting...",
             "Creating session...",
             "Creating new session...",
             "Loading session...":
            return true
        default:
            return acpStatus.hasPrefix("Reconnecting")
        }
    }
    /// Error triplet moved to RichChatViewModel in M7 #2 so ScarfGo can
    /// share the same banner. These are forwarding accessors to keep
    /// the many existing call sites in this file unchanged.
    var acpError: String? {
        get { richChatViewModel.acpError }
        set { richChatViewModel.acpError = newValue }
    }
    var acpErrorHint: String? {
        get { richChatViewModel.acpErrorHint }
        set { richChatViewModel.acpErrorHint = newValue }
    }
    var acpErrorDetails: String? {
        get { richChatViewModel.acpErrorDetails }
        set { richChatViewModel.acpErrorDetails = newValue }
    }
    /// True when `hasAnyAICredential()` returned false at last preflight.
    var missingCredentials: Bool = false

    private static let maxReconnectAttempts = 5
    private static let reconnectBaseDelay: UInt64 = 1_000_000_000 // 1 second
    private static let maxReconnectDelay: UInt64 = 16_000_000_000 // 16 seconds

    /// Cached result of probing for `hermes` on the target server. Updated
    /// once at init by a detached task; defaults to `true` so the chat
    /// view doesn't briefly flash "Hermes not found" while the async
    /// probe runs. Set to `false` only after the probe confirms the
    /// binary really isn't there.
    var hermesBinaryExists: Bool = true

    /// Re-checks env + `~/.hermes/.env` for AI-provider credentials and
    /// updates `missingCredentials`. Cheap — safe to call from view `.task`.
    func refreshCredentialPreflight() {
        missingCredentials = !fileService.hasAnyAICredential()
    }

    /// Forwarders to the ScarfCore implementation so the error-banner
    /// state lives in one place (M7 #2). The per-site logging label
    /// stays here — only the storage is shared.
    private func clearACPErrorState() {
        richChatViewModel.clearACPErrorState()
    }

    @MainActor
    private func recordACPFailure(_ error: Error, client: ACPClient?, context: String) async {
        logger.error("\(context): \(error.localizedDescription)")
        await richChatViewModel.recordACPFailure(error, client: client)
    }

    // MARK: - Session Lifecycle

    func startNewSession(projectPath: String? = nil) {
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            startACPSession(resume: nil, projectPath: projectPath)
        } else {
            // Terminal mode doesn't surface project attribution today —
            // `hermes chat` uses the shell's cwd, so starting a terminal
            // chat from a project button would require changing the
            // shell's cwd too. Out of scope for v2.3 — Rich Chat is
            // the primary surface for project-scoped sessions.
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
                if !opened {
                    acpError = context.isRemote
                        ? "Couldn't reach \(context.displayName). Check the SSH connection and try again."
                        : "Couldn't open the Hermes state database."
                    acpErrorHint = nil
                    acpErrorDetails = nil
                    return
                }
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

    /// Start ACP for the current session (or create a new one), then send the
    /// queued prompt. Typing into a blank Chat screen ALWAYS creates a new
    /// session — the "Continue from Last Session" button is the explicit path
    /// for resuming. The previous behavior (falling back to the most recently
    /// active session in the DB) would pick up cron/background sessions the
    /// user never interacted with; those can be garbage-collected by Hermes
    /// between the DB read and ACP `session/load`, producing a silent prompt
    /// failure with no UI feedback.
    private func autoStartACPAndSend(text: String) {
        // Show the user message immediately
        richChatViewModel.addUserMessage(text: text)

        Task { @MainActor in
            let sessionToResume = richChatViewModel.sessionId

            let client = ACPClient.forMacApp(context: context)
            self.acpClient = client

            do {
                try await client.start()
                acpStatus = await client.statusMessage
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                let cwd = await context.resolvedUserHome()

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
                acpStatus = "Failed"
                await recordACPFailure(error, client: client, context: "Auto-start ACP failed")
                hasActiveProcess = false
                acpClient = nil
            }
        }
    }

    /// If `text` is a `/<name> [args]` invocation matching a project-
    /// scoped slash command currently loaded into the view model, return
    /// the expanded prompt body (with `{{argument}}` substituted). Otherwise
    /// return the input unchanged.
    ///
    /// ACP commands and `quick_commands:` keep going to Hermes literally —
    /// only project-scoped commands get the client-side expansion treatment
    /// because Hermes has no concept of them.
    private func expandIfProjectScoped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return text }
        let withoutSlash = String(trimmed.dropFirst())
        let name: String
        let argument: String
        if let space = withoutSlash.firstIndex(of: " ") {
            name = String(withoutSlash[..<space])
            argument = String(withoutSlash[withoutSlash.index(after: space)...])
        } else {
            name = withoutSlash
            argument = ""
        }
        guard !name.isEmpty,
              let cmd = richChatViewModel.projectScopedCommand(named: name)
        else { return text }
        return ProjectSlashCommandService(context: context).expand(cmd, withArgument: argument)
    }

    private func sendViaACP(client: ACPClient, text: String) {
        guard let sessionId = richChatViewModel.sessionId else {
            clearACPErrorState()
            acpError = "No session ID — cannot send"
            return
        }

        // Don't duplicate user message if autoStartACPAndSend already added it
        if richChatViewModel.messages.last?.isUser != true
            || richChatViewModel.messages.last?.content != text {
            richChatViewModel.addUserMessage(text: text)
        }

        // Project-scoped slash commands expand client-side: the user
        // sees the literal `/<name> args` they typed (already in the
        // transcript as their bubble), but Hermes receives the expanded
        // prompt template. The literal slash is meaningless to Hermes
        // for project-scoped commands; this is what makes them portable
        // and Hermes-version-independent. v2.5.
        let wireText = expandIfProjectScoped(text)

        acpStatus = "Agent working..."
        acpPromptTask = Task { @MainActor in
            do {
                let result = try await client.sendPrompt(sessionId: sessionId, text: wireText)
                acpStatus = "Ready"
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: result)
                )
                // Re-fetch session from DB to pick up cost/token data Hermes may have written
                await richChatViewModel.refreshSessionFromDB()
            } catch is CancellationError {
                acpStatus = "Cancelled"
            } catch {
                acpStatus = "Error"
                await recordACPFailure(error, client: client, context: "ACP prompt failed")
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

    private func startACPSession(resume sessionId: String?, projectPath: String? = nil) {
        stopACP()
        clearACPErrorState()
        acpStatus = "Starting..."

        let client = ACPClient.forMacApp(context: context)
        self.acpClient = client
        let attribution = SessionAttributionService(context: context)

        // If the caller passed a project path, refresh the Scarf-
        // managed block in the project's AGENTS.md BEFORE starting
        // ACP — Hermes auto-reads AGENTS.md at session boot, so the
        // block has to land on disk first. Non-blocking on failure:
        // we log and proceed without the block. Safe on bare
        // projects (creates AGENTS.md with just the block); safe on
        // template-installed projects (splices the block into
        // existing AGENTS.md without touching template content).
        if let projectPath {
            let registry = ProjectDashboardService(context: context).loadRegistry()
            if let project = registry.projects.first(where: { $0.path == projectPath }) {
                do {
                    try ProjectAgentContextService(context: context).refresh(for: project)
                } catch {
                    logger.warning("couldn't refresh project context block for \(project.name): \(error.localizedDescription)")
                }
            }
        }

        Task { @MainActor in
            do {
                // Start ACP process and event loop FIRST
                try await client.start()
                acpStatus = await client.statusMessage
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                // Project-scoped chats pass the project's absolute path
                // as cwd so Hermes tool calls and subsequent ACP ops
                // resolve relative paths against the project's files.
                // Falls back to the user's home (existing v2.2 behavior)
                // when the caller didn't request a project scope.
                // `??` can't wrap an async autoclosure, so we
                // materialize the fallback with an if-let.
                let cwd: String
                if let projectPath {
                    cwd = projectPath
                } else {
                    cwd = await context.resolvedUserHome()
                }

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

                // Attribute this session to the project it was started
                // under, so the per-project Sessions tab can surface it
                // without a user action. No-op when projectPath is nil.
                // Idempotent: re-attribution of the same pair is free.
                if let projectPath {
                    attribution.attribute(
                        sessionID: resolvedSessionId,
                        toProjectPath: projectPath
                    )
                }

                // Resolve which project (if any) this session belongs
                // to, so SessionInfoBar + nav title can surface it.
                // Two inputs — use whichever is non-nil:
                //   * `projectPath` — the caller asked for a project
                //     scope (fresh project chat). Just-attributed;
                //     definitely in the sidecar.
                //   * `attribution.projectPath(for: resolvedSessionId)`
                //     — the resumed session was previously attributed.
                //     Covers "click an old project-attributed session
                //     from the global Sessions sidebar / Resume menu"
                //     where projectPath isn't known at the call site.
                let attributedPath = projectPath
                    ?? attribution.projectPath(for: resolvedSessionId)
                if let path = attributedPath {
                    // Look up a human-readable name from the projects
                    // registry. Missing project (path in the sidecar,
                    // project since removed) → show the path as a
                    // fallback label so the chip still renders and the
                    // user sees *something* rather than silently losing
                    // the indicator.
                    let registry = ProjectDashboardService(context: context).loadRegistry()
                    let name = registry.projects.first(where: { $0.path == path })?.name
                    self.currentProjectPath = path
                    self.currentProjectName = name ?? path
                    // Pull any project-scoped slash commands the user has
                    // authored at <path>/.scarf/slash-commands/ so the
                    // chat slash menu surfaces them. Async + non-fatal —
                    // the menu degrades to ACP + quick commands only on
                    // any failure (logged inside the service).
                    self.richChatViewModel.loadProjectScopedCommands(at: path)
                } else {
                    // Explicit clear on non-project sessions so the
                    // indicator doesn't leak from a previous chat.
                    self.currentProjectPath = nil
                    self.currentProjectName = nil
                    self.richChatViewModel.loadProjectScopedCommands(at: nil)
                }

                // Refresh session list so the new ACP session appears in the Resume menu
                await loadRecentSessions()

                logger.info("ACP session ready: \(resolvedSessionId)")
            } catch {
                acpStatus = "Failed"
                await recordACPFailure(error, client: client, context: "Failed to start ACP session")
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
        clearACPErrorState()

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

                let client = ACPClient.forMacApp(context: context)
                do {
                    try await client.start()

                    let cwd = await context.resolvedUserHome()
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
                    clearACPErrorState()

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
        clearACPErrorState()
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
        // Inherit ssh-agent socket for remote so password-less auth works.
        if context.isRemote {
            let shellEnv = HermesFileService.enrichedEnvironment()
            for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
                if env[key] == nil, let v = shellEnv[key], !v.isEmpty {
                    env[key] = v
                }
            }
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // For remote: wrap the invocation in `ssh -t host -- hermes <args>`
        // so the embedded terminal opens a pty against the remote and the
        // hermes TUI gets the bytes it expects. `-t` requests a pty (the
        // SwiftTerm view is one).
        let exe: String
        let argv: [String]
        if context.isRemote, case .ssh(let cfg) = context.kind {
            let host = cfg.user.map { "\($0)@\(cfg.host)" } ?? cfg.host
            exe = "/usr/bin/ssh"
            var sshArgs: [String] = ["-t"]
            if let port = cfg.port { sshArgs += ["-p", String(port)] }
            if let id = cfg.identityFile, !id.isEmpty { sshArgs += ["-i", id] }
            sshArgs += ["-o", "StrictHostKeyChecking=accept-new"]
            sshArgs += ["-o", "BatchMode=yes"]
            sshArgs.append(host)
            sshArgs.append("--")
            sshArgs.append(context.paths.hermesBinary)
            sshArgs.append(contentsOf: arguments)
            argv = sshArgs
        } else {
            exe = context.paths.hermesBinary
            argv = arguments
        }

        terminal.startProcess(
            executable: exe,
            args: argv,
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
