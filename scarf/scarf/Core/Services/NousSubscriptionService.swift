import Foundation
import os

/// Snapshot of the user's Nous Portal subscription state, derived from the
/// `providers.nous` entry in `~/.hermes/auth.json`. Read-only — Scarf never
/// writes the subscription record; `hermes model` + `hermes auth` own that
/// path.
struct NousSubscriptionState: Sendable, Hashable {
    /// True when `providers.nous` exists and has a usable access token.
    /// Mirrors the `nous_auth_present` field on
    /// `NousSubscriptionFeatures` in `hermes_cli/nous_subscription.py`.
    let present: Bool
    /// True when the user's **active provider** is `nous`, i.e. they've not
    /// just authed but selected it as the primary model provider. The Tool
    /// Gateway only routes tools when this is true — auth alone isn't enough.
    let providerIsNous: Bool
    /// Last update time for the auth record, if known. Useful in the Health
    /// view to tell the user when their subscription state was last refreshed.
    let updatedAt: Date?

    static let absent = NousSubscriptionState(present: false, providerIsNous: false, updatedAt: nil)

    /// Overall subscription active for Tool Gateway routing. Both halves have
    /// to line up: auth record present *and* `nous` is the active provider.
    /// Mirrors `NousSubscriptionFeatures.subscribed` on the Python side.
    var subscribed: Bool { present && providerIsNous }
}

/// Reads `auth.json` to detect Nous Portal subscription state. Delegates file
/// I/O to the active `ServerTransport`, so remote installations work the same
/// as local ones.
///
/// The auth-record shape is defined by hermes-agent and is load-bearing. This
/// service parses a small, stable subset and tolerates anything new Hermes
/// adds — we only rely on `providers.nous` being a dict with `access_token`
/// and `active_provider` being either `"nous"` or not.
struct NousSubscriptionService: Sendable {
    private let logger = Logger(subsystem: "com.scarf", category: "NousSubscriptionService")
    let authJSONPath: String
    let transport: any ServerTransport

    nonisolated init(context: ServerContext = .local) {
        self.authJSONPath = context.paths.authJSON
        self.transport = context.makeTransport()
    }

    /// Escape hatch for tests — point at a fixture `auth.json` without
    /// constructing a full `ServerContext`. Uses `LocalTransport` so the
    /// fixture must live on the local filesystem.
    init(path: String) {
        self.authJSONPath = path
        self.transport = LocalTransport()
    }

    /// Load the current subscription state. Returns ``NousSubscriptionState/absent``
    /// on any read or parse failure — callers treat "absent" and "can't
    /// read" the same in UI (show a "not subscribed" CTA).
    nonisolated func loadState() -> NousSubscriptionState {
        guard let data = try? transport.readFile(authJSONPath) else {
            return .absent
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("auth.json is not a JSON object; assuming no Nous subscription")
            return .absent
        }
        let providers = root["providers"] as? [String: Any] ?? [:]
        let nous = providers["nous"] as? [String: Any]
        let token = nous?["access_token"] as? String
        let present = (token?.isEmpty == false)

        let activeProvider = root["active_provider"] as? String
        let providerIsNous = (activeProvider == "nous")

        let updatedAt: Date? = {
            guard let raw = root["updated_at"] as? String else { return nil }
            return ISO8601DateFormatter().date(from: raw)
        }()

        return NousSubscriptionState(
            present: present,
            providerIsNous: providerIsNous,
            updatedAt: updatedAt
        )
    }
}
