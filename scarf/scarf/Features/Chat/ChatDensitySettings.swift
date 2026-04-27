import SwiftUI

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
    static let fontScale      = "scarf.chat.fontScale"
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
}
