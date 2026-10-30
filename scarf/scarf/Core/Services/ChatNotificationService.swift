import Foundation
import UserNotifications
import ScarfCore
import os
#if canImport(AppKit)
import AppKit
#endif

/// Where a click on a chat notification goes: the server window, the
/// Hermes home it was viewing, and the session. Carried in the
/// notification's `userInfo`. Bot Chat's notifications carry none — its
/// conversation isn't a main-window chat.
///
/// The home tells profiles apart: a window's viewing profile (#126)
/// re-points its context at another `HERMES_HOME` under the SAME server
/// id, and a session id means nothing in another profile's state.db.
struct ChatNotificationRoute: Equatable, Sendable {
    let serverID: ServerID
    /// `ServerContext.paths.home` of the window that posted it.
    let hermesHome: String
    let sessionId: String

    nonisolated static let serverKey = "scarf.serverId"
    nonisolated static let homeKey = "scarf.hermesHome"
    nonisolated static let sessionKey = "scarf.sessionId"

    nonisolated init(serverID: ServerID, hermesHome: String, sessionId: String) {
        self.serverID = serverID
        self.hermesHome = hermesHome
        self.sessionId = sessionId
    }

    /// The route a notification's `userInfo` carries, or nil (none, or not
    /// one of Scarf's).
    nonisolated init?(userInfo: [AnyHashable: Any]) {
        guard let server = (userInfo[Self.serverKey] as? String).flatMap(UUID.init(uuidString:)),
              let home = userInfo[Self.homeKey] as? String, !home.isEmpty,
              let session = userInfo[Self.sessionKey] as? String, !session.isEmpty
        else { return nil }
        self.init(serverID: server, hermesHome: home, sessionId: session)
    }

    nonisolated var userInfo: [String: String] {
        [Self.serverKey: serverID.uuidString, Self.homeKey: hermesHome, Self.sessionKey: sessionId]
    }
}

/// One chat notification, as the window decided to post it.
struct ChatNotification: Equatable {
    enum Kind: Equatable {
        /// A reply finished (issue #64). Gated by the user's toggle.
        case turnFinished
        /// An approval or question waits in a chat (parallel chats P1).
        case needsAnswer
        /// A background chat's connection is gone and it couldn't reconnect.
        case connectionFailed
    }

    let kind: Kind
    /// Stable per chat and purpose, so a newer one replaces the older and
    /// the window can withdraw it (`ChatNotificationPolicy.identifier`).
    let identifier: String
    let title: String
    let body: String
    let route: ChatNotificationRoute?
}

/// Posts and withdraws chat notifications. `ChatNotificationService` in the
/// app; tests inject a recorder.
@MainActor
protocol ChatNotificationPosting: AnyObject {
    func post(_ notification: ChatNotification)
    func remove(identifiers: [String])
}

/// The decisions around a chat notification, kept pure so they can be
/// pinned without a notification center.
enum ChatNotificationPolicy {
    /// Notify unless the user is looking at this chat: Scarf is the active
    /// app AND the chat is the one its window shows AND that window's chat
    /// pane is on screen AND the window is in front (not minimized, not a
    /// background window). A reply finishing in a background chat, or
    /// while the user is in another section or window, notifies even with
    /// Scarf frontmost (the delegate's `willPresent` shows it).
    nonisolated static func shouldPost(
        appIsActive: Bool,
        isFocusedChat: Bool,
        isChatPaneVisible: Bool,
        isWindowVisible: Bool
    ) -> Bool {
        !(appIsActive && isFocusedChat && isChatPaneVisible && isWindowVisible)
    }

    /// Whether the "Notify when Hermes finishes" setting also silences the
    /// "needs your answer" notifications (the row badge shows either way).
    /// One switch, pending Alan's call.
    nonisolated static let needsAnswerFollowsToggle = true

    /// `server/session/chat/<suffix>`. The chat id keeps two windows (or two
    /// chats) on one session from replacing or withdrawing each other's
    /// notes — request ids restart with every process. A chat with no
    /// session yet says "new".
    nonisolated static func identifier(serverID: ServerID, sessionId: String?, chatID: UUID, suffix: String) -> String {
        "\(serverID.uuidString)/\(sessionId ?? "new")/\(chatID.uuidString)/\(suffix)"
    }

    nonisolated static func finishedTitle(chatName: String) -> String {
        String(localized: "Hermes finished — \(chatName)")
    }

    nonisolated static func connectionFailedTitle(chatName: String) -> String {
        String(localized: "Connection lost — \(chatName)")
    }

    nonisolated static var connectionFailedBody: String {
        String(localized: "Hermes couldn't reconnect this chat. Open it to try again.")
    }

    nonisolated static func needsAnswerTitle(chatName: String) -> String {
        String(localized: "Hermes needs your answer — \(chatName)")
    }

    /// The needs-answer body: what is being asked about.
    nonisolated static func needsAnswerBody(requestTitle: String) -> String {
        let title = requestTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? String(localized: "A tool is waiting for your approval.")
            : trimmedPreview(title)
    }

    /// First non-empty line, capped at ~140 chars so the notification
    /// surface stays readable on every macOS notification style.
    nonisolated static func trimmedPreview(_ raw: String) -> String {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? raw
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        let prefix = trimmed.prefix(140).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }
}

