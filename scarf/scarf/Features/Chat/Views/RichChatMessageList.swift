import SwiftUI

struct RichChatMessageList: View {
    let groups: [MessageGroup]
    let isWorking: Bool
    /// External trigger to force a scroll-to-bottom (e.g., from "Return to Active Session").
    var scrollTrigger: UUID = UUID()

    /// Why `.defaultScrollAnchor(.bottom)` *alone* and no `proxy.scrollTo`.
    ///
    /// `.defaultScrollAnchor(.bottom)` tells SwiftUI to pin the viewport to
    /// the bottom of the content automatically — as messages stream in or
    /// new turns arrive, the scroll position tracks the bottom edge.
    ///
    /// We used to also call `proxy.scrollTo(lastID, anchor: .bottom)` from
    /// six different `onChange` handlers during streaming. The two
    /// mechanisms fought each other: the ScrollViewReader can resolve an ID
    /// to a position **before** LazyVStack has finished laying out that
    /// row, so `scrollTo` would land past the actual content — the
    /// "viewport showing whitespace, chat is above" symptom. Removing the
    /// manual scroll and trusting `defaultScrollAnchor` eliminates the race.
    ///
    /// The only remaining explicit scroll is `scrollTrigger` for the "Return
    /// to Active Session" button; that fires rarely, after layout has
    /// settled, so the overshoot doesn't happen.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
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
            .onChange(of: scrollTrigger) {
                let target = lastAnchorID
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }
    }

    /// Anchor ID used by the explicit scrollTrigger path. Prefers the typing
    /// indicator when visible (so we scroll to the very bottom of the
    /// current turn), otherwise the last group.
    private var lastAnchorID: String {
        if isWorking { return "typing-indicator" }
        if let last = groups.last { return "group-\(last.id)" }
        return "group-0"
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
