import Foundation
import UIKit
import UserNotifications
import os
import ScarfCore
import ScarfIOS

/// UNUserNotificationCenter delegate for ScarfGo. M9 #4.4 skeleton —
/// the push path won't fire in production until:
///
/// 1. The Push Notifications capability is enabled in the Xcode
///    target (not on yet — requires Apple Developer Program + APNs
///    auth key).
/// 2. The corresponding Hermes-side sender exists to POST pushes to
///    APNs when a cron job finishes or a pending permission appears.
///
/// What this file ships now (ready to light up):
/// - Foreground presentation: show the banner + play default sound.
/// - Response handling: "default" (user tapped the notification)
///   routes to the Chat tab with the target sessionID preloaded via
///   the ScarfGoCoordinator. "Approve" / "Deny" categories send the
///   response over a one-shot ACPClient connection and exit.
/// - Local notification scheduling helper for in-app UX that doesn't
///   need APNs (e.g. "saved" confirmations that persist after the
///   keyboard dismisses). Currently unused but useful plumbing.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Master gate for the APNs / push pipeline. While `false`:
    ///
    /// - The `SCARF_PENDING_PERMISSION` category (Approve / Deny actions)
    ///   is NOT registered, so even if a notification with that
    ///   `categoryIdentifier` slipped through somehow, iOS would render
    ///   it without action buttons rather than route the tap to the
    ///   stub-only `APPROVE_PERMISSION` / `DENY_PERMISSION` handlers.
    /// - `registerForRemoteNotifications()` stays uncalled.
    ///
    /// Flip to `true` only when (a) the Push Notifications capability is
    /// enabled in the Xcode target, (b) Hermes ships a push sender, and
    /// (c) `APPROVE_PERMISSION` / `DENY_PERMISSION` cases below have real
    /// implementations (not just `logger.info` stubs). This gate is the
    /// single switch — flipping it in isolation should not cause the
    /// stub handlers to silently swallow real user intent.
    static let apnsEnabled = false

    private let logger = Logger(subsystem: "com.scarf", category: "NotificationRouter")

    /// Coordinator reference set by ScarfGoTabRoot on appear so the
    /// router can route notification-taps to the correct tab. Weak to
    /// avoid a retain cycle with the view's state.
    weak var coordinator: ScarfGoCoordinator?

    /// Foreground presentation: always show banners for now. A future
    /// refinement could suppress when the Chat tab is already visible
    /// for the target session (the user is already looking at it).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tap / action handling. Payload shape (planned Hermes sender
    /// convention — reflected here for when pushes start arriving):
    ///
    /// ```json
    /// { "scarf": { "sessionId": "abc123",
    ///              "serverId": "...",
    ///              "kind": "cron-complete" | "pending-permission" } }
    /// ```
    ///
    /// Keeping the parse defensive — we log + drop anything we don't
    /// recognise rather than crashing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let scarfPayload = info["scarf"] as? [String: Any] else {
            logger.warning("notification missing scarf payload; ignoring")
            return
        }
        let sessionID = scarfPayload["sessionId"] as? String

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            // User tapped the banner. Route to Chat tab on the target
            // session if one is included.
            if let sessionID {
                coordinator?.resumeSession(sessionID)
            } else {
                coordinator?.selectedTab = .chat
            }
        case "APPROVE_PERMISSION":
            logger.info("user approved pending permission from notification")
            // TODO (pending full pipe): build a one-shot ACPClient
            // against the target server + sessionID, send
            // respondToPermission, tear down. Out of scope until the
            // Hermes sender + sessionID-in-payload flow exists.
        case "DENY_PERMISSION":
            logger.info("user denied pending permission from notification")
            // TODO: mirror of APPROVE_PERMISSION, different response.
        default:
            break
        }
    }

    /// Install the notification category that exposes Approve / Deny
    /// action buttons on the lock screen. Safe to call multiple times
    /// — registerCategories replaces.
    ///
    /// **Gated on `apnsEnabled`.** Until Hermes ships a real push sender
    /// and the `APPROVE_PERMISSION` / `DENY_PERMISSION` handlers have
    /// real implementations, register the empty set so iOS has no
    /// category by which to route action-tapped notifications to the
    /// stub handlers. When `apnsEnabled` flips to `true`, the category
    /// is installed and the handlers are simultaneously expected to be
    /// real.
    func registerCategories() {
        guard Self.apnsEnabled else {
            UNUserNotificationCenter.current().setNotificationCategories([])
            return
        }
        let approve = UNNotificationAction(
            identifier: "APPROVE_PERMISSION",
            title: "Approve",
            options: [.authenticationRequired] // Face ID / passcode
        )
        let deny = UNNotificationAction(
            identifier: "DENY_PERMISSION",
            title: "Deny",
            options: [.destructive, .authenticationRequired]
        )
        let pendingPermission = UNNotificationCategory(
            identifier: "SCARF_PENDING_PERMISSION",
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([pendingPermission])
    }

    /// Request permission + hook up the delegate. Called once at
    /// app launch. Best-effort — denials log and move on.
    func setUpOnLaunch() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error = error {
                self?.logger.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard granted else {
                self?.logger.info("notification authorization denied")
                return
            }
            // NOTE: `registerForRemoteNotifications` would go here to
            // start the APNs token dance. Gated on the capability +
            // sender pipe — see APNSTokenStore for why we don't do
            // it yet.
        }
    }
}
