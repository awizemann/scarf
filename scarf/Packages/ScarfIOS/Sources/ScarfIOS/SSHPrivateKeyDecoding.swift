// Bridges a stored `SSHKeyBundle.privateKeyPEM` into the CryptoKit
// `Curve25519.Signing.PrivateKey` that Citadel's `.ed25519(...)` auth
// method needs — accepting BOTH private-key shapes Scarf can hold.
//
// Why two shapes: the "Generate a new key" flow mints the key on-device
// and stores it as the app's own raw PEM (`BEGIN SCARF ED25519 PRIVATE
// KEY`, 32-byte seed ‖ 32-byte public — see `Ed25519KeyGenerator`). The
// "Import existing key" flow stores exactly what the user pasted, which is
// a standard OpenSSH private key (`BEGIN OPENSSH PRIVATE KEY`). Before this
// helper the three connect sites decoded ONLY the Scarf raw PEM, so every
// imported key failed at connect with "not in the expected Scarf Ed25519
// PEM format" — the import path could never succeed (gh: import-key).
#if canImport(Citadel) && canImport(CryptoKit)

import Foundation
import Citadel
import CryptoKit
import ScarfCore

public enum SSHPrivateKeyDecoding {
    public enum DecodeError: Error, CustomStringConvertible {
        /// Neither a Scarf raw PEM nor an OpenSSH private key.
        case unrecognizedFormat
        /// Scarf raw PEM decoded but the 32-byte seed wasn't a valid key.
        case malformedScarfPEM
        /// OpenSSH envelope present but Citadel couldn't parse it (wrong key
        /// type, or an encrypted key we can't unlock without a passphrase).
        case opensshParseFailed(underlying: Error)

        public var description: String {
            switch self {
            case .unrecognizedFormat:
                return "Stored private key isn't a recognized Ed25519 key (expected an OpenSSH private key or a Scarf-generated key)."
            case .malformedScarfPEM:
                return "Stored private key is malformed."
            case .opensshParseFailed(let underlying):
                return "OpenSSH private key couldn't be parsed (\(underlying.localizedDescription)). It must be an unencrypted Ed25519 key."
            }
        }
    }

    /// Decode `privateKeyPEM` into a CryptoKit Ed25519 signing key.
    ///
    /// Order: try the app's own raw PEM first (cheap, exact-prefix match),
    /// then fall back to the OpenSSH container that `Import existing key`
    /// stores. Both round-trip to the same `.ed25519` Citadel auth method.
    public static func curve25519PrivateKey(fromPEM pem: String) throws -> Curve25519.Signing.PrivateKey {
        // Generate flow: Scarf raw PEM (seed ‖ public).
        if let parts = Ed25519KeyGenerator.decodeRawEd25519PEM(pem) {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: parts.privateKey) else {
                throw DecodeError.malformedScarfPEM
            }
            return key
        }

        // Import flow: standard OpenSSH private key. Citadel unwraps the
        // `openssh-key-v1` envelope (see Citadel `SSHCert.swift`).
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
            do {
                return try Curve25519.Signing.PrivateKey(sshEd25519: trimmed)
            } catch {
                throw DecodeError.opensshParseFailed(underlying: error)
            }
        }

        throw DecodeError.unrecognizedFormat
    }
}

#endif // canImport(Citadel) && canImport(CryptoKit)
