import SwiftUI
import ScarfCore
import ScarfDesign

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
                    .scarfStyle(.body)
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
                        .font(ScarfFont.caption2)
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
        let blocks = parseContentBlocks(message.content)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownContentView(content: text)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
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
                .font(ScarfFont.monoSmall)
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
                    .scarfStyle(.captionStrong)
                    .tracking(0.5)
                if let tokens = message.tokenCount, tokens > 0 {
                    Text("· \(tokens) tok")
                        .font(ScarfFont.monoSmall)
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
                .font(ScarfFont.caption)
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
                    onFocus: { chatViewModel.focusedToolCallId = call.callId }
                )
            }
        }
    }

    /// One-line tappable chip per call. Click sets focus so the right-
    /// pane inspector opens with the same data the inline expand
    /// shows. Status dot mirrors the full-card status icon: in-flight
    /// progress / success check / non-zero exit code → danger.
    private var toolCallsCompact: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(message.toolCalls) { call in
                let result = toolResults[call.callId]
                let isFocused = chatViewModel.focusedToolCallId == call.callId
                let color = compactToolColor(for: call.toolKind)
                Button {
                    chatViewModel.focusedToolCallId = call.callId
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: call.toolKind.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(color)
                        Text(call.functionName)
                            .font(ScarfFont.monoSmall)
                            .fontWeight(.medium)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        compactStatusIcon(call: call, result: result)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color.opacity(isFocused ? 0.16 : 0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        color.opacity(isFocused ? 0.45 : 0.20),
                                        lineWidth: isFocused ? 1.2 : 1
                                    )
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Click to inspect this tool call")
            }
        }
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
                    .font(ScarfFont.monoSmall)
            }
            if let reason = message.finishReason, !reason.isEmpty {
                Text("·")
                Text(reason)
                    .scarfStyle(.caption)
            }
            if let time = message.timestamp {
                Text("·")
                Text(time, style: .time)
                    .scarfStyle(.caption)
            }
            if let seconds = turnDuration {
                Text("·")
                Text(RichChatViewModel.formatTurnDuration(seconds))
                    .font(ScarfFont.monoSmall)
                    .help("Wall-clock duration of this turn")
            }
        }
        .foregroundStyle(ScarfColor.foregroundFaint)
        .padding(.leading, 4)
    }
}

// MARK: - Content Block Parsing

private enum ContentBlock {
    case text(String)
    case code(String, String?)
}

private func parseContentBlocks(_ content: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    let lines = content.components(separatedBy: "\n")
    var currentText: [String] = []
    var currentCode: [String] = []
    var codeLanguage: String?
    var inCode = false

    for line in lines {
        if !inCode && line.hasPrefix("```") {
            if !currentText.isEmpty {
                blocks.append(.text(currentText.joined(separator: "\n")))
                currentText = []
            }
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
        } else {
            currentText.append(line)
        }
    }

    if inCode && !currentCode.isEmpty {
        blocks.append(.code(currentCode.joined(separator: "\n"), codeLanguage))
    }
    if !currentText.isEmpty {
        let text = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(.text(text))
        }
    }

    return blocks
}
