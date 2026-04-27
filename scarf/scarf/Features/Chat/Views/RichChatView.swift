import SwiftUI
import ScarfCore
import ScarfDesign

/// 3-pane chat layout — sessions list | transcript | inspector.
/// Mirrors `design/static-site/ui-kit/Chat.jsx` and the
/// `ScarfChatView.ChatRootView` reference component, but composed over
/// the real `ChatViewModel` + `RichChatViewModel` so the live ACP
/// pipeline stays intact.
///
/// We always render the full 3-pane layout — earlier `ViewThatFits`
/// fallbacks were dropping to transcript-only when the transcript's
/// own ideal width grew mid-load (long code blocks pushed the HStack
/// past the available width and ViewThatFits picked the smallest
/// variant). The window has a sensible minimum (~944 px content area
/// at the default 1100 px window width); narrower than that the user
/// can scroll horizontally inside the panes rather than losing them.
struct RichChatView: View {
    @Bindable var richChat: RichChatViewModel
    var onSend: (String) -> Void
    var isEnabled: Bool
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(ChatViewModel.self) private var chatViewModel

    /// User-controlled font scale for the chat surface (issue #48).
    /// Applied via `.environment(\.dynamicTypeSize, ...)` so message
    /// list, input bar, session info bar, and the inspector pane all
    /// scale together. Default 1.0 = today's UI.
    @AppStorage(ChatDensityKeys.fontScale)
    private var fontScale: Double = ChatFontScale.default

    /// In ACP mode, events drive updates directly — no DB polling needed.
    private var isACPMode: Bool { chatViewModel.isACPConnected }

    var body: some View {
        HStack(spacing: 0) {
            ChatSessionListPane(chatViewModel: chatViewModel, richChat: richChat)
                .frame(width: 264)
            Divider().background(ScarfColor.border)
            ChatTranscriptPane(
                richChat: richChat,
                chatViewModel: chatViewModel,
                onSend: onSend,
                isEnabled: isEnabled
            )
            .frame(maxWidth: .infinity)
            Divider().background(ScarfColor.border)
            ChatInspectorPane(chatViewModel: chatViewModel)
                .frame(width: 320)
        }
        .frame(minHeight: 0, idealHeight: 500, maxHeight: .infinity)
        .environment(\.dynamicTypeSize, ChatFontScale.dynamicTypeSize(for: fontScale))
        // DB polling fallback for terminal mode only — never overwrite ACP messages
        .onChange(of: fileWatcher.lastChangeDate) {
            if !isACPMode, !richChat.hasMessages, richChat.sessionId != nil {
                richChat.scheduleRefresh()
            }
        }
    }
}
