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
public struct HermesPathSet: Sendable, Hashable {
    public let home: String
    /// `true` when this path set belongs to a remote installation. Affects
    /// only `hermesBinary` resolution — every other path is identical in
    /// shape between local and remote.
    public let isRemote: Bool
    /// Pre-resolved remote binary path (e.g. `/home/deploy/.local/bin/hermes`).
    /// Populated by `SSHTransport` once `command -v hermes` has run on the
    /// target host. Unused when `isRemote == false`.
    public let binaryHint: String?

    // MARK: - Defaults

    /// Absolute path to the local user's `~/.hermes` directory.

    public init(
        home: String,
        isRemote: Bool,
        binaryHint: String?
    ) {
        self.home = home
        self.isRemote = isRemote
        self.binaryHint = binaryHint
    }
    /// Resolved path to the active local Hermes profile (issue #50).
    ///
    /// Hermes v0.11+ supports multiple profiles via `hermes profile use`;
    /// each profile is a fully independent `HERMES_HOME` directory. We
    /// delegate to `HermesProfileResolver` (which reads
    /// `~/.hermes/active_profile`) so every derived path — `state.db`,
    /// `sessions/`, `config.yaml`, `memories/`, etc. — automatically
    /// follows the active profile. Returns the pre-profile default
    /// `~/.hermes` whenever no named profile is active, so existing
    /// (non-profile) installations are unaffected.
    ///
    /// Backed by a 5-second cache inside the resolver, so frequent
    /// `HermesPathSet` constructions don't hammer the filesystem.
    public nonisolated static var defaultLocalHome: String {
        HermesProfileResolver.resolveLocalHome()
    }

    /// Default remote home when the user doesn't override it in `SSHConfig`.
    /// We leave `~` unexpanded on purpose — the remote shell resolves it.
    public nonisolated static let defaultRemoteHome: String = "~/.hermes"

    // MARK: - Paths (mirror of the old HermesPaths layout)

    public nonisolated var stateDB: String { home + "/state.db" }
    public nonisolated var configYAML: String { home + "/config.yaml" }
    public nonisolated var envFile: String { home + "/.env" }
    public nonisolated var authJSON: String { home + "/auth.json" }
    public nonisolated var soulMD: String { home + "/SOUL.md" }
    public nonisolated var pluginsDir: String { home + "/plugins" }
    public nonisolated var memoriesDir: String { home + "/memories" }
    public nonisolated var memoryMD: String { memoriesDir + "/MEMORY.md" }
    public nonisolated var userMD: String { memoriesDir + "/USER.md" }
    public nonisolated var sessionsDir: String { home + "/sessions" }
    public nonisolated var cronJobsJSON: String { home + "/cron/jobs.json" }
    public nonisolated var cronOutputDir: String { home + "/cron/output" }
    public nonisolated var gatewayStateJSON: String { home + "/gateway_state.json" }
    public nonisolated var skillsDir: String { home + "/skills" }
    public nonisolated var errorsLog: String { home + "/logs/errors.log" }
    public nonisolated var agentLog: String { home + "/logs/agent.log" }
    public nonisolated var gatewayLog: String { home + "/logs/gateway.log" }
    public nonisolated var scarfDir: String { home + "/scarf" }
    public nonisolated var projectsRegistry: String { scarfDir + "/projects.json" }

    /// Maps Hermes session IDs to the Scarf project path a chat was
    /// started for. Scarf-owned; Hermes never touches this file.
    public nonisolated var sessionProjectMap: String { scarfDir + "/session_project_map.json" }
    public nonisolated var mcpTokensDir: String { home + "/mcp-tokens" }

    // MARK: - Binary resolution

    /// Install locations we probe for the local `hermes` binary, in priority
    /// order. Checked on every access so a user installing via a different
    /// method doesn't need to relaunch Scarf.
    public nonisolated static let hermesBinaryCandidates: [String] = {
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
    public nonisolated var hermesBinary: String {
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
