import Foundation
import ScarfCore

/// Mac-target glue that wires `ACPClient` (now in `ScarfCore`) with a
/// `ProcessACPChannel` factory. The channel spawns `hermes acp`
/// locally, or `ssh -T host -- hermes acp` remotely via
/// `SSHTransport.makeProcess`, carrying the enriched shell env so
/// Hermes can find Homebrew / nvm / asdf binaries and credentials.
///
/// iOS will ship a sibling `ACPClient+iOS.swift` in M4+ that wires a
/// `SSHExecACPChannel` (Citadel) factory instead.
extension ACPClient {
    /// Convenience: build an `ACPClient` for `context` pre-wired with a
    /// `ProcessACPChannel` factory. Use this at every call site that
    /// used to do `ACPClient(context:)` before M1.
    public static func forMacApp(context: ServerContext = .local) -> ACPClient {
        ACPClient(context: context) { ctx in
            try await makeProcessChannel(for: ctx)
        }
    }

    /// Build the channel — spawn `hermes acp` (local) or `ssh host --
    /// hermes acp` (remote via `SSHTransport.makeProcess`) and hand the
    /// configured Process to `ProcessACPChannel`. Env merges the full
    /// shell-enriched environment (so PATH includes brew/nvm/asdf and
    /// credentials exported from `.zprofile` / `.zshrc` are visible)
    /// minus `TERM` (ACP speaks raw JSON over stdio, any terminal
    /// escape sequence would corrupt it).
    nonisolated private static func makeProcessChannel(for context: ServerContext) async throws -> any ACPChannel {
        let transport = context.makeTransport()
        let proc = transport.makeProcess(
            executable: context.paths.hermesBinary,
            args: ["acp"]
        )

        if context.isRemote {
            // Remote: this is the LOCAL ssh process spawning
            // `ssh host … hermes acp`. We don't forward our local
            // PATH / credentials to the remote (hermes runs under the
            // remote user's login env), but the ssh binary itself needs
            // SSH_AUTH_SOCK to reach the local ssh-agent for auth.
            var env = ProcessInfo.processInfo.environment
            let shellEnv = HermesFileService.enrichedEnvironment()
            for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
                if env[key] == nil, let v = shellEnv[key], !v.isEmpty {
                    env[key] = v
                }
            }
            env.removeValue(forKey: "TERM")
            proc.environment = env
        } else {
            // Local: enriched env so any tools hermes spawns (MCP
            // servers, shell commands) can find brew/nvm/asdf binaries
            // on PATH.
            var env = HermesFileService.enrichedEnvironment()
            env.removeValue(forKey: "TERM")
            proc.environment = env
        }

        return try await ProcessACPChannel(process: proc)
    }
}
