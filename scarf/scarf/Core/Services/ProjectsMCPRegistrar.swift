import Foundation
import ScarfCore
import os

/// Registers the bundled `scarf-projects` MCP server into the LOCAL
/// Hermes config at every launch.
///
/// Unconditional and untoggled by decision: the server is how agents are
/// meant to touch projects, and a setting that turns it off is a setting
/// that leaves an agent hand-appending rows to `projects.json` — the exact
/// failure the projects-first-class work exists to end.
///
/// **Idempotent.** A launch where the entry already points at this
/// binary writes nothing at all, which matters because Hermes watches its
/// own config and this runs on every single launch.
///
/// **Re-points on relocation.** The `command` is an absolute path into
/// the app bundle, so moving Scarf.app (Downloads → Applications, or a
/// Sparkle update landing elsewhere) would otherwise leave Hermes
/// spawning a binary that no longer exists. The path is re-asserted each
/// launch, in place, so the user's own edits to the entry — tool filters,
/// timeouts, env — survive; remove-and-re-add would discard them.
///
/// **Local only.** An MCP server runs where the agent runs, and the
/// bundled binary is a Mach-O for this Mac. SSH contexts are skipped
/// entirely; remote hosts keep the skill-driven fallback.
struct ProjectsMCPRegistrar: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectsMCPRegistrar")

    /// The config key, and the name agents see. Stable forever: renaming
    /// it strands the old entry in every user's config.
    static let serverName = "scarf-projects"

    /// Where the executable lands in the bundle — see the app target's
    /// "Embed scarf-projects-mcp" copy-files phase.
    static let helperName = "scarf-projects-mcp"

    let context: ServerContext
    /// Injectable for tests; production resolves the running bundle.
    let binaryURL: URL?

    init(context: ServerContext = .local, binaryURL: URL? = nil) {
        self.context = context
        self.binaryURL = binaryURL
    }

    /// The bundled helper, or `nil` when it isn't there — a developer
    /// build that predates the copy phase, or a stripped bundle. Absence
    /// is a no-op, never an error dialog: Scarf works fine without it.
    static func bundledBinaryURL(bundle: Bundle = .main) -> URL? {
        let candidates = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(helperName)"),
            bundle.bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Why this copy of Scarf must NOT claim the user's config, or `nil`
    /// when it may.
    ///
    /// The registration re-points `command` at whatever bundle is running,
    /// which is right for the installed app and wrong for every other copy
    /// on this Mac. `scripts/build-detached.sh` installs a dev copy at
    /// `/Applications/scarf-dev.app` and agents run test copies out of
    /// `/tmp` and DerivedData: without this guard, every launch of any of
    /// them rewrites `~/.hermes/config.yaml` — churn on a file Hermes
    /// watches — and the `/tmp` and DerivedData ones point the user's
    /// agents at a binary the next clean build deletes.
    static func transientBundleReason(_ path: String) -> String? {
        let transientRoots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        if transientRoots.contains(where: { path.hasPrefix($0) }) {
            return "running from a temporary build location — leaving the Hermes config alone"
        }
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") {
            return "running from a build directory — leaving the Hermes config alone"
        }
        // The dev copy is a stable path, so it WORKS — but registering it
        // makes the dev and release copies fight over the entry on every
        // launch. The installed app wins by default.
        if path.contains("-dev.app/") {
            return "running the dev copy — leaving the Hermes config to the installed app"
        }
        return nil
    }

    enum Outcome: Equatable {
        /// No bundled binary (or a remote context) — nothing attempted.
        case skipped(String)
        /// The entry was created via `hermes mcp add`.
        case added(path: String)
        /// The entry existed with a stale `command`; re-pointed in place.
        case repointed(from: String, to: String)
        /// Already correct. The common case, and it writes nothing.
        case unchanged(path: String)
        case failed(String)
    }

    /// Blocking transport + subprocess work. Callers run it off-main
    /// (charter C10) — `scarfApp` does, on a detached utility task.
    @discardableResult
    nonisolated func ensureRegistered() -> Outcome {
        guard !context.isRemote else {
            return .skipped("remote context — the bundled binary only runs on this Mac")
        }
        // An injected path that isn't executable is treated exactly like a
        // missing one: registering a command Hermes cannot spawn would
        // turn a no-op into a broken entry the user has to find and
        // delete.
        guard let binary = binaryURL ?? Self.bundledBinaryURL(),
              FileManager.default.isExecutableFile(atPath: binary.path)
        else {
            return .skipped("no bundled \(Self.helperName) in this build")
        }
        let path = binary.path

        if binaryURL == nil, let reason = Self.transientBundleReason(path) {
            return .skipped(reason)
        }

        let fileService = HermesFileService(context: context)
        let existing = fileService.loadMCPServers().first { $0.name == Self.serverName }

        guard let existing else {
            // Creation goes through `hermes mcp add`, the argv Scarf
            // already ships and has verified against Hermes's argparse
            // (`hermes mcp add <name> --command <cmd>`, v0.21.0) — not a
            // second hand-written YAML entry writer.
            let result = fileService.addMCPServerStdio(
                name: Self.serverName,
                command: path,
                args: []
            )
            guard result.exitCode == 0 else {
                Self.logger.warning(
                    "hermes mcp add \(Self.serverName, privacy: .public) failed: \(result.output, privacy: .public)"
                )
                return .failed(result.output)
            }
            Self.logger.info("registered \(Self.serverName, privacy: .public) at \(path, privacy: .public)")
            return .added(path: path)
        }

        guard let currentCommand = existing.command else {
            // The entry exists but isn't a stdio server — a user's own
            // URL-based server squatting the name. Leave it alone: it is
            // theirs, and overwriting it would break whatever it serves.
            return .skipped(
                "an MCP server named \(Self.serverName) already exists and is not a stdio server"
            )
        }
        guard currentCommand != path else { return .unchanged(path: path) }

        guard fileService.setMCPServerCommand(name: Self.serverName, command: path) else {
            return .failed("could not re-point \(Self.serverName) to \(path)")
        }
        // `patchMCPServerField` reports success even when the write itself
        // failed (it logs and swallows), so confirm by reading back — a
        // re-point that silently didn't happen leaves Hermes spawning a
        // binary that isn't there, and this is the ONE launch pass that
        // would have caught it.
        let written = fileService.loadMCPServers().first { $0.name == Self.serverName }?.command
        guard written == path else {
            return .failed(
                "re-point of \(Self.serverName) did not stick (config still says "
                    + "\(written ?? "nothing"))"
            )
        }
        Self.logger.info(
            "re-pointed \(Self.serverName, privacy: .public): \(currentCommand, privacy: .public) → \(path, privacy: .public)"
        )
        return .repointed(from: currentCommand, to: path)
    }
}
