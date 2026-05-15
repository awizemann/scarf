import SwiftUI
import ScarfCore
import ScarfDesign
#if canImport(AppKit)
import AppKit
import AVKit
#endif

struct RichMessageBubble: View, Equatable {
    let message: HermesMessage
    let toolResults: [String: HermesMessage]
    /// Wall-clock duration of the agent turn this assistant message
    /// belongs to (v2.5). Rendered as a compact stopwatch pill in the
    /// metadata footer when present. Nil for user bubbles, for the
    /// streaming-in-progress placeholder, and for resumed sessions
    /// loaded from `state.db` (no live timing available).
    var turnDuration: TimeInterval? = nil

    @Environment(ChatViewModel.self) private var chatViewModel

    /// Chat-only font scale set on `RichChatView`. Chat content uses
    /// these multiplied sizes (issue #68); other surfaces still see
    /// the static ScarfFont tokens at scale = 1.0.
    @Environment(\.chatFontScale) private var chatFontScale: Double

    /// Scarf-local chat density preferences (issues #47 / #48). All
    /// three default to today's UI. Read here so the reasoning + tool-
    /// call switches don't have to thread the values through every
    /// layer; the AppStorage seam is one line per dependency.
    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyleRaw: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyle)
    private var reasoningStyleRaw: String = ReasoningStyle.disclosure.rawValue
    private var toolCardStyle: ToolCardStyle {
        ToolCardStyle(rawValue: toolCardStyleRaw) ?? .full
    }
    private var reasoningStyle: ReasoningStyle {
        ReasoningStyle(rawValue: reasoningStyleRaw) ?? .disclosure
    }
    @State private var expandedCompactToolCallId: String?

    /// SwiftUI body short-circuit (issue #46). Settled bubbles
    /// (`message.id != 0`) are immutable — id equality plus a couple
    /// of cheap stored-field comparisons is sufficient. The streaming
    /// bubble (id == 0) gets a content + reasoning + toolCalls.count
    /// comparison so it correctly redraws on every chunk.
    /// `toolResults` is compared by count: results are append-only
    /// within a group, so a count change implies a new tool result.
    static func == (lhs: RichMessageBubble, rhs: RichMessageBubble) -> Bool {
        guard lhs.message.id == rhs.message.id else { return false }
        if lhs.message.id == 0 {
            return lhs.message.content == rhs.message.content
                && lhs.message.reasoning == rhs.message.reasoning
                && lhs.message.reasoningContent == rhs.message.reasoningContent
                && lhs.message.toolCalls.count == rhs.message.toolCalls.count
                && lhs.turnDuration == rhs.turnDuration
                && lhs.toolResults.count == rhs.toolResults.count
        }
        return lhs.turnDuration == rhs.turnDuration
            && lhs.toolResults.count == rhs.toolResults.count
            && lhs.message.tokenCount == rhs.message.tokenCount
            && lhs.message.finishReason == rhs.message.finishReason
    }

    var body: some View {
        // Per-bubble render counter. The streaming bubble re-renders
        // per token; cross-reference with `mac.ChatView.body` and
        // `chatStream.handleACPEvent` to see whether streaming churn
        // lives in the parent, the bubble, or the event handler.
        let _: Void = ScarfMon.event(.chatRender, "mac.RichMessageBubble.body")
        if message.isUser {
            userBubble
        } else if message.isAssistant {
            assistantBubble
        }
        // Tool result messages are rendered inline in ToolCallCard, not as standalone bubbles
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .font(ChatFontScale.body(chatFontScale))
                    .foregroundStyle(ScarfColor.onAccent)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(
                                topLeading: 14,
                                bottomLeading: 14,
                                bottomTrailing: 4,
                                topTrailing: 14
                            )
                        )
                        .fill(ScarfColor.accent)
                    )
            }
            if let time = message.timestamp {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(ScarfColor.success)
                    Text(time, style: .time)
                        .font(ChatFontScale.caption2(chatFontScale))
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar — rust gradient sparkles, matches ScarfChatView's pattern.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ScarfGradient.brand)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                        .font(.system(size: 12, weight: .semibold))
                )
                .scarfShadow(.sm)

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    if message.hasReasoning, reasoningStyle != .hidden {
                        reasoningSection
                    }
                    if !message.content.isEmpty {
                        contentView
                    }
                    if !message.toolCalls.isEmpty, toolCardStyle != .hidden {
                        toolCallsSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )
                metadataFooter
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content Rendering

    @ViewBuilder
    private var contentView: some View {
        // Skip the per-token code-fence walk while the streaming bubble
        // is in flight (id == 0). At ~30–60 chunks/sec the parse was
        // the dominant chat-render cost; render plain markdown until
        // finalize and the body re-evaluates once with a permanent id.
        // The Equatable short-circuit on RichMessageBubble (id != 0)
        // then memoizes the parsed blocks for the lifetime of the
        // bubble — no per-render cache needed.
        if message.id == 0 && !Self.contentMayContainMedia(message.content) {
            MarkdownContentView(content: message.content)
        } else {
            let blocks = parseContentBlocks(message.content)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        MarkdownContentView(content: text)
                    case .code(let code, let language):
                        CodeBlockView(code: code, language: language)
                    case .media(let media):
                        MessageMediaAttachmentView(media: media)
                    }
                }
            }
        }
    }

    // MARK: - Reasoning

    /// Reasoning is rendered in one of three styles, controlled by
    /// `Settings → Display → Chat density → Reasoning` (issue #48).
    /// Token count for the reasoning-bearing message is kept in the
    /// metadataFooter (always-visible), so collapsing or hiding the
    /// box doesn't drop telemetry.
    @ViewBuilder
    private var reasoningSection: some View {
        switch reasoningStyle {
        case .disclosure:
            reasoningDisclosure
        case .inline:
            reasoningInline
        case .hidden:
            EmptyView()
        }
    }

    private var reasoningDisclosure: some View {
        DisclosureGroup {
            Text(message.preferredReasoning ?? "")
                .font(ChatFontScale.monoSmall(chatFontScale))
                .foregroundStyle(ScarfColor.foregroundMuted)
                .italic()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                Text("REASONING")
                    .font(ChatFontScale.captionStrong(chatFontScale))
                    .tracking(0.5)
                if let tokens = message.tokenCount, tokens > 0 {
                    Text("· \(tokens) tok")
                        .font(ChatFontScale.monoSmall(chatFontScale))
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }
        }
        .foregroundStyle(ScarfColor.warning)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(ScarfColor.warning.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(ScarfColor.warning.opacity(0.30), lineWidth: 1))
        )
    }

    /// Inline reasoning: italic foregroundFaint caption with a 9pt
    /// brain prefix, no box / border / disclosure. Same data, far less
    /// vertical space — addresses the #48 complaint.
    private var reasoningInline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "brain")
                .font(.system(size: 9))
                .foregroundStyle(ScarfColor.warning)
            Text(message.preferredReasoning ?? "")
                .font(ChatFontScale.caption(chatFontScale))
                .italic()
                .foregroundStyle(ScarfColor.foregroundFaint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Tool Calls

    /// Tool calls render in one of three styles, controlled by
    /// `Settings → Display → Chat density → Tool calls` (issue #47).
    /// `.hidden` is handled by the caller (skips this view entirely)
    /// AND by the parent `MessageGroupView`, which makes its
    /// always-visible toolSummary pill tappable so the inspector pane
    /// remains reachable in both compact and hidden modes.
    @ViewBuilder
    private var toolCallsSection: some View {
        switch toolCardStyle {
        case .full:
            toolCallsFull
        case .compact:
            toolCallsCompact
        case .hidden:
            EmptyView()
        }
    }

    private var toolCallsFull: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.toolCalls) { call in
                ToolCallCard(
                    call: call,
                    result: toolResults[call.callId],
                    isFocused: chatViewModel.focusedToolCallId == call.callId,
                    onFocus: nil
                )
            }
        }
    }

    /// One-line tappable chip per call. Click expands the row inline
    /// instead of summoning the side inspector; users can inspect tool
    /// details without the chat layout shifting sideways. Status dot
    /// mirrors the full-card status icon: in-flight
    /// progress / success check / non-zero exit code → danger.
    private var toolCallsCompact: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(message.toolCalls) { call in
                let result = toolResults[call.callId]
                let isExpanded = expandedCompactToolCallId == call.callId
                let color = compactToolColor(for: call.toolKind)
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        withAnimation(ScarfAnimation.fast) {
                            expandedCompactToolCallId = isExpanded ? nil : call.callId
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: call.toolKind.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(color)
                            Text(call.functionName)
                                .font(ChatFontScale.monoSmall(chatFontScale))
                                .fontWeight(.medium)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !call.argumentsSummary.isEmpty {
                                Text(call.argumentsSummary)
                                    .font(ChatFontScale.monoSmall(chatFontScale))
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 6)
                            compactStatusIcon(call: call, result: result)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(ScarfColor.foregroundFaint)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(color.opacity(isExpanded ? 0.16 : 0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(
                                            color.opacity(isExpanded ? 0.45 : 0.20),
                                            lineWidth: isExpanded ? 1.2 : 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Click to expand this tool call inline")
                    if isExpanded {
                        compactToolInlineDetails(call: call, result: result)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func compactToolInlineDetails(call: HermesToolCall, result: HermesMessage?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !call.arguments.isEmpty && call.arguments != "{}" {
                Text("ARGUMENTS")
                    .font(ChatFontScale.captionStrong(chatFontScale))
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Text(call.arguments)
                    .font(ChatFontScale.monoSmall(chatFontScale))
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScarfColor.backgroundSecondary, in: RoundedRectangle(cornerRadius: 6))
            }
            if let result, !result.content.isEmpty {
                Text("RESULT")
                    .font(ChatFontScale.captionStrong(chatFontScale))
                    .foregroundStyle(ScarfColor.foregroundMuted)
                ToolResultContent(content: result.content)
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func compactStatusIcon(call: HermesToolCall, result: HermesMessage?) -> some View {
        if let exit = call.exitCode {
            Image(systemName: exit == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(exit == 0 ? ScarfColor.success : ScarfColor.danger)
        } else if result != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(ScarfColor.success)
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private func compactToolColor(for kind: ToolKind) -> Color {
        switch kind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }

    // MARK: - Metadata Footer

    private var metadataFooter: some View {
        HStack(spacing: 8) {
            if let tokens = message.tokenCount, tokens > 0 {
                Text("\(tokens) tok")
                    .font(ChatFontScale.monoSmall(chatFontScale))
            }
            if let reason = message.finishReason,
               Self.shouldShowFinishReason(reason)
            {
                Text("·")
                Text(reason)
                    .font(ChatFontScale.caption(chatFontScale))
                    .foregroundStyle(Self.finishReasonTone(reason))
            }
            if let time = message.timestamp {
                Text("·")
                Text(time, style: .time)
                    .font(ChatFontScale.caption(chatFontScale))
            }
            if let seconds = turnDuration {
                Text("·")
                Text(RichChatViewModel.formatTurnDuration(seconds))
                    .font(ChatFontScale.monoSmall(chatFontScale))
                    .help("Wall-clock duration of this turn")
            }
            // Per-message TTS playback toggle (issue #66). Only on
            // settled assistant bubbles — streaming bubble (id == 0)
            // would speak partial text. Empty content has nothing to
            // speak.
            if message.id != 0, !message.content.isEmpty {
                speakButton
            }
        }
        .font(ChatFontScale.caption(chatFontScale))
        .foregroundStyle(ScarfColor.foregroundFaint)
        .padding(.leading, 4)
    }

    /// Whether `finishReason` should render as a visible badge in the
    /// message footer. `stop` and `end_turn` are normal end-of-turn
    /// signals — `RichChatViewModel.finalizeStreamingMessage` stamps
    /// `"stop"` on every text-bearing turn-final assistant message —
    /// so showing them creates the impression that something stopped
    /// the agent prematurely. We suppress them and reserve the badge
    /// for abnormal terminations (max_tokens, error, refusal,
    /// content_filter, …) the user actually wants to see. Matches
    /// the conventions in ChatGPT, Claude.ai, Cursor, etc.
    private static func shouldShowFinishReason(_ reason: String) -> Bool {
        let normalized = reason.trimmingCharacters(in: .whitespaces).lowercased()
        return !["stop", "end_turn", "end-turn", ""].contains(normalized)
    }

    private static func contentMayContainMedia(_ content: String) -> Bool {
        content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .hasPrefix("MEDIA:")
        }
    }

    /// Visual tone for an abnormal finish-reason badge. Severity
    /// scales: warning (yellow) for "the response was cut short" cases
    /// the user can usually retry, danger (red) for outright failures
    /// or refusals, muted otherwise so unrecognized reasons stay
    /// readable but un-alarming.
    private static func finishReasonTone(_ reason: String) -> Color {
        switch reason.lowercased() {
        case "max_tokens", "length", "content_filter":
            return ScarfColor.warning
        case "error", "refusal":
            return ScarfColor.danger
        default:
            return ScarfColor.foregroundMuted
        }
    }

    /// Speaker glyph that toggles `AVSpeechSynthesizer` playback for
    /// the assistant reply. Lives in its own view so the
    /// `MessageSpeechService` observation doesn't fight the bubble's
    /// `Equatable` short-circuit — the parent only needs to pass
    /// stable id + content; this view re-renders on its own when
    /// playback state flips.
    private var speakButton: some View {
        SpeakMessageButton(messageId: message.id, content: message.content)
    }
}

/// Stand-alone speaker button so the `MessageSpeechService`
/// observation doesn't get short-circuited by `RichMessageBubble`'s
/// `Equatable`. Only the button re-renders when playback flips —
/// the bubble itself stays optimised.
private struct SpeakMessageButton: View {
    let messageId: Int
    let content: String

    @State private var speech = MessageSpeechService.shared

    var body: some View {
        let isPlaying = speech.playingMessageId == messageId
        Button {
            speech.toggle(messageId: messageId, content: content)
        } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(isPlaying ? ScarfColor.accent : ScarfColor.foregroundFaint)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Stop speaking" : "Read this reply aloud")
    }
}

// MARK: - Content Block Parsing

private enum ContentBlock {
    case text(String)
    case code(String, String?)
    case media(MessageMediaAttachment)
}

private struct MessageMediaAttachment: Equatable, Identifiable {
    enum Kind: Equatable {
        case image
        case video
        case file
    }

    let id: String
    let url: URL
    let kind: Kind

    var displayName: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var isReachableLocalFile: Bool {
        guard url.isFileURL else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsedURL: URL
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" || url.scheme == "file" {
            parsedURL = url
        } else {
            parsedURL = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }

        self.id = parsedURL.absoluteString
        self.url = parsedURL
        let ext = parsedURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext) {
            self.kind = .image
        } else if ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext) {
            self.kind = .video
        } else {
            self.kind = .file
        }
    }
}

private struct MessageMediaAttachmentView: View, Equatable {
    let media: MessageMediaAttachment
    @Environment(\.serverContext) private var serverContext
    @State private var fileBackedImage: NSImage?
    @State private var fileBackedImageError: String?

    static func == (lhs: MessageMediaAttachmentView, rhs: MessageMediaAttachmentView) -> Bool {
        lhs.media == rhs.media
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            switch media.kind {
            case .image:
                imagePreview
            case .video:
                videoPreview
            case .file:
                filePreview(icon: "doc")
            }

            HStack(spacing: ScarfSpace.s2) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ScarfColor.accent)
                Text(media.displayName)
                    .font(ChatFontScale.caption(1.0))
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: ScarfSpace.s2)
                Button("Open") {
                    openMedia()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundPrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
        .contextMenu {
            Button("Open") { openMedia() }
            Button("Copy Path") { copyMediaReference() }
        }
    }
    @ViewBuilder
    private var imagePreview: some View {
        if media.url.isFileURL {
            Group {
                if let image = fileBackedImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous))
                } else if let fileBackedImageError {
                    filePreview(
                        icon: fileBackedImageError == "File not found" ? "photo.badge.exclamationmark" : "photo",
                        message: fileBackedImageError
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: 560, minHeight: 160, alignment: .center)
                }
            }
            .task(id: "\(serverContext.id.uuidString)|\(media.id)") {
                await loadFileBackedImage()
            }
            .onChange(of: media.id) { _, _ in
                fileBackedImage = nil
                fileBackedImageError = nil
            }
            .onChange(of: serverContext.id) { _, _ in
                fileBackedImage = nil
                fileBackedImageError = nil
            }
        } else {
            AsyncImage(url: media.url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: 560, minHeight: 160, alignment: .center)
                case .success(let image):
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 360)
                case .failure:
                    filePreview(icon: "photo.badge.exclamationmark")
                @unknown default:
                    filePreview(icon: "photo.badge.exclamationmark")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous))
        }
    }

    private func loadFileBackedImage() async {
        let path = media.url.path
        let context = serverContext
        let result: (image: NSImage?, error: String?) = await Task.detached {
            let transport = context.makeTransport()
            guard transport.fileExists(path) else { return (nil, "File not found") }
            do {
                let data = try transport.readFile(path)
                if let image = NSImage(data: data) {
                    return (image, nil)
                }
                return (nil, "Preview unavailable")
            } catch {
                return (nil, "Preview unavailable")
            }
        }.value

        fileBackedImage = result.image
        fileBackedImageError = result.error
    }

    @ViewBuilder
    private var videoPreview: some View {
        if media.isReachableLocalFile || !media.url.isFileURL {
            AppKitInlineVideoPlayer(url: media.url)
                .frame(maxWidth: 560)
                .frame(height: 315)
                .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous))
        } else {
            filePreview(icon: "film.badge.exclamationmark")
        }
    }

    private func filePreview(icon: String, message: String? = nil) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(message ?? (media.isReachableLocalFile ? "Preview unavailable" : "File not found"))
                .font(ChatFontScale.caption(1.0))
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .frame(maxWidth: 560, minHeight: 72, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
    }

    private var iconName: String {
        switch media.kind {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .file: return "paperclip"
        }
    }

    private func openMedia() {
#if canImport(AppKit)
        NSWorkspace.shared.open(media.url)
#endif
    }

    private func copyMediaReference() {
#if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(media.url.isFileURL ? media.url.path : media.url.absoluteString, forType: .string)
#endif
    }

}

