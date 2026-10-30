import SwiftUI
import ScarfCore
import ScarfDesign

/// Middle pane of the 3-pane chat layout — composes the existing
/// `SessionInfoBar` + `RichChatMessageList` + `RichChatInputBar` with
/// no new state of its own. Pulled out of `RichChatView` so the
/// 3-pane HStack is readable.
struct ChatTranscriptPane: View {
    @Bindable var richChat: RichChatViewModel
    @Bindable var chatViewModel: ChatViewModel
    var onSend: (String, [ChatImageAttachment], ChatViewModel.ChatInputMode) -> Void
    var isEnabled: Bool
    /// Bot Chat reuses this pane but routes its sends through the bot's
    /// own pipeline, which voice turns would bypass: it opts out.
    var allowsVoiceLive = true
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    /// Key or main window (`.key` / `.active`) vs. behind, minimized, or in
    /// an inactive app (`.inactive`): whether the user can see this pane.
    @Environment(\.controlActiveState) private var controlActiveState

    /// Live-count badge for the Kanban chip. Created lazily so the VM
    /// is per-context (not per-window) and a re-rendered view doesn't
    /// stack pollers.
    @State private var kanbanBadgeViewModel: KanbanChatBadgeViewModel?
    @State private var resolvedTenantForChat: String?

    /// The composer's Live Voice button, or `nil` (no button) unless this
    /// host passes the readiness gate — Hermes ≥ 0.21.3 and
    /// `voice.voice_chat_mode: gpt-live`.
    private var voiceLiveEntry: VoiceLiveComposerEntry? {
        guard allowsVoiceLive else { return nil }
        let capabilities = voiceCapabilities
        guard let engineKind = chatViewModel.voiceLiveAvailability(capabilities: capabilities).engineKind else { return nil }
        // Starting counts: an end in that gap cancels the start.
        let isActive = chatViewModel.voiceLive.holdsSession
        return VoiceLiveComposerEntry(
            engineKind: engineKind,
            isActive: isActive,
            canStart: chatViewModel.canStartVoiceTurns,
            blockedByAnotherWindow: chatViewModel.voiceLive.isBlockedByAnotherWindow,
            onToggle: {
                if isActive {
                    chatViewModel.voiceLive.end()
                } else {
                    chatViewModel.startVoiceLive(capabilities: capabilities)
                }
            }
        )
    }

    private var voiceCapabilities: HermesCapabilities { capabilitiesStore?.capabilities ?? .empty }

