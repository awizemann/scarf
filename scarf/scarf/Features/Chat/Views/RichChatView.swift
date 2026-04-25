import SwiftUI
import ScarfCore

struct RichChatView: View {
    @Bindable var richChat: RichChatViewModel
    var onSend: (String) -> Void
    var isEnabled: Bool
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(ChatViewModel.self) private var chatViewModel

    /// In ACP mode, events drive updates directly — no DB polling needed.
    private var isACPMode: Bool { chatViewModel.isACPConnected }

    var body: some View {
        VStack(spacing: 0) {
            SessionInfoBar(
                session: richChat.currentSession,
                // Prefer `isGenerating` over the raw `isAgentWorking`
                // so the info bar drops the spinner as soon as the
                // assistant's reply is visible, even while ACP
                // auxiliary work (title gen, usage accounting) is
                // still in flight. See RichChatViewModel docs — same
                // fix as ScarfGo for pass-1 M7 #4.
                isWorking: richChat.isGenerating,
                acpInputTokens: richChat.acpInputTokens,
                acpOutputTokens: richChat.acpOutputTokens,
                acpThoughtTokens: richChat.acpThoughtTokens,
                // v2.3: surface the active Scarf project (if any) as
                // a folder chip at the start of the bar. Driven by
                // ChatViewModel.currentProjectName which is set in
                // startACPSession on both new project chats and
                // resumed project-attributed sessions.
                projectName: chatViewModel.currentProjectName
            )
            Divider()

            // Always mount RichChatMessageList; empty state lives inside it.
            // Swapping between a ContentUnavailableView and the ScrollView
            // hierarchy on first message caused a full view tree rebuild,
            // which manifests as a white flash.
            RichChatMessageList(
                groups: richChat.messageGroups,
                isWorking: richChat.isGenerating,
                isLoadingSession: chatViewModel.isPreparingSession,
                scrollTrigger: richChat.scrollTrigger
            )

            Divider()
            if let hint = richChat.transientHint {
                steeringToast(hint)
            }
            RichChatInputBar(
                onSend: { text in
                    onSend(text)
                },
                isEnabled: isEnabled,
                commands: richChat.availableCommands,
                showCompressButton: richChat.supportsCompress && !richChat.hasBroaderCommandMenu
            )
        }
        // `idealHeight: 500` caps what this subtree REPORTS as its ideal
        // height. Load-bearing: RichChatMessageList uses a plain VStack
        // (not LazyVStack — see RichChatMessageList.swift:13-24 for the
        // rationale) inside a ScrollView, so its natural ideal grows
        // with message count. Under the WindowGroup's
        // `.windowResizability(.contentMinSize)` policy, that uncapped
        // ideal would open the window at a height that exceeds the
        // screen on long conversations, pushing the input bar below
        // the visible desktop. `maxHeight: .infinity` still lets the
        // view fill any larger offered space, and `minHeight: 0`
        // allows it to shrink freely — the ideal cap only affects the
        // initial-size hint reported up to the window.
        .frame(minHeight: 0, idealHeight: 500, maxHeight: .infinity)
        // DB polling fallback for terminal mode only — never overwrite ACP messages
        .onChange(of: fileWatcher.lastChangeDate) {
            if !isACPMode, !richChat.hasMessages, richChat.sessionId != nil {
                richChat.scheduleRefresh()
            }
        }
    }

    /// Soft pill above the composer that confirms a non-interruptive
    /// command (e.g. `/steer`) was received. Auto-clears after a short
    /// delay (managed by `ChatViewModel`); presence in the model is
    /// what drives this view.
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
        .background(.tint.opacity(0.12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
