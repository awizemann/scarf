import SwiftUI

struct RichChatMessageList: View {
    let groups: [MessageGroup]
    let isWorking: Bool
    /// External trigger to force a scroll-to-bottom (e.g., from "Return to Active Session").
    var scrollTrigger: UUID = UUID()

    /// Stable scroll target. Must NOT depend on `isWorking` — if the anchor
    /// flipped between "typing-indicator" and "group-N" at stream start/
    /// finish, two onChange handlers would race to scroll to different
    /// targets and the chat would visibly jump.
    private var scrollAnchor: String {
        if let last = groups.last { return "group-\(last.id)" }
        return "scroll-top"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 0)
                        .id("scroll-top")

                    if groups.isEmpty && !isWorking {
                        emptyState
                    }

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
            .onAppear {
                if !groups.isEmpty {
                    DispatchQueue.main.async {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                }
            }
            // New turn: animate to the bottom.
            .onChange(of: groups.count) {
                scrollToBottom(proxy: proxy)
            }
            // Streaming chunks: track the bottom without animation so the
            // text glides instead of bouncing.
            .onChange(of: groups.last?.assistantMessages.last?.content ?? "") {
                scrollToBottom(proxy: proxy, animated: false)
            }
            // Explicit "Return to Active Session" button.
            .onChange(of: scrollTrigger) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Chat Messages")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Messages will appear here as the conversation progresses.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
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

            // Identify by array offset rather than `message.id`. The
            // streaming assistant message starts with id=0 and gets a
            // new negative id when finalized — using `\.id` would make
            // SwiftUI think the bubble disappeared and a new one appeared
            // (destroying + recreating the view, which manifests as the
            // chat flashing or jumping right when the prompt completes).
            // Within a single group the assistant messages are
            // append-only, so offset is a stable identity for the
            // group's lifetime.
            let assistantMessages = group.assistantMessages.filter(\.isAssistant)
            ForEach(Array(assistantMessages.enumerated()), id: \.offset) { _, message in
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
