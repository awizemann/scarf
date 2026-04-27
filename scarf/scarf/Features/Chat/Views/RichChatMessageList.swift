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
                            .equatable()
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

struct MessageGroupView: View, Equatable {
    let group: MessageGroup
    /// Wall-clock turn durations keyed by assistant-message id (v2.5).
    /// Forwarded into `RichMessageBubble` so the metadata footer can
    /// render the stopwatch pill. Defaults empty so existing callers
    /// that haven't been updated yet still compile.
    var turnDurations: [Int: TimeInterval] = [:]

    @Environment(ChatViewModel.self) private var chatViewModel
    /// Read here so the toolSummary pill knows whether to render as
    /// always-visible (today's behavior) or as a tappable inspector
    /// shortcut when per-call tool cards are hidden (issue #47).
    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyleRaw: String = ToolCardStyle.full.rawValue
    private var toolCardStyle: ToolCardStyle {
        ToolCardStyle(rawValue: toolCardStyleRaw) ?? .full
    }

    /// Equatable short-circuit for SwiftUI: when the trailing group's
    /// streaming bubble grows, only that group's `==` returns false.
    /// All earlier groups skip body re-evaluation, dropping per-chunk
    /// render work from O(n) to O(1) for settled groups (issue #46).
    ///
    /// What participates:
    ///  - `group.id` (primary key — stable sequential index).
    ///  - assistant-message id list (additions / finalize-id-flip).
    ///  - For the streaming message (id == 0): content, reasoning,
    ///    reasoningContent, toolCalls.count — the only fields that
    ///    mutate while streaming.
    ///  - `turnDurations[msg.id]` for assistants in this group only —
    ///    the dict is large and shared across groups, but each group
    ///    only renders its own entries.
    ///  - `group.toolResults.count` — append-only within a group.
    static func == (lhs: MessageGroupView, rhs: MessageGroupView) -> Bool {
        guard lhs.group.id == rhs.group.id else { return false }
        guard lhs.group.userMessage?.id == rhs.group.userMessage?.id else { return false }
        guard lhs.group.userMessage?.content == rhs.group.userMessage?.content else { return false }
        guard lhs.group.assistantMessages.count == rhs.group.assistantMessages.count else { return false }
        for (l, r) in zip(lhs.group.assistantMessages, rhs.group.assistantMessages) {
            if l.id != r.id { return false }
            if l.id == 0 {
                if l.content != r.content { return false }
                if l.reasoning != r.reasoning { return false }
                if l.reasoningContent != r.reasoningContent { return false }
                if l.toolCalls.count != r.toolCalls.count { return false }
            }
        }
        if lhs.group.toolResults.count != rhs.group.toolResults.count { return false }
        for msg in lhs.group.assistantMessages where msg.isAssistant && msg.id != 0 {
            if lhs.turnDurations[msg.id] != rhs.turnDurations[msg.id] { return false }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let user = group.userMessage {
                RichMessageBubble(message: user, toolResults: [:])
                    .equatable()
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
                .equatable()
            }

            // When per-call tool cards are visible, the summary pill
            // is informational only. When tool cards are hidden
            // (issue #47), this pill becomes the only chrome surfacing
            // tool activity AND the only path back into the inspector
            // pane — render it on every group with calls (not just >1)
            // and make it tappable to focus the first call.
            let showSummary = (toolCardStyle == .hidden)
                ? group.toolCallCount > 0
                : group.toolCallCount > 1
            if showSummary {
                toolSummary
            }
        }
    }

    @ViewBuilder
    private var toolSummary: some View {
        let kinds = group.toolKindCounts
        if !kinds.isEmpty {
            let firstCallId = group.assistantMessages
                .flatMap(\.toolCalls)
                .first?.callId
            let isInteractive = (toolCardStyle == .hidden) && firstCallId != nil
            Group {
                if isInteractive, let firstCallId {
                    Button {
                        chatViewModel.focusedToolCallId = firstCallId
                    } label: {
                        toolSummaryPill(kinds, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .help("Click to inspect tool calls")
                } else {
                    toolSummaryPill(kinds, interactive: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func toolSummaryPill(_ kinds: [ToolKind: Int], interactive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "wrench")
                .font(.caption2)
            Text(summaryText(kinds))
                .font(.caption2)
            if interactive {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.tertiary)
    }

    private func summaryText(_ kinds: [ToolKind: Int]) -> String {
        let total = kinds.values.reduce(0, +)
        let parts = kinds.sorted(by: { $0.value > $1.value })
            .map { "\($0.value) \($0.key.rawValue)" }
            .joined(separator: ", ")
        return "Used \(total) tools (\(parts))"
    }
}
