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
                    if message.hasReasoning {
                        reasoningSection
                    }
                    if !message.content.isEmpty {
                        contentView
                    }
                    if !message.toolCalls.isEmpty {
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

    private var reasoningSection: some View {
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

    // MARK: - Tool Calls

    private var toolCallsSection: some View {
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
