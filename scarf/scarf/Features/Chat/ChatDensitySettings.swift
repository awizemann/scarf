import SwiftUI
import ScarfCore

/// Scarf-local chat rendering preferences (issues #47 / #48).
///
/// **Scope vs. Hermes config.** These three keys control how Scarf
/// *renders* the chat transcript on screen — they do not affect what
/// Hermes emits over ACP. The companion Hermes flags (`display.compact`,
/// `showReasoning`, `showCost`) live on the Settings → Display tab's
/// "Output" section and gate emission. Two separate concerns; both can
/// be on at once.
///
/// **Defaults match today's UI exactly.** Existing users see no change
/// until they opt in via Settings → Display → Chat density.
enum ChatDensityKeys {
    static let toolCardStyle  = "scarf.chat.toolCardStyle"
    static let reasoningStyle = "scarf.chat.reasoningStyle"
    /// The style each SessionInfoBar visibility toggle restores when
    /// flipped back on — so a compact-chip user gets compact back, not
    /// full. Written by the bar toggles only.
    static let toolCardStyleBeforeHide  = "scarf.chat.toolCardStyleBeforeHide"
    static let reasoningStyleBeforeHide = "scarf.chat.reasoningStyleBeforeHide"
    static let fontScale      = "scarf.chat.fontScale"
    /// Whether the left sessions list pane is visible in the Mac
    /// 3-pane chat layout. Defaults true (today's behavior). Issue #58.
    static let showSessionsList = "scarf.chat.showSessionsList"
    /// Whether the right tool inspector pane is visible. Defaults true.
    /// When hidden, clicking a tool card auto-flips it back on so the
    /// click does what the user expects (`ToolCallCard.onFocus`). Issue #58.
    static let showInspector    = "scarf.chat.showInspector"
    /// v2.8 — opt-in auto-fetch of tool result CONTENT in past chats.
    /// Defaults FALSE because a single tool result blob (file dump,
    /// stack trace) can be hundreds of KB; bulk-fetching all of them
    /// during chat resume on a slow remote can blow past the 30s SSH
    /// timeout (observed in 2026-05-05 dogfooding). When false, tool
    /// CALL cards still render (the `tool_calls` JSON path is bounded
    /// and fast); only the inspector pane's "Output" section is empty
    /// until the user expands a card, at which point we lazy-fetch
    /// just that single result via `fetchToolResult(callId:)`.
    static let loadHistoricalToolResults = RichChatViewModel.loadHistoricalToolResultsKey
}

/// How `RichMessageBubble` renders the per-call tool widgets.
enum ToolCardStyle: String, CaseIterable, Identifiable {
    /// Today's behavior: full expandable card per call with arguments
    /// preview and inline result.
    case full
    /// Single-line chip per call (icon + name + status dot). Tap opens
    /// the right-pane inspector with the same details the inline expand
    /// shows. Saves significant vertical space when the assistant
    /// chains many tool calls.
    case compact
    /// No per-call rows. The `MessageGroupView.toolSummary` pill stays
    /// visible (showing aggregate counts) and is tappable — clicking it
    /// opens the inspector on the first call so per-call telemetry
    /// (duration, exit code) remains reachable.
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full:    return "Full card"
        case .compact: return "Compact chip"
        case .hidden:  return "Hidden"
        }
    }
}

/// How `RichMessageBubble` renders the assistant's reasoning channel.
enum ReasoningStyle: String, CaseIterable, Identifiable {
    /// Today's behavior: yellow tinted DisclosureGroup with a brain
    /// icon, "REASONING" label, and reasoning-token chip in the label.
    case disclosure
    /// Italic foregroundFaint caption inline above the reply, with a
    /// 9pt brain prefix. No box, no border, no toggle — just the text.
    /// Reasoning token count moves into the bubble's metadataFooter
    /// (`· N reasoning tok`) so it isn't lost.
    case inline
    /// Reasoning is not rendered. Token count still appears in the
    /// metadataFooter so user retains visibility into reasoning cost.
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disclosure: return "Disclosure box"
        case .inline:     return "Inline (italic)"
        case .hidden:     return "Hidden"
        }
    }
}

// MARK: - Density visibility

extension HermesMessage {
    /// True when the current density styles would leave this assistant
    /// message with nothing to show — a tool-call-only message with tool
    /// cards hidden (and any reasoning hidden too). Shared by
    /// `RichMessageBubble` (skips the bubble) and `MessageGroupView` /
    /// the group list (skips whole groups, so hidden messages don't
    /// leave stacked row-spacing gaps behind).
    func isHiddenByDensity(toolStyle: ToolCardStyle, reasoningStyle: ReasoningStyle) -> Bool {
        guard isAssistant, !isCompactionSummary else { return false }
        return content.isEmpty
            && (toolCalls.isEmpty || toolStyle == .hidden)
            && (!hasReasoning || reasoningStyle == .hidden)
    }
}

