import Foundation
import CryptoKit
import Security
#if canImport(os)
import os
#endif

/// Authenticity for `miniapp_grants.json`.
///
/// **Integrity is not authenticity.** `GuardedJSONStore` (D1) made the
/// grants file safe from Scarf's own read failures: a blip can no longer
/// blank it, corrupt bytes are quarantined, an unreadable file refuses the
/// write. None of that says anything about WHO wrote the bytes — and the
/// file lives in `~/.hermes/scarf/`, which every agent Hermes runs can
/// write. The manifest fingerprint the grant records is computed from the
/// mini-app's own `miniapp.json`, so an agent that wants `file:read`,
/// `net` and `prompt` can compute the fingerprint of the manifest it just
/// wrote, append a grant carrying it, and the launcher's
/// `hasDecision(…matching:)` check — the trust-on-first-use gate — passes
/// without a permission sheet ever appearing. The consent surface is the
/// whole security model of mini-apps; a self-servable consent record is no
/// consent record at all.
///
/// **The fix, minimally.** Each grant row carries an HMAC-SHA256 tag over
/// its own fields, keyed by a 32-byte random secret Scarf mints once and
/// keeps in the login Keychain (`com.scarf.miniapp-grants` /
/// `hmac-key-v1`). Scarf can mint the tag; an agent cannot, because the key
/// never leaves the Keychain and never appears in any file the agent can
/// read. A row whose tag is missing or wrong is DROPPED at load — not
/// refused, not repaired: dropping a grant means default-deny and the
/// permission sheet reappears, which is the safe direction and a recovery
/// the user already understands.
///
/// **Why per-row and not per-file.** A whole-file signature would make one
/// forged row invalidate every real grant the user made. Per-row means the
/// forgery is dropped and the honest decisions survive.
///
/// **What this deliberately does not defend against.** Anything that can
/// read the app's Keychain items is already inside the app's trust boundary
/// and does not need to forge a grant. And the key is per-machine: grants a
/// DIFFERENT Mac wrote into a shared remote `~/.hermes` verify as
/// unsigned, so they are dropped and re-asked on this machine. That is the
/// correct answer — a consent decision is a decision made by a person at a
/// machine, and importing another host's is exactly the trust we are
/// refusing.
/// Why a grant could not be signed. The two cases are deliberately
/// distinct: one is an environment failure the caller must refuse on, the
/// other is a row shape we will not put our name to.
public enum MiniAppGrantSignerError: LocalizedError, Sendable, Equatable {
    /// The Keychain would not produce the machine's signing key.
    ///
    /// **Refuse, don't purge (P8 DI-M3).** Without the key every stored row
    /// verifies as inauthentic, so the load hands the writer an empty list;
    /// writing that back turns a locked Keychain into the permanent
    /// deletion of every permission decision the user ever made. Dropping
    /// on READ is a recovery (the sheet re-asks); dropping on WRITE is not.
    case signingKeyUnavailable
    /// A field carries a byte the payload grammar uses as structure.
    case uninjectiveComponent(String)

    public var errorDescription: String? {
        switch self {
        case .signingKeyUnavailable:
            return "The mini-app grant signing key is unavailable; refusing to rewrite the grants file."
        case let .uninjectiveComponent(field):
            return "Mini-app grant field \"\(field)\" contains a reserved separator character; refusing to sign it."
        }
    }
}

