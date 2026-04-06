import SwiftUI

struct RichChatView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(HermesFileWatcher.self) private var fileWatcher

    var body: some View {
        VStack(spacing: 0) {
            SessionInfoBar(
                session: viewModel.richChatViewModel.currentSession,
                isWorking: viewModel.richChatViewModel.isAgentWorking
            )
            Divider()

            if viewModel.richChatViewModel.messageGroups.isEmpty && !viewModel.richChatViewModel.isAgentWorking {
                ContentUnavailableView(
                    "Chat Messages",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Messages will appear here as the conversation progresses.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RichChatMessageList(
                    groups: viewModel.richChatViewModel.messageGroups,
                    isWorking: viewModel.richChatViewModel.isAgentWorking
                )
            }

            Divider()
            RichChatInputBar(
                onSend: { text in
                    viewModel.sendText(text)
                    viewModel.richChatViewModel.markAgentWorking()
                },
                isEnabled: viewModel.hasActiveProcess
            )
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.richChatViewModel.refreshMessages() }
        }
    }
}
