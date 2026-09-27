import Foundation
import os
import ScarfCore

/// Snapshot of the user's Nous Portal subscription state, derived from the
/// `providers.nous` entry in `~/.hermes/auth.json`. Read-only — Scarf never
/// writes the subscription record; `hermes model` + `hermes auth` own that
/// path.
nonisolated struct NousSubscriptionState: Sendable, Hashable {
    /// True when `providers.nous` exists and has a usable access token.
    /// Mirrors the `nous_auth_present` field on
    /// `NousSubscriptionFeatures` in `hermes_cli/nous_subscription.py`.
    let present: Bool
    /// Last update time for the auth record, if known. Useful in the Health
    /// view to tell the user when their subscription state was last refreshed.
    let updatedAt: Date?

    nonisolated static let absent = NousSubscriptionState(present: false, updatedAt: nil)

    /// Signed in to Nous Portal, which is all Scarf can see of the Tool
    /// Gateway gate.
    ///
    /// Hermes routes a tool through the gateway when the Portal account is
    /// signed in AND entitled (`tools/tool_backend_helpers.py:18-28` @
    /// v2026.9.24). The inference provider is not part of that gate, and
    /// never was (before v2026.4.16 the gate was an env flag). It only
    /// decides whether Hermes offers and auto-applies the gateway defaults
    /// (`hermes_cli/nous_subscription.py:494,557`); each tool's own
    /// selection decides whether it routes. This used to also require auth.json's
    /// `active_provider == "nous"`, so a user who signed in and then chose
    /// another provider was told their tools would not route (T3-F2). The
    /// entitlement is a live Portal lookup Scarf does not make, so the UI
    /// says "signed in", not "entitled".
    var subscribed: Bool { present }

    /// Days since the auth record was last touched (refreshed by Hermes
    /// or re-authed by the user). Hermes refreshes on every agent boot,
    /// so a large value here means the user hasn't started a session
    /// recently — which is exactly when the refresh token is at risk
    /// of expiring (typical ~30 day lifetime). Returns nil when
    /// `updatedAt` is unknown (older Hermes versions). Capped at
    /// `Int.max` to avoid overflow on absurd inputs.
    func daysSinceLastRefresh(now: Date = Date()) -> Int? {
        guard let updatedAt else { return nil }
        let seconds = now.timeIntervalSince(updatedAt)
        guard seconds > 0 else { return 0 }
        return Int(seconds / 86_400)
    }

    /// True when we haven't seen a Hermes refresh in ≥14 days — half
    /// the typical 30-day Nous refresh-token lifetime. This is the
    /// trigger for the "enable keepalive" nudge: still recoverable
    /// (refresh token hasn't expired yet) but heading there. Returns
    /// false when `updatedAt` is unknown — we don't nudge on missing
    /// data, only on confirmed staleness.
    var hasStaleRefresh: Bool {
        guard let days = daysSinceLastRefresh() else { return false }
        return days >= 14
    }
}

/// Reads `auth.json` to detect Nous Portal subscription state. Delegates file
/// I/O to the active `ServerTransport`, so remote installations work the same
/// as local ones.
///
/// The auth-record shape is defined by hermes-agent and is load-bearing. This
/// service parses a small, stable subset and tolerates anything new Hermes
/// adds — we only rely on `providers.nous` being a dict with
/// `access_token`.
struct NousSubscriptionService: Sendable {
    private let logger = Logger(subsystem: "com.scarf", category: "NousSubscriptionService")
    let authJSONPath: String
    let transport: any ServerTransport
    /// Set for a real server: used to decide whether Hermes would fall back
    /// to the root `auth.json` (named profile, S06-F3). `nil` for the
    /// fixture initializer, which reads exactly one file.
    private let context: ServerContext?

    nonisolated init(context: ServerContext = .local) {
        self.authJSONPath = context.paths.authJSON
        self.transport = context.makeTransport()
        self.context = context
    }

    /// Escape hatch for tests — point at a fixture `auth.json` without
    /// constructing a full `ServerContext`. Uses `LocalTransport` so the
    /// fixture must live on the local filesystem.
    init(path: String) {
        self.authJSONPath = path
        self.transport = LocalTransport()
        self.context = nil
    }

    /// Load the current subscription state. Returns ``NousSubscriptionState/absent``
    /// on any read or parse failure — callers treat "absent" and "can't
    /// read" the same in UI (show a "not subscribed" CTA).
    nonisolated func loadState() -> NousSubscriptionState {
        ScarfMon.measure(.diskIO, "nous.subscription.loadState") {
            // Under a named profile Hermes reads `providers.nous` from the
            // ROOT auth.json when the profile has none (S06-F3). Off-main:
            // `loadState` runs through OffPool, and a version-cache miss
            // probes the host.
            let data: Data?
            if let context {
                data = HermesAuthFallback.load(
                    authJSONPath: authJSONPath,
                    home: context.paths.home,
                    capabilities: HermesVersionCache.shared.capabilitiesSync(for: context),
                    transport: transport
                ).data
            } else {
                data = try? transport.readFile(authJSONPath)
            }
            guard let data else {
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

            let updatedAt: Date? = {
                guard let raw = root["updated_at"] as? String else { return nil }
                return ISO8601DateFormatter().date(from: raw)
            }()

            return NousSubscriptionState(
                present: present,
                updatedAt: updatedAt
            )
        }
    }
}
