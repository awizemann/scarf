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
public struct MiniAppGrantSigner: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "MiniAppGrantSigner")
    #endif

    public static let keychainService = "com.scarf.miniapp-grants"
    public static let keychainAccount = "hmac-key-v1"

    private let keychain: ProjectConfigKeychain

    /// - Parameter testServiceSuffix: routes the key into a test-only
    ///   Keychain service, exactly as `ProjectConfigKeychain` does, so a
    ///   suite can sign and verify without touching the user's real
    ///   Keychain or sharing a key with the running app.
    public nonisolated init(testServiceSuffix: String? = nil) {
        self.keychain = ProjectConfigKeychain(testServiceSuffix: testServiceSuffix)
    }

    /// The tag for a grant, or `nil` when the signing key is unavailable.
    ///
    /// A `nil` here is a Keychain failure (locked, denied, unavailable in a
    /// sandboxed test host), NOT a security decision — the caller decides
    /// what to do, and both callers choose the direction that fails safe:
    /// a write stores no tag (so the row is dropped at the next load and
    /// re-asked), a read drops the row.
    public nonisolated func tag(for grant: MiniAppGrant) -> String? {
        guard let key = signingKey() else { return nil }
        let message = Data(Self.canonicalPayload(for: grant).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }

    /// Whether `grant`'s recorded `signature` is one THIS machine produced
    /// for exactly these fields. False for an unsigned row, a row whose
    /// permissions/fingerprint were edited after signing, and a row signed
    /// with a key we don't hold.
    public nonisolated func isAuthentic(_ grant: MiniAppGrant) -> Bool {
        guard let recorded = grant.signature,
              let recordedData = Data(base64Encoded: recorded),
              let key = signingKey()
        else { return false }
        let message = Data(Self.canonicalPayload(for: grant).utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(
            recordedData, authenticating: message, using: SymmetricKey(data: key)
        )
    }

    /// The exact bytes the tag covers. Every security-relevant field of the
    /// grant is in here — most importantly `permissions` (what was
    /// approved), `manifestFingerprint` (what it was approved FOR) and the
    /// (projectId, miniAppId) the decision belongs to. `signature` itself
    /// is excluded, obviously. Field-separated with a character that cannot
    /// occur in any of the components, so `("ab", "c")` and `("a", "bc")`
    /// cannot collide onto one payload.
    ///
    /// The format is versioned: changing it invalidates every stored tag,
    /// which drops every grant and re-asks. That is a survivable migration
    /// but not a silent one, so the version prefix makes it deliberate.
    static func canonicalPayload(for grant: MiniAppGrant) -> String {
        let parts = [
            "v1",
            grant.projectId,
            grant.miniAppId,
            grant.permissions.sorted().joined(separator: ","),
            grant.decidedAt,
            grant.manifestFingerprint ?? "",
        ]
        return parts.joined(separator: "\u{1F}")
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
