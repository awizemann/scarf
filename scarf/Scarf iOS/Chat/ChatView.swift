import SwiftUI
import ScarfCore
import ScarfIOS

// The Chat feature on iOS is gated on `canImport(SQLite3)` because
// `RichChatViewModel` reads session history from `HermesDataService`
// (which is itself SQLite3-gated). iOS always has SQLite3 available,
// so on any real iOS build this renders normally. The guard exists
// so ScarfCore-agnostic static analysis doesn't choke.
#if canImport(SQLite3)

/// M4 iOS Chat: streams JSON-RPC over a Citadel SSH exec channel to a
/// remote `hermes acp` process. Reuses ScarfCore's `RichChatViewModel`
/// state machine (from M0d) + `ACPClient` (from M1).
///
/// Scope: one active session, rich-chat mode only (no terminal /
/// SwiftTerm mode). Permission prompts, tool-call display, markdown,
/// voice — all deferred to M5+ polish.
struct ChatView: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle

    @Environment(\.scarfGoCoordinator) private var coordinator
    @Environment(\.serverContext) private var envContext
    @State private var controller: ChatController
    @State private var showProjectPicker = false

    init(config: IOSServerConfig, key: SSHKeyBundle) {
        self.config = config
        self.key = key
        let ctx = config.toServerContext(id: Self.sharedContextID)
        _controller = State(initialValue: ChatController(context: ctx))
    }

    /// Same UUID DashboardView uses, so the transport's cached SSH
    /// connection (if still open) can be reused when the user hops
    /// between Chat and Dashboard.
    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    var body: some View {
        VStack(spacing: 0) {
            errorBanner
            messageList
            Divider()
            composer
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showProjectPicker = true
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .disabled(controller.state == .connecting)
            }
        }
        .sheet(isPresented: $showProjectPicker) {
            ProjectPickerSheet(
                context: config.toServerContext(id: Self.sharedContextID),
                onQuickChat: {
                    Task { await controller.resetAndStartNewSession() }
                },
                onProject: { project in
                    Task { await controller.resetAndStartInProject(project) }
                }
            )
        }
        .task {
            // Dashboard row taps set `pendingResumeSessionID` on the
            // coordinator before switching to the Chat tab. Honor
            // that if present, else open a fresh session. Clearing
            // the coordinator value is the consumer's responsibility
            // (us) — otherwise a later plain tap on the Chat tab
            // would accidentally re-resume the old session.
            if let sessionID = coordinator?.pendingResumeSessionID {
                coordinator?.pendingResumeSessionID = nil
                await controller.startResuming(sessionID: sessionID)
            } else {
                await controller.start()
            }
        }
        // Also react to a coordinator change that happens while Chat
        // is already mounted (e.g., user is in Chat, switches to
        // Dashboard, taps a session row — coordinator flips the tab
        // AND sets pendingResumeSessionID. The `.task` above only
        // fires on first appear; this is the mid-session hook.)
        .onChange(of: coordinator?.pendingResumeSessionID) { _, new in
            guard let sessionID = new else { return }
            coordinator?.pendingResumeSessionID = nil
            Task { await controller.startResuming(sessionID: sessionID) }
        }
        .onDisappear {
            Task { await controller.stop() }
        }
        .overlay {
            if case .failed(let msg) = controller.state {
                errorOverlay(msg)
            } else if controller.state == .connecting {
                connectingOverlay
            }
        }
        .sheet(item: Binding(
            get: { controller.vm.pendingPermission.map(PermissionWrapper.init) },
            set: { if $0 == nil { controller.vm.pendingPermission = nil } }
        )) { wrapper in
            PermissionSheet(permission: wrapper.value) { optionId in
                await controller.respondToPermission(
                    requestId: wrapper.value.requestId,
                    optionId: optionId
                )
            }
            // Custom detents — `.medium` is either too tall (empty
            // space above) or too short (options clipped). A 220pt
            // peek shows the prompt + first ~3 options; users can
            // drag to large for long option lists.
            .presentationDetents([.height(220), .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if controller.vm.messages.isEmpty, controller.state == .ready {
                    emptyState
                }
                ForEach(controller.vm.messages) { msg in
                    MessageBubble(message: msg)
                        .id(msg.id)
                }
                if controller.vm.isGenerating {
                    HStack {
                        ProgressView()
                        Text("Agent is thinking…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                } else if controller.vm.isPostProcessing {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("Finishing up…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        // iOS 17+ keeps the scroll pinned to the newest content at
        // the bottom; iOS 18's `.sizeChanges` variant also tracks
        // when a message grows (streaming chunks, Expand-all on a
        // code block). Replaces the old manual proxy.scrollTo dance
        // which fought with the user's own scroll gestures.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Ask Hermes something")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Connected to \(config.displayName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Message…",
                text: $controller.draft,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .disabled(controller.state != .ready)
            .submitLabel(.send)
            .onSubmit {
                Task { await controller.send() }
            }

            Button {
                Task { await controller.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(controller.state != .ready || controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @State private var showErrorDetails: Bool = false

    /// Inline error banner rendered above the message list when the
    /// ACP layer signals a non-retryable failure (provider HTTP 4xx,
    /// malformed model, missing credentials…). Mirrors the Mac pattern
    /// in scarf/scarf/Features/Chat/Views/ChatView.swift:errorBanner;
    /// both now pull from RichChatViewModel's shared error triplet.
    /// Pass-1 M7 #2 — previously errors vanished into stderr and the
    /// user saw a perpetual spinner.
    @ViewBuilder
    private var errorBanner: some View {
        if let err = controller.vm.acpError {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if let hint = controller.vm.acpErrorHint {
                            Text(hint)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(showErrorDetails ? nil : 2)
                    }
                    Spacer(minLength: 4)
                    if controller.vm.acpErrorDetails != nil {
                        Button(showErrorDetails ? "Hide" : "Details") {
                            showErrorDetails.toggle()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    Button {
                        let payload = [
                            controller.vm.acpErrorHint,
                            err,
                            controller.vm.acpErrorDetails
                        ]
                            .compactMap { $0 }
                            .joined(separator: "\n\n")
                        UIPasteboard.general.string = payload
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                if showErrorDetails, let details = controller.vm.acpErrorDetails {
                    ScrollView(.vertical) {
                        Text(details)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
        }
    }

    /// Shown while we're opening the SSH exec channel + spawning
    /// `hermes acp` + creating the ACP session. Typically ~0.5–1.5 s
    /// on a warm network — silent before this overlay existed, which
    /// made the app feel frozen (pass-1 M7 #3).
    @ViewBuilder
    private var connectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(config.displayName)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Chat connection failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Retry") {
                Task { await controller.start() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}

// MARK: - ChatController

/// Owns the ACPClient + RichChatViewModel lifecycle for one iOS chat
/// screen. Kept out of `ChatView.body` so SwiftUI view re-renders don't
/// spawn or tear down SSH connections unintentionally.
@Observable
@MainActor
final class ChatController {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    var vm: RichChatViewModel
    var draft: String = ""

    private let context: ServerContext
    private var client: ACPClient?
    private var eventTask: Task<Void, Never>?

    init(context: ServerContext) {
        self.context = context
        self.vm = RichChatViewModel(context: context)
    }

    /// Open the SSH exec channel, send ACP `initialize`, then
    /// `session/new` — so that by the time `state == .ready` the user
    /// can type and hit send immediately.
    func start() async {
        if state == .connecting || state == .ready { return }
        state = .connecting
        vm.reset()
        let client = ACPClient.forIOSApp(
            context: context,
            keyProvider: {
                let store = KeychainSSHKeyStore()
                guard let key = try await store.load() else {
                    throw SSHKeyStoreError.backendFailure(
                        message: "No SSH key in Keychain — re-run onboarding.",
                        osStatus: nil
                    )
                }
                return key
            }
        )
        self.client = client

        // Hand the VM a closure that can fetch the ACPClient's recent
        // stderr when it needs to enrich the error banner on a non-
        // retryable `promptComplete` (pass-1 M7 #2). The VM caches
        // this; we only need to set it once per client.
        vm.acpStderrProvider = { [weak client] in
            await client?.recentStderr ?? ""
        }

        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            return
        }

        // Start streaming ACP events into the view-model BEFORE we
        // send session/new, so the `available_commands_update`
        // notification that the server sends on session init is
        // captured.
        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await MainActor.run {
                    self.vm.handleACPEvent(event)
                }
            }
        }

        // Create a fresh ACP session. `cwd` is the remote user's home
        // directory — Hermes defaults to that for tool scoping.
        do {
            let home = await context.resolvedUserHome()
            let sessionId = try await client.newSession(cwd: home)
            vm.setSessionId(sessionId)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            await stop()
        }
    }

    /// Send the current draft as a prompt. Fire-and-forget — the
    /// assistant reply streams back as ACP notifications handled by
    /// the event task.
    func send() async {
        guard state == .ready, let client else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let sessionId = vm.sessionId ?? ""
        guard !sessionId.isEmpty else { return }
        draft = ""
        vm.addUserMessage(text: text)
        do {
            _ = try await client.sendPrompt(sessionId: sessionId, text: text)
        } catch {
            // The event task may already have surfaced a
            // .connectionLost; show the send-time error only if the
            // state didn't already fail. Always populate the error
            // banner so the user sees actionable detail regardless
            // of which path raised first (M7 #2).
            await vm.recordACPFailure(error, client: client)
            if case .ready = state {
                state = .failed("Prompt failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stop the current session + tear down the SSH exec channel.
    /// Idempotent.
    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        if let client {
            await client.stop()
        }
        client = nil
        state = .idle
    }

    /// User tapped "New chat". Stop, reset the VM, start again.
    func resetAndStartNewSession() async {
        await stop()
        vm.reset()
        await start()
    }

    /// User tapped "In project… <project>". Stop, reset, and start
    /// with the project's path as cwd. Writes the Scarf-managed
    /// AGENTS.md block via ProjectContextBlock BEFORE spawning `hermes
    /// acp`, so Hermes sees the project context at boot. Records the
    /// returned session id in the attribution sidecar.
    func resetAndStartInProject(_ project: ProjectEntry) async {
        await stop()
        vm.reset()
        // Write the context block first. Non-fatal on failure — chat
        // still starts, just without the managed block; the user sees
        // the error via controller.state if it escalates.
        let block = ProjectContextBlock.renderMinimalBlock(
            projectName: project.name,
            projectPath: project.path
        )
        let ctx = context
        await Task.detached {
            try? ProjectContextBlock.writeBlock(
                block,
                forProjectAt: project.path,
                context: ctx
            )
        }.value
        await start(projectPath: project.path, projectName: project.name)
    }

    /// Inline variant of `start()` that accepts a cwd + attribution
    /// hooks. The default `start()` delegates to this with nil project
    /// fields, so the ACP code path stays single-sourced.
    private func startInternal(
        projectPath: String?,
        projectName: String?
    ) async {
        if state == .connecting || state == .ready { return }
        state = .connecting
        let client = ACPClient.forIOSApp(
            context: context,
            keyProvider: {
                let store = KeychainSSHKeyStore()
                guard let key = try await store.load() else {
                    throw SSHKeyStoreError.backendFailure(
                        message: "No SSH key in Keychain — re-run onboarding.",
                        osStatus: nil
                    )
                }
                return key
            }
        )
        self.client = client
        vm.acpStderrProvider = { [weak client] in
            await client?.recentStderr ?? ""
        }

        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            return
        }

        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await MainActor.run {
                    self.vm.handleACPEvent(event)
                }
            }
        }

        do {
            // Use the project's path as cwd when provided; else the
            // remote user's home, matching the pre-M9 default.
            let cwd: String
            if let projectPath {
                cwd = projectPath
            } else {
                cwd = await context.resolvedUserHome()
            }
            let sessionId = try await client.newSession(cwd: cwd)
            vm.setSessionId(sessionId)
            state = .ready

            // If this was a project-scoped session, record the
            // attribution so the Mac's per-project Sessions tab picks
            // it up. Best-effort — ACP session creation already won,
            // a failed attribution write is cosmetic.
            if let projectPath {
                let ctx = context
                Task.detached {
                    SessionAttributionService(context: ctx)
                        .attribute(sessionID: sessionId, toProjectPath: projectPath)
                }
            }
            _ = projectName // reserved for future chat-header chip
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            await stop()
        }
    }

    /// Public entry used internally by resetAndStartInProject.
    func start(projectPath: String, projectName: String) async {
        await startInternal(projectPath: projectPath, projectName: projectName)
    }

    /// Resume an existing ACP session. Called from ChatView when the
    /// coordinator carries a `pendingResumeSessionID` (Dashboard row
    /// tap). If we're currently on a different session, stop first
    /// so there's no phantom ACP process hanging around. Falls back
    /// to `session/load` if the remote doesn't support `session/resume`
    /// (Hermes < 0.9.x).
    func startResuming(sessionID: String) async {
        await stop()
        vm.reset()
        state = .connecting
        let client = ACPClient.forIOSApp(
            context: context,
            keyProvider: {
                let store = KeychainSSHKeyStore()
                guard let key = try await store.load() else {
                    throw SSHKeyStoreError.backendFailure(
                        message: "No SSH key in Keychain — re-run onboarding.",
                        osStatus: nil
                    )
                }
                return key
            }
        )
        self.client = client
        vm.acpStderrProvider = { [weak client] in
            await client?.recentStderr ?? ""
        }

        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            return
        }

        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await MainActor.run {
                    self.vm.handleACPEvent(event)
                }
            }
        }

        do {
            let home = await context.resolvedUserHome()
            // Prefer `session/resume` for true resume semantics
            // (same session id preserved in state.db); fall back to
            // `session/load` if the remote doesn't know resume.
            let resolvedID: String
            do {
                resolvedID = try await client.resumeSession(cwd: home, sessionId: sessionID)
            } catch {
                resolvedID = try await client.loadSession(cwd: home, sessionId: sessionID)
            }
            vm.setSessionId(resolvedID)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            await stop()
        }
    }

    /// Dispatch the user's answer to a pending permission request.
    /// Called by `PermissionSheet`.
    func respondToPermission(requestId: Int, optionId: String) async {
        guard let client else { return }
        await client.respondToPermission(requestId: requestId, optionId: optionId)
        vm.pendingPermission = nil
    }
}

/// `Identifiable` wrapper so SwiftUI's `.sheet(item:)` can key off
/// the pending permission. Two permissions for the same request-id
/// are treated as identical (rare — would only happen if the remote
/// sends a duplicate).
private struct PermissionWrapper: Identifiable {
    let value: RichChatViewModel.PendingPermission
    var id: Int { value.requestId }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: HermesMessage

    var body: some View {
        if message.isToolResult {
            ToolResultRow(message: message)
        } else {
            HStack(alignment: .bottom) {
                if message.isUser { Spacer(minLength: 40) }
                VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                    if message.hasReasoning, let r = message.reasoning, !r.isEmpty {
                        ReasoningDisclosure(reasoning: r)
                    }
                    // Only render the bubble when there's actual text
                    // to show. Assistant messages can exist in a
                    // "reasoning-only" or "tool-calls-only" state
                    // while the agent is thinking / invoking tools —
                    // rendering an empty gray bubble next to every
                    // "Thinking…" disclosure looked like a ghost
                    // message. User bubbles we always render (the
                    // user explicitly submitted content, even if
                    // it's just whitespace, they saw it land).
                    if message.isUser || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        bubbleContent
                    }
                    if !message.toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.toolCalls) { call in
                                ToolCallCard(call: call)
                            }
                        }
                    }
                }
                if !message.isUser { Spacer(minLength: 40) }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        // User bubbles are plain text — no reason to parse what the
        // user just typed. Assistant bubbles route through the
        // ChatContentFormatter so fenced code blocks get horizontal
        // scrolling instead of soft-wrapping into ugly 4-line
        // vertical columns on an iPhone.
        if message.isUser {
            Text(message.content)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
                .contextMenu { messageContextMenu }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ChatContentFormatter.segments(for: message.content).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let body):
                        Self.markdownText(body)
                            .font(.body)
                            .textSelection(.enabled)
                    case .code(let lang, let body):
                        CodeBlockView(language: lang, body: body)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Color.primary)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contextMenu { messageContextMenu }
        }
    }

    /// Shared context-menu actions for user + assistant bubbles.
    /// Copy is the most-used action; Share hands off to the system
    /// share sheet via ShareLink. Regenerate is intentionally absent —
    /// ACP doesn't support it natively and the pattern would require
    /// non-trivial session-state surgery.
    @ViewBuilder
    private var messageContextMenu: some View {
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        ShareLink(item: message.content) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    /// Parses message text as markdown for the assistant side. Text-
    /// only segments coming from ChatContentFormatter can contain
    /// inline backticks / bold / links; `.inlineOnlyPreservingWhitespace`
    /// preserves newlines + spacing and won't mangle the output if
    /// the input isn't valid markdown.
    private static func markdownText(_ body: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: body,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(body)
    }
}

/// Horizontally-scrollable fenced code block. ~240pt max height
/// collapsed (Expand button reveals full height). Monospaced
/// .footnote font keeps the bubble narrow enough to still show
/// adjacent text on the same screen. Language label is a tiny
/// header when present.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var expanded = false

    private let collapsedMaxHeight: CGFloat = 240

    init(language: String?, body: String) {
        self.language = language
        self.code = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let lang = language, !lang.isEmpty {
                    Text(lang.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? "Collapse" : "Expand") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: expanded ? nil : collapsedMaxHeight)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Inline, expandable "chain-of-thought" disclosure shown above the
/// assistant's primary message when the remote surfaces `reasoning`.
/// Collapsed by default so a chatty model doesn't dominate the scroll
/// position.
private struct ReasoningDisclosure: View {
    let reasoning: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label("Thinking…", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

/// Expanding card for a single `HermesToolCall` — shows function name
/// + summary collapsed; full JSON arguments expanded.
private struct ToolCallCard: View {
    let call: HermesToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .foregroundStyle(.tint)
                    Text(call.functionName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                    Text(call.argumentsSummary.prefix(60))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(call.arguments)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
    }

    private var iconName: String {
        call.toolKind.icon
    }
}

/// Row showing a tool-result (role="tool"). Styled as a small
/// quoted block beneath whichever assistant message preceded it.
private struct ToolResultRow: View {
    let message: HermesMessage
    @State private var isExpanded = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Tool output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(message.content.prefix(80))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if isExpanded {
                    Text(message.content)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemBackground))
            )
            Spacer(minLength: 40)
        }
        .padding(.horizontal)
    }
}

// MARK: - Permission sheet

/// Sheet presented when the remote asks for permission (e.g.,
/// "allow write to /etc/hosts"). Renders the VM's `PendingPermission`
/// options as tappable buttons. Tapping responds via the ChatController
/// which dispatches the answer over the ACP channel.
private struct PermissionSheet: View {
    let permission: RichChatViewModel.PendingPermission
    let onRespond: (_ optionId: String) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(permission.title)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text("Kind: \(permission.kind)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Your response") {
                    ForEach(permission.options, id: \.optionId) { opt in
                        Button {
                            Task {
                                await onRespond(opt.optionId)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(opt.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Agent permission")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#endif // canImport(SQLite3)

// Empty shim so the file compiles on platforms without SQLite3 — the
// target never runs there, but the typechecker visits the file.
#if !canImport(SQLite3)
struct ChatView: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle
    var body: some View {
        Text("Chat requires SQLite3 — this platform is not supported.")
    }
}
#endif
