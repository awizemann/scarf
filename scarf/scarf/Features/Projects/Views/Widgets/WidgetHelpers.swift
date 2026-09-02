import SwiftUI
import Foundation

/// Strips CSI ANSI escape sequences (`ESC [ ... letter`) so log output
/// pasted into the dashboard renders cleanly. Single regex, fast enough
/// for the small windows the log_tail / cron_status widgets work with.
/// Lightweight result type for file-reading widgets — failure is just a
/// human-readable string the widget surfaces in its error card. `Result<_, String>`
/// won't compile because `String` doesn't conform to `Error`; this alias
/// uses a typed wrapper so the rest of the call sites stay readable.
typealias WidgetIOResult<T> = Result<T, WidgetIOError>

struct WidgetIOError: Error, Sendable {
    let message: String
    nonisolated init(_ m: String) { self.message = m }
}

extension Result where Failure == WidgetIOError {
    /// Convenience constructor — `.failure("…")` instead of
    /// `.failure(WidgetIOError("…"))`. Marked nonisolated so detached
    /// tasks can call it from outside the main actor.
    nonisolated static func failure(_ message: String) -> Self {
        .failure(WidgetIOError(message))
    }
}

enum AnsiStripper {
    /// COMPILED ONCE. The previous comment claimed a per-call compile was
    /// negligible "because log windows are small" — but the log_tail widget
    /// strips a whole N-line window on every watcher tick, so this ran on the
    /// dashboard's hot path. `NSRegularExpression` is documented thread-safe
    /// once constructed, so a shared instance is safe from the detached tasks
    /// the widgets use; `nonisolated(unsafe)` states that for Swift 6.
    ///
    /// ESC = \u{1B}; CSI = ESC `[`; final byte is in 0x40..0x7E.
    nonisolated private static let ansiPattern = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]", options: []
    )

    nonisolated static func strip(_ s: String) -> String {
        guard let pattern = ansiPattern else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return pattern.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: ""
        )
    }
}

func parseColor(_ name: String?) -> Color {
    switch name?.lowercased() {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "pink": return .pink
    case "teal", "cyan": return .teal
    case "indigo": return .indigo
    case "mint": return .mint
    case "brown": return .brown
    case "gray", "grey": return .gray
    default: return .blue
    }
}
