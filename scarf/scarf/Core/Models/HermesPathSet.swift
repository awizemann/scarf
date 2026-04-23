import Foundation

/// The filesystem layout of a Hermes installation, parameterized by the
/// `home` directory. The same layout is used for local installations (where
/// `home` is an absolute macOS path like `/Users/alan/.hermes`) and for
/// remote installations reached over SSH (where `home` is a remote path like
/// `/home/deploy/.hermes` or an unexpanded `~/.hermes` that the remote shell
/// will resolve).
///
/// Every path that used to live as a module-level static on `HermesPaths` is
/// an instance property here. `ServerContext.paths` is the canonical way to
/// reach these values; the old `HermesPaths` statics are preserved as
/// deprecated forwarders so Phase 1 can migrate call sites incrementally.
struct HermesPathSet: Sendable, Hashable {
    let home: String
    /// `true` when this path set belongs to a remote installation. Affects
    /// only `hermesBinary` resolution — every other path is identical in
    /// shape between local and remote.
    let isRemote: Bool
    /// Pre-resolved remote binary path (e.g. `/home/deploy/.local/bin/hermes`).
    /// Populated by `SSHTransport` once `command -v hermes` has run on the
    /// target host. Unused when `isRemote == false`.
    let binaryHint: String?

    // MARK: - Defaults

    /// Absolute path to the local user's `~/.hermes` directory.
    nonisolated static let defaultLocalHome: String = {
        let user = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return user + "/.hermes"
    }()

    /// Default remote home when the user doesn't override it in `SSHConfig`.
    /// We leave `~` unexpanded on purpose — the remote shell resolves it.
    nonisolated static let defaultRemoteHome: String = "~/.hermes"

    // MARK: - Paths (mirror of the old HermesPaths layout)

    nonisolated var stateDB: String { home + "/state.db" }
    nonisolated var configYAML: String { home + "/config.yaml" }
    nonisolated var envFile: String { home + "/.env" }
    nonisolated var authJSON: String { home + "/auth.json" }
    nonisolated var soulMD: String { home + "/SOUL.md" }
    nonisolated var pluginsDir: String { home + "/plugins" }
    nonisolated var memoriesDir: String { home + "/memories" }
    nonisolated var memoryMD: String { memoriesDir + "/MEMORY.md" }
    nonisolated var userMD: String { memoriesDir + "/USER.md" }
    nonisolated var sessionsDir: String { home + "/sessions" }
    nonisolated var cronJobsJSON: String { home + "/cron/jobs.json" }
    nonisolated var cronOutputDir: String { home + "/cron/output" }
    nonisolated var gatewayStateJSON: String { home + "/gateway_state.json" }
    nonisolated var skillsDir: String { home + "/skills" }
    nonisolated var errorsLog: String { home + "/logs/errors.log" }
    nonisolated var agentLog: String { home + "/logs/agent.log" }
    nonisolated var gatewayLog: String { home + "/logs/gateway.log" }
    nonisolated var scarfDir: String { home + "/scarf" }
    nonisolated var projectsRegistry: String { scarfDir + "/projects.json" }

    /// Maps Hermes session IDs to the Scarf project path a chat was
    /// started for. Written by `SessionAttributionService` when
    /// Scarf spawns `hermes acp` with a project-scoped cwd; read by
    /// the per-project Sessions tab (v2.3) to filter the session list
    /// to just those attributed to a given project.
    ///
    /// Scarf-owned — Hermes never touches this file. Forward-only:
    /// we only attribute sessions Scarf creates in a project context;
    /// older / CLI-started sessions stay unattributed and surface in
    /// the global Sessions sidebar unchanged.
    nonisolated var sessionProjectMap: String { scarfDir + "/session_project_map.json" }
    nonisolated var mcpTokensDir: String { home + "/mcp-tokens" }

    // MARK: - Binary resolution

    /// Install locations we probe for the local `hermes` binary, in priority
    /// order. Checked on every access so a user installing via a different
    /// method doesn't need to relaunch Scarf.
    nonisolated static let hermesBinaryCandidates: [String] = {
        let user = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return [
            user + "/.local/bin/hermes",   // pipx / pip --user (default)
            "/opt/homebrew/bin/hermes",    // Homebrew on Apple Silicon
            "/usr/local/bin/hermes",       // Homebrew on Intel / manual install
            user + "/.hermes/bin/hermes"   // Some self-install layouts
        ]
    }()

    /// Resolved path to the `hermes` executable for this installation.
    ///
    /// Local: returns the first executable candidate, falling back to the
    /// pipx default so error messages still make sense on a fresh machine.
    ///
    /// Remote: returns `binaryHint` (populated at connect time) or bare
    /// `"hermes"` as a last-resort default that relies on the remote `$PATH`.
    nonisolated var hermesBinary: String {
        if isRemote {
            return binaryHint ?? "hermes"
        }
        for path in Self.hermesBinaryCandidates
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return Self.hermesBinaryCandidates[0]
    }
}
