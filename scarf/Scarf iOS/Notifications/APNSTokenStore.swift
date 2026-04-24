import Foundation
import os

/// Stub store for the iOS APNs device token. ScarfGo's M9 #4.4
/// skeleton captures the token for future Hermes-side integration
/// (when Hermes gains a `hermes register-device` command + an APNs
/// sender). Today the token just gets logged — there's no remote to
/// ship it to yet.
///
/// **Why this isn't wired to the Push Notifications capability in
/// the Xcode target:**
///
/// 1. Enabling the capability requires a valid Apple Developer Program
///    enrollment + APNs auth key + configured provisioning profile.
///    None of that's set up for this iteration.
/// 2. The server side (Hermes APNs sender) is upstream work that
///    hasn't been specced yet.
/// 3. Without (1) and (2), turning the capability on just produces
///    "no valid aps-environment entitlement string found" at runtime
///    and `registerForRemoteNotifications` fails.
///
/// So this file ships the client code ready, but the capability stays
/// OFF. When Hermes gains the sender + we get the APNs key, we flip
/// the capability on in the Xcode target and change the log-only stub
/// here into a real HTTPS POST to the Hermes register endpoint.
///
/// Thread-safety: APNs device-token callbacks come on UIKit's main
/// thread already. The store keeps its tiny state behind a serial
/// queue anyway so future background-registration paths work too.
actor APNSTokenStore {
    static let shared = APNSTokenStore()

    private var lastToken: String?
    private let logger = Logger(subsystem: "com.scarf", category: "APNSTokenStore")

    /// Called by the AppDelegate's
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// when the capability IS enabled. No-ops otherwise. Token arrives
    /// as `Data`; we format it as a hex string (standard APNs wire
    /// encoding) for later POST-body construction.
    func record(token rawToken: Data) {
        let hex = rawToken.map { String(format: "%02x", $0) }.joined()
        if hex == lastToken { return }
        lastToken = hex
        logger.info("APNs device token registered: \(hex, privacy: .private(mask: .hash))")
        // TODO (Hermes-side sender): POST { deviceToken, serverID,
        // appBuild } to the Hermes register-device endpoint here so
        // the server knows where to deliver cron-completion + pending-
        // permission notifications for this device. Stay async (HTTPS
        // fetch) — the iOS delegate callback is the launch point but
        // the real work belongs off-thread.
    }

    /// Called when `registerForRemoteNotifications` fails. Log and
    /// move on — APNs failures aren't fatal to the app, they just
    /// mean this device won't receive push.
    func recordError(_ error: Error) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Read the last-known token. Nil until the first successful
    /// registration. Future Hermes handshake uses this when building
    /// the register-device payload.
    func currentToken() -> String? { lastToken }
}