    var body: some View {
        VStack(spacing: 0) {
            SessionInfoBar(
                session: richChat.currentSession,
                isWorking: richChat.isGenerating,
                acpInputTokens: richChat.acpInputTokens,
                acpOutputTokens: richChat.acpOutputTokens,
                acpThoughtTokens: richChat.acpThoughtTokens,
                acpCompressionCount: richChat.acpCompressionCount,
                projectName: chatViewModel.currentProjectName,
                gitBranch: chatViewModel.currentGitBranch,
                approvalMode: chatViewModel.approvalMode,
                queuedPrompts: richChat.queuedPrompts,
                capabilities: capabilitiesStore?.capabilities ?? .empty,
                kanbanLiveCount: kanbanBadgeViewModel?.liveCount,
                onOpenKanban: { handleOpenKanban() },
                modelPreset: chatViewModel.currentModelPreset,
                onSwitchModel: { preset in
                    chatViewModel.switchModelPreset(preset)
                },
                approvalSessionMode: richChat.activeApprovalMode,
                onSwitchApprovalMode: { mode in
                    chatViewModel.switchApprovalMode(mode)
                }
            )
            Divider()

            // Always mount RichChatMessageList; empty state lives inside it.
            // Swapping between a ContentUnavailableView and the ScrollView
            // hierarchy on first message caused a full view tree rebuild,
            // which manifests as a white flash.
            RichChatMessageList(
                groups: richChat.visibleGroups,
                isWorking: richChat.isGenerating,
                isLoadingSession: chatViewModel.isPreparingSession,
                scrollTrigger: richChat.scrollTrigger,
                turnDurations: richChat.turnDurations,
                // Two-stage Load-earlier: bumps the render window first
                // (cheap derived-property change), only hops to the DB
                // once the in-memory tail is exhausted.
                hasMoreHistory: richChat.hasHiddenInMemoryGroups || richChat.hasMoreHistory,
                isLoadingEarlier: richChat.isLoadingEarlier,
                onLoadEarlier: {
                    if richChat.hasHiddenInMemoryGroups {
                        richChat.extendRenderWindow()
                    } else {
                        Task { await richChat.loadEarlier() }
                    }
                },
                isHydratingTools: richChat.isHydratingTools,
                liveStatus: richChat.liveActivityStatus,
                earlierCutoffId: richChat.earlierHistoryCutoffId,
                workingSince: richChat.workingSince,
                resumeNotice: richChat.resumeContinuityNotice
            )

            Divider()
            if let hint = richChat.transientHint {
                steeringToast(hint)
            }
            // Live Voice session strip (also hosts the media web view for
            // the whole session). Absent unless a session was started.
            VoiceLivePanel(
                controller: chatViewModel.voiceLive,
                onRestart: { chatViewModel.startVoiceLive(capabilities: voiceCapabilities) },
                ttsProvider: chatViewModel.voiceTTSProviderRaw,
                canRestart: chatViewModel.canStartVoiceTurns
                    && !chatViewModel.voiceLive.isBlockedByAnotherWindow
            )
            // The draft belongs to the chat (`ChatSession.composer`), so
            // moving to another chat shows that chat's draft and moving
            // back restores this one (parallel chats P1). The composer's
            // identity follows the CHAT, not its session id: the id is nil
            // until a start is ready, and a session change used to rebuild
            // the view and drop what was typed meanwhile. Issue #62 (a
            // draft leaking into another conversation) is kept by the chat
            // clearing its draft when it is reused for another session
            // (`resetForSessionSwitch`).
            RichChatInputBar(
                draft: chatViewModel.focusedChat.composer,
                onSend: onSend,
                isEnabled: isEnabled,
                commands: richChat.availableCommands,
                showCompressButton: richChat.supportsCompress && !richChat.hasBroaderCommandMenu,
                isAgentWorking: richChat.isAgentWorking,
                hasActiveSession: richChat.sessionId != nil,
                activeModelPreset: chatViewModel.currentModelPreset,
                voiceLive: voiceLiveEntry,
                canStop: richChat.isAgentWorking && chatViewModel.canStopCurrentTurn,
                onStop: { chatViewModel.stopCurrentTurn() }
            )
            .id(chatViewModel.focusedChat.id)
        }
        // Leaving the chat (another sidebar section, terminal mode, window
        // close) takes the panel — and the web view WebKit needs for audio
        // — with it, so the session ends here rather than billing unseen.
        .onDisappear {
            chatViewModel.isChatPaneVisible = false
            chatViewModel.leaveChatVoiceLive()
        }
        // Whether the focused chat is on screen: a reply finishing in it
        // then is neither unread nor notified. Coming on screen (the pane,
        // or its window to the front) reads what finished meanwhile.
        .onAppear {
            chatViewModel.isChatPaneVisible = true
            chatViewModel.isWindowVisible = controlActiveState != .inactive
            chatViewModel.chatPaneVisibilityChanged()
        }
        .onChange(of: controlActiveState) { _, state in
            chatViewModel.isWindowVisible = state != .inactive
            chatViewModel.chatPaneVisibilityChanged()
        }
        // The one-time Live Voice consent (F4): raised by the first start
        // on this Mac; Cancel starts nothing and bills nothing.
        .sheet(item: Binding(
            get: { chatViewModel.voiceLive.pendingConsent },
            set: { if $0 == nil { chatViewModel.voiceLive.declineConsent() } }
        )) { recipient in
            VoiceLiveConsentSheet(
                recipient: recipient,
                mode: .ask(
                    onContinue: { chatViewModel.acceptVoiceLiveConsent(capabilities: voiceCapabilities) },
                    onCancel: { chatViewModel.voiceLive.declineConsent() }
                )
            )
        }
        .background(ScarfColor.backgroundPrimary)
        .task(id: chatViewModel.currentProjectPath ?? "") {
            // Resolve the project's tenant once per project change.
            // Background — don't block the chat render on the disk
            // read for the manifest. Nil for global chats.
            await refreshResolvedTenant()
        }
        .task(id: kanbanBadgePollKey) {
            // Long-running poller scoped to (capabilities, chat session,
            // scene phase). Restarts cleanly when any changes. The badge
            // counts tasks this chat produced, scoped by the ACP session id.
            let caps = capabilitiesStore?.capabilities ?? .empty
            let sid = richChat.sessionId
            guard caps.hasKanbanSessionFilter, sid != nil else {
                // Nothing to poll — and the badge must go blank rather than
                // keep asserting the count of whatever chat it last saw.
                kanbanBadgeViewModel?.bind(to: nil)
                return
            }
            if kanbanBadgeViewModel == nil {
                kanbanBadgeViewModel = KanbanChatBadgeViewModel(
                    context: chatViewModel.context
                )
            }
            // Rebind before polling: a different session clears the old
            // count and releases the previous chat's in-flight slot, and
            // tags every result so a late one for the old chat is dropped.
            kanbanBadgeViewModel?.bind(to: sid)
            await kanbanBadgeViewModel?.run(capabilities: caps)
        }
    }

