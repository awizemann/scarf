import SwiftUI

struct ChatView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showErrorDetails = false

    var body: some View {
        @Bindable var vm = viewModel
        @Bindable var coord = coordinator
        VStack(spacing: 0) {
            toolbar
            Divider()
            errorBanner
            chatArea
        }
        // Clamp the outer VStack to the detail column's offered
        // space. Without this, the chat area's intrinsic height (a
        // RichChatView whose message list grows with content) can
        // bubble up through NavigationSplitView's detail slot and
        // push the whole window past the screen. Same pattern as
        // the Sessions tab fix in the v2.3 branch.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v2.3: reflect the active Scarf project in the nav title
        // so the user can see at a glance that the chat is scoped
        // (complements the folder chip in SessionInfoBar). Falls
        // back to the plain "Chat" label for global chats.
        .navigationTitle(
            viewModel.currentProjectName.map { "Chat · \($0)" } ?? "Chat"
        )
        .task {
            await viewModel.loadRecentSessions()
            viewModel.refreshCredentialPreflight()
            // Cold-launch handoff: if the user clicked "New Chat" on
            // a project before ChatView had a chance to render, the
            // coordinator was already populated. Consume the request
            // here. The onChange below handles the live case.
            if let pending = coordinator.pendingProjectChat {
                coordinator.pendingProjectChat = nil
                viewModel.startNewSession(projectPath: pending)
            }
            // Same story for resume-session handoff: the user clicked
            // a session in the Projects Sessions tab (routes to `.chat`
            // rather than `.sessions` so the chat actually reopens).
            // SessionsView consumes `selectedSessionId` for its own
            // routing; Chat now consumes it too. Mutually exclusive at
            // any given render because only one section is active per
            // `coordinator.selectedSection`. `else if` makes precedence
            // explicit — pendingProjectChat (new) outranks
            // selectedSessionId (resume) when both are somehow set.
            else if let pendingId = coordinator.selectedSessionId {
                coordinator.selectedSessionId = nil
                viewModel.resumeSession(pendingId)
            }
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.loadRecentSessions() }
            viewModel.refreshCredentialPreflight()
        }
        // Live handoff from the per-project Sessions tab: the tab
        // sets `pendingProjectChat` + flips `selectedSection` to
        // `.chat`; this view consumes the path and starts a fresh
        // session with cwd=projectPath. Attribution happens inside
        // ChatViewModel on successful session creation.
        .onChange(of: coord.pendingProjectChat) { _, new in
            if let projectPath = new {
                coordinator.pendingProjectChat = nil
                viewModel.startNewSession(projectPath: projectPath)
            }
        }
        // Live handoff for resume: user clicked an existing session in
        // the Projects Sessions tab while already in the Chat section
        // (or switched back to Chat after). Project-chip rendering
        // happens automatically inside ChatViewModel.resumeSession ->
        // startACPSession via the attribution.projectPath(for:) lookup.
        .onChange(of: coord.selectedSessionId) { _, new in
            if let sessionId = new {
                coordinator.selectedSessionId = nil
                viewModel.resumeSession(sessionId)
            }
        }
    }

    /// Banner rendered between the toolbar and the chat area when either
    /// (a) a preflight credential check failed, or (b) the ACP subprocess
    /// returned an error we captured. Shows a short hint + expandable raw
    /// details (stderr tail) that the user can copy to the clipboard.
    @ViewBuilder
    private var errorBanner: some View {
        if let err = viewModel.acpError {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if let hint = viewModel.acpErrorHint {
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
                    Spacer()
                    if viewModel.acpErrorDetails != nil {
                        Button(showErrorDetails ? "Hide details" : "Show details") {
                            showErrorDetails.toggle()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    Button {
                        let payload = [viewModel.acpErrorHint, err, viewModel.acpErrorDetails]
                            .compactMap { $0 }
                            .joined(separator: "\n\n")
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(payload, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy error details")
                }
                if showErrorDetails, let details = viewModel.acpErrorDetails {
                    ScrollView {
                        Text(details)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .overlay(
                Rectangle()
                    .fill(Color.orange.opacity(0.25))
                    .frame(height: 1),
                alignment: .bottom
            )
        } else if viewModel.missingCredentials && !viewModel.hasActiveProcess {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No AI provider credentials detected")
                        .font(.callout)
                    Text("Add credentials in **Configure → Credential Pools**, set `ANTHROPIC_API_KEY` (or similar) in `~/.hermes/.env`, or export it in your shell profile, then restart Scarf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .overlay(
                Rectangle()
                    .fill(Color.orange.opacity(0.25))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.displayMode == .terminal ? "terminal" : "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)

            if viewModel.hasActiveProcess {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                (viewModel.acpStatus.isEmpty ? Text("Active") : Text(viewModel.acpStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let error = viewModel.acpError {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
                if let sid = viewModel.richChatViewModel.sessionId {
                    Button("Reconnect") {
                        viewModel.resumeSession(sid)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if !viewModel.acpStatus.isEmpty {
                Circle()
                    .fill(.yellow)
                    .frame(width: 6, height: 6)
                Text(viewModel.acpStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                Text("No active session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.hasActiveProcess && viewModel.displayMode == .terminal {
                voiceControls
            }

            Picker("View", selection: Bindable(viewModel).displayMode) {
                Image(systemName: "terminal")
                    .help("Terminal")
                    .tag(ChatDisplayMode.terminal)
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .help("Rich Chat")
                    .tag(ChatDisplayMode.richChat)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if !viewModel.hermesBinaryExists {
                Label("Hermes binary not found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Menu {
                if viewModel.hasActiveProcess, let activeId = viewModel.richChatViewModel.sessionId {
                    Button("Return to Active Session (\(activeId.prefix(8))...)") {
                        viewModel.richChatViewModel.requestScrollToBottom()
                    }
                    Divider()
                }
                Button("New Session") {
                    viewModel.startNewSession()
                }
                Button("Continue Last Session") {
                    viewModel.continueLastSession()
                }
                if !viewModel.recentSessions.isEmpty {
                    Divider()
                    Text("Resume Session")
                    let activeSessionId = viewModel.richChatViewModel.sessionId
                    let originSessionId = viewModel.richChatViewModel.originSessionId
                    ForEach(viewModel.recentSessions) { session in
                        Button {
                            viewModel.resumeSession(session.id)
                        } label: {
                            HStack {
                                Text(viewModel.previewFor(session))
                                    .lineLimit(1)
                                if let date = session.startedAt {
                                    Text("·")
                                        .foregroundStyle(.secondary)
                                    Text(date, style: .relative)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(session.id == activeSessionId || session.id == originSessionId)
                    }
                }
            } label: {
                Label("Session", systemImage: "play.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var voiceControls: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.toggleVoice()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.voiceEnabled ? "mic.fill" : "mic.slash")
                        .foregroundStyle(viewModel.voiceEnabled ? .green : .secondary)
                    (viewModel.voiceEnabled ? Text("Voice On") : Text("Voice Off"))
                        .font(.caption)
                        .foregroundStyle(viewModel.voiceEnabled ? .primary : .secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Toggle voice mode (/voice)")

            if viewModel.voiceEnabled {
                Button {
                    viewModel.toggleTTS()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.ttsEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                            .foregroundStyle(viewModel.ttsEnabled ? .green : .secondary)
                        (viewModel.ttsEnabled ? Text("TTS On") : Text("TTS Off"))
                            .font(.caption)
                            .foregroundStyle(viewModel.ttsEnabled ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Toggle text-to-speech (/voice tts)")

                Button {
                    viewModel.pushToTalk()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isRecording ? "waveform.circle.fill" : "waveform.circle")
                            .foregroundStyle(viewModel.isRecording ? .red : Color.accentColor)
                            .symbolEffect(.pulse, isActive: viewModel.isRecording)
                        (viewModel.isRecording ? Text("Recording…") : Text("Push to Talk"))
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("Push to talk (Ctrl+B)")
                .keyboardShortcut("b", modifiers: .control)
            }
        }
    }

    @ViewBuilder
    private var chatArea: some View {
        switch viewModel.displayMode {
        case .terminal:
            terminalArea
        case .richChat:
            richChatArea
        }
    }

    @ViewBuilder
    private var terminalArea: some View {
        if let terminal = viewModel.terminalView {
            PersistentTerminalView(terminalView: terminal)
        } else if viewModel.hermesBinaryExists {
            ContentUnavailableView(
                "No Active Session",
                systemImage: "terminal",
                description: Text("Start a new session or resume an existing one from the Session menu above.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Hermes Not Found",
                systemImage: "terminal",
                description: Text("Expected at \(viewModel.context.paths.hermesBinary)")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var richChatArea: some View {
        ZStack {
            // Keep terminal alive in background if it exists (terminal mode session)
            if let terminal = viewModel.terminalView {
                PersistentTerminalView(terminalView: terminal)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
            }

            if viewModel.hermesBinaryExists {
                RichChatView(
                    richChat: viewModel.richChatViewModel,
                    onSend: { viewModel.sendText($0) },
                    isEnabled: viewModel.hasActiveProcess || viewModel.hermesBinaryExists
                )
            } else {
                ContentUnavailableView(
                    "Hermes Not Found",
                    systemImage: "terminal",
                    description: Text("Expected at \(viewModel.context.paths.hermesBinary)")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Permission approval sheet
        .sheet(item: permissionBinding) { permission in
            PermissionApprovalView(
                title: permission.title,
                kind: permission.kind,
                options: permission.options,
                onRespond: { optionId in
                    viewModel.respondToPermission(optionId: optionId)
                }
            )
        }
    }

    private var permissionBinding: Binding<RichChatViewModel.PendingPermission?> {
        Binding(
            get: { viewModel.richChatViewModel.pendingPermission },
            set: { viewModel.richChatViewModel.pendingPermission = $0 }
        )
    }
}

// MARK: - Permission Approval View

extension RichChatViewModel.PendingPermission: Identifiable {
    var id: Int { requestId }
}

struct PermissionApprovalView: View {
    let title: String
    let kind: String
    let options: [(optionId: String, name: String)]
    let onRespond: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: kindIcon)
                .font(.title)
                .foregroundStyle(kindColor)

            Text("Tool Approval Required")
                .font(.headline)

            Text(title)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 12) {
                ForEach(options, id: \.optionId) { option in
                    if option.optionId == "deny" {
                        Button(option.name) {
                            onRespond(option.optionId)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(option.name) {
                            onRespond(option.optionId)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 350)
    }

    private var kindIcon: String {
        switch kind {
        case "execute": return "terminal"
        case "edit": return "pencil"
        case "delete": return "trash"
        default: return "wrench"
        }
    }

    private var kindColor: Color {
        switch kind {
        case "execute": return .orange
        case "edit": return .blue
        case "delete": return .red
        default: return .secondary
        }
    }
}
