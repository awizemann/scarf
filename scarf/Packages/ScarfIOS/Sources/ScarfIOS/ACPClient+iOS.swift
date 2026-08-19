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
    ///   - projectCwd: When set, `hermes acp` is spawned with this as its
    ///     working directory (via a `cd …;` prefix), so Hermes loads that
    ///     project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` context
    ///     files. Hermes reads them from the PROCESS cwd, not the ACP
    ///     session cwd — this is the iOS counterpart to Mac's
    ///     `ACPClient.forMacApp(projectCwd:)`. Nil for non-project chats.
    ///   - keyProvider: Override for how the SSH private key is loaded.
    ///     Tests inject a fixed bundle here. `nil` (the default, and
    ///     what the app uses) resolves the key for THIS connection's
    ///     server entry via `SSHKeyResolver` — the singleton
    ///     `KeychainSSHKeyStore().load()` the app used to pass picks
    ///     the first-sorted key across ALL entries, which is the wrong
    ///     key on any device with more than one stored key (gh#133).
    static func forIOSApp(
        context: ServerContext,
        projectCwd: String? = nil,
        keyProvider: (@Sendable () async throws -> SSHKeyBundle)? = nil
    ) -> ACPClient {
        ACPClient(context: context) { ctx in
            try await makeSSHExecChannel(for: ctx, projectCwd: projectCwd, keyProvider: keyProvider)
        }
    }

    /// Open a dedicated SSHClient for this ACP session and hand it
    /// to `SSHExecACPChannel`. The channel owns the client lifecycle
    /// — when `ACPClient.stop()` triggers `channel.close()`, the
    /// underlying SSH connection is also closed (clean teardown).
    nonisolated private static func makeSSHExecChannel(
        for context: ServerContext,
        projectCwd: String?,
        keyProvider: (@Sendable () async throws -> SSHKeyBundle)?
    ) async throws -> any ACPChannel {
        guard case .ssh(let sshConfig) = context.kind else {
            throw ACPChannelError.other("iOS ACPClient requires a remote .ssh context — got \(context.kind)")
        }
        let key: SSHKeyBundle
        if let keyProvider {
            key = try await keyProvider()
        } else {
            key = try await SSHKeyResolver.key(for: sshConfig)
        }
        let client = try await openSSHClient(config: sshConfig, key: key)

        let command = buildACPCommand(
            hermesBinary: context.paths.hermesBinary,
            home: context.paths.home,
            projectCwd: projectCwd
        )

        return try await SSHExecACPChannel(
            client: client,
            command: command,
            ownsClient: true
        )
    }

    /// Build the remote shell command that spawns `hermes acp`. Pure and
    /// side-effect-free so it's unit-testable without an SSH connection
    /// (see `ACPCommandBuilderTests`).
    ///
    /// SSH `exec` (RFC 4254) runs a non-interactive, non-login shell whose
    /// PATH is the sshd default (`/usr/bin:/bin:/usr/sbin:/sbin`). Common
    /// Hermes install locations like `~/.local/bin` (pipx),
    /// `/opt/homebrew/bin`, and `/usr/local/bin` aren't on that PATH, and
    /// `-l` alone doesn't help because most users add PATH exports to
    /// `.zshrc` which is only sourced for interactive shells. We mirror
    /// `HermesPathSet.hermesBinaryCandidates` (the Mac-side local probe
    /// list) by prepending all four common locations to PATH before
    /// `exec`-ing hermes. Binary-clean stdio (JSON-RPC on stdin/stdout) is
    /// preserved because `exec` replaces the shell process — no
    /// intermediate layer buffers the bytes.
    ///
    /// When `projectCwd` is set, the command `cd`s into the project dir
    /// FIRST so Hermes loads that project's `AGENTS.md` / `CLAUDE.md` /
    /// `.cursorrules` (it reads context files from the process cwd, not the
    /// ACP session cwd — same rationale and counterpart to Mac's
    /// `SSHTransport.makeProcess(cwd:)`). `;` not `&&` is deliberate: a
    /// stale/missing project dir degrades to the login dir rather than
    /// failing the whole session. The path is quoted via
    /// `HermesProfileScope.shellQuotePath` so spaces survive and an
    /// injected `$()`/`;`/backtick in a hostile path is inert.
    static func buildACPCommand(
        hermesBinary: String,
        home: String,
        projectCwd: String?
    ) -> String {
        // Scope the chat session to the selected profile's HERMES_HOME
        // (#120, Design B), so chat reads/writes the same profile the rest
        // of the app shows. Empty for a default/root home → unchanged
        // `exec hermes acp`. `home` already carries the profile-resolved
        // remoteHome from ScarfGoTabRoot's effectiveConfig.
        let hermesHome = HermesProfileScope.hermesHomeShellAssignment(forHome: home)
        let cdPrefix: String
        if let projectCwd, !projectCwd.isEmpty {
            cdPrefix = "cd \(HermesProfileScope.shellQuotePath(projectCwd)); "
        } else {
            cdPrefix = ""
        }
        return "\(cdPrefix)PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH\" \(hermesHome)exec \(hermesBinary) acp"
    }

    /// Shared SSH connect flow — used by ACPClient and
    /// `CitadelServerTransport.ConnectionHolder`. Single source of
    /// truth for the auth-method translation (SSHKeyBundle → Citadel
    /// `SSHAuthenticationMethod.ed25519`).
    nonisolated private static func openSSHClient(
        config: SSHConfig,
        key: SSHKeyBundle
    ) async throws -> SSHClient {
        let ck: Curve25519.Signing.PrivateKey
        do {
            ck = try SSHPrivateKeyDecoding.curve25519PrivateKey(fromPEM: key.privateKeyPEM)
        } catch {
            throw ACPChannelError.launchFailed(String(describing: error))
        }
        let username = config.user ?? "root"
        let host = config.host
        let port = config.port
        do {
            return try await SSHConnectPolicy.connect {
                // Fresh SSHAuthenticationMethod per attempt — Citadel's
                // auth delegate consumes its offer list on use, so a
                // reused instance would fail the retry with
                // `allAuthenticationOptionsFailed` instead of re-offering
                // the key.
                let auth: SSHAuthenticationMethod = .ed25519(username: username, privateKey: ck)
                var settings = SSHClientSettings(
                    host: host,
                    authenticationMethod: { auth },
                    hostKeyValidator: .acceptAnything()
                )
                if let port { settings.port = port }
                return try await SSHClient.connect(to: settings)
            }
        } catch {
            throw ACPChannelError.launchFailed(
                "SSH connect to \(config.host) failed: \(SSHConnectPolicy.describeConnectFailure(error, host: config.host))"
            )
        }
    }
}

#endif // canImport(Citadel)
