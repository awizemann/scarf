import SwiftUI
import ScarfCore
import ScarfDesign

/// Whether user bubbles in this transcript should be scanned for a Bot Mode
/// teammate-DM prefix. **False everywhere except the Bots section's own
/// conversation pane.**
///
/// The parse (`BotMessageAttribution.parse`) is strict but it is not free,
/// and main Chat has no teammate DMs in it: running it on every user message
/// on every host would spend work on a result that is structurally always
/// `nil` there — and, worse, would let a human-typed message that happened to
/// mimic the prefix render as if a bot had sent it. Scoping it to the Bots
/// context keeps main Chat byte-identical to v2.23.0.
private struct ShowsBotAttributionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsBotAttribution: Bool {
        get { self[ShowsBotAttributionKey.self] }
        set { self[ShowsBotAttributionKey.self] = newValue }
    }
}

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

    /// Chat-only font scale set on `RichChatView`. Chat content uses
    /// these multiplied sizes (issue #68); other surfaces still see
    /// the static ScarfFont tokens at scale = 1.0.
    @Environment(\.chatFontScale) private var chatFontScale: Double

    /// See ``ShowsBotAttributionKey`` — only the Bots conversation pane sets
    /// this, so main Chat never runs the teammate-DM parse.
    @Environment(\.showsBotAttribution) private var showsBotAttribution: Bool

    /// Scarf-local chat density preferences (issues #47 / #48). All
    /// three default to today's UI. Read here so the reasoning + tool-
    /// call switches don't have to thread the values through every
    /// layer; the AppStorage seam is one line per dependency.
    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyleRaw: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyle)
    private var reasoningStyleRaw: String = ReasoningStyle.disclosure.rawValue

    /// Lazy-loaded rich `reasoning_content` (v0.11), fetched when the
    /// REASONING disclosure is first expanded. The bulk fetch excludes it
    /// (issue #74), so on resume the bubble starts with the lighter
    /// `reasoning` channel and upgrades on demand. View-local @State so the
    /// update re-renders this bubble without fighting the Equatable
    /// short-circuit (issue #46) a message-splice would hit. (t-aud21)
    @State private var reasoningExpanded = false
    @State private var lazyReasoningContent: String?

    /// Hermes v0.20 replayed compaction summaries. `isCompactionSummary`
    /// (the whole message IS the handoff summary) renders as a
    /// collapsed disclosure row instead of a normal bubble, starting
    /// closed — the summary is Hermes' internal context bookkeeping,
    /// not something the user asked for or wrote. `@State` so
    /// expanding one bubble doesn't re-render siblings.
    @State private var compactionSummaryExpanded = false

    private var toolCardStyle: ToolCardStyle {
        ToolCardStyle(rawValue: toolCardStyleRaw) ?? .full
    }

    /// The current density styles would leave this assistant bubble with
    /// nothing inside — a tool-call-only message with tool cards hidden
    /// (and any reasoning hidden too). Rendering it anyway left an empty
    /// bubble plus a "tool_calls" footer for every hidden call group,
    /// which made the bar's hide-tool-calls toggle look like a no-op
    /// (Alan, 2026-09-02). Skip the bubble entirely; the content comes
    /// back the moment the style flips.
    private var hiddenByDensity: Bool {
        message.isHiddenByDensity(toolStyle: toolCardStyle, reasoningStyle: reasoningStyle)
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
        // Per-bubble render counter. The streaming bubble re-renders
        // per token; cross-reference with `mac.ChatView.body` and
        // `chatStream.handleACPEvent` to see whether streaming churn
        // lives in the parent, the bubble, or the event handler.
        let _: Void = ScarfMon.event(.chatRender, "mac.RichMessageBubble.body")
        if message.isCompactionSummary {
            // The ENTIRE message is a replayed handoff summary (Hermes
            // v0.20 `_meta.hermes.compactionSummary`) — collapse it
            // behind a disclosure row regardless of role, rather than
            // rendering a normal user/assistant bubble the user never
            // actually wrote or read.
            compactionSummaryRow
        } else if message.isUser {
            // Role is conveyed only by alignment and bubble colour, so
            // VoiceOver had no way to tell who said what. `.contain` names
            // the group while leaving the content, the copy button and any
            // disclosures individually reachable — and the label is a
            // static literal, so it adds no work to the per-token
            // streaming update path.
            userBubble
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("You"))
        } else if message.isAssistant {
            if !hiddenByDensity {
                assistantBubble
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Assistant"))
            }
        }
        // Tool result messages are rendered inline in ToolCallCard, not as standalone bubbles
    }

    // MARK: - Compaction Summary

    /// Collapsed-by-default disclosure for a replayed compaction
    /// summary message (`_meta.hermes.compactionSummary`). Matches the
    /// REASONING disclosure's visual language (icon + uppercase label +
    /// tinted capsule) so it reads as "transcript chrome" rather than a
    /// conversational turn. `.textSelection(.enabled)` on the expanded
    /// text keeps it consistent with every other bubble for copy —
    /// there's no separate "copy" affordance to wire up.
    private var compactionSummaryRow: some View {
        DisclosureGroup(isExpanded: $compactionSummaryExpanded) {
            Text(message.content)
                .font(ChatFontScale.monoSmall(chatFontScale))
                .foregroundStyle(ScarfColor.foregroundMuted)
                .italic()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                Text("CONVERSATION COMPACTED — SUMMARY")
                    .font(ChatFontScale.captionStrong(chatFontScale))
                    .tracking(0.5)
            }
        }
        .foregroundStyle(ScarfColor.foregroundFaint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(ScarfColor.backgroundSecondary)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(ScarfColor.border, lineWidth: 1))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Subtle marker for a merged-tail replay message
    /// (`_meta.hermes.containsCompactionSummary`): real preserved turn
    /// content followed by a compaction summary. The message stays
    /// fully visible on purpose (collapsing would hide the preserved
    /// content) — this is just a badge, not a disclosure.
    @ViewBuilder
    private var containsCompactionSummaryBadge: some View {
        if message.containsCompactionSummary {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8))
                Text("Includes compacted history")
                    .font(ChatFontScale.caption2(chatFontScale))
            }
            .foregroundStyle(ScarfColor.foregroundFaint)
        }
    }

    // MARK: - User Bubble

    /// Threshold above which a user-message bubble switches to clipped
    /// mode and shows an "Expand in inspector" pill. v2.10.2: pasting
    /// a long prompt was overflowing the bubble (no lineLimit /
    /// maxHeight on the Text) and overlapping later messages —
    /// clipping at this height and routing the full content through
    /// the existing inspector ScrollView fixes both the overlap and
    /// the unscrollable-cutoff symptoms in one move. 600 chars is
    /// roughly 3–4 lines at the default scale; short replies pass
    /// through untouched.
    private static let userBubbleClipThreshold = 600
    private static let userBubbleMaxHeight: CGFloat = 220

    /// Teammate attribution, when this user message is an agent-to-agent DM
    /// rather than something the human typed. Hermes stamps the sender into
    /// the message text server-side (`tools/bot_mode_dm.py:292`) — there is
    /// no column to read — so the prefix is parsed back off and rendered as
    /// a sender chip instead of being shown as body text. See
    /// `BotMessageAttribution` for why the parse is deliberately strict.
    private var attribution: BotMessageAttribution? {
        guard showsBotAttribution else { return nil }
        return message.botAttribution
    }

    /// What the user bubble actually shows: the body with the attribution
    /// prefix lifted into the chip, or the message unchanged.
    private var userDisplayContent: String { attribution?.body ?? message.content }

    /// Sender chip for an attributed teammate DM. Uses B1's generated
    /// avatar, seeded on the handle, so the bot looks the same here as it
    /// does in the roster even though the transcript has no profile data.
    @ViewBuilder
    private var attributionChip: some View {
        if let attribution {
            HStack(spacing: 5) {
                BotAvatarView(
                    displayName: attribution.handle,
                    shapeString: nil,
                    colorHex: nil,
                    imageData: nil,
                    size: 14,
                    cornerStyle: .circle
                )
                Text("@\(attribution.handle)")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.onAccent.opacity(0.85))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Message from the bot @\(attribution.handle)")
        }
    }

    private var userBubble: some View {
        let isLong = userDisplayContent.count > Self.userBubbleClipThreshold
        return VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 4) {
                    attributionChip
                    if isLong {
                        Text(userDisplayContent)
                            .font(ChatFontScale.body(chatFontScale))
                            .foregroundStyle(ScarfColor.onAccent)
                            .textSelection(.enabled)
                            .frame(maxHeight: Self.userBubbleMaxHeight, alignment: .topLeading)
                            .clipped()
                        // "Expand in inspector" pill — tap routes the
                        // full content into the right-side inspector
                        // pane (where the existing ScrollView handles
                        // arbitrarily long text). Using a Button on
                        // top of the bubble's tap-to-select-text
                        // gesture is fine — the pill is its own hit
                        // region.
                        Button {
                            chatViewModel.setInspectorFocus(
                                .userMessage(id: message.id)
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                Text("Expand in inspector")
                                    .scarfStyle(.captionUppercase)
                            }
                            .foregroundStyle(ScarfColor.onAccent.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(ScarfColor.onAccent.opacity(0.18))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Open the full message in the inspector pane (\(userDisplayContent.count) chars)")
                    } else {
                        Text(userDisplayContent)
                            .font(ChatFontScale.body(chatFontScale))
                            .foregroundStyle(ScarfColor.onAccent)
                            .textSelection(.enabled)
                    }
                }
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
            if message.timestamp != nil || message.containsCompactionSummary {
                HStack(spacing: 4) {
                    containsCompactionSummaryBadge
                    if let time = message.timestamp {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(ScarfColor.success)
                        Text(time, style: .time)
                            .font(ChatFontScale.caption2(chatFontScale))
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
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
        // Skip the per-token code-fence walk while the streaming bubble
        // is in flight (id == 0). At ~30–60 chunks/sec the parse was
        // the dominant chat-render cost; render plain markdown until
        // finalize and the body re-evaluates once with a permanent id.
        // The Equatable short-circuit on RichMessageBubble (id != 0)
        // then memoizes the parsed blocks for the lifetime of the
        // bubble — no per-render cache needed.
        if message.id == 0 {
            MarkdownContentView(content: message.content, streaming: true)
        } else {
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
            // Inline can't lazy-load (no open affordance), so only show it when
            // there's already text. A reasoning_content-only message whose blob
            // isn't loaded (t-aud27) has empty `preferredReasoning` — skip it
            // here so we don't render a brain icon with no text; the disclosure
            // style handles that case via its on-open lazy fetch.
            if !(message.preferredReasoning ?? "").isEmpty {
                reasoningInline
            }
        case .hidden:
            EmptyView()
        }
    }

    private var reasoningDisclosure: some View {
        DisclosureGroup(isExpanded: $reasoningExpanded) {
            Text(lazyReasoningContent ?? message.preferredReasoning ?? "")
                .font(ChatFontScale.monoSmall(chatFontScale))
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
                    .font(ChatFontScale.captionStrong(chatFontScale))
                    .tracking(0.5)
                if let tokens = message.tokenCount, tokens > 0 {
                    Text("· \(tokens) tok")
                        .font(ChatFontScale.monoSmall(chatFontScale))
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
        // Upgrade to the richer reasoning_content the first time the user
        // opens the disclosure (it's excluded from the bulk fetch). (t-aud21)
        .onChange(of: reasoningExpanded) { _, expanded in
            guard expanded else { return }
            Task { await loadFullReasoningIfNeeded() }
        }
    }

    /// Fetch the richer `reasoning_content` on first disclosure-open if it
    /// wasn't in the bulk-loaded message. No-op for live/streaming bubbles
    /// (id == 0, which already carry reasoning_content) and pre-v0.11 hosts
    /// (the fetch returns nil). (t-aud21)
    private func loadFullReasoningIfNeeded() async {
        guard message.id > 0,
              (message.reasoningContent ?? "").isEmpty,
              lazyReasoningContent == nil else { return }
        if let full = await chatViewModel.richChatViewModel.reasoningContent(for: message.id),
           !full.isEmpty {
            lazyReasoningContent = full
        }
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
                .font(ChatFontScale.caption(chatFontScale))
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
                            .font(ChatFontScale.monoSmall(chatFontScale))
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
                    .font(ChatFontScale.monoSmall(chatFontScale))
            }
            if let reason = message.finishReason,
               Self.shouldShowFinishReason(reason)
            {
                Text("·")
                Text(reason)
                    .font(ChatFontScale.caption(chatFontScale))
                    .foregroundStyle(Self.finishReasonTone(reason))
            }
            if let time = message.timestamp {
                Text("·")
                Text(time, style: .time)
                    .font(ChatFontScale.caption(chatFontScale))
            }
            if let seconds = turnDuration {
                Text("·")
                Text(RichChatViewModel.formatTurnDuration(seconds))
                    .font(ChatFontScale.monoSmall(chatFontScale))
                    .help("Wall-clock duration of this turn")
            }
            // Per-message TTS playback toggle (issue #66). Only on
            // settled assistant bubbles — streaming bubble (id == 0)
            // would speak partial text. Empty content has nothing to
            // speak.
            if message.id != 0, !message.content.isEmpty {
                speakButton
            }
            if message.containsCompactionSummary {
                containsCompactionSummaryBadge
            }
        }
        .font(ChatFontScale.caption(chatFontScale))
        .foregroundStyle(ScarfColor.foregroundFaint)
        .padding(.leading, 4)
    }

    /// Whether `finishReason` should render as a visible badge in the
    /// message footer. `stop` and `end_turn` are normal end-of-turn
    /// signals — `RichChatViewModel.finalizeStreamingMessage` stamps
    /// `"stop"` on every text-bearing turn-final assistant message —
    /// so showing them creates the impression that something stopped
    /// the agent prematurely. We suppress them and reserve the badge
    /// for abnormal terminations (max_tokens, error, refusal,
    /// content_filter, …) the user actually wants to see. Matches
    /// the conventions in ChatGPT, Claude.ai, Cursor, etc.
    private static func shouldShowFinishReason(_ reason: String) -> Bool {
        let normalized = reason.trimmingCharacters(in: .whitespaces).lowercased()
        // `tool_calls` / `tool_use` / `function_call` are the normal way a
        // tool-calling turn ends — as unremarkable as `stop` (the tool
        // count already has its own pill). Rendering the raw wire token
        // read as a warning label under every tool-bearing bubble.
        return !["stop", "end_turn", "end-turn", "tool_calls", "tool_use", "function_call", ""]
            .contains(normalized)
    }

    /// Visual tone for an abnormal finish-reason badge. Severity
    /// scales: warning (yellow) for "the response was cut short" cases
    /// the user can usually retry, danger (red) for outright failures
    /// or refusals, muted otherwise so unrecognized reasons stay
    /// readable but un-alarming.
    private static func finishReasonTone(_ reason: String) -> Color {
        switch reason.lowercased() {
        case "max_tokens", "length", "content_filter":
            return ScarfColor.warning
        case "error", "refusal":
            return ScarfColor.danger
        default:
            return ScarfColor.foregroundMuted
        }
    }

    /// Speaker glyph that toggles `AVSpeechSynthesizer` playback for
    /// the assistant reply. Lives in its own view so the
    /// `MessageSpeechService` observation doesn't fight the bubble's
    /// `Equatable` short-circuit — the parent only needs to pass
    /// stable id + content; this view re-renders on its own when
    /// playback state flips.
    private var speakButton: some View {
        SpeakMessageButton(messageId: message.id, content: message.content)
    }
}

/// Stand-alone speaker button so the `MessageSpeechService`
/// observation doesn't get short-circuited by `RichMessageBubble`'s
/// `Equatable`. Only the button re-renders when playback flips —
/// the bubble itself stays optimised.
private struct SpeakMessageButton: View {
    let messageId: Int
    let content: String

    @State private var speech = MessageSpeechService.shared

    var body: some View {
        let isPlaying = speech.playingMessageId == messageId
        Button {
            speech.toggle(messageId: messageId, content: content)
        } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(isPlaying ? ScarfColor.accent : ScarfColor.foregroundFaint)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Stop speaking" : "Read this reply aloud")
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
