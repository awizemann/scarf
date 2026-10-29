import Foundation
import ScarfCore

/// The open server windows a chat notification click can land in
/// (parallel chats P1). Each `ContextBoundRoot` registers its chat view
/// model, its coordinator, the Hermes home it views (its profile, #126) and
/// a way to bring its window forward (its captured `openWindow`); entries
/// are weak and go when the root does — a profile switch rebuilds the root,
/// so a window is re-registered under its new home.
///
/// A click (`route`) only ever lands in a window on the route's server AND
/// home: a session id means nothing in another profile's state.db. Among
/// those it prefers the window with a live chat on that session — it
/// switches that window to Chat and focuses the chat — then the most
/// recently opened one, through the resume handoff ChatView already
/// consumes (`AppCoordinator.selectedSessionId`: it focuses a live chat or
/// opens the session). With no such window the route is staged (for
/// `stagedRouteLifetime`), a window on that server is asked for or brought
/// forward, and the next root registering for that server and home takes
/// it — a window switched to that profile included.
@MainActor
final class ChatWindowDirectory {
    static let shared = ChatWindowDirectory()

    /// How long a staged click waits for its window.
    nonisolated static let stagedRouteLifetime: TimeInterval = 60

    private struct Window {
        weak var chat: ChatViewModel?
        weak var coordinator: AppCoordinator?
        let serverID: ServerID
        let hermesHome: String
        /// Open (or bring forward) the window for a server id: the root's
        /// `openWindow(value:)`.
        let openWindow: (ServerID) -> Void
    }

    private var windows: [Window] = []

    /// A click no window could take yet, and when it was staged.
    private var staged: (route: ChatNotificationRoute, at: Date)?
    /// Whether a window has been asked for the staged route yet.
    private var stagedOpenRequested = false

    /// The most recent `openWindow` any root handed in, kept after its
    /// window closed so a click with no window open can still ask for one.
    /// (Whether SwiftUI honours an `OpenWindowAction` captured from a closed
    /// window is not verified; if it doesn't, the click just activates the
    /// app and the route waits for the next window.)
    private var lastOpenWindow: ((ServerID) -> Void)?

    /// The clock staged routes expire by (tests move it).
    var now: () -> Date = Date.init

    init() {}

    /// The staged click still waiting for its window, or nil (none, or
    /// expired).
    var pendingRoute: ChatNotificationRoute? {
        guard let staged else { return nil }
        guard now().timeIntervalSince(staged.at) <= Self.stagedRouteLifetime else {
            self.staged = nil
            stagedOpenRequested = false
            return nil
        }
        return staged.route
    }

    /// Count a window in. Takes a staged route for its server and home.
    func register(
        chat: ChatViewModel,
        coordinator: AppCoordinator,
        serverID: ServerID,
        hermesHome: String,
        openWindow: @escaping (ServerID) -> Void
    ) {
        prune()
        windows.removeAll { $0.chat === chat }
        windows.append(Window(
            chat: chat, coordinator: coordinator, serverID: serverID,
            hermesHome: hermesHome, openWindow: openWindow))
        lastOpenWindow = openWindow
        guard let pending = pendingRoute else { return }
        if pending.serverID == serverID, pending.hermesHome == hermesHome {
            staged = nil
            stagedOpenRequested = false
            Self.handOff(pending, to: coordinator)
        } else if !stagedOpenRequested {
            // Nothing could ask for the route's window when it was staged
            // (no window was open): this one can.
            stagedOpenRequested = true
            openWindow(pending.serverID)
        }
    }

    func unregister(chat: ChatViewModel) {
        windows.removeAll { $0.chat == nil || $0.chat === chat }
    }

    enum Outcome: Equatable {
        /// A window had a live chat on the session: focused there.
        case focusedLiveChat
        /// A window on the server and home was handed the session to focus
        /// or open.
        case handedOff
        /// No window on the server and home: staged for the next one.
        case staged
    }

    /// Bring the chat `route` names forward (see the type's comment).
    @discardableResult
    func route(_ route: ChatNotificationRoute) -> Outcome {
        prune()
        let matching = windows.filter {
            $0.serverID == route.serverID && $0.hermesHome == route.hermesHome && $0.chat?.mode == .window
        }
        for window in matching.reversed() {
            guard let chat = window.chat, let live = chat.liveChat(covering: route.sessionId) else { continue }
            window.coordinator?.selectedSection = .chat
            chat.focus(live)
            window.openWindow(route.serverID)
            return .focusedLiveChat
        }
        if let window = matching.last, let coordinator = window.coordinator {
            Self.handOff(route, to: coordinator)
            window.openWindow(route.serverID)
            return .handedOff
        }
        staged = (route, now())
        // A window on the server viewing another profile is brought
        // forward, not handed the session; with none, one is asked for.
        let open = windows.last(where: { $0.serverID == route.serverID })?.openWindow
            ?? windows.last?.openWindow
            ?? lastOpenWindow
        stagedOpenRequested = open != nil
        open?(route.serverID)
        return .staged
    }

    /// The resume handoff: ChatView consumes `selectedSessionId` (on appear
    /// or on change) through `resumeSession`, which focuses a live chat on
    /// it or opens it.
    private static func handOff(_ route: ChatNotificationRoute, to coordinator: AppCoordinator) {
        coordinator.selectedSection = .chat
        coordinator.selectedSessionId = route.sessionId
    }

    private func prune() {
        windows.removeAll { $0.chat == nil || $0.coordinator == nil }
    }
}
