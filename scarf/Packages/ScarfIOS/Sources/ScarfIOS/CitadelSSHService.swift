// Citadel is an Apple-only package; the whole service is gated so
// Linux CI (which builds `ScarfCore` standalone) doesn't try to
// resolve it. On iOS and macOS the file compiles normally.
#if canImport(Citadel) && canImport(CryptoKit)

import Foundation
import Citadel
import NIOCore
import CryptoKit
import ScarfCore

/// Citadel-backed implementation of `SSHConnectionTester`.
///
/// Responsible for:
///   - Minting fresh Ed25519 keypairs (delegated to
///     `Ed25519KeyGenerator`).
///   - Running one-shot SSH exec probes (`echo ok`) for the
///     onboarding "Test Connection" step.
///   - Future: hosting the long-lived SSH session M3+ features
///     (file transport, SQLite snapshot pulls, ACP channel) will
///     layer on top.
///
/// **Citadel API disclaimer.** Citadel 0.9's exact authentication-
/// method spelling for Ed25519 private keys is evolving across
/// 0.7 → 0.9. The `runOneShotProbe(...)` helper below is written
/// against the documented `SSHClientSettings` + `.privateKey(...)`
/// pattern; if Citadel has renamed or refactored that variant,
/// adjust `buildClientSettings(...)` — everything else (the retry
/// loop, the error classification, the exit-code handling) is
/// Citadel-version-independent.
public struct CitadelSSHService: SSHConnectionTester {
    /// Seconds to wait for the probe exec. Set tight so onboarding
    /// doesn't hang on a silently-dropped connection.
    public static let probeTimeoutSeconds: TimeInterval = 10

    public init() {}

    // MARK: - Key generation (public entry point)

    /// Passthrough to `Ed25519KeyGenerator.generate(...)`. Exposed on
    /// the service so ViewModels only depend on `CitadelSSHService`,
    /// not on the generator type directly (cleaner for mocking).
    public func generateEd25519Key(comment: String? = nil) throws -> SSHKeyBundle {
        try Ed25519KeyGenerator.generate(comment: comment)
    }

    // MARK: - SSHConnectionTester

    public func testConnection(
        config: IOSServerConfig,
        key: SSHKeyBundle
    ) async throws {
        let probe = try await runOneShotProbe(
            config: config,
            key: key,
            command: "echo scarf-ok"
        )
        if !probe.stdout.contains("scarf-ok") {
            throw SSHConnectionTestError.commandFailed(
                exitCode: Int(probe.exitCode),
                stderr: probe.stderr.isEmpty
                    ? "probe command didn't echo back the expected marker"
                    : probe.stderr
            )
        }
    }

    // MARK: - Probe

    /// Thin wrapper that owns the full connect → exec → disconnect
    /// lifecycle and surfaces a typed error on failure. Separated
    /// from `testConnection(...)` so a future M3 feature (list
    /// remote projects, spin up tunneled services) can reuse the
    /// same connection glue.
    public struct ProbeResult: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    public func runOneShotProbe(
        config: IOSServerConfig,
        key: SSHKeyBundle,
        command: String
    ) async throws -> ProbeResult {
        let settings = try buildClientSettings(config: config, key: key)

        let client: SSHClient
        do {
            client = try await SSHClient.connect(to: settings)
        } catch {
            throw Self.classifyConnectError(error, host: config.host)
        }
        // Always try to close the client, even on exec failure.
        defer {
            Task { try? await client.close() }
        }

        do {
            let buffer: ByteBuffer = try await client.executeCommand(command)
            var buf = buffer
            let stdout = buf.readString(length: buf.readableBytes) ?? ""
            return ProbeResult(
                stdout: stdout,
                stderr: "",
                exitCode: 0
            )
        } catch {
            throw SSHConnectionTestError.commandFailed(
                exitCode: 1,
                stderr: error.localizedDescription
            )
        }
    }

    // MARK: - Citadel glue

    /// Translate our in-house `SSHKeyBundle` (raw 32+32 byte Ed25519)
    /// into Citadel's authentication method.
    ///
    /// **FIXME when updating Citadel.** The exact function name below
    /// is my best read of Citadel 0.7–0.9's API surface — private-key
    /// auth has gone through several iterations. If the build fails
    /// here with "no member `ed25519`" or similar, check the current
    /// `SSHAuthenticationMethod.swift` in the pinned Citadel version
    /// and adjust. Everything else (key decode, error classification,
    /// timeout) is independent.
    private func buildClientSettings(
        config: IOSServerConfig,
        key: SSHKeyBundle
    ) throws -> SSHClientSettings {
        guard let parts = Ed25519KeyGenerator.decodeRawEd25519PEM(key.privateKeyPEM) else {
            throw SSHConnectionTestError.other(
                "Stored private key is not in the expected Scarf Ed25519 PEM format"
            )
        }
        guard let ck = try? Curve25519.Signing.PrivateKey(rawRepresentation: parts.privateKey) else {
            throw SSHConnectionTestError.other("Stored private key is malformed")
        }
        let username = config.user ?? "root"
        // See FIXME above — the `.ed25519(...)` method name is the
        // shape I expect based on Citadel 0.7–0.9 docs; double-check
        // on Mac once the pod is resolved.
        let auth: SSHAuthenticationMethod = .ed25519(
            username: username,
            privateKey: ck
        )

        var settings = SSHClientSettings(
            host: config.host,
            authenticationMethod: { auth },
            hostKeyValidator: .acceptAnything()
        )
        if let port = config.port {
            settings.port = port
        }
        return settings
    }

    // MARK: - Error mapping

    /// Best-effort classification of Citadel / NIO connect errors to
    /// our `SSHConnectionTestError` cases. Keep the pattern-matching
    /// loose — NIO wraps errors in multiple layers and the exact
    /// strings shift across versions.
    nonisolated static func classifyConnectError(
        _ error: Error,
        host: String
    ) -> SSHConnectionTestError {
        let s = String(describing: error).lowercased()
        if s.contains("authentication") || s.contains("publickey") || s.contains("userauth") {
            return .authenticationFailed(host: host, detail: "Check that the public key above is in ~/.ssh/authorized_keys on the remote.")
        }
        if s.contains("host key") || s.contains("hostkey") {
            return .hostKeyMismatch(host: host, detail: String(describing: error))
        }
        if s.contains("connection refused") || s.contains("unreachable") || s.contains("no route") {
            return .hostUnreachable(host: host, underlying: String(describing: error))
        }
        if s.contains("timeout") || s.contains("timed out") {
            return .timeout(seconds: probeTimeoutSeconds)
        }
        return .other(error.localizedDescription)
    }
}

#endif // canImport(Citadel) && canImport(CryptoKit)
