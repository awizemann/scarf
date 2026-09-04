import Foundation
import Observation

/// Per-user collapse/expand state for the main sidebar's nav sections.
///
/// Deliberately a UI convenience, not trust-bearing state: it decides
/// nothing about what the app is allowed to do, only which rows are on
/// screen. `UserDefaults` is therefore the right home — no Keychain, no
/// integrity MAC, and a corrupted/absent value simply falls back to the
/// per-section default below.
///
/// One key per section title (`sidebar.section.collapsed.<Title>`)
/// rather than one array of collapsed titles: sections are
/// capability-gated and appear/disappear as the window's Hermes host
/// changes, so "absent" has to keep meaning "use this section's
/// default" — with a single blob, a section the user has never seen
/// would inherit whatever the blob happened to say.
///
/// Shared app-wide (not per-window): the collapse state is a preference
/// about the chrome, and two windows on the same Mac disagreeing about
/// whether Configure is open reads as a bug.
@MainActor
@Observable
final class SidebarSectionCollapseStore {
    /// Sections that start COLLAPSED on a first launch. Everything else
    /// (Monitor, Bots, Interact) starts expanded — those are the rows
    /// people use every session; Configure and Manage are long tails
    /// visited a few times and then left alone.
    nonisolated static let defaultCollapsedTitles: Set<String> = ["Configure", "Manage"]

    nonisolated static let keyPrefix = "sidebar.section.collapsed."

    /// Shared instance backed by `UserDefaults.standard`. Tests build
    /// their own with an isolated suite.
    static let shared = SidebarSectionCollapseStore()

    private let defaults: UserDefaults

    /// Observed mirror of what's on disk, so toggling a section
    /// invalidates the sidebar body. Populated lazily: a title the user
    /// has never touched has no entry here and no key in `defaults`.
    private var states: [String: Bool] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated static func key(for title: String) -> String { keyPrefix + title }

    /// Default state for a section the user has never toggled.
    nonisolated static func defaultCollapsed(for title: String) -> Bool {
        defaultCollapsedTitles.contains(title)
    }

    func isCollapsed(_ title: String) -> Bool {
        if let cached = states[title] { return cached }
        // `object(forKey:)` rather than `bool(forKey:)`: the latter
        // maps "never written" to `false`, which would force every
        // section — Configure and Manage included — open on first
        // launch.
        let stored = defaults.object(forKey: Self.key(for: title)) as? Bool
        let value = stored ?? Self.defaultCollapsed(for: title)
        states[title] = value
        return value
    }

    func setCollapsed(_ collapsed: Bool, for title: String) {
        // Equality-guard only the OBSERVED mirror — assigning an
        // identical value into `@Observable` storage is still a
        // mutation and would re-render the whole sidebar. The defaults
        // write is unconditional so an explicit choice that happens to
        // match the default still persists (and therefore survives a
        // later change to `defaultCollapsedTitles`).
        if states[title] != collapsed { states[title] = collapsed }
        defaults.set(collapsed, forKey: Self.key(for: title))
    }

    func toggle(_ title: String) {
        setCollapsed(!isCollapsed(title), for: title)
    }
}