public struct MiniAppGrantSigner: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "MiniAppGrantSigner")
    #endif

    public static let keychainService = "com.scarf.miniapp-grants"
    public static let keychainAccount = "hmac-key-v1"

    private let keychain: ProjectConfigKeychain
    /// Test seam: simulates a Keychain that will not produce the key —
    /// the DI-M3 failure — which cannot otherwise be provoked, because
    /// `signingKey()` mints one on first use.
    let keyUnavailableForTesting: Bool

    /// - Parameter testServiceSuffix: routes the key into a test-only
    ///   Keychain service, exactly as `ProjectConfigKeychain` does, so a
    ///   suite can sign and verify without touching the user's real
    ///   Keychain or sharing a key with the running app.
    public nonisolated init(testServiceSuffix: String? = nil) {
        self.keychain = ProjectConfigKeychain(testServiceSuffix: testServiceSuffix)
        self.keyUnavailableForTesting = false
    }

    nonisolated init(testServiceSuffix: String?, keyUnavailableForTesting: Bool) {
        self.keychain = ProjectConfigKeychain(testServiceSuffix: testServiceSuffix)
        self.keyUnavailableForTesting = keyUnavailableForTesting
    }

    /// The tag for a grant, or `nil` when it cannot be produced.
    ///
    /// `nil` collapses two very different situations, which is why every
    /// caller that MUTATES the file uses ``signedTag(for:)`` instead: a
    /// Keychain that won't hand over the key is a transient environment
    /// failure, while a permission component carrying a separator byte is a
    /// hostile row. Kept for read-side and test convenience.
    public nonisolated func tag(for grant: MiniAppGrant) -> String? {
        try? signedTag(for: grant)
    }

    /// The tag for a grant, distinguishing "the key is unavailable" from
    /// "these field values cannot be signed".
    ///
    /// - Throws: ``MiniAppGrantSignerError/signingKeyUnavailable`` when the
    ///   Keychain would not produce the key (locked, denied, sandboxed test
    ///   host) — the caller must REFUSE the mutation rather than write a
    ///   list it filtered with a signer that can't verify anything;
    ///   ``MiniAppGrantSignerError/uninjectiveComponent(_:)`` when a field
    ///   carries a byte the payload grammar uses as structure.
    public nonisolated func signedTag(for grant: MiniAppGrant) throws -> String {
        let payload = try Self.canonicalPayload(for: grant)
        guard let key = signingKey() else {
            throw MiniAppGrantSignerError.signingKeyUnavailable
        }
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8), using: SymmetricKey(data: key)
        )
        return Data(mac).base64EncodedString()
    }

    /// Whether the machine's signing key can be reached right now.
    ///
    /// The grants store asks BEFORE it filters: a signer with no key calls
    /// every row inauthentic, and writing that filtered list back is a
    /// permanent purge of decisions the user really made. Read paths keep
    /// their default-deny (a dropped grant re-asks); write paths refuse.
    public nonisolated func isKeyAvailable() -> Bool {
        signingKey() != nil
    }

    /// Whether `grant`'s recorded `signature` is one THIS machine produced
    /// for exactly these fields. False for an unsigned row, a row whose
    /// permissions/fingerprint were edited after signing, and a row signed
    /// with a key we don't hold.
    public nonisolated func isAuthentic(_ grant: MiniAppGrant) -> Bool {
        guard let recorded = grant.signature,
              let recordedData = Data(base64Encoded: recorded),
              // A row whose fields carry a structural byte was never signed
              // by us — signing refuses them — so it is inauthentic without
              // needing the key at all.
              let payload = try? Self.canonicalPayload(for: grant),
              let key = signingKey()
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            recordedData, authenticating: Data(payload.utf8), using: SymmetricKey(data: key)
        )
    }

    /// The exact bytes the tag covers. Every security-relevant field of the
    /// grant is in here — most importantly `permissions` (what was
    /// approved), `manifestFingerprint` (what it was approved FOR) and the
    /// (projectId, miniAppId) the decision belongs to. `signature` itself
    /// is excluded, obviously.
    ///
    /// **v2: the permissions field is length-prefixed (P8 SEC-M2).** v1
    /// joined the permission list with a comma, which is not injective on a
    /// field whose members may themselves contain a comma — and one of them
    /// can, because `query:<kind>` carries an arbitrary kind string from an
    /// agent-written `miniapp.json`. So the single approved permission
    /// `query:sessions,store` produced the SAME payload — and therefore the
    /// same valid tag — as the two-permission set `{query:sessions, store}`:
    /// the user approved one read-only query and the row re-split into a
    /// never-approved `store` grant under a tag Scarf itself had minted.
    /// Each permission is now rendered as `<utf8 byte count>:<permission>`,
    /// which is unambiguous whatever the payload separators are, and any
    /// component carrying `0x1F` or a comma is REFUSED at sign time rather
    /// than trusted to the encoding.
    ///
    /// The format is versioned: changing it invalidates every stored tag,
    /// which drops every grant and re-asks. That is a survivable migration
    /// but not a silent one, so the version prefix makes it deliberate — v1
    /// tags do not verify against a v2 payload, so the v2 rollout re-asks
    /// every grant exactly once. (The already-filed release note covers it.)
    static func canonicalPayload(for grant: MiniAppGrant) throws -> String {
        let permissions = try grant.permissions.sorted().map { permission -> String in
            try validate(permission, field: "permission")
            return "\(permission.utf8.count):\(permission)"
        }
        let parts = [
            "v2",
            try validated(grant.projectId, field: "projectId"),
            try validated(grant.miniAppId, field: "miniAppId"),
            permissions.joined(separator: ","),
            try validated(grant.decidedAt, field: "decidedAt"),
            try validated(grant.manifestFingerprint ?? "", field: "manifestFingerprint"),
        ]
        return parts.joined(separator: Self.fieldSeparator)
    }

    /// The payload's field separator. Structural, so no component may hold
    /// it — enforced rather than assumed.
    static let fieldSeparator = "\u{1F}"

    /// Bytes a component may not contain: the field separator (which would
    /// let one field forge extra fields) and the comma (which is the
    /// permission-list separator; length prefixes already make the list
    /// unambiguous, but a comma-free component means the payload can be
    /// read by a human and by a future parser without one).
    private static func validate(_ component: String, field: String) throws {
        guard !component.contains(fieldSeparator), !component.contains(",") else {
            throw MiniAppGrantSignerError.uninjectiveComponent(field)
        }
    }

    private static func validated(_ component: String, field: String) throws -> String {
        try validate(component, field: field)
        return component
    }

    // MARK: - Key material

    /// The machine's grant-signing key, minting one on first use.
    ///
    /// Mint-on-read is deliberate: there is no install step to hook, and a
    /// key that only exists after the user's first grant would leave the
    /// verify path unable to tell "no key yet" from "key gone". A fresh key
    /// invalidates any grant signed with a previous one, which is the same
    /// safe direction as every other failure here.
    private nonisolated func signingKey() -> Data? {
        if keyUnavailableForTesting { return nil }
        do {
            if let existing = try keychain.get(
                service: Self.keychainService, account: Self.keychainAccount
            ), existing.count == 32 {
                return existing
            }
        } catch {
            #if canImport(os)
            Self.logger.warning(
                "couldn't read the mini-app grant signing key: \(error.localizedDescription, privacy: .public); grants will be re-asked"
            )
            #endif
            return nil
        }
        var fresh = Data(count: 32)
        let ok = fresh.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base) == errSecSuccess
        }
        guard ok else { return nil }
        do {
            try keychain.set(
                service: Self.keychainService, account: Self.keychainAccount, secret: fresh
            )
        } catch {
            #if canImport(os)
            Self.logger.warning(
                "couldn't store the mini-app grant signing key: \(error.localizedDescription, privacy: .public)"
            )
            #endif
            return nil
        }
        return fresh
    }
}
