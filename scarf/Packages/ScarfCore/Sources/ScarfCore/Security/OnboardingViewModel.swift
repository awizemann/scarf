import Foundation
import Observation

/// Drives the iOS onboarding flow's state. SwiftUI views bind to this
/// via `@State var viewModel: OnboardingViewModel`; tests drive it
/// directly without a UI.
///
/// This VM lives in ScarfCore (not ScarfIOS) because the state-machine
/// transitions are pure logic — no Keychain, no Citadel, no UIKit.
/// The concrete storage + SSH implementations are injected as
/// protocol references so tests can stub them.
@Observable
@MainActor
public final class OnboardingViewModel {
    // MARK: - Public state

    public private(set) var step: OnboardingStep = .serverDetails

    /// Input fields for the server-details screen.
    public var host: String = ""
    public var user: String = ""
    public var portText: String = ""
    public var displayName: String = ""

    /// What the user picks on the key-source screen.
    public private(set) var keyChoice: OnboardingKeyChoice?

    /// Freshly-generated or freshly-imported key bundle. Populated on
    /// the transition INTO `.showPublicKey`; the view reads
    /// `keyBundle?.publicKeyOpenSSH` to display.
    public private(set) var keyBundle: SSHKeyBundle?

    /// Raw PEM the user pasted on the import screen. Bound by the
    /// import form's text editor.
    public var importPEM: String = ""

    /// Is some async operation in flight (key generation, connection
    /// test, save)? Views disable buttons while `true`.
    public private(set) var isWorking: Bool = false

    /// Last connection-test error, if any — surfaced on the
    /// `.testFailed` screen.
    public private(set) var lastTestError: SSHConnectionTestError?

    // MARK: - Dependencies

    /// Produces a fresh Ed25519 keypair. Lives in ScarfIOS on real
    /// builds (`CitadelSSHService`) and in tests as a closure that
    /// returns a fixed bundle.
    public typealias KeyGenerator = @Sendable () async throws -> SSHKeyBundle

    private let keyStore: any SSHKeyStore
    private let configStore: any IOSServerConfigStore
    private let tester: any SSHConnectionTester
    private let keyGenerator: KeyGenerator

    public init(
        keyStore: any SSHKeyStore,
        configStore: any IOSServerConfigStore,
        tester: any SSHConnectionTester,
        keyGenerator: @escaping KeyGenerator
    ) {
        self.keyStore = keyStore
        self.configStore = configStore
        self.tester = tester
        self.keyGenerator = keyGenerator
    }

    // MARK: - Derived

    public var serverDetailsValidation: OnboardingServerDetailsValidation {
        OnboardingLogic.validateServerDetails(host: host, portText: portText)
    }

    // MARK: - Transitions

    public func advanceFromServerDetails() {
        guard serverDetailsValidation.canAdvance else { return }
        step = .keySource
    }

    public func pickKeyChoice(_ choice: OnboardingKeyChoice) {
        keyChoice = choice
        switch choice {
        case .generate:     step = .generate
        case .importExisting: step = .importKey
        }
    }

    /// Called from the "Generate" screen. Runs the injected generator,
    /// stores the bundle, and advances to `.showPublicKey`.
    public func generateKey() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let bundle = try await keyGenerator()
            self.keyBundle = bundle
            step = .showPublicKey
        } catch {
            // Generation really shouldn't fail under normal circumstances
            // (it's CPU, no network). Surface as testFailed for now so
            // the user can retry; there's no dedicated error screen.
            lastTestError = .other("Key generation failed: \(error.localizedDescription)")
            step = .testFailed(reason: "Failed to generate SSH key: \(error.localizedDescription)")
        }
    }

    /// Called from the "Import" screen after the user pastes PEM.
    /// Validates the shape; on success populates `keyBundle` and
    /// moves to `.showPublicKey` so the user can still copy the public
    /// key if they haven't added it to `authorized_keys` yet.
    public func importKey(publicKey: String, deviceComment: String, iso8601Date: String) -> Bool {
        let pem = importPEM
        guard OnboardingLogic.isLikelyValidOpenSSHPrivateKey(pem) else {
            lastTestError = .other("Pasted text doesn't look like an OpenSSH private key. Export it with `ssh-keygen -p -m PEM-OpenSSH`.")
            step = .testFailed(reason: lastTestError?.errorDescription ?? "Invalid key")
            return false
        }
        guard let pub = OnboardingLogic.parseOpenSSHPublicKeyLine(publicKey) else {
            lastTestError = .other("The public-key line doesn't look right. Paste the single line from your `id_ed25519.pub`.")
            step = .testFailed(reason: lastTestError?.errorDescription ?? "Invalid public key")
            return false
        }
        keyBundle = SSHKeyBundle(
            privateKeyPEM: pem.trimmingCharacters(in: .whitespacesAndNewlines),
            publicKeyOpenSSH: pub,
            comment: deviceComment,
            createdAt: iso8601Date
        )
        step = .showPublicKey
        return true
    }

    /// Called from the "Show public key" screen when the user taps
    /// "I've added this to authorized_keys". Persists the key to the
    /// Keychain, then runs the connection test inline.
    public func confirmPublicKeyAdded() async {
        guard let bundle = keyBundle, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await keyStore.save(bundle)
        } catch {
            lastTestError = .other("Couldn't save key to Keychain: \(error.localizedDescription)")
            step = .testFailed(reason: lastTestError?.errorDescription ?? "Keychain save failed")
            return
        }

        await performConnectionTest()
    }

    /// Re-run the SSH connection probe. Called from the `.testFailed`
    /// screen's "Retry" button, or from any other path that wants to
    /// bounce the connection without re-saving the key.
    public func runConnectionTest() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await performConnectionTest()
    }

    /// Core probe implementation. Must be called with `isWorking == true`
    /// already set by the caller (both entry points above do this). On
    /// success, saves the config and transitions to `.connected`. On
    /// failure, transitions to `.testFailed` carrying the reason.
    private func performConnectionTest() async {
        guard let bundle = keyBundle else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let trimmedDisplayName: String = {
            let d = displayName.trimmingCharacters(in: .whitespaces)
            return d.isEmpty ? trimmedHost : d
        }()
        let port: Int? = Int(portText.trimmingCharacters(in: .whitespaces))

        let config = IOSServerConfig(
            host: trimmedHost,
            user: trimmedUser.isEmpty ? nil : trimmedUser,
            port: port,
            hermesBinaryHint: nil,
            remoteHome: nil,
            displayName: trimmedDisplayName
        )

        step = .testConnection
        lastTestError = nil

        do {
            try await tester.testConnection(config: config, key: bundle)
            try await configStore.save(config)
            step = .connected
        } catch let err as SSHConnectionTestError {
            lastTestError = err
            step = .testFailed(reason: err.errorDescription ?? "Connection failed")
        } catch {
            lastTestError = .other(error.localizedDescription)
            step = .testFailed(reason: error.localizedDescription)
        }
    }

    /// Called from `.testFailed` when the user taps "Back".
    public func goBackToServerDetails() {
        step = .serverDetails
        lastTestError = nil
    }

    /// Reset all state — used by a "Start over" affordance.
    public func reset() async {
        step = .serverDetails
        host = ""
        user = ""
        portText = ""
        displayName = ""
        importPEM = ""
        keyChoice = nil
        keyBundle = nil
        lastTestError = nil
        try? await keyStore.delete()
        try? await configStore.delete()
    }
}
