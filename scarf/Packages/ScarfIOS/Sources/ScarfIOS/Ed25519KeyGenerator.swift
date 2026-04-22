// Uses CryptoKit (Apple's standard-library crypto). Available on iOS 13+
// and macOS 10.15+; the OpenSSH public-key wire format below is the same
// across both.
#if canImport(CryptoKit)

import Foundation
import CryptoKit
import ScarfCore

/// Mints a fresh Ed25519 keypair and packages it as an `SSHKeyBundle`.
///
/// The **public half** is encoded in OpenSSH wire format and wrapped in
/// a standard `ssh-ed25519 AAAA… <comment>` line — paste-ready into a
/// remote host's `authorized_keys`. The format is spec'd in RFC 4253
/// §6.6 + draft-ietf-curdle-ssh-ed25519-02 and is trivially
/// deterministic to serialize by hand: `string("ssh-ed25519")` +
/// `string(<32-byte-public-key>)`, where `string(x)` is
/// `uint32_be(len(x)) ‖ x`, all base64-wrapped.
///
/// The **private half** is stored as a custom PEM string in the
/// bundle. The serialization below is a documented pre-OpenSSH PEM
/// shape that round-trips through `Curve25519.Signing.PrivateKey(
/// rawRepresentation:)`. It is **not** the standard OpenSSH
/// `BEGIN OPENSSH PRIVATE KEY` envelope — that format is more complex
/// (requires a bcrypt KDF header even for unencrypted keys) and would
/// pull in a lot of serialization code that Citadel can generate via
/// its own OpenSSH helpers.
///
/// **Interop note.** `CitadelSSHService` in this same package is
/// responsible for bridging this bundle's raw-PEM private key into
/// whatever Citadel's authentication method expects — see the FIXME
/// comments in that file. The public key goes on the remote; the
/// private key never leaves the iPhone.
public enum Ed25519KeyGenerator {
    /// Default comment attached to generated keys. Unique enough to
    /// distinguish "key from this device" in a shared `authorized_keys`.
    public static func defaultComment() -> String {
        "scarf-iphone-\(UUID().uuidString.prefix(8))"
    }

    /// Generate a fresh Ed25519 keypair. `comment` appears at the end
    /// of the OpenSSH public-key line. `now` is injected for testable
    /// timestamp formatting — defaults to the current instant.
    public static func generate(
        comment: String? = nil,
        now: Date = Date()
    ) throws -> SSHKeyBundle {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation    // 32 bytes
        let priv = key.rawRepresentation             // 32 bytes

        let commentStr = comment ?? defaultComment()
        let openSSHPublic = makeOpenSSHPublicKeyLine(
            publicKeyBytes: pub,
            comment: commentStr
        )
        let privatePEM = makeRawEd25519PEM(privateBytes: priv, publicBytes: pub)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let timestamp = iso.string(from: now)

        return SSHKeyBundle(
            privateKeyPEM: privatePEM,
            publicKeyOpenSSH: openSSHPublic,
            comment: commentStr,
            createdAt: timestamp
        )
    }

    /// Build `ssh-ed25519 AAAA… comment`. Pure function; testable
    /// without any crypto. The `publicKeyBytes` must be the exact
    /// 32-byte raw Ed25519 public key.
    public static func makeOpenSSHPublicKeyLine(
        publicKeyBytes: Data,
        comment: String
    ) -> String {
        let algo = "ssh-ed25519"
        var blob = Data()
        appendSSHString(&blob, bytes: Data(algo.utf8))
        appendSSHString(&blob, bytes: publicKeyBytes)
        let b64 = blob.base64EncodedString()
        if comment.isEmpty {
            return "\(algo) \(b64)"
        } else {
            return "\(algo) \(b64) \(comment)"
        }
    }

    /// Build the raw-bytes PEM we use in-app. Format:
    /// ```
    /// -----BEGIN SCARF ED25519 PRIVATE KEY-----
    /// <base64 of: 32-byte private | 32-byte public>
    /// -----END SCARF ED25519 PRIVATE KEY-----
    /// ```
    /// This is NOT an interop format with OpenSSH tooling — it's
    /// purely for round-tripping within Scarf. `CitadelSSHService`
    /// decodes these 64 bytes back into a `Curve25519.Signing.PrivateKey`
    /// before calling into Citadel.
    ///
    /// If you want an `~/.ssh/id_ed25519`-compatible export, use the
    /// "Share key" flow (not in M2 — future phase) which will re-serialize
    /// into proper OpenSSH PEM via Citadel's helpers.
    public static func makeRawEd25519PEM(
        privateBytes: Data,
        publicBytes: Data
    ) -> String {
        let combined = privateBytes + publicBytes
        let b64 = combined.base64EncodedString()
        // Wrap the base64 in 76-column lines for display-friendliness.
        let wrapped = wrap(b64, at: 76)
        return """
        -----BEGIN SCARF ED25519 PRIVATE KEY-----
        \(wrapped)
        -----END SCARF ED25519 PRIVATE KEY-----
        """
    }

    /// Decode a `makeRawEd25519PEM` result back into the 32-byte private
    /// + 32-byte public tuple. Used by `CitadelSSHService`.
    public static func decodeRawEd25519PEM(
        _ pem: String
    ) -> (privateKey: Data, publicKey: Data)? {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-----BEGIN SCARF ED25519 PRIVATE KEY-----"),
              trimmed.hasSuffix("-----END SCARF ED25519 PRIVATE KEY-----") else {
            return nil
        }
        let inner = trimmed
            .replacingOccurrences(of: "-----BEGIN SCARF ED25519 PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END SCARF ED25519 PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: inner), data.count == 64 else { return nil }
        let priv = data.prefix(32)
        let pub = data.suffix(32)
        return (Data(priv), Data(pub))
    }

    // MARK: - Internal helpers

    /// SSH wire format "string": `uint32_be(len(x)) ‖ x`.
    private static func appendSSHString(_ blob: inout Data, bytes: Data) {
        let len = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: len) { raw in
            blob.append(contentsOf: raw)
        }
        blob.append(bytes)
    }

    private static func wrap(_ s: String, at width: Int) -> String {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: width, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[i..<next]))
            i = next
        }
        return out.joined(separator: "\n")
    }
}

#endif // canImport(CryptoKit)
