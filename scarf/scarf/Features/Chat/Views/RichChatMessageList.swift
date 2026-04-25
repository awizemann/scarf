import SwiftUI
import ScarfCore

struct RichChatMessageList: View {
    let groups: [MessageGroup]
    let isWorking: Bool
    /// True while the ACP session is being established or restored — used to
    /// swap the empty-state placeholder for a progress indicator so the user
    /// knows something is happening while history loads.
    var isLoadingSession: Bool = false
    /// External trigger to force a scroll-to-bottom (e.g., from "Return to Active Session").
    var scrollTrigger: UUID = UUID()
    /// Wall-clock turn durations indexed by assistant-message id.
    /// Threaded through to `MessageGroupView` → `RichMessageBubble` so the
    /// bubble's metadata footer can render the v2.5 stopwatch pill.
    /// Defaults empty so callers that don't care can omit it.
    var turnDurations: [Int: TimeInterval] = [:]

    /// Scrolling strategy: plain `VStack` (not `LazyVStack`) plus
    /// `.defaultScrollAnchor(.bottom)`.
    ///
    /// `LazyVStack` was causing the classic "loaded session shows whitespace
    /// and the chat is above" bug: lazy rows return estimated heights before
    /// they render, `.defaultScrollAnchor(.bottom)` positions the viewport
    /// at the *estimated* bottom (which overshoots the real content), and
    /// when rows materialize and real heights land, the viewport ends up
    /// past the content. Attempts to correct via `proxy.scrollTo(lastID)`
    /// failed because unrendered rows have no resolvable ID.
    ///
    /// Switching to `VStack` materializes every row immediately, so
    /// `.defaultScrollAnchor(.bottom)` has real heights to work with and
    /// can't overshoot. For typical Hermes sessions (<500 messages) the
    /// first-render cost is acceptable. If ever needed for huge sessions
    /// we can reintroduce lazy with a preference-key-based height
    /// measurement, but that's a much larger change.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if groups.isEmpty && !isWorking {
                        // Fill the scroll view's visible height so Spacers
                        // can vertically center the placeholder. Previously
                        // `.padding(.vertical, 80)` left the placeholder
                        // floating at whatever y-offset `.defaultScrollAnchor(.bottom)`
                        // settled on — usually near the bottom of the pane.
                        VStack {
                            Spacer(minLength: 0)
                            if isLoadingSession {
                                loadingState
                            } else {
                                emptyState
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical)
                        .transition(.opacity)
                    }

                    ForEach(groups) { group in
                        MessageGroupView(group: group, turnDurations: turnDurations)
                            .id("group-\(group.id)")
                    }

                    if isWorking {
                        typingIndicator
                            .id("typing-indicator")
                    }
                }
                .padding()
                .animation(.easeInOut(duration: 0.15), value: isLoadingSession)
                .animation(.easeInOut(duration: 0.15), value: groups.isEmpty)
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
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading session…")
                .font(.callout)
                .foregroundStyle(.secondary)
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
    /// Wall-clock turn durations keyed by assistant-message id (v2.5).
    /// Forwarded into `RichMessageBubble` so the metadata footer can
    /// render the stopwatch pill. Defaults empty so existing callers
    /// that haven't been updated yet still compile.
    var turnDurations: [Int: TimeInterval] = [:]

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
                RichMessageBubble(
                    message: message,
                    toolResults: group.toolResults,
                    turnDuration: turnDurations[message.id]
                )
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