extension MessageGroup {
    /// A group with no user message whose every assistant message is
    /// density-hidden renders as a zero-height row that still collects
    /// the list's row spacing — N of them in a tool-heavy turn read as
    /// one big blank gap. Skip the group entirely instead.
    func isHiddenByDensity(toolStyle: ToolCardStyle, reasoningStyle: ReasoningStyle) -> Bool {
        userMessage == nil
            && !assistantMessages.isEmpty
            && assistantMessages.allSatisfy {
                $0.isHiddenByDensity(toolStyle: toolStyle, reasoningStyle: reasoningStyle)
            }
    }
}

/// Convenience helpers for translating the user's chat font scale into
/// SwiftUI's `DynamicTypeSize`. Applied once at the `RichChatView` root
/// so all of message list / input bar / session info bar scale together.
enum ChatFontScale {
    static let min: Double  = 0.85
    static let max: Double  = 1.30
    static let step: Double = 0.05
    static let `default`: Double = 1.0

    /// Map the slider value to the closest `DynamicTypeSize`. We avoid
    /// the accessibility sizes deliberately — the Mac chat layout has
    /// fixed-width side panes and accessibility-XXL would push tool
    /// chips into truncation. Users who need larger text should also
    /// resize the window.
    static func dynamicTypeSize(for scale: Double) -> DynamicTypeSize {
        switch scale {
        case ..<0.92:  return .xSmall
        case ..<1.00:  return .small
        case ..<1.08:  return .medium
        case ..<1.18:  return .large
        case ..<1.25:  return .xLarge
        default:       return .xxLarge
        }
    }

    /// Display percentage for the slider's value chip.
    static func percentLabel(for scale: Double) -> String {
        let pct = Int((scale * 100).rounded())
        return "\(pct)%"
    }

    // MARK: - Scaled font helpers
    //
    // ScarfFont's tokens are fixed-point (`Font.system(size: 14, …)`),
    // so `.environment(\.dynamicTypeSize, …)` doesn't reach them — the
    // Mac chat slider had no visible effect on bubbles, reasoning,
    // tool chips, or code blocks (issue #68). These helpers mirror the
    // ScarfFont base sizes, multiplied by the user's chat scale, and
    // are used by `RichMessageBubble`, `MarkdownContentView`, and
    // `CodeBlockView` in place of the static tokens. At scale = 1.0
    // they're byte-for-byte identical to ScarfFont so the default UI
    // is unchanged.

    static func body(_ scale: Double) -> Font {
        .system(size: 14 * scale, weight: .regular)
    }

    static func bodyEmph(_ scale: Double) -> Font {
        .system(size: 14 * scale, weight: .medium)
    }

    static func callout(_ scale: Double) -> Font {
        .system(size: 15 * scale, weight: .regular)
    }

    static func caption(_ scale: Double) -> Font {
        .system(size: 12 * scale, weight: .regular)
    }

    static func captionStrong(_ scale: Double) -> Font {
        .system(size: 12 * scale, weight: .semibold)
    }

    static func caption2(_ scale: Double) -> Font {
        .system(size: 10 * scale, weight: .medium)
    }

    static func mono(_ scale: Double) -> Font {
        .system(size: 13 * scale, weight: .regular, design: .monospaced)
    }

    static func monoSmall(_ scale: Double) -> Font {
        .system(size: 12 * scale, weight: .regular, design: .monospaced)
    }

    /// Code-block body — matches `CodeBlockView`'s 12pt mono.
    static func codeBlock(_ scale: Double) -> Font {
        .system(size: 12 * scale, weight: .regular, design: .monospaced)
    }

    /// Inline code in markdown paragraphs — `.callout` (15pt) mono.
    static func codeInline(_ scale: Double) -> Font {
        .system(size: 15 * scale, weight: .regular, design: .monospaced)
    }
}

// MARK: - Environment plumbing

private struct ChatFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = ChatFontScale.default
}

extension EnvironmentValues {
    /// Multiplier applied to chat content fonts. Set once on
    /// `RichChatView`'s root so message bubbles, markdown paragraphs,
    /// and code blocks scale together. Default 1.0 = today's UI.
    var chatFontScale: Double {
        get { self[ChatFontScaleKey.self] }
        set { self[ChatFontScaleKey.self] = newValue }
    }
}
