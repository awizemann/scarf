import SwiftUI
import ScarfCore

/// Cross-tab signalling for ScarfGo. Mirrors the Mac app's
/// `AppCoordinator` pattern: an `@Observable` carrier injected via
/// `.environment(_:)` that any view in the tab tree can reach.
///
/// Single responsibility in M9 scope: route "user tapped a recent
/// session in Dashboard" → "open the Chat tab with a resume request."
/// Future uses (project-scoped chat handoff, notification deep-link
/// → specific session) compose naturally on the same primitive.
@Observable
@MainActor
final class ScarfGoCoordinator {

    /// Which tab ScarfGoTabRoot should present. Changing this from
    /// anywhere in the tree re-selects the tab. Bound as `selection:`
    /// on the root TabView.
    var selectedTab: Tab = .chat

    /// If non-nil, ChatController should resume this session on next
    /// appear instead of starting a fresh one. Consumed (cleared) by
    /// ChatController after it honours the request.
    var pendingResumeSessionID: String?

    enum Tab: Hashable {
        case chat, dashboard, memory, more
    }

    /// Convenience: route to Chat and queue a resume. Dashboard rows
    /// call this on tap. Clearing `pendingResumeSessionID` is the
    /// consumer's responsibility — in ChatController's case, right
    /// after the resume flow wins (success or failure).
    func resumeSession(_ id: String) {
        pendingResumeSessionID = id
        selectedTab = .chat
    }
}

/// Environment key so subviews can pull the coordinator without
/// explicit threading.
private struct ScarfGoCoordinatorKey: EnvironmentKey {
    static let defaultValue: ScarfGoCoordinator? = nil
}

extension EnvironmentValues {
    var scarfGoCoordinator: ScarfGoCoordinator? {
        get { self[ScarfGoCoordinatorKey.self] }
        set { self[ScarfGoCoordinatorKey.self] = newValue }
    }
}
