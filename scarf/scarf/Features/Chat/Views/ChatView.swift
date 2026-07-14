import SwiftUI
import ScarfCore

struct ChatView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(AppCoordinator.self) private var coordinator
    /// Capabilities store for the active server (injected on
    /// `ContextBoundRoot`). Forwarded into `ChatViewModel` so the
    /// rich-chat slash menu can gate v0.13 surfaces (`/goal`, `/queue`,
    /// `/steer` on idle). Nil during harness scenarios; treated the
    /// same as `.empty` capabilities.
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var showErrorDetails = false

    /// Side-pane visibility toggles (issue #58). Drive the new
    /// sidebar.left / sidebar.right toolbar buttons; `RichChatView.body`
    /// reads the same `@AppStorage` keys and conditionally renders the
    /// panes with a slide animation.
    @AppStorage(ChatDensityKeys.showSessionsList)
    private var showSessionsList: Bool = true
    @AppStorage(ChatDensityKeys.showInspector)
    private var showInspector: Bool = true

    var body: some View {
        // ScarfMon body-evaluation counter — tracks how many times
        // SwiftUI re-evaluates this view per second during streaming.
        // High counts here usually mean state is fanning out further
        // than necessary; pair with `mac.RichMessageBubble.body` to
        // see whether the churn lives in the parent or the bubbles.
        let _: Void = ScarfMon.event(.chatRender, "mac.ChatView.body")
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
        // Forward the env-injected capabilities store into the chat VM
        // on every refresh tick so the rich-chat slash menu picks up
        // v0.13 surfaces the moment the host advertises them. The id
        // value is the capabilities-line string — a stable identity
        // that flips exactly when the detector fires. Nil store ↔
        // `.empty` capabilities, which is what the VM defaults to.
        .task(id: capabilitiesStore?.capabilities.versionLine ?? "") {
            viewModel.attachCapabilitiesStore(capabilitiesStore)
        }
        .task {
            await viewModel.loadRecentSessions()
            viewModel.refreshCredentialPreflight()
            viewModel.refreshConfigDiagnostics()
            // Surface the `/scarf-*` global slash commands in the chat
            // input's menu BEFORE the user opens a session. Without this
            // the menu collapses to `/new` + greyed agent commands at
            // cold launch, which was the original "slash commands not
            // loading" complaint. Same loader fires again at session
            // start so any version bump applied this launch lands.
            viewModel.richChatViewModel.loadGlobalScopedCommands()
            // Cold-launch handoff: if the user clicked "New Chat" on
            // a project before ChatView had a chance to render, the
            // coordinator was already populated. Consume the request
            // here. The onChange below handles the live case.
            if let pending = coordinator.pendingProjectChat {
                let prompt = coordinator.pendingInitialPrompt
                coordinator.pendingProjectChat = nil
                coordinator.pendingInitialPrompt = nil
                if let prompt {
                    viewModel.startNewSessionAndSend(projectPath: pending, text: prompt)
                } else {
                    viewModel.startNewSession(projectPath: pending)
                }
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
            // Debounced rather than immediate. During an active ACP
            // message stream the watcher fires many times per second
            // (every persisted message bumps `state.db-wal`'s mtime);
            // an unconditional reload on each tick caused the chat
            // sidebar to visibly flicker as `recentSessions` was
            // reassigned over and over with the same data. The
            // debounced helper coalesces bursts into one trailing
            // fetch ~500 ms after the last tick. New sessions still
            // appear immediately because the create/resume paths
            // call `loadRecentSessions()` synchronously themselves.
            viewModel.scheduleSessionsRefresh()
            // Debounced + off-main (see `scheduleCredentialPreflightRefresh`):
            // keeps the missing-credential banner live on an external `.env`
            // edit without the per-message, on-main read that caused the
            // gh#102 typing-lag.
            viewModel.scheduleCredentialPreflightRefresh()
        }
        // Live handoff from the per-project Sessions tab: the tab
        // sets `pendingProjectChat` + flips `selectedSection` to
        // `.chat`; this view consumes the path and starts a fresh
        // session with cwd=projectPath. Attribution happens inside
        // ChatViewModel on successful session creation.
        //
        // The "New Project from Scratch" wizard (v2.8) sets the
        // sister slot `pendingInitialPrompt` alongside the project
        // path so the agent receives a kickoff prompt without the
        // user having to type one. We drain both atomically and
        // route to `startNewSessionAndSend` when present.
        .onChange(of: coord.pendingProjectChat) { _, new in
            if let projectPath = new {
                let prompt = coordinator.pendingInitialPrompt
                coordinator.pendingProjectChat = nil
                coordinator.pendingInitialPrompt = nil
                if let prompt {
                    viewModel.startNewSessionAndSend(projectPath: projectPath, text: prompt)
                } else {
                    viewModel.startNewSession(projectPath: projectPath)
                }
            }
        }
        // Live handoff for resume: user clicked an existing session in
        // the Projects Sessions tab while already in the Chat section
        // (or switched back to Chat after). ChatViewModel.resumeSession
        // recovers the session's project from the attribution sidecar and
        // threads it through startACPSession, so the respawned `hermes acp`
        // gets the project cwd (AGENTS.md + tool dirs) and the header chip
        // — not just the chip. t-24594c4a.
        .onChange(of: coord.selectedSessionId) { _, new in
            if let sessionId = new {
                coordinator.selectedSessionId = nil
                viewModel.resumeSession(sessionId)
            }
        }
    }

    /// Banner rendered between the toolbar and the chat area when either
    /// Status string surfaced in the toolbar pill. When the agent's
    /// thought stream is in flight without any visible message bytes
    /// (Hermes reasoning models routinely take 3–8 s here), promote
    /// the generic "Agent working..." to "Thinking…" so the user
    /// sees the model is reasoning rather than stalled. v2.7.
    private var displayedStatus: String {
        if viewModel.richChatViewModel.isStreamingThoughtsOnly {
            return "Thinking…"
        }
        // v2.8 — promote the otherwise-ready status to a more honest
        // "Loading tool details…" while the two-phase loader's
        // background hydration is still pulling tool_calls JSON and
        // tool result rows. The bare conversation transcript is
        // already on screen; this just tells the user that the
        // missing tool cards / result bodies are on their way.
        if viewModel.richChatViewModel.isHydratingTools {
            return "Loading tool details…"
        }
        return viewModel.acpStatus.isEmpty ? "Active" : viewModel.acpStatus
    }

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
                    if let provider = viewModel.acpErrorOAuthProvider {
                        Button("Re-authenticate") {
                            coordinator.pendingOAuthReauth = provider
                            coordinator.selectedSection = .credentialPools
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Open Credential Pools and re-authenticate \(provider).")
                    }
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
        } else if let mismatch = viewModel.modelProviderMismatch, !viewModel.hasActiveProcess {
            // Provider/model mismatch — `model.default` carries one
            // provider prefix while `model.provider` names another.
            // Hermes can't reconcile and the chat dies with -32603 at
            // first prompt. v2.8 surfaces a one-click fix for both
            // directions: align provider to the model's prefix
            // (likely the user just authed against `prefixProvider`),
            // or strip the prefix to keep the active provider intact.
            // t-79569a15 adds the third path: open the full model
            // picker and replace both keys with a valid pair.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model/provider mismatch in config.yaml")
                        .font(.callout)
                    Text("`model.default` is `\(mismatch.modelDefault)` but `model.provider` is `\(mismatch.activeProvider)`. Chats will fail at first prompt until this is reconciled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !mismatch.prefixIsKnownProvider {
                        // The prefix isn't a provider Hermes has, so
                        // "Use \(prefix)" would write a nonexistent
                        // provider into config.yaml — offer only the
                        // strip fix and point at the likely intent.
                        Text("`\(mismatch.prefixProvider)` isn't a provider Hermes knows. If this model ID came from an aggregator (e.g. OpenRouter), set `model.provider` to that aggregator instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        if mismatch.prefixIsKnownProvider {
                            Button("Use \(mismatch.prefixProvider)") {
                                viewModel.alignProviderToModelPrefix(mismatch)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Set model.provider = \(mismatch.prefixProvider) and model.default = \(mismatch.bareModel).")
                        }
                        Button("Keep \(mismatch.activeProvider)") {
                            viewModel.stripPrefixFromModelDefault(mismatch)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Strip the prefix from model.default, leaving model.provider = \(mismatch.activeProvider).")
                        // The honest escape hatch, offered on EVERY
                        // mismatch (t-79569a15): open the full model
                        // picker and replace both keys with a valid
                        // pair. For an unknown prefix it's the only
                        // constructive action (the align button is
                        // hidden), so it takes the prominent style
                        // there.
                        let choose = Button("Choose model…") {
                            viewModel.chooseModelForMismatch(mismatch)
                        }
                        .controlSize(.small)
                        .help("Pick a model and provider from the full catalog — Scarf saves both to config.yaml.")
                        if mismatch.prefixIsKnownProvider {
                            choose.buttonStyle(.bordered)
                        } else {
                            choose.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 2)
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
                // Promote the generic "Agent working..." status to
                // "Thinking…" the moment the thought stream starts
                // arriving without visible message bytes — the user
                // gets a more honest signal that the model is
                // reasoning, not stalled. Falls back to whatever
                // status string the VM has when no thought stream
                // is in flight.
                Text(displayedStatus)
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

            // Side-pane toggles (issue #58). Only meaningful in rich-chat
            // mode where the 3-pane layout exists; terminal mode is a
            // single SwiftTerm view and these would do nothing. Hide
            // them on the terminal side so the toolbar stays uncluttered.
            if viewModel.displayMode == .richChat {
                Button {
                    showSessionsList.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(showSessionsList ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showSessionsList ? "Hide sessions list" : "Show sessions list")

                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showInspector ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showInspector ? "Hide tool inspector" : "Show tool inspector")
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

            // The session list pane on the left is the canonical home
            // for browsing + resuming sessions and starting new ones.
            // We keep a slim toolbar Menu for the actions that aren't
            // expressed by clicking a row: "Return to Active Session"
            // (scroll back to the live session) and "Continue Last
            // Session" (continue the most-recent without explicit pick).
            Menu {
                if viewModel.hasActiveProcess, let activeId = viewModel.richChatViewModel.sessionId {
                    Button("Return to Active Session (\(activeId.prefix(8))…)") {
                        viewModel.richChatViewModel.requestScrollToBottom()
                    }
                    Divider()
                }
                Button("Continue Last Session") {
                    viewModel.continueLastSession()
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
                    onSend: { text, images in viewModel.sendText(text, images: images) },
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
        // Model preflight — open before any ACP plumbing when the active
        // server has no `model.default` / `model.provider` set. Keeps the
        // user from typing a prompt only to find out the upstream
        // provider rejected it.
        .sheet(isPresented: modelPreflightBinding) {
            ChatModelPreflightSheet(
                reason: viewModel.modelPreflightReason ?? "",
                serverDisplayName: viewModel.context.displayName,
                onSelect: { model, provider in
                    viewModel.confirmModelPreflight(model: model, provider: provider)
                },
                onSelectLocal: { selection in
                    viewModel.confirmModelPreflight(
                        model: selection.modelID,
                        provider: selection.providerID,
                        local: selection
                    )
                },
                onCancel: {
                    viewModel.cancelModelPreflight()
                }
            )
            .environment(\.serverContext, viewModel.context)
        }
        // Kanban toolset onboarding — fires on the user's first `/goal`
        // against a host whose `cli` platform_toolsets list lacks
        // `kanban`. ChatViewModel sets the trigger flag; this sheet
        // explains the gating + offers one-click enable.
        .sheet(isPresented: kanbanOnboardingBinding) {
            ChatKanbanOnboardingSheet(
                onEnable: {
                    await viewModel.enableKanbanToolset()
                },
                onOpenTools: {
                    viewModel.dismissKanbanToolsetOnboarding()
                    coordinator.selectedSection = .tools
                },
                onSkip: {
                    viewModel.dismissKanbanToolsetOnboarding()
                }
            )
        }
    }

    private var kanbanOnboardingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showKanbanOnboardingSheet },
            set: { viewModel.showKanbanOnboardingSheet = $0 }
        )
    }

    private var permissionBinding: Binding<RichChatViewModel.PendingPermission?> {
        Binding(
            get: { viewModel.richChatViewModel.pendingPermission },
            set: { viewModel.richChatViewModel.pendingPermission = $0 }
        )
    }

    private var modelPreflightBinding: Binding<Bool> {
        Binding(
            get: { viewModel.modelPreflightReason != nil },
            set: { newValue in
                if !newValue { viewModel.cancelModelPreflight() }
            }
        )
    }
}

// MARK: - Permission Approval View

// `@retroactive` acknowledges that we're declaring conformance for a
// type (`PendingPermission`) and protocol (`Identifiable`) we don't own
// — the Swift 6 compiler flags this otherwise so that downstream
// breakage is loud if `ScarfCore` ever adds the conformance upstream.
extension RichChatViewModel.PendingPermission: @retroactive Identifiable {
    public var id: Int { requestId }
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

            // Numbered keyboard shortcuts (1–9) on the option buttons.
            // Mirrors the new TUI pattern Hermes v2026.4.23 ships —
            // power users approve / deny without reaching for the
            // mouse. Visible "1." prefixes act as discoverability
            // hints; the actual key binding goes through
            // `.keyboardShortcut`. Capped at 9 — extra options stay
            // tappable but unbound (they'd need modifiers to
            // disambiguate beyond 9, which isn't worth it).
            HStack(spacing: 12) {
                ForEach(Array(options.enumerated()), id: \.element.optionId) { idx, option in
                    let label = idx < 9 ? "\(idx + 1). \(option.name)" : option.name
                    Group {
                        if option.optionId == "deny" {
                            Button(label) {
                                onRespond(option.optionId)
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(label) {
                                onRespond(option.optionId)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .applyingNumberShortcut(index: idx)
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

private extension View {
    /// Bind the digit `idx + 1` (1-9) to this view as a no-modifier
    /// keyboard shortcut. Indices ≥ 9 silently skip — there are only
    /// nine numeric shortcut keys without modifier conflicts.
    @ViewBuilder
    func applyingNumberShortcut(index idx: Int) -> some View {
        if idx < 9, let scalar = Unicode.Scalar(48 + idx + 1) {
            self.keyboardShortcut(KeyEquivalent(Character(scalar)), modifiers: [])
        } else {
            self
        }
    }
}