#if canImport(AppKit)
private struct AppKitInlineVideoPlayer: NSViewRepresentable, Equatable {
    let url: URL

    static func == (lhs: AppKitInlineVideoPlayer, rhs: AppKitInlineVideoPlayer) -> Bool {
        lhs.url == rhs.url
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = context.coordinator.player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.update(url: url)
        if nsView.player !== context.coordinator.player {
            nsView.player = context.coordinator.player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player.pause()
        nsView.player = nil
    }

    final class Coordinator {
        private(set) var url: URL
        private(set) var player: AVPlayer

        init(url: URL) {
            self.url = url
            self.player = AVPlayer(url: url)
        }

        func update(url: URL) {
            guard url != self.url else { return }
            player.pause()
            self.url = url
            self.player = AVPlayer(url: url)
        }

        deinit {
            player.pause()
        }
    }
}
#endif

private func parseContentBlocks(_ content: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    let lines = content.components(separatedBy: "\n")
    var currentText: [String] = []
    var currentCode: [String] = []
    var codeLanguage: String?
    var inCode = false

    func flushText() {
        let text = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(.text(text))
        }
        currentText = []
    }

    for line in lines {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inCode && line.hasPrefix("```") {
            flushText()
            inCode = true
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeLanguage = lang.isEmpty ? nil : lang
        } else if inCode && line.hasPrefix("```") {
            blocks.append(.code(currentCode.joined(separator: "\n"), codeLanguage))
            currentCode = []
            codeLanguage = nil
            inCode = false
        } else if inCode {
            currentCode.append(line)
        } else if trimmedLine.uppercased().hasPrefix("MEDIA:") {
            flushText()
            let rawMedia = String(trimmedLine.dropFirst("MEDIA:".count))
            if let media = MessageMediaAttachment(rawValue: rawMedia) {
                blocks.append(.media(media))
            } else {
                currentText.append(line)
            }
        } else {
            currentText.append(line)
        }
    }

    if inCode && !currentCode.isEmpty {
        blocks.append(.code(currentCode.joined(separator: "\n"), codeLanguage))
    }
    flushText()

    return blocks
}
