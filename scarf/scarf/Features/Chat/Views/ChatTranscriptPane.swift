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
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @Environment(AppCoordinator.self) private var coordinator

    /// Live-count badge for the Kanban chip. Created lazily so the VM
    /// is per-context (not per-window) and a re-rendered view doesn't
    /// stack pollers.
    @State private var kanbanBadgeViewModel: KanbanChatBadgeViewModel?
    @State private var resolvedTenantForChat: String?

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
                activeGoal: richChat.activeGoal,
                onClearGoal: {
                    chatViewModel.sendText("/goal --clear", images: [], inputMode: .quickCommand)
                },
                activeSubgoals: richChat.activeSubgoals,
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
                isHydratingTools: richChat.isHydratingTools
            )

            Divider()
            if let hint = richChat.transientHint {
                steeringToast(hint)
            }
            // Issue #62: bind composer identity to the active session
            // ID so SwiftUI rebuilds `RichChatInputBar` (and its
            // `@State` `text`/`attachments`) when the user switches
            // conversations. Without this the composer is structurally
            // identical across sessions and SwiftUI happily reuses the
            // instance, leaking the unsent draft into the new session.
            // A stable fallback id covers the brief "no session
            // selected" window — using `UUID()` here would mint a
            // fresh value per render and trash the composer on every
            // body re-eval.
            RichChatInputBar(
                onSend: onSend,
                isEnabled: isEnabled,
                commands: richChat.availableCommands,
                showCompressButton: richChat.supportsCompress && !richChat.hasBroaderCommandMenu,
                isAgentWorking: richChat.isAgentWorking,
                hasActiveSession: richChat.sessionId != nil,
                activeModelPreset: chatViewModel.currentModelPreset
            )
            .id(richChat.sessionId ?? "scarf.chat.no-session")
        }
        .background(ScarfColor.backgroundPrimary)
        .task(id: chatViewModel.currentProjectPath ?? "") {
            // Resolve the project's tenant once per project change.
            // Background — don't block the chat render on the disk
            // read for the manifest. Nil for global chats.
            await refreshResolvedTenant()
        }
        .task(id: kanbanBadgePollKey) {
            // Long-running poller scoped to (capabilities, chat session).
            // Restarts cleanly when either changes. The badge counts
            // tasks this chat produced, scoped by the ACP session id.
            let caps = capabilitiesStore?.capabilities ?? .empty
            guard caps.hasKanbanSessionFilter,
                  let sid = richChat.sessionId else { return }
            if kanbanBadgeViewModel == nil {
                kanbanBadgeViewModel = KanbanChatBadgeViewModel(
                    context: chatViewModel.context
                )
            }
            await kanbanBadgeViewModel?.run(
                sessionId: sid,
                capabilities: caps
            )
        }
    }

    /// Stable identity for the badge poller's `.task(id:)`. Includes
    /// every input that should restart the poll loop: the chat session
    /// (so a /new restarts polling for the new session) and the
    /// capability flag (so a host upgrade activates the chip without
    /// reload).
    private var kanbanBadgePollKey: String {
        let caps = capabilitiesStore?.capabilities ?? .empty
        return [
            caps.hasKanbanSessionFilter ? "k" : "",
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
