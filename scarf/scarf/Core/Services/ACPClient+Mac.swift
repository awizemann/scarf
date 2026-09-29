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
    /// `environmentHint` (gh#142) delivers Scarf's `HERMES_ENVIRONMENT_HINT`
    /// composed with the user's own hint (env, else config), never replacing
    /// it — see `EnvironmentHintComposer`. Nil = today's spawn.
    public static func forMacApp(
        context: ServerContext = .local,
        projectCwd: String? = nil,
        profile: String? = nil,
        environmentHint: EnvironmentHintRequest? = nil
    ) -> ACPClient {
        forMacApp(
            context: context, projectCwd: projectCwd, profile: profile,
            environmentHintSlot: nil, environmentHint: environmentHint)
    }

    /// `forMacApp` whose hint is read from `environmentHintSlot` when the
    /// channel is opened (`start()`), not when the client is built. The
    /// chat builds its client before the project prep that decides the
    /// hint has run (#142 P3); the slot only answers for `projectCwd`.
    /// A nil slot, or one holding nothing for this cwd, falls back to
    /// `environmentHint` (nil = today's spawn).
    public static func forMacApp(
        context: ServerContext = .local,
        projectCwd: String? = nil,
        profile: String? = nil,
        environmentHintSlot: EnvironmentHintSlot?,
        environmentHint: EnvironmentHintRequest? = nil
    ) -> ACPClient {
        ACPClient(context: context) { ctx in
            let hint = environmentHintSlot?.request(forProjectCwd: projectCwd) ?? environmentHint
            return try await makeProcessChannel(
                for: ctx, projectCwd: projectCwd, profile: profile,
                environmentHint: hint)
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
    /// - `nil` (an ordinary chat, not a bot) emits no flag: the window's
    ///   own scope decides. Locally that is the host's `active_profile`,
    ///   which is also where the window reads its files; remotely
    ///   `SSHTransport` adds the pin (`HERMES_HOME=` for a named profile,
    ///   `-p default` for the root).
    /// - A bot name is re-validated against Hermes' own
    ///   `^[a-z0-9][a-z0-9_-]{0,63}$` (``HermesProfileScope/isValidName(_:)``)
    ///   so a malformed value never reaches the command line; it launches
    ///   unpinned by our own decision rather than pinned to the wrong
    ///   profile.
    /// - `"default"` IS pinned, as `-p default` (S13-F2). It is not a no-op:
    ///   without any `-p`, Hermes follows the sticky `active_profile`
    ///   (`hermes_cli/main.py:607-619` @ v2026.9.24), so the default bot's
    ///   ACP process would run in another profile than the root home its
    ///   Bot Chat lives in, and `session/load` would miss. `-p default`
    ///   resolves to the root (`hermes_cli/profiles.py:2366-2369`).
    nonisolated static func acpArguments(profile: String?) -> [String] {
        guard let raw = profile?.trimmingCharacters(in: .whitespacesAndNewlines),
              HermesProfileScope.isValidName(raw) else { return ["acp"] }
        return HermesProfileScope.profileFlag(raw) + ["acp"]
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
        profile: String? = nil,
        environmentHint: EnvironmentHintRequest? = nil
    ) async throws -> any ACPChannel {
        let transport = context.makeTransport()
        // Remote takes the SAME argv: `SSHTransport.makeProcess` composes
        // `ssh -T host -- <executable> <args…>`, so the profile flag rides
        // the transport untouched and a bot on an SSH host is pinned
        // exactly like a local one.
        let proc = transport.makeProcess(
            executable: context.paths.hermesBinary,
            args: acpArguments(profile: profile),
            cwd: projectCwd,
            environmentHint: environmentHint
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
            // The hint composes against THIS env (the user's shell
            // exports included), since it replaces what LocalTransport set.
            let env = localACPEnvironment(
                enriched: HermesFileService.enrichedEnvironment(),
                environmentHint: environmentHint)
            proc.environment = env
        }

        return try await ProcessACPChannel(process: proc)
    }

    /// The local `hermes acp` environment: the enriched shell env minus
    /// `TERM`, plus the composed hint when one is given. Pure so a nil hint
    /// is testably identical to the pre-gh#142 env.
    nonisolated static func localACPEnvironment(
        enriched: [String: String], environmentHint: EnvironmentHintRequest?
    ) -> [String: String] {
        var env = enriched
        env.removeValue(forKey: "TERM")
        return EnvironmentHintComposer.applying(
            scarfHint: environmentHint?.scarfHint,
            configHint: environmentHint?.configHint, to: env)
    }
}
