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
    /// `projectCwd` (when set) becomes the spawned `hermes acp` process's
    /// working directory, so Hermes loads that project's AGENTS.md context
    /// files (it reads them from the process cwd, not the ACP session cwd).
    /// `profile` (when set) pins the agent to that Hermes profile — the
    /// Bot Mode path, where the ACP process must run as the *bot*, not as
    /// the user's active profile. See `acpArguments(profile:)`.
    public static func forMacApp(
        context: ServerContext = .local,
        projectCwd: String? = nil,
        profile: String? = nil
    ) -> ACPClient {
        ACPClient(context: context) { ctx in
            try await makeProcessChannel(for: ctx, projectCwd: projectCwd, profile: profile)
        }
    }

    /// Compose the `hermes` argv for an ACP session, optionally pinned to a
    /// profile. Pure and `internal` so the composition is unit-tested
    /// without spawning anything.
    ///
    /// **`-p` composes with `acp`, verified at tag v2026.8.31.**
    /// `hermes_cli/main._apply_profile_override` (:519-600) runs *before*
    /// argparse and before any hermes module import: it scans the whole of
    /// `sys.argv` for `-p` / `--profile` / `--profile=`, sets `HERMES_HOME`
    /// to that profile's directory, and STRIPS the flag so argparse never
    /// sees it. It is therefore a genuine global that works with every
    /// subcommand, `acp` included — and the scan is deliberately broad
    /// ("Historically this worked even after the subcommand", :571-572), so
    /// neither `hermes -p x acp` nor `hermes acp -p x` is fragile. The flag
    /// goes FIRST here anyway, matching the form Hermes' own Bot Mode
    /// transport uses (`tools/bot_mode_dm.py:32` — `hermes -p <name> chat
    /// …`), so the argv Scarf writes is the argv Hermes documents.
    ///
    /// Two guards ride on `HermesProfileScope.normalize`:
    /// - the name is re-validated against Hermes' own
    ///   `^[a-z0-9][a-z0-9_-]{0,63}$`, so a malformed value never reaches
    ///   the command line. Hermes rejects such values too (main.py:606-615,
    ///   dropping the flag and falling back to `active_profile`) — which is
    ///   exactly the silent wrong-profile outcome to avoid: better to launch
    ///   unpinned by our own decision than to think we pinned and not have.
    /// - `"default"` normalizes to `nil` and emits no flag at all, because
    ///   the default profile IS the root home and `-p default` is a no-op
    ///   Hermes special-cases anyway.
    nonisolated static func acpArguments(profile: String?) -> [String] {
        guard let name = HermesProfileScope.normalize(profile) else { return ["acp"] }
        return ["-p", name, "acp"]
    }

    /// Build the channel — spawn `hermes acp` (local) or `ssh host --
    /// hermes acp` (remote via `SSHTransport.makeProcess`) and hand the
    /// configured Process to `ProcessACPChannel`. Env merges the full
    /// shell-enriched environment (so PATH includes brew/nvm/asdf and
    /// credentials exported from `.zprofile` / `.zshrc` are visible)
    /// minus `TERM` (ACP speaks raw JSON over stdio, any terminal
    /// escape sequence would corrupt it).
    nonisolated private static func makeProcessChannel(
        for context: ServerContext,
        projectCwd: String? = nil,
        profile: String? = nil
    ) async throws -> any ACPChannel {
        let transport = context.makeTransport()
        // Remote takes the SAME argv: `SSHTransport.makeProcess` composes
        // `ssh -T host -- <executable> <args…>`, so the profile flag rides
        // the transport untouched and a bot on an SSH host is pinned
        // exactly like a local one.
        let proc = transport.makeProcess(
            executable: context.paths.hermesBinary,
            args: acpArguments(profile: profile),
            cwd: projectCwd
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
