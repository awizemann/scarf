import Foundation
import Observation
import ScarfCore

/// Per-window "viewing profile" selection for the Mac app (#126).
///
/// The Mac analogue of iOS's `ScarfGoCoordinator.selectedProfile` (#120,
/// "Design B"): it holds which Hermes profile *this window* is viewing on its
/// bound server, WITHOUT mutating the server's own `active_profile` (what the
/// agent, cron, terminal, and `hermes profile use` care about). The window
/// root (`ProfileScopedRoot` in `scarfApp.swift`) reads `selectedProfile`,
/// re-points the `ServerContext`'s `remoteHome` via
/// `ServerContext.scoped(toProfile:)`, and rebuilds the whole window subtree
/// so Sessions / Chat / Memory / Cron all reload against the profile's
/// `HERMES_HOME` — the no-relaunch analogue of "Switch & Relaunch".
///
/// Only meaningful for remote (`.ssh`) windows; on a local window
/// `ServerContext.scoped(toProfile:)` is a no-op (local profiles resolve from
/// `active_profile` instead), so the selection has no effect there.
///
/// One instance per window, keyed to the window's `ServerID`, and the choice
/// persists across launches via `UserDefaultsProfileSelectionStore`.
@Observable
@MainActor
final class WindowProfileScope {

    /// Mac-specific `UserDefaults` key — kept distinct from iOS's default so
    /// the two apps' selections stay independent even though they share the
    /// store type.
    nonisolated static let macDefaultsKey = "com.scarf.mac.profile-selections.v1"

    private let serverID: ServerID
    private let store: any IOSProfileSelectionStore

    /// The profile this window is viewing, or `nil` for the default (root)
    /// profile. Mutating it (via `select(_:)`) drives the window rebuild.
    private(set) var selectedProfile: String?

    init(
        serverID: ServerID,
        store: any IOSProfileSelectionStore = UserDefaultsProfileSelectionStore(key: WindowProfileScope.macDefaultsKey)
    ) {
        self.serverID = serverID
        self.store = store
        self.selectedProfile = store.selectedProfile(for: serverID)
    }

    /// Set and persist the viewing profile. Pass `nil`/`"default"`/an invalid
    /// name to return to the root profile. A no-op when the (normalized)
    /// value is unchanged, so callers can wire it straight to a picker
    /// without churning the window tree.
    func select(_ name: String?) {
        let normalized = HermesProfileScope.normalize(name)
        guard normalized != selectedProfile else { return }
        store.setSelectedProfile(normalized, for: serverID)
        selectedProfile = normalized
    }

    /// Whether `name` is the profile this window is currently viewing
    /// (both normalize to `nil` for the default profile).
    func isViewing(_ name: String?) -> Bool {
        HermesProfileScope.normalize(name) == selectedProfile
    }
}