/// Posts Scarf's chat notifications — "Hermes finished" (issue #64) and
/// "Hermes needs your answer" (parallel chats P1) — and is the app's
/// `UNUserNotificationCenterDelegate`: it shows them while Scarf is
/// frontmost (`willPresent`; the window only posts for a chat the user
/// isn't looking at) and routes a click to the chat (`didReceive`, through
/// `ChatWindowDirectory`). Installed in `ScarfApp.init`, so a click that
/// launches the app is delivered.
///
/// Authorization is requested lazily on first post. The user's toggle
/// (`scarf.chat.notifyOnComplete`, default on) gates "finished", and
/// "needs your answer" too while `needsAnswerFollowsToggle` says so.
@MainActor
final class ChatNotificationService: NSObject, ChatNotificationPosting, UNUserNotificationCenterDelegate {
    static let shared = ChatNotificationService()

    private let logger = Logger(subsystem: "com.scarf", category: "ChatNotifications")
    private var hasRequestedAuthorization = false
    private var isAuthorized = false

    /// AppStorage-shared key for the "notify on completion" toggle.
    /// Default true; the toggle lives under Settings → Display.
    static let toggleKey = "scarf.chat.notifyOnComplete"

    private let isSyntheticHost: Bool
    private let defaults: UserDefaults
    /// Seams over the notification center (tests gate and record them).
    private let authorizeOverride: (@MainActor () async -> Bool)?
    private let deliverOverride: (@MainActor (UNNotificationRequest) async throws -> Void)?
    private let withdrawOverride: (@MainActor ([String]) -> Void)?

    /// Identifiers posted and not withdrawn since. A post waits for
    /// authorization before it reaches the center, while a withdrawal is
    /// immediate: a request answered in that gap must not be delivered
    /// afterwards, so the post re-checks this right before (and after) it
    /// adds the notification.
    private(set) var wanted: Set<String> = []

    /// Nil arguments: the real notification center and settings.
    init(
        isSyntheticHost: Bool? = nil,
        defaults: UserDefaults? = nil,
        authorize: (@MainActor () async -> Bool)? = nil,
        deliver: (@MainActor (UNNotificationRequest) async throws -> Void)? = nil,
        withdraw: (@MainActor ([String]) -> Void)? = nil
    ) {
        self.isSyntheticHost = isSyntheticHost ?? Analytics.isSyntheticHost
        self.defaults = defaults ?? .standard
        self.authorizeOverride = authorize
        self.deliverOverride = deliver
        self.withdrawOverride = withdraw
        super.init()
    }

    private var center: UNUserNotificationCenter { .current() }

    /// Become the notification center's delegate. Call once, at launch.
    func installAsDelegate() {
        center.delegate = self
    }

    func post(_ notification: ChatNotification) {
        // A unit-test or preview host never posts to the real center.
        guard !isSyntheticHost else { return }
        if notification.kind != .needsAnswer || ChatNotificationPolicy.needsAnswerFollowsToggle {
            let enabled = defaults.object(forKey: Self.toggleKey) as? Bool ?? true
            guard enabled else { return }
        }
        let identifier = notification.identifier
        wanted.insert(identifier)
        Task { [weak self] in
            guard let self else { return }
            guard await self.authorize() else { return }
            // Withdrawn while authorization was pending: never deliver it.
            guard self.wanted.contains(identifier) else { return }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            if let route = notification.route {
                content.userInfo = route.userInfo
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await self.deliver(request)
                // Withdrawn while the add was in flight: take it back down.
                if !self.wanted.contains(identifier) { self.withdraw([identifier]) }
            } catch {
                self.logger.warning("Notification post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func remove(identifiers: [String]) {
        guard !identifiers.isEmpty, !isSyntheticHost else { return }
        wanted.subtract(identifiers)
        withdraw(identifiers)
    }

    private func authorize() async -> Bool {
        if let authorizeOverride { return await authorizeOverride() }
        return await ensureAuthorized()
    }

    private func deliver(_ request: UNNotificationRequest) async throws {
        if let deliverOverride { return try await deliverOverride(request) }
        try await center.add(request)
    }

    private func withdraw(_ identifiers: [String]) {
        if let withdrawOverride { return withdrawOverride(identifiers) }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func ensureAuthorized() async -> Bool {
        if isAuthorized { return true }
        if hasRequestedAuthorization {
            // Already asked once this run; respect the current settings.
            let settings = await center.notificationSettings()
            isAuthorized = settings.authorizationStatus == .authorized
            return isAuthorized
        }
        hasRequestedAuthorization = true
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            isAuthorized = granted
            return granted
        } catch {
            logger.warning("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// First non-empty line, capped (`ChatNotificationPolicy.trimmedPreview`).
    nonisolated static func trimmedPreview(_ raw: String) -> String {
        ChatNotificationPolicy.trimmedPreview(raw)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// The window posts only for a chat the user isn't looking at, so while
    /// Scarf is frontmost show it — without this macOS drops a notification
    /// for the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A click: bring the chat it names forward. No route (Bot Chat, or not
    /// Scarf's) just activates the app, as the click itself does.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let route = ChatNotificationRoute(userInfo: response.notification.request.content.userInfo)
        await MainActor.run {
            Self.handleClick(route: route, directory: .shared)
        }
    }

    /// The click's work, apart from the delegate so it can be tested.
    static func handleClick(route: ChatNotificationRoute?, directory: ChatWindowDirectory) {
        #if canImport(AppKit)
        NSApp?.activate()
        #endif
        guard let route else { return }
        directory.route(route)
    }
}
