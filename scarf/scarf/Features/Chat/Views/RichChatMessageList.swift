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
    /// Show the "Load earlier messages" button at the top of the
    /// transcript when the underlying session has more on-disk
    /// history that hasn't been paged in yet. Hidden by default so
    /// existing callers who haven't opted in see no UI change.
    var hasMoreHistory: Bool = false
    var hasNewerHistory: Bool = false
    var isLoadingEarlier: Bool = false
    var onLoadEarlier: (() async -> Void)? = nil
    var onLoadNewer: (() async -> Void)? = nil
    /// True while the v2.8 two-phase loader's background hydration
    /// is filling in `toolCalls` JSON + tool-result rows. Forwarded
    /// to `MessageGroupView` so it can skip render-side bubble
    /// coalescing while messages are mid-hydration — otherwise pairs
    /// that were merged pre-hydration un-merge as each one's tools
    /// land, which the user perceives as bubbles spawning one-by-one.
    var isHydratingTools: Bool = false

    @State private var initialBottomAnchor: String?

    /// Scrolling strategy: bounded input (`groups` is already windowed by
    /// `RichChatViewModel`) plus `LazyVStack`. We avoid the old
    /// `.defaultScrollAnchor(.bottom)` overshoot by using explicit anchors:
    /// initial load and "jump to bottom" scroll to `bottom-anchor`; prepends
    /// preserve the previously-first visible group.
    var body: some View {
        // ScarfMon — confirms whether the parent re-issues the
        // ForEach. If this fires once and we still see RichMessageBubble.body
        // burst N times, churn lives inside the bubbles (or in their inputs).
        // If this fires N times, the ForEach itself is being rebuilt.
        let _: Void = ScarfMon.event(.chatRender, "mac.RichChatMessageList.body")
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
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

                    if hasMoreHistory, let onLoadEarlier {
                        historySentinel(
                            id: olderSentinelID,
                            label: isLoadingEarlier ? "Loading earlier…" : "Loading earlier messages",
                            systemImage: "arrow.up.circle",
                            isLoading: isLoadingEarlier
                        ) {
                            await loadEarlierAndPreserveAnchor(proxy: proxy, action: onLoadEarlier)
                        }
                    }

                    ForEach(groups) { group in
                        MessageGroupView(
                            group: group,
                            turnDurations: turnDurations,
                            isHydratingTools: isHydratingTools
                        )
                        .equatable()
                        .id("group-\(group.id)")
                    }

                    if isWorking {
                        typingIndicator
                            .id("typing-indicator")
                    }

                    if hasNewerHistory, let onLoadNewer {
                        historySentinel(
                            id: newerSentinelID,
                            label: "Load newer messages",
                            systemImage: "arrow.down.circle",
                            isLoading: false
                        ) {
                            await onLoadNewer()
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom-anchor")
                }
                .padding()
                // Intentionally NO `.animation(_:value:)` on this VStack.
                // `.animation(value:)` applies its animation context to
                // every descendant change in the same render pass — so
                // when `groups.isEmpty` flips on session load, the 25+
                // newly-inserted MessageGroupView children all run
                // through the implicit transition. Combined with the
                // per-bubble first-render cost (markdown parsing,
                // metadata layout) the bubbles cascade in over time
                // and the user perceives a "loading message-by-message"
                // effect on opening an old chat. Letting state changes
                // land instantly is the right trade for chat history;
                // the empty-state fade was a minor flourish, not a
                // load-bearing affordance.
            }
            .task(id: initialScrollKey) {
                guard !groups.isEmpty else {
                    initialBottomAnchor = nil
                    return
                }
                // Only auto-pin on the initial/latest window. When the user is
                // browsing an older in-memory slice, `groups.last` changes as
                // the window slides; treating that as an "initial load" yanks
                // the scroll position to the bottom of the slice and can make
                // the transcript appear to disappear for a frame.
                guard !hasNewerHistory else { return }
                guard initialBottomAnchor != initialScrollKey else { return }
                initialBottomAnchor = initialScrollKey
                await MainActor.run {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: scrollTrigger) {
                let target = lastAnchorID
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(target == "group-0" ? "bottom-anchor" : target, anchor: .bottom)
                }
            }
        }
    }

    private var initialScrollKey: String {
        groups.last.map { "initial-\($0.id)" } ?? "empty"
    }

    /// Anchor ID used by the explicit scrollTrigger path. Prefers the typing
    /// indicator when visible (so we scroll to the very bottom of the
    /// current turn), otherwise the last group.
    private var lastAnchorID: String {
        if isWorking { return "typing-indicator" }
        if let last = groups.last { return "group-\(last.id)" }
        return "group-0"
    }

    private var firstAnchorID: String {
        if let first = groups.first { return "group-\(first.id)" }
        return "group-0"
    }

    private var olderSentinelID: String { "older-sentinel-\(firstAnchorID)" }
    private var newerSentinelID: String { "newer-sentinel-\(lastAnchorID)" }

    @ViewBuilder
    private func historySentinel(
        id: String,
        label: String,
        systemImage: String,
        isLoading: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            guard !isLoading else { return }
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: systemImage).font(.caption)
                }
                Text(label).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .id(id)
    }

    private func loadEarlierAndPreserveAnchor(
        proxy: ScrollViewProxy,
        action: @escaping () async -> Void
    ) async {
        let anchor = firstAnchorID
        await action()
        await MainActor.run {
            proxy.scrollTo(anchor, anchor: .top)
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
    /// Plumbed in from the parent so the coalescing decision can
    /// participate in the Equatable short-circuit. Without this the
    /// hydration-end transition wouldn't re-render — `==` would see
    /// the same `group` + `turnDurations` and skip body. Stored
    /// property + included in `==` ensures the flag flip cascades
    /// through every visible bubble exactly once.
    var isHydratingTools: Bool = false

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
        // Hydration flag flip changes the assistant-bubble layout
        // (coalesced vs raw) — must invalidate or the body never
        // re-evals after Phase 2 finishes.
        guard lhs.isHydratingTools == rhs.isHydratingTools else { return false }
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
            //
            // `coalescedAssistantBubbles` collapses runs of consecutive
            // pure-text assistant messages into one synthesized bubble
            // so that turns Hermes recorded as multiple `assistant`
            // rows (split by an interleaving tool call, or emitted as
            // multiple discrete chunks by some thinking models) read
            // as one continuous reply. Tool-bearing bubbles and the
            // streaming bubble (id == 0) are never merged — see the
            // computed's docs for the invariants.
            //
            // Coalescing is GATED on `!isHydratingTools` because the
            // v2.8 two-phase loader populates `toolCalls` after the
            // initial render — assistants with empty `toolCalls`
            // pre-hydration would merge into a single bubble, then
            // un-merge as Phase 2 reveals each one's tools. The user
            // perceives this as bubbles spawning one-by-one. By
            // skipping the merge during hydration we render the raw
            // shape up front; a single re-render at hydration end
            // applies coalescing if it's still appropriate.
            let assistantBubbles = isHydratingTools
                ? group.assistantMessages.filter(Self.shouldRenderAssistantBubble)
                : group.coalescedAssistantBubbles.filter(Self.shouldRenderAssistantBubble)
            ForEach(Array(assistantBubbles.enumerated()), id: \.offset) { _, message in
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

    /// Suppress skeleton assistant rows whose only persisted signal is
    /// `finish_reason = tool_calls` while Phase 2 is still hydrating the
    /// actual `tool_calls` JSON. Without this, reopening a tool-heavy
    /// chat briefly renders empty assistant bubbles that show only
    /// metadata like “· tool_calls · 12:16”. Once hydration supplies
    /// `message.toolCalls`, the row becomes visible as a normal tool-card
    /// bubble; if hydration fails, the empty artifact stays hidden.
    private static func shouldRenderAssistantBubble(_ message: HermesMessage) -> Bool {
        guard message.isAssistant else { return false }
        return message.id == 0
            || !message.content.isEmpty
            || message.hasReasoning
            || !message.toolCalls.isEmpty
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
