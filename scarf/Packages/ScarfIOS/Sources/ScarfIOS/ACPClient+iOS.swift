// Gated on `canImport(Citadel)` so Linux CI skips.
#if canImport(Citadel)

import Foundation
import Citadel
import CryptoKit
import ScarfCore

/// iOS-target glue that produces `ACPClient`s pre-wired with a
/// Citadel-backed `SSHExecACPChannel`. Sibling to the Mac app's
/// `ACPClient+Mac.swift` — both expose a `forXXX(context:)` factory
/// that `ACPClient.ChannelFactory` consumes.
///
/// **Connection reuse.** The factory opens a fresh `SSHClient` per
/// ACP session rather than reusing the long-lived `CitadelServerTransport`
/// client — ACP sessions are long-lived (minutes to hours of streaming
/// chat) and cohabiting them with the SFTP + exec calls that the
/// transport uses would multiplex SSH channels on one connection,
/// which OpenSSH servers often cap at 10 channels. Two separate
/// connections stay well under that ceiling and fail-isolate.
///
/// If that per-feature cost becomes a bottleneck, a future phase
/// can coalesce — Citadel's single `SSHClient` can host multiple
/// concurrent channels up to the server's limit.
public extension ACPClient {
    /// Build an `ACPClient` for `context` pre-wired with a Citadel
    /// exec channel that spawns `hermes acp` remotely.
    ///
    /// - Parameters:
    ///   - context: Server context — must be a `.ssh` kind; `.local`
    ///     doesn't make sense on iOS (no local subprocess on iOS).
    ///   - keyProvider: How to load the SSH private key for the
    ///     connection. Typically `{ try await KeychainSSHKeyStore().load() }`.
    static func forIOSApp(
        context: ServerContext,
        keyProvider: @escaping @Sendable () async throws -> SSHKeyBundle
    ) -> ACPClient {
        ACPClient(context: context) { ctx in
            try await makeSSHExecChannel(for: ctx, keyProvider: keyProvider)
        }
    }

    /// Open a dedicated SSHClient for this ACP session and hand it
    /// to `SSHExecACPChannel`. The channel owns the client lifecycle
    /// — when `ACPClient.stop()` triggers `channel.close()`, the
    /// underlying SSH connection is also closed (clean teardown).
    nonisolated private static func makeSSHExecChannel(
        for context: ServerContext,
        keyProvider: @Sendable () async throws -> SSHKeyBundle
    ) async throws -> any ACPChannel {
        guard case .ssh(let sshConfig) = context.kind else {
            throw ACPChannelError.other("iOS ACPClient requires a remote .ssh context — got \(context.kind)")
        }
        let key = try await keyProvider()
        let client = try await openSSHClient(config: sshConfig, key: key)

        // Command to spawn. `hermes acp` is the ACP entry point.
        //
        // SSH `exec` (RFC 4254) runs a non-interactive, non-login shell
        // whose PATH is the sshd default (`/usr/bin:/bin:/usr/sbin:/sbin`).
        // Common Hermes install locations like `~/.local/bin` (pipx),
        // `/opt/homebrew/bin`, and `/usr/local/bin` aren't on that PATH,
        // and `-l` alone doesn't help because most users add PATH exports
        // to `.zshrc` which is only sourced for interactive shells.
        //
        // We mirror `HermesPathSet.hermesBinaryCandidates` (the Mac-side
        // local probe list) by prepending all four common locations to
        // PATH before `exec`-ing hermes. Binary-clean stdio (JSON-RPC on
        // stdin/stdout) is preserved because `exec` replaces the shell
        // process — no intermediate layer buffers the bytes.
        let hermesCmd = context.paths.hermesBinary + " acp"
        let command = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH\" exec \(hermesCmd)"

        return try await SSHExecACPChannel(
            client: client,
            command: command,
            ownsClient: true
        )
    }

    /// Shared SSH connect flow — used by ACPClient and
    /// `CitadelServerTransport.ConnectionHolder`. Single source of
    /// truth for the auth-method translation (SSHKeyBundle → Citadel
    /// `SSHAuthenticationMethod.ed25519`).
    nonisolated private static func openSSHClient(
        config: SSHConfig,
        key: SSHKeyBundle
    ) async throws -> SSHClient {
        guard let parts = Ed25519KeyGenerator.decodeRawEd25519PEM(key.privateKeyPEM) else {
            throw ACPChannelError.launchFailed("Stored private key is not in the expected Scarf Ed25519 PEM format")
        }
        guard let ck = try? Curve25519.Signing.PrivateKey(rawRepresentation: parts.privateKey) else {
            throw ACPChannelError.launchFailed("Stored private key is malformed")
        }
        let username = config.user ?? "root"
        let auth: SSHAuthenticationMethod = .ed25519(username: username, privateKey: ck)
        var settings = SSHClientSettings(
            host: config.host,
            authenticationMethod: { auth },
            hostKeyValidator: .acceptAnything()
        )
        if let port = config.port { settings.port = port }
        do {
            return try await SSHClient.connect(to: settings)
        } catch {
            throw ACPChannelError.launchFailed("SSH connect to \(config.host) failed: \(error.localizedDescription)")
        }
    }
}

#endif // canImport(Citadel)
