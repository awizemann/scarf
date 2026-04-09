import SwiftUI

struct RichChatMessageList: View {
    let groups: [MessageGroup]
    let isWorking: Bool

    /// Track the last group's assistant content length to detect streaming updates.
    private var scrollAnchor: String {
        if isWorking { return "typing-indicator" }
        if let last = groups.last { return "group-\(last.id)" }
        return "scroll-top"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 0)
                        .id("scroll-top")
                    ForEach(groups) { group in
                        MessageGroupView(group: group)
                            .id("group-\(group.id)")
                    }

                    if isWorking {
                        typingIndicator
                            .id("typing-indicator")
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            // Scroll on new groups
            .onChange(of: groups.count) {
                scrollToBottom(proxy: proxy)
            }
            // Scroll when agent starts/stops working
            .onChange(of: isWorking) {
                scrollToBottom(proxy: proxy)
            }
            // Scroll on streaming content updates (group content changes)
            .onChange(of: scrollAnchor) {
                scrollToBottom(proxy: proxy)
            }
            // Scroll on last message content change (streaming text)
            .onChange(of: groups.last?.assistantMessages.last?.content ?? "") {
                scrollToBottom(proxy: proxy, animated: false)
            }
            // Scroll on tool call count change
            .onChange(of: groups.last?.toolCallCount ?? 0) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let target = scrollAnchor
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private var typingIndicator: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 80)
        }
        .symbolEffect(.pulse)
    }
}

struct MessageGroupView: View {
    let group: MessageGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let user = group.userMessage {
                RichMessageBubble(message: user, toolResults: [:])
            }

            ForEach(group.assistantMessages.filter(\.isAssistant)) { message in
                RichMessageBubble(message: message, toolResults: group.toolResults)
            }

            if group.toolCallCount > 1 {
                toolSummary
            }
        }
    }

    @ViewBuilder
    private var toolSummary: some View {
        let kinds = toolKindCounts
        if !kinds.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "wrench")
                    .font(.caption2)
                Text(summaryText(kinds))
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
        }
    }

    private var toolKindCounts: [ToolKind: Int] {
        var counts: [ToolKind: Int] = [:]
        for msg in group.assistantMessages where msg.isAssistant {
            for call in msg.toolCalls {
                counts[call.toolKind, default: 0] += 1
            }
        }
        return counts
    }

    private func summaryText(_ kinds: [ToolKind: Int]) -> String {
        let total = kinds.values.reduce(0, +)
        let parts = kinds.sorted(by: { $0.value > $1.value })
            .map { "\($0.value) \($0.key.rawValue)" }
            .joined(separator: ", ")
        return "Used \(total) tools (\(parts))"
    }
}
