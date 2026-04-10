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

            if richChat.messageGroups.isEmpty && !richChat.isAgentWorking {
                ContentUnavailableView(
                    "Chat Messages",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Messages will appear here as the conversation progresses.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RichChatMessageList(
                    groups: richChat.messageGroups,
                    isWorking: richChat.isAgentWorking,
                    scrollTrigger: richChat.scrollTrigger
                )
            }

            Divider()
            RichChatInputBar(
                onSend: { text in
                    onSend(text)
                },
                isEnabled: isEnabled
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
