import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign
import os

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
    @State private var showSlashCommandsSheet = false

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
            projectContextBar
            messageList
            Divider()
            if let hint = controller.vm.transientHint {
                steeringToast(hint)
            }
            composer
        }
        .background(ScarfColor.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Principal: "Chat" title + small folder chip below when
            // the current session is project-attributed. iOS-native
            // equivalent of Mac's SessionInfoBar project-chip pattern.
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
            // Dashboard row taps set `pendingResumeSessionID`, Project
            // Detail's "New Chat" sets `pendingProjectChat`. Both fire
            // a tab switch to .chat alongside the value set; we
            // consume + clear here on first appear. Resume wins over
            // project-chat if both somehow get set in a single hop —
            // but in practice the coordinator never sets both at once.
            if let sessionID = coordinator?.pendingResumeSessionID {
                coordinator?.pendingResumeSessionID = nil
                await controller.startResuming(sessionID: sessionID)
            } else if let projectPath = coordinator?.pendingProjectChat {
                coordinator?.pendingProjectChat = nil
                await consumePendingProjectChat(projectPath)
            } else {
                await controller.start()
            }
        }
        // React to coordinator changes that happen while Chat is
        // already mounted (e.g., user is in Chat, taps Projects, opens
        // a project detail, taps "New Chat" — coordinator flips the
        // tab AND sets pendingProjectChat. The `.task` above only
        // fires on first appear; these are the mid-session hooks.)
        .onChange(of: coordinator?.pendingResumeSessionID) { _, new in
            guard let sessionID = new else { return }
            coordinator?.pendingResumeSessionID = nil
            Task { await controller.startResuming(sessionID: sessionID) }
        }
        .onChange(of: coordinator?.pendingProjectChat) { _, new in
            guard let projectPath = new else { return }
            coordinator?.pendingProjectChat = nil
            Task { await consumePendingProjectChat(projectPath) }
        }
        // Deliberately NOT tearing down the ACP session on .onDisappear.
        // `TabView` unmounts tab content when the user switches tabs
        // (disappear fires), but `@State var controller` keeps the
        // ChatController alive across those switches, so dropping the
        // SSH exec channel + re-opening on next appear would cost the
        // user a ~1-2s reconnect every time they hop to Dashboard
        // and back. The ACPClient stays open; the controller cleans up
        // properly when:
        //   - the user Disconnects / Forgets the server (RootModel
        //     flips out of .connected, whole tab root unmounts, and
        //     ChatController.deinit + transport teardown runs),
        //   - or the app goes to background (iOS will terminate the
        //     socket eventually if memory pressure hits anyway).
        // If a future iPad / multi-window variant wants to explicitly
        // pause idle connections, add a coordinator-driven stop() on
        // app-lifecycle phase changes instead.
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

    /// Resolve a project absolute path to a `ProjectEntry` via the
    /// transport-backed registry, then dispatch `resetAndStartInProject`.
    /// If the path isn't registered (race with a Mac-app removal, or
    /// SFTP read failure), fall back to a synthesized entry whose name
    /// is the path's last component — chat still starts and the user
    /// sees a usable project chip.
    private func consumePendingProjectChat(_ path: String) async {
        let ctx = config.toServerContext(id: Self.sharedContextID)
        let entry: ProjectEntry = await Task.detached {
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            if let match = registry.projects.first(where: { $0.path == path }) {
                return match
            }
            return ProjectEntry(
                name: (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent,
                path: path
            )
        }.value
        await controller.resetAndStartInProject(entry)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if controller.vm.messages.isEmpty, controller.state == .ready {
                    if controller.vm.sessionId != nil {
                        // Resumed-session path: session ID is set but
                        // no messages loaded. ACP-native sessions don't
                        // persist their transcript to state.db (only
                        // CLI/terminal sessions do), so resuming one
                        // reconnects to the agent but can't surface
                        // the history client-side. Explain to the user
                        // rather than showing a blank canvas.
                        resumedEmptyState
                    } else {
                        emptyState
                    }
                }
                ForEach(controller.vm.messages) { msg in
                    MessageBubble(
                        message: msg,
                        turnDuration: controller.vm.turnDuration(forMessageId: msg.id)
                    )
                    .equatable()
                    .id(msg.id)
                }
                if controller.vm.isGenerating {
                    HStack {
                        ProgressView()
                        Text("Agent is thinking…")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
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
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text("Connected to \(config.displayName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Friendlier-than-blank state for a session resumed from the
    /// Dashboard that had no transcript persisted to `state.db`.
    /// Hermes doesn't write ACP-native session messages to the
    /// client DB — only CLI/terminal sessions leave a history there —
    /// so resuming a "recent session" started via Chat means the
    /// agent has the context but the client can't replay it. The
    /// user can keep chatting and the agent will have full memory.
    @ViewBuilder
    private var resumedEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Session resumed")
                .font(.headline)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text("Hermes has the context for this session, but the transcript isn't cached locally. Send a message to continue.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    /// Soft pill above the composer confirming a non-interruptive
    /// command was received (e.g. `/steer`). Auto-clears via the
    /// 4-second Task in `ChatController.send()`.
    private func steeringToast(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .foregroundStyle(.tint)
                .font(.caption)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12))
        .transition(.opacity)
    }

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
                            .foregroundStyle(ScarfColor.foregroundMuted)
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
                            .foregroundStyle(ScarfColor.foregroundMuted)
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

    /// Contextual header rendered BELOW the navigation bar when the
    /// current session is scoped to a Scarf project. Sits full-width
    /// so the project name has room to breathe (the nav bar's
    /// `.principal` slot gets squeezed to icon-only by adjacent
    /// toolbar buttons on iPhone — exactly the pass-2 bug). Drawn as
    /// a subtle tinted strip so it doesn't dominate but is clearly
    /// informational.
    @ViewBuilder
    private var projectContextBar: some View {
        if let projectName = controller.currentProjectName,
           !projectName.isEmpty
        {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Project chat")
                        .font(.caption2)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    HStack(spacing: 6) {
                        Text(projectName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let branch = controller.currentGitBranch, !branch.isEmpty {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if !controller.vm.projectScopedCommands.isEmpty {
                    Button {
                        showSlashCommandsSheet = true
                    } label: {
                        Label(
                            "\(controller.vm.projectScopedCommands.count) slash",
                            systemImage: "slash.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.1))
            .sheet(isPresented: $showSlashCommandsSheet) {
                ProjectSlashCommandsBrowser(
                    projectName: projectName,
                    commands: controller.vm.projectScopedCommands
                )
            }
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
                .foregroundStyle(ScarfColor.foregroundMuted)
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
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal)
            Button("Retry") {
                Task { await controller.start() }
            }
            .buttonStyle(ScarfPrimaryButton())
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
    /// Display name of the Scarf project this session is scoped to,
    /// or nil for "quick chat" / global sessions. Surfaced as a
    /// subtitle under the "Chat" title in the nav bar so users can
    /// see at a glance which project the agent is operating inside.
    /// Set by `resetAndStartInProject` and by `startResuming` when
    /// the resumed session is attributed to a registered project.
    private(set) var currentProjectName: String?

    /// Git branch of the project's working directory at session start
    /// (v2.5). Nil for non-project sessions and projects that aren't
    /// git repos / have git missing on the host. Surfaced as a small
    /// chip on the right side of the project context bar.
    private(set) var currentGitBranch: String?

    private let context: ServerContext
    private var client: ACPClient?
    private var eventTask: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: "com.scarf.ios",
        category: "ChatController"
    )

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
        // /steer is non-interruptive — the agent is still on its
        // current turn; the guidance applies after the next tool call.
        // Surface a transient toast confirming the guidance was
        // received. v2.5 / Hermes v2026.4.23+.
        if vm.isNonInterruptiveSlash(text) {
            vm.transientHint = "Guidance queued — applies after the next tool call."
            Task { @MainActor [weak vm] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if vm?.transientHint == "Guidance queued — applies after the next tool call." {
                    vm?.transientHint = nil
                }
            }
        }
        // Project-scoped slash commands expand client-side: the user
        // bubble shows the literal `/<name> args` they typed (above);
        // Hermes receives the expanded prompt template body. Other
        // command sources (ACP, quick_commands) keep going to Hermes
        // literally. v2.5.
        let wireText = expandIfProjectScoped(text)
        do {
            _ = try await client.sendPrompt(sessionId: sessionId, text: wireText)
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

    /// Mirror of `ChatViewModel.expandIfProjectScoped(_:)` on Mac.
    /// `/<name> args` matching a loaded project-scoped command is
    /// expanded; everything else is sent literally.
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
              let cmd = vm.projectScopedCommand(named: name)
        else { return text }
        return ProjectSlashCommandService(context: context).expand(cmd, withArgument: argument)
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
        currentProjectName = nil
        currentGitBranch = nil
        // Quick-chat sessions don't have a project; clear any leftover
        // project-scoped slash commands from a prior session.
        vm.loadProjectScopedCommands(at: nil)
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
        currentProjectName = project.name
        currentGitBranch = nil
        // Pull any project-authored slash commands at
        // <project.path>/.scarf/slash-commands/ into the chat menu.
        // Async + non-fatal — degrades cleanly on SFTP failures (logged).
        vm.loadProjectScopedCommands(at: project.path)
        // v2.5 git branch indicator. Async + nil on failure — the chip
        // simply doesn't render if the project isn't a git repo.
        let ctx = context
        let projectPath = project.path
        Task { @MainActor [weak self] in
            let branch = await GitBranchService(context: ctx).branch(at: projectPath)
            if self?.currentProjectName == project.name {
                self?.currentGitBranch = branch
            }
        }
        // Synchronously load the slash command NAMES so we can list them
        // in the AGENTS.md block (the agent needs to know what commands
        // are available). This is a separate read from the async one
        // above because the block has to land on disk BEFORE `hermes acp`
        // boots — async loads might lose the race. Blocking load on a
        // detached task to keep the MainActor responsive.
        let slashNames: [String] = await Task.detached {
            ProjectSlashCommandService(context: ctx)
                .loadCommands(at: projectPath)
                .map(\.name)
        }.value
        // Write the context block first. Non-fatal on failure — chat
        // still starts, just without the managed block. We capture the
        // failure (rather than swallowing via `try?`) so the user gets
        // a yellow banner explaining the agent won't see project context
        // for this session, with the underlying error in "Show details".
        let block = ProjectContextBlock.renderMinimalBlock(
            projectName: project.name,
            projectPath: project.path,
            slashCommandNames: slashNames
        )
        let writeResult: Result<Void, Error> = await Task.detached {
            do {
                try ProjectContextBlock.writeBlock(
                    block,
                    forProjectAt: projectPath,
                    context: ctx
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = writeResult {
            Self.logger.error(
                "ProjectContextBlock.writeBlock failed for \(projectPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            vm.acpError = "Project context not written — agent will proceed without it."
            vm.acpErrorHint = "Check that the SSH user can write to \(projectPath)/AGENTS.md."
            vm.acpErrorDetails = error.localizedDescription
        }
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
            // attribution so Dashboard's Sessions tab can render the
            // project badge for it. Best-effort and intentionally fire-
            // and-forget — `SessionAttributionService.persist` already
            // logs SFTP failures via `os.Logger` (see the
            // `Self.logger.error` in `persist`), and a failed write
            // here is purely cosmetic: the chat works, only the badge
            // is missing until the next reconcile. We deliberately
            // don't surface this to the chat banner because it would
            // alarm users about a non-issue.
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
        // Clear eagerly so a lingering project name from a prior
        // session doesn't flash onto the new header while the
        // attribution lookup runs.
        currentProjectName = nil
        // Resolve the project name for this session (if any) via the
        // attribution sidecar + project registry. Set BEFORE the ACP
        // handshake so the nav-bar subtitle is visible the moment the
        // "Connecting…" overlay disappears. Run off-thread so we
        // don't block while the SFTP reads happen. Empty-string names
        // are treated as nil — registry entries should never have
        // empty names in practice, but guard against a surprise
        // JSON-decode edge case that would render just a folder icon
        // with no text (pass-2 bug: user saw exactly that).
        let ctx = context
        // Resolve both the path AND the name so we can (a) render the
        // header chip with the name and (b) load any project-scoped
        // slash commands at the project's `.scarf/slash-commands/` dir.
        let resolved: (path: String, name: String)? = await Task.detached {
            let attribution = SessionAttributionService(context: ctx)
            guard let path = attribution.projectPath(for: sessionID) else { return nil }
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            guard let name = registry.projects.first(where: { $0.path == path })?.name,
                  !name.isEmpty
            else { return nil }
            return (path: path, name: name)
        }.value
        currentProjectName = resolved?.name
        currentGitBranch = nil
        vm.loadProjectScopedCommands(at: resolved?.path)
        // v2.5 git branch indicator for the resumed-session header.
        if let resumePath = resolved?.path {
            let resolvedName = resolved?.name
            Task { @MainActor [weak self] in
                let branch = await GitBranchService(context: ctx).branch(at: resumePath)
                // Guard against a project switch landing while we
                // were resolving — only set if the chat hasn't moved.
                if self?.currentProjectName == resolvedName {
                    self?.currentGitBranch = branch
                }
            }
        }

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
            // Pull the transcript out of state.db so the user sees
            // everything said up to now. Mirrors the Mac resume flow
            // (scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:376).
            // `loadSessionHistory` refreshes the SQLite snapshot first
            // so we pick up messages Hermes wrote between the
            // Dashboard's last load and now.
            await vm.loadSessionHistory(
                sessionId: sessionID,
                acpSessionId: resolvedID == sessionID ? nil : resolvedID
            )
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

private struct MessageBubble: View, Equatable {
    let message: HermesMessage
    /// Wall-clock duration of the agent turn this assistant message
    /// belongs to (v2.5). Renders as a small `4.2s` pill below the
    /// bubble when present. Nil for user / streaming / pre-v2.5
    /// resumed messages.
    var turnDuration: TimeInterval? = nil

    /// SwiftUI body short-circuit (issue #46 — iOS path). On iOS the
    /// chat list is `LazyVStack` over `controller.vm.messages` directly
    /// (no message-group layer), so every visible bubble re-evaluates
    /// its body on each streamed chunk because `messages` mutates and
    /// the `@Observable` VM invalidates anyone reading it. Without
    /// equatable short-circuiting, every visible bubble re-runs
    /// `ChatContentFormatter.segments` + `AttributedString(markdown:)`
    /// per chunk — CPU-expensive on phones, especially with long
    /// content already on screen.
    ///
    /// Streaming message has `id == 0` (shared with Mac via
    /// `RichChatViewModel.streamingId`); it correctly redraws on
    /// every chunk via the content/reasoning/toolCalls.count compare.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        guard lhs.message.id == rhs.message.id else { return false }
        if lhs.message.id == 0 {
            return lhs.message.content == rhs.message.content
                && lhs.message.reasoning == rhs.message.reasoning
                && lhs.message.reasoningContent == rhs.message.reasoningContent
                && lhs.message.toolCalls.count == rhs.message.toolCalls.count
                && lhs.turnDuration == rhs.turnDuration
        }
        return lhs.turnDuration == rhs.turnDuration
            && lhs.message.tokenCount == rhs.message.tokenCount
            && lhs.message.finishReason == rhs.message.finishReason
    }

    var body: some View {
        if message.isToolResult {
            ToolResultRow(message: message)
        } else {
            HStack(alignment: .bottom) {
                if message.isUser { Spacer(minLength: 40) }
                VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                    // v2.5: prefer reasoning_content (Hermes v0.11+);
                    // fall back to legacy reasoning when only it's set.
                    if message.hasReasoning, let r = message.preferredReasoning, !r.isEmpty {
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
                    // Per-turn stopwatch — assistant only, when the
                    // turn duration was captured (live ACP turns).
                    if !message.isUser, let seconds = turnDuration {
                        Text(RichChatViewModel.formatTurnDuration(seconds))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(ScarfColor.onAccent)
                .background(
                    UnevenRoundedRectangle(cornerRadii:
                        .init(topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14))
                        .fill(ScarfColor.accent)
                )
                .textSelection(.enabled)
                .contextMenu { messageContextMenu }
        } else {
            HStack(alignment: .top, spacing: 8) {
                // Assistant avatar — rust gradient sparkles tile,
                // matches the Mac side and the ScarfChatView reference.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ScarfGradient.brand)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "sparkles")
                            .foregroundStyle(.white)
                            .font(.system(size: 10, weight: .semibold))
                    )
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
                .padding(.vertical, 10)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )
                .contextMenu { messageContextMenu }
            }
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
                        .foregroundStyle(ScarfColor.foregroundMuted)
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
                .foregroundStyle(ScarfColor.foregroundMuted)
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
                .foregroundStyle(ScarfColor.foregroundMuted)
                .italic()
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.caption)
                Text("REASONING")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.5)
            }
            .foregroundStyle(ScarfColor.warning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(ScarfColor.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(ScarfColor.warning.opacity(0.30), lineWidth: 1)
                )
        )
    }
}

/// Expanding card for a single `HermesToolCall` — kind-tinted with
/// uppercase tracked label, matches the Mac ToolCallCard treatment.
private struct ToolCallCard: View {
    let call: HermesToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: call.toolKind.icon)
                            .foregroundStyle(toolColor)
                            .font(.caption2)
                        Text(toolLabel)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .tracking(0.4)
                            .foregroundStyle(toolColor)
                    }
                    Text(call.functionName)
                        .font(.caption.monospaced())
                        .fontWeight(.semibold)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Text(call.argumentsSummary.prefix(60))
                        .font(.caption.monospaced())
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(toolColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(toolColor.opacity(0.30), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(call.arguments)
                    .font(.caption2.monospaced())
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(ScarfColor.backgroundSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(ScarfColor.border, lineWidth: 1)
                            )
                    )
                    .padding(.leading, 4)
            }
        }
    }

    private var toolLabel: String {
        switch call.toolKind {
        case .read: return "READ"
        case .edit: return "EDIT"
        case .execute: return "EXECUTE"
        case .fetch: return "FETCH"
        case .browser: return "BROWSER"
        case .other: return "TOOL"
        }
    }

    private var toolColor: Color {
        switch call.toolKind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
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
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text("Tool output")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
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
                        .foregroundStyle(ScarfColor.foregroundMuted)
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
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .padding(.vertical, 4)
                }

                Section("Your response") {
                    // Visual numbering 1-9 matches the Mac sheet's
                    // keyboard shortcuts; on iPhone the numbers serve
                    // as a hierarchy hint rather than an accelerator
                    // (no hardware keyboard binding). Mirrors the new
                    // Hermes v2026.4.23 TUI pattern.
                    ForEach(Array(permission.options.enumerated()), id: \.element.optionId) { idx, opt in
                        Button {
                            Task {
                                await onRespond(opt.optionId)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                if idx < 9 {
                                    Text("\(idx + 1).")
                                        .font(.body.monospaced())
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                }
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
