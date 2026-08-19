#if canImport(Citadel) && canImport(CryptoKit)

import Testing
import Foundation
import CryptoKit
import ScarfCore
@testable import ScarfIOS

/// Both onboarding paths must round-trip to the same Citadel `.ed25519`
/// auth method: "Generate" stores the app's own Scarf raw PEM, "Import
/// existing key" stores a standard OpenSSH private key. Before the shared
/// decoder, the connect path only understood the Scarf PEM, so every
/// imported key failed at connect ("not in the expected Scarf Ed25519 PEM
/// format") — the import flow could never succeed.
@Suite struct SSHPrivateKeyDecodingTests {

    // A throwaway, unencrypted OpenSSH ed25519 key (generated for this test —
    // not used anywhere) and its known 32-byte raw public key.
    private static let opensshKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACD6qNG+9pT1elxqvMXdRLc2dHMA8dwIC8ERfAY7ovCkfAAAAJDcs36s3LN+
    rAAAAAtzc2gtZWQyNTUxOQAAACD6qNG+9pT1elxqvMXdRLc2dHMA8dwIC8ERfAY7ovCkfA
    AAAEBaalRF1NhGxgzKVQEKYCuXdXW7oTeH2V+d8wxZ/mx2SPqo0b72lPV6XGq8xd1EtzZ0
    cwDx3AgLwRF8Bjui8KR8AAAAC2RlY29kZS10ZXN0AQI=
    -----END OPENSSH PRIVATE KEY-----
    """
    private static let opensshPublicRawB64 = "+qjRvvaU9XpcarzF3US3NnRzAPHcCAvBEXwGO6LwpHw="

    @Test("Import flow: a standard OpenSSH ed25519 key decodes to the matching key")
    func decodesOpenSSH() throws {
        let key = try SSHPrivateKeyDecoding.curve25519PrivateKey(fromPEM: Self.opensshKey)
        #expect(key.publicKey.rawRepresentation.base64EncodedString() == Self.opensshPublicRawB64)
    }

    @Test("Import flow tolerates surrounding whitespace")
    func decodesOpenSSHWithWhitespace() throws {
        let padded = "\n  \n" + Self.opensshKey + "\n\n"
        let key = try SSHPrivateKeyDecoding.curve25519PrivateKey(fromPEM: padded)
        #expect(key.publicKey.rawRepresentation.base64EncodedString() == Self.opensshPublicRawB64)
    }

    @Test("Generate flow: the app's own Scarf raw PEM still decodes")
    func decodesScarfPEM() throws {
        let bundle = try Ed25519KeyGenerator.generate(comment: "unit-test")
        let key = try SSHPrivateKeyDecoding.curve25519PrivateKey(fromPEM: bundle.privateKeyPEM)
        // The decoded key's public half must equal the bundle's stored public.
        let expected = Ed25519KeyGenerator.decodeRawEd25519PEM(bundle.privateKeyPEM)!.publicKey
        #expect(key.publicKey.rawRepresentation == expected)
    }

    @Test("Neither format → unrecognizedFormat")
    func rejectsGarbage() {
        #expect(throws: SSHPrivateKeyDecoding.DecodeError.self) {
            try SSHPrivateKeyDecoding.curve25519PrivateKey(fromPEM: "not a key")
        }
    }
}

#endif // canImport(Citadel) && canImport(CryptoKit)