    /// Stable identity for the badge poller's `.task(id:)`. Includes
    /// every input that should restart the poll loop: the chat session
    /// (so a /new restarts polling for the new session), the capability
    /// flag (so a host upgrade activates the chip without reload), and
    /// the scene phase.
    ///
    /// The scene phase is the same C10 pause every other Kanban surface
    /// already has (`KanbanBoardView.swift` `.onChange(of: scenePhase)`;
    /// likewise `KanbanListView`, `KanbanInspectorPane`): a backgrounded
    /// window used to keep spawning `hermes kanban list` — one process,
    /// possibly over SSH, every five seconds per open chat window,
    /// forever — for a number nobody was looking at. Here the poller IS
    /// the `.task`, so folding the phase into its id is that same pause:
    /// leaving `.active` cancels the loop, returning restarts it with an
    /// immediate tick.
    private var kanbanBadgePollKey: String {
        let caps = capabilitiesStore?.capabilities ?? .empty
        return [
            caps.hasKanbanSessionFilter ? "k" : "",
            scenePhase == .active ? "active" : "paused",
            richChat.sessionId ?? ""
        ].joined(separator: "|")
    }

    private func refreshResolvedTenant() async {
        guard let path = chatViewModel.currentProjectPath,
              let name = chatViewModel.currentProjectName else {
            resolvedTenantForChat = nil
            return
        }
        let entry = ProjectEntry(name: name, path: path)
        let context = chatViewModel.context
        let tenant: String? = await Task.detached {
            let resolver = KanbanTenantResolver(context: context)
            return try? resolver.resolveOrMint(for: entry)
        }.value
        await MainActor.run {
            resolvedTenantForChat = tenant
        }
    }

    /// Called from the SessionInfoBar Kanban chip. Builds the hand-off
    /// snapshot, hands it to AppCoordinator, then flips the route to
    /// the global Kanban surface — which drains the slot and renders
    /// the board scoped to this chat's ACP session id. The chip only
    /// renders on v0.15+ hosts (gated on `hasKanbanSessionFilter`), so a
    /// session id is always present here; bail defensively if it isn't.
    private func handleOpenKanban() {
        guard let sessionId = richChat.sessionId else { return }
        coordinator.pendingKanbanHandoff = KanbanHandoff(
            tenant: resolvedTenantForChat,
            projectPath: chatViewModel.currentProjectPath,
            projectName: chatViewModel.currentProjectName,
            sessionId: sessionId
        )
        coordinator.selectedSection = .kanban
    }

    /// Soft pill above the composer that confirms a non-interruptive
    /// command (e.g. `/steer`) was received. Auto-clears after a short
    /// delay (managed by `ChatViewModel`); presence in the model is what
    /// drives this view.
    private func steeringToast(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .foregroundStyle(ScarfColor.accent)
                .scarfStyle(.caption)
            Text(hint)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.accentTint)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
