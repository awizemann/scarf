import SwiftUI
import ScarfCore

struct RichMessageBubble: View {
    let message: HermesMessage
    let toolResults: [String: HermesMessage]
    /// Wall-clock duration of the agent turn this assistant message
    /// belongs to (v2.5). Rendered as a compact stopwatch pill in the
    /// metadata footer when present. Nil for user bubbles, for the
    /// streaming-in-progress placeholder, and for resumed sessions
    /// loaded from `state.db` (no live timing available).
    var turnDuration: TimeInterval? = nil

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
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let time = message.timestamp {
                Text(time, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Spacer(minLength: 40)
            }

            metadataFooter
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
            // v2.5: prefer the v0.11 `reasoning_content` column (newer,
            // typically richer); fall back to the legacy `reasoning`
            // blob when only it's populated.
            Text(message.preferredReasoning ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 4) {
                Text("Reasoning")
                if let tokens = message.tokenCount, tokens > 0 {
                    Text("(\(tokens) tokens)")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.orange)
    }

    // MARK: - Tool Calls

    private var toolCallsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.toolCalls) { call in
                ToolCallCard(
                    call: call,
                    result: toolResults[call.callId]
                )
            }
        }
    }

    // MARK: - Metadata Footer

    private var metadataFooter: some View {
        HStack(spacing: 8) {
            if let tokens = message.tokenCount, tokens > 0 {
                Text("\(tokens) tokens")
            }
            if let reason = message.finishReason, !reason.isEmpty {
                Text(reason)
            }
            if let time = message.timestamp {
                Text(time, style: .time)
            }
            if let seconds = turnDuration {
                Text(RichChatViewModel.formatTurnDuration(seconds))
                    .help("Wall-clock duration of this turn")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
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
