// Gated on `canImport(Citadel)` like every Citadel-touching file.
#if canImport(Citadel)

import Foundation
import Citadel
import CryptoKit
@preconcurrency import NIOSSH
import NIOCore

/// The one host-key check every ScarfGo SSH connection goes through (the
/// pooled transport, the ACP chat channel, onboarding's Test Connection).
/// Trust on first use, then refuse any other key — see `HostKeyPinStore`.
///
/// NIOSSH calls `validateHostKey` on the connection's event loop during key
/// exchange; the store answers synchronously under a lock, so the promise is
/// completed inline without blocking the loop or touching the main actor.
public struct PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    public let endpoint: HostKeyEndpoint
    let store: HostKeyPinStore
    /// Captures the typed mismatch so the connect funnel can rethrow it even
    /// if Citadel/NIO hands back a wrapped or different error.
    let recorder: HostKeyRejectionRecorder?

    public init(endpoint: HostKeyEndpoint, store: HostKeyPinStore = .shared) {
        self.init(endpoint: endpoint, store: store, recorder: nil)
    }

    init(endpoint: HostKeyEndpoint, store: HostKeyPinStore, recorder: HostKeyRejectionRecorder?) {
        self.endpoint = endpoint
        self.store = store
        self.recorder = recorder
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        do {
            switch try store.evaluate(presentedOpenSSHKey: line, for: endpoint) {
            case .pinnedOnFirstUse, .matched:
                validationCompletePromise.succeed(())
            case .mismatch(let mismatch):
                recorder?.record(mismatch)
                validationCompletePromise.fail(mismatch)
            }
        } catch {
            // A key NIOSSH parsed but we can't fingerprint: never trust it.
            validationCompletePromise.fail(error)
        }
    }

    /// Wrap as Citadel's validator type for `SSHClientSettings`.
    public var citadelValidator: SSHHostKeyValidator { .custom(self) }
}

/// Lock-protected slot for the mismatch a validator saw during one connect.
final class HostKeyRejectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HostKeyMismatchError?

    func record(_ error: HostKeyMismatchError) { lock.withLock { value = error } }
    var mismatch: HostKeyMismatchError? { lock.withLock { value } }
}

/// The shared Citadel connect for every ScarfGo funnel: Ed25519 auth, the
/// pinned host-key validator, and `SSHConnectPolicy`'s timeout retries.
///
/// A host-key mismatch is always thrown as `HostKeyMismatchError` (never a
/// generic connect failure), so each caller can pass it through untouched.
enum PinnedSSHConnect {
    static func connect(
        host: String,
        port: Int?,
        username: String,
        privateKey: Curve25519.Signing.PrivateKey,
        store: HostKeyPinStore
    ) async throws -> SSHClient {
        let endpoint = HostKeyEndpoint(host: host, port: port)
        let recorder = HostKeyRejectionRecorder()
        do {
            return try await SSHConnectPolicy.connect {
                // Fresh SSHAuthenticationMethod per attempt — Citadel's
                // auth delegate consumes its offer list on use, so a reused
                // instance would fail the retry with
                // `allAuthenticationOptionsFailed` instead of re-offering
                // the key.
                let auth: SSHAuthenticationMethod = .ed25519(username: username, privateKey: privateKey)
                var settings = SSHClientSettings(
                    host: host,
                    authenticationMethod: { auth },
                    hostKeyValidator: PinnedHostKeyValidator(
                        endpoint: endpoint, store: store, recorder: recorder
                    ).citadelValidator
                )
                if let port { settings.port = port }
                do {
                    return try await SSHClient.connect(to: settings)
                } catch {
                    // Surface a refused host key as itself, inside the
                    // policy loop too: `SSHConnectPolicy` retries only
                    // timeouts, so a mismatch is never retried even if
                    // Citadel reports the dropped handshake some other way.
                    throw recorder.mismatch ?? error
                }
            }
        } catch {
            if let mismatch = HostKeyMismatchError.find(in: error) ?? recorder.mismatch {
                throw mismatch
            }
            throw error
        }
    }
}

extension HostKeyMismatchError {
    /// The mismatch inside `error`, if it is one (directly or as the
    /// underlying error of a wrapper that exposes one).
    static func find(in error: Error) -> HostKeyMismatchError? {
        if let mismatch = error as? HostKeyMismatchError { return mismatch }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        return underlying.flatMap { $0 as? HostKeyMismatchError }
    }
}

#endif // canImport(Citadel)
