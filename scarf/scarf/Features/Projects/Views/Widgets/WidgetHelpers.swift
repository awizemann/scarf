import SwiftUI
import Foundation
import ScarfCore

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

// MARK: - Bounded, change-aware widget file reads

/// The size ceilings and the stat-first read every file-reading widget owes
/// its host.
///
/// Two problems this closes, both of which only showed up on a dashboard
/// that reloads from the watcher tick:
///
/// 1. **Unbounded reads.** `markdown_file` and `image` point at agent-named
///    paths inside the project and read whatever is there, whole, into
///    memory — no cap at all, where the registry and the dashboard JSON
///    itself have had a 4 MB one for phases. A cron job that appends to the
///    file the widget renders is all it takes.
/// 2. **Re-reading what hasn't changed.** `.task(id:)` keyed on
///    `lastChangeDate` re-ran every read on EVERY tick, whatever changed —
///    a per-message re-read and re-decode of every widget's file during a
///    stream. One `stat` says whether the bytes could possibly differ.
enum WidgetFileRead {
    /// Text parity with `ProjectDashboardService.maxJSONBytes`: the file is
    /// rendered as markdown into a panel a few hundred points tall, so this
    /// is already far past generous.
    static let maxTextBytes: Int64 = 4 * 1024 * 1024
    /// Images decode to roughly `width × height × 4` bytes regardless of
    /// how well the file compresses, so the file cap is the wrong lever on
    /// its own — see `downsample`. This bounds the read.
    static let maxImageBytes: Int64 = 32 * 1024 * 1024

    /// `"<mtime-seconds>:<size>"`, or `nil` when the file isn't there.
    ///
    /// Size is paired with mtime because `stat` reports whole seconds over
    /// SSH: mtime alone calls two writes inside one second identical.
    nonisolated static func signature(
        _ path: String, transport: any ServerTransport
    ) -> String? {
        guard let info = transport.stat(path) else { return nil }
        return "\(Int(info.mtime.timeIntervalSince1970)):\(info.size)"
    }

    /// Read `path`, refusing anything over `cap`.
    ///
    /// The refusal is a message, never a truncation: half a markdown file
    /// or half a PNG rendered as if it were the whole thing is worse than a
    /// widget that says why it is empty.
    nonisolated static func read(
        _ path: String, cap: Int64, transport: any ServerTransport
    ) -> WidgetIOResult<Data> {
        if let info = transport.stat(path), info.size > cap {
            return .failure(
                "File is \(info.size / (1024 * 1024)) MB — over the \(cap / (1024 * 1024)) MB widget limit."
            )
        }
        do {
            let data = try transport.readFile(path)
            // The stat above can be stale or absent (a file that grew
            // between the stat and the read, a transport that can't stat).
            // The bytes are already in memory here, so this is a cheap
            // second gate rather than a redundant one.
            guard Int64(data.count) <= cap else {
                return .failure(
                    "File is \(data.count / (1024 * 1024)) MB — over the \(cap / (1024 * 1024)) MB widget limit."
                )
            }
            return .success(data)
        } catch {
            return .failure("Could not read file: \(error.localizedDescription)")
        }
    }
}
