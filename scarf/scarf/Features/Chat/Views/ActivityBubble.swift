import SwiftUI
import ScarfCore
import ScarfDesign

/// One aggregated bubble for a run of agent *activity* — tool calls and
/// textless reasoning — replacing the former N+1 assistant rows a
/// tool-looping turn produced (chat-transcript UX package, P1).
///
/// Layout:
///  - Header: aggregate counts ("N tools · M reasoning"), plus — when
///    this is the trailing live segment — a spinner and a Scarf-composed
///    status line ("Running terminal…", "Reasoning…", "Receiving
///    response…") derived from live ACP events (P2).
///  - Collapsed: the LATEST tool call rendered as today (full card or
///    compact chip per density).
///  - Expanded: every collapsed entry (identical consecutive calls show
///    once with a "×N" badge) and reasoning per `ReasoningStyle`.
///
/// Density: with tool cards hidden the header is all that remains for
/// tools (clicking it focuses the first call in the inspector, matching
/// the old summary pill's affordance); reasoning still follows
/// `ReasoningStyle` in the expanded area.
struct ActivityBubbleView: View {
    let segment: MessageGroup.ChatActivitySegment
    let toolResults: [String: HermesMessage]
    /// Non-nil only when this is the trailing segment of the in-flight
    /// turn — the bubble then doubles as the typing indicator.
    var liveStatus: RichChatViewModel.LiveActivityStatus? = nil
    /// Wall-clock turn durations keyed by assistant-message id (the
    /// existing v2.5 plumbing). A settled segment shows the duration
    /// recorded on one of its own source messages — honest: it's the
    /// turn stopwatch value finalize stamped, never a synthesized sum.
    var turnDurations: [Int: TimeInterval] = [:]

