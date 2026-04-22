import Foundation

/// The screens the iOS onboarding flow moves through. Kept out of the
/// iOS package so the transition logic is exercised by tests that
/// don't need a simulator.
///
/// **Flow:**
/// ```
/// .serverDetails  ─▶  .keySource        (user taps "Next")
/// .keySource      ─▶  .generate         (user picks "Create new key")
///                 ─▶  .importKey        (user picks "Import existing key")
/// .generate       ─▶  .showPublicKey    (key pair minted, show public key to copy)
/// .importKey      ─▶  .showPublicKey    (OR .testConnection — if import succeeds)
/// .showPublicKey  ─▶  .testConnection   (user confirms they've added the key to authorized_keys)
/// .testConnection ─▶  .connected        (ssh exec "echo ok" succeeded)
///                 ─▶  .testFailed       (connect failed — allow retry)
/// .testFailed     ─▶  .testConnection   (retry)
///                 ─▶  .serverDetails    (back)
/// ```
public enum OnboardingStep: Sendable, Equatable {
    case serverDetails
    case keySource
    case generate
    case importKey
    case showPublicKey
    case testConnection
    case testFailed(reason: String)
    case connected
}

/// What the user wants to do with the SSH key at the start of
/// onboarding.
public enum OnboardingKeyChoice: Sendable, Equatable {
    case generate
    case importExisting
}

/// Validation result for the server-details form. The onboarding view
/// consumes this to decide whether the "Next" button is enabled.
public struct OnboardingServerDetailsValidation: Sendable, Equatable {
    public var isHostValid: Bool
    public var isPortValid: Bool
    public var canAdvance: Bool

    public init(isHostValid: Bool, isPortValid: Bool, canAdvance: Bool) {
        self.isHostValid = isHostValid
        self.isPortValid = isPortValid
        self.canAdvance = canAdvance
    }
}

/// Pure functions used by the iOS onboarding. Kept in ScarfCore so
/// the logic is testable on any platform without mocking SwiftUI.
public enum OnboardingLogic {
    /// Validate the typed host + port. Host must be non-empty and
    /// not contain whitespace; port (if provided) must be a valid
    /// 1-65535 integer. User + remoteHome + hermesBinaryHint are
    /// all optional; their emptiness doesn't block advancement.
    public static func validateServerDetails(
        host: String,
        portText: String
    ) -> OnboardingServerDetailsValidation {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let hostValid = !trimmed.isEmpty
            && trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil

        let portValid: Bool
        if portText.isEmpty {
            portValid = true
        } else if let n = Int(portText), (1...65535).contains(n) {
            portValid = true
        } else {
            portValid = false
        }

        return OnboardingServerDetailsValidation(
            isHostValid: hostValid,
            isPortValid: portValid,
            canAdvance: hostValid && portValid
        )
    }

    /// Build the OpenSSH `authorized_keys`-style line the user should
    /// paste into their remote account, including a trailing newline
    /// so append-style workflows don't merge lines.
    public static func authorizedKeysLine(for bundle: SSHKeyBundle) -> String {
        bundle.publicKeyOpenSSH.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Basic sanity-check an imported OpenSSH private key PEM. Accepts
    /// `-----BEGIN OPENSSH PRIVATE KEY-----` + `-----END …-----` bookends
    /// and a non-empty body between them. Rejects legacy `BEGIN RSA
    /// PRIVATE KEY` formats — users who only have those need to
    /// re-export their key with `ssh-keygen -p -m PEM-OpenSSH`.
    ///
    /// Does NOT verify the key is cryptographically valid — that's
    /// Citadel's job at connect time. This is just a "did the user
    /// paste the right thing?" gate on the import form.
    public static func isLikelyValidOpenSSHPrivateKey(_ pem: String) -> Bool {
        let text = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") else { return false }
        guard text.hasSuffix("-----END OPENSSH PRIVATE KEY-----") else { return false }
        // Body between the bookends must be non-trivial.
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.count >= 3
    }

    /// Extract the public-key line embedded in a user-supplied
    /// import. Some users paste their `authorized_keys` line (just
    /// the public half). We accept that — the flow lets them skip
    /// the "show public key" step since they already have it on
    /// the remote.
    ///
    /// Returns the trimmed line if it matches the `ssh-* AAAA… [comment]`
    /// shape; nil otherwise.
    public static func parseOpenSSHPublicKeyLine(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let algo = parts[0]
        let keyBlob = parts[1]
        let validAlgos: Set<Substring> = [
            "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        ]
        guard validAlgos.contains(algo) else { return nil }
        // Base64 blob should start with a standard base64 alphabet.
        let blobFirstCharOK = keyBlob.first.map {
            $0.isLetter || $0.isNumber
        } ?? false
        guard blobFirstCharOK else { return nil }
        return trimmed
    }
}
