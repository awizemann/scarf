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
    var onSend: (String, [ChatImageAttachment]) -> Void
    var isEnabled: Bool
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(ChatViewModel.self) private var chatViewModel

    /// User-controlled font scale for the chat surface (issue #48).
    /// Applied via `.environment(\.dynamicTypeSize, ...)` so message
    /// list, input bar, session info bar, and the inspector pane all
    /// scale together. Default 1.0 = today's UI.
    @AppStorage(ChatDensityKeys.fontScale)
    private var fontScale: Double = ChatFontScale.default

    /// Sessions-list / inspector pane visibility (issue #58). Defaults
    /// `true` so existing users see no change until they opt out via
    /// the toolbar buttons or Settings → Display → Chat density.
    @AppStorage(ChatDensityKeys.showSessionsList)
    private var showSessionsList: Bool = true
    @AppStorage(ChatDensityKeys.showInspector)
    private var showInspector: Bool = true

    /// In ACP mode, events drive updates directly — no DB polling needed.
    private var isACPMode: Bool { chatViewModel.isACPConnected }

    var body: some View {
        HStack(spacing: 0) {
            if showSessionsList {
                ChatSessionListPane(chatViewModel: chatViewModel, richChat: richChat)
                    // Give session titles more breathing room without changing
                    // the fixed 3-pane layout or the user's pane toggles.
                    .frame(width: 304)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().background(ScarfColor.border)
            }
            ChatTranscriptPane(
                richChat: richChat,
                chatViewModel: chatViewModel,
                onSend: onSend,
                isEnabled: isEnabled
            )
            .frame(maxWidth: .infinity)
            if showInspector {
                Divider().background(ScarfColor.border)
                ChatInspectorPane(chatViewModel: chatViewModel)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minHeight: 0, idealHeight: 500, maxHeight: .infinity)
        .environment(\.dynamicTypeSize, ChatFontScale.dynamicTypeSize(for: fontScale))
        // ScarfFont tokens are fixed-point so dynamicTypeSize alone
        // doesn't move bubble / markdown / code-block text. Plumb the
        // raw scale via `\.chatFontScale` so chat content views can
        // read it and scale their explicit sizes too (issue #68).
        .environment(\.chatFontScale, fontScale)
        // Animate side-pane shows/hides so the transcript reflows
        // smoothly rather than snapping. ~180ms feels responsive
        // without being jarring.
        .animation(.easeInOut(duration: 0.18), value: showSessionsList)
        .animation(.easeInOut(duration: 0.18), value: showInspector)
        // Auto-show inspector when a tool call is focused so a click
        // on a tool card is never silently lost (issue #58 follow-up).
        // Tool clicks set `chatViewModel.focusedToolCallId`; if that
        // becomes non-nil while the inspector is hidden, flip it back
        // on. The animation modifiers above cover the slide-in.
        .onChange(of: chatViewModel.focusedToolCallId) { _, new in
            if new != nil, !showInspector {
                showInspector = true
            }
        }
        // DB polling fallback for terminal mode only — never overwrite ACP messages
        .onChange(of: fileWatcher.lastChangeDate) {
            if !isACPMode, !richChat.hasMessages, richChat.sessionId != nil {
                richChat.scheduleRefresh()
            }
        }
    }
}
