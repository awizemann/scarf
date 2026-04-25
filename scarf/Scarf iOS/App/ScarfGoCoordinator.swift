import SwiftUI
import ScarfCore

/// Cross-tab signalling for ScarfGo. Mirrors the Mac app's
/// `AppCoordinator` pattern: an `@Observable` carrier injected via
/// `.environment(_:)` that any view in the tab tree can reach.
///
/// v2.5 expands the surface to include project handoff: tapping
/// "New Chat" inside a Project Detail view sets `pendingProjectChat`
/// and routes to the Chat tab, where ChatController consumes it and
/// dispatches `resetAndStartInProject(_:)` (same wiring the in-Chat
/// project picker sheet already uses).
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

    /// If non-nil, the Chat tab should start an in-project session at
    /// this absolute remote path on next appear instead of a quick
    /// chat. Consumed (cleared) by ChatController after it kicks off
    /// `resetAndStartInProject(_:)`. Mirrors Mac's
    /// `AppCoordinator.pendingProjectChat`.
    var pendingProjectChat: String?

    enum Tab: Hashable {
        case dashboard, projects, chat, skills, system
    }

    /// Convenience: route to Chat and queue a resume. Dashboard rows
    /// call this on tap. Clearing `pendingResumeSessionID` is the
    /// consumer's responsibility — in ChatController's case, right
    /// after the resume flow wins (success or failure).
    func resumeSession(_ id: String) {
        pendingResumeSessionID = id
        selectedTab = .chat
    }

    /// Convenience: route to Chat and queue a project-scoped session
    /// start at `path`. Project Detail's "New Chat" toolbar button
    /// calls this. Clearing `pendingProjectChat` is the consumer's
    /// responsibility (ChatController) once `resetAndStartInProject`
    /// has been dispatched.
    func startChatInProject(path: String) {
        pendingProjectChat = path
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
