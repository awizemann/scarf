import Foundation

/// Drops the window and split-view frames SwiftUI saves on its own, at launch.
///
/// **Why.** SwiftUI names each saved frame after the window's full generic
/// type, which embeds a per-build address ("unknown context at $…"). Every new
/// build — each release a user installs, each test or dev run — writes a fresh
/// set under new names and never cleans up the old ones. One Mac collected
/// ~3,400 of them (3.4 MB of preferences), and SwiftUI re-reads the whole
/// domain on every preferences change, so it slows launch for good.
///
/// **Safe to drop.** Scarf never reads them: window frames are restored by
/// `WindowFrameAutosave` (`ScarfWindowFrame.*`) because SwiftUI never re-applies
/// its own, and the main sidebar split autosaves as `ScarfMainSidebar.*`. Only
/// the SwiftUI-named keys go; AppKit-named ones (e.g. Sparkle's) are kept.
enum StaleWindowFrameKeys {
    static let prefixes = [
        "NSWindow Frame SwiftUI.",
        "NSSplitView Subview Frames SwiftUI.",
    ]

    /// The keys in `keys` that are SwiftUI-saved frames.
    static func stale(in keys: [String]) -> [String] {
        keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
    }

    /// Removes them from the app's own preferences in a single write (one
    /// change notification, not one per key — see `HermesVersionCache`).
    static func prune() {
        let app = kCFPreferencesCurrentApplication
        let user = kCFPreferencesCurrentUser
        let host = kCFPreferencesAnyHost
        guard let all = CFPreferencesCopyKeyList(app, user, host) as? [String] else { return }
        let names = stale(in: all)
        guard !names.isEmpty else { return }
        CFPreferencesSetMultiple(nil, names as CFArray, app, user, host)
    }
}
