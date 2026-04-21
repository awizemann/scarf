import SwiftUI

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
                isWorking: richChat.isAgentWorking,
                acpInputTokens: richChat.acpInputTokens,
                acpOutputTokens: richChat.acpOutputTokens,
                acpThoughtTokens: richChat.acpThoughtTokens
            )
            Divider()

            // Always mount RichChatMessageList; empty state lives inside it.
            // Swapping between a ContentUnavailableView and the ScrollView
            // hierarchy on first message caused a full view tree rebuild,
            // which manifests as a white flash.
            RichChatMessageList(
                groups: richChat.messageGroups,
                isWorking: richChat.isAgentWorking,
                isLoadingSession: chatViewModel.isPreparingSession,
                scrollTrigger: richChat.scrollTrigger
            )

            Divider()
            RichChatInputBar(
                onSend: { text in
                    onSend(text)
                },
                isEnabled: isEnabled,
                commands: richChat.availableCommands,
                showCompressButton: richChat.supportsCompress && !richChat.hasBroaderCommandMenu
            )
        }
        // DB polling fallback for terminal mode only — never overwrite ACP messages
        .onChange(of: fileWatcher.lastChangeDate) {
            if !isACPMode, !richChat.hasMessages, richChat.sessionId != nil {
                richChat.scheduleRefresh()
            }
        }
    }
}