    @Environment(ChatViewModel.self) private var chatViewModel
    @Environment(\.chatFontScale) private var chatFontScale: Double

    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyleRaw: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyle)
    private var reasoningStyleRaw: String = ReasoningStyle.disclosure.rawValue

    @State private var expanded = false

    private var toolCardStyle: ToolCardStyle {
        ToolCardStyle(rawValue: toolCardStyleRaw) ?? .full
    }
    private var reasoningStyle: ReasoningStyle {
        ReasoningStyle(rawValue: reasoningStyleRaw) ?? .disclosure
    }

    /// Whether the expanded area would show anything at the current
    /// density. Header-only segments don't need a chevron.
    private var hasExpandableContent: Bool {
        (toolCardStyle != .hidden && segment.entries.count > 0)
            || (reasoningStyle != .hidden && segment.reasoningCount > 0)
    }

    /// Turn is over for this segment: not streaming, no live status.
    private var isSettled: Bool {
        !segment.isLive && liveStatus == nil
    }

    /// Duration recorded on one of this segment's source messages, if
    /// the v2.5 stopwatch landed there (it lands on the turn's first
    /// finalized message — usually a tool-bearing row inside the run).
    private var settledDuration: TimeInterval? {
        segment.messageIds.compactMap { turnDurations[$0] }.max()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Gear badge mirrors the assistant avatar column so activity
            // aligns with assistant bubbles rather than floating.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .font(.system(size: 11, weight: .semibold))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                // A segment holding ONLY "(empty)" sentinel rows has no
                // counts worth a pill — the muted row below carries it.
                if segment.totalToolCount > 0 || segment.reasoningCount > 0
                    || liveStatus != nil {
                    header
                }
                if segment.emptyResponseCount > 0 {
                    emptyResponseRow
                }
                if expanded {
                    expandedContent
                } else if toolCardStyle != .hidden, let latest = segment.latestEntry {
                    entryCard(latest)
                }
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        Button {
            if toolCardStyle == .hidden,
               let firstCall = segment.entries.first?.call {
                // Old summary-pill affordance: with cards hidden the
                // header is the only path into the inspector.
                chatViewModel.focusedToolCallId = firstCall.callId
            }
            if hasExpandableContent {
                withAnimation(ScarfAnimation.fast) { expanded.toggle() }
            }
        } label: {
            HStack(spacing: 6) {
                // Settled affordance: subtle completed checkmark ahead
                // of the counts once the turn is done ("✓ 23 tools · 41s").
                if isSettled {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(ScarfColor.success.opacity(0.8))
                }
                if segment.totalToolCount > 0 {
                    Image(systemName: "wrench")
                        .font(.system(size: 10))
                    Text("\(segment.totalToolCount) tools")
                        .font(ChatFontScale.caption2(chatFontScale))
                }
                if segment.reasoningCount > 0 {
                    if segment.totalToolCount > 0 {
                        Text(verbatim: "·")
                    }
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    Text("\(segment.reasoningCount) reasoning")
                        .font(ChatFontScale.caption2(chatFontScale))
                }
                if isSettled, let seconds = settledDuration {
                    Text(verbatim: "·")
                    Text(verbatim: RichChatViewModel.formatTurnDuration(seconds))
                        .font(ChatFontScale.caption2(chatFontScale))
                        .help("Wall-clock duration of this turn")
                }
                if let liveStatus {
                    if segment.totalToolCount > 0 || segment.reasoningCount > 0 {
                        Text(verbatim: "·")
                    }
                    ProgressView()
                        .controlSize(.mini)
                    statusText(liveStatus)
                        .font(ChatFontScale.caption2(chatFontScale))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                if hasExpandableContent {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(ScarfColor.backgroundSecondary)
                    .overlay(Capsule().strokeBorder(ScarfColor.border, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSettled
                ? Text("\(segment.totalToolCount) tool calls, completed, expandable")
                : Text("\(segment.totalToolCount) tool calls, expandable")
        )
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
    }

    @ViewBuilder
    private func statusText(_ status: RichChatViewModel.LiveActivityStatus) -> some View {
        switch status {
        case .runningTool(let name):
            Text("Running \(name)…")
        case .reasoning:
            Text("Reasoning…")
        case .receiving:
            Text("Receiving response…")
        }
    }

    /// Muted, honest rendering of Hermes' `"(empty)"` sentinel — the
    /// model returned an empty response. Detection is render-level
    /// only (stored content is untouched); never a full text bubble.
    private var emptyResponseRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 9))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("Empty response from the model")
                .font(ChatFontScale.caption(chatFontScale))
                .italic()
                .foregroundStyle(ScarfColor.foregroundFaint)
            if segment.emptyResponseCount > 1 {
                Text(verbatim: "×\(segment.emptyResponseCount)")
                    .font(ChatFontScale.caption2(chatFontScale))
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }

    // MARK: - Expanded content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if reasoningStyle != .hidden {
                ForEach(segment.reasoningMessages) { msg in
                    reasoningRow(msg)
                }
            }
            if toolCardStyle != .hidden {
                ForEach(segment.entries) { entry in
                    entryCard(entry)
                }
            }
        }
    }

    /// A textless reasoning message inside the segment, rendered per
    /// `ReasoningStyle`. Both non-hidden styles render as the inline
    /// treatment here — the segment's own disclosure already provides
    /// the expand/collapse affordance, so nesting a second
    /// DisclosureGroup per message would be chrome on chrome.
    private func reasoningRow(_ msg: HermesMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "brain")
                .font(.system(size: 9))
                .foregroundStyle(ScarfColor.warning)
            Text(msg.preferredReasoning ?? "")
                .font(ChatFontScale.caption(chatFontScale))
                .italic()
                .foregroundStyle(ScarfColor.foregroundFaint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: MessageGroup.ChatActivityEntry) -> some View {
        let call = entry.call
        switch toolCardStyle {
        case .full:
            ToolCallCard(
                call: call,
                result: toolResults[call.callId],
                isFocused: chatViewModel.focusedToolCallId == call.callId,
                onFocus: { chatViewModel.focusedToolCallId = call.callId },
                repeatCount: entry.count
            )
        case .compact:
            compactChip(entry)
        case .hidden:
            EmptyView()
        }
    }

    /// One-line tappable chip — mirrors `RichMessageBubble`'s compact
    /// treatment, plus the ×N repeat badge.
    private func compactChip(_ entry: MessageGroup.ChatActivityEntry) -> some View {
        let call = entry.call
        let result = toolResults[call.callId]
        let isFocused = chatViewModel.focusedToolCallId == call.callId
        let color = chipColor(for: call.toolKind)
        return Button {
            chatViewModel.focusedToolCallId = call.callId
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
                if entry.count > 1 {
                    Text(verbatim: "×\(entry.count)")
                        .font(ChatFontScale.caption2(chatFontScale))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer(minLength: 6)
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

    private func chipColor(for kind: ToolKind) -> Color {
        switch kind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }
}

/// Standalone live-status row for the edge where the turn is in flight
/// but the trailing transcript item is a text bubble (e.g. the model
/// finalized text and Scarf is waiting between events) — there is no
/// ActivityBubble to host the status, so it renders on its own line.
struct LiveActivityStatusRow: View {
    let status: RichChatViewModel.LiveActivityStatus
    @Environment(\.chatFontScale) private var chatFontScale: Double

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            switch status {
            case .runningTool(let name):
                Text("Running \(name)…")
            case .reasoning:
                Text("Reasoning…")
            case .receiving:
                Text("Receiving response…")
            }
        }
        .font(ChatFontScale.caption2(chatFontScale))
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(ScarfColor.backgroundSecondary)
                .overlay(Capsule().strokeBorder(ScarfColor.border, lineWidth: 1))
        )
    }
}
