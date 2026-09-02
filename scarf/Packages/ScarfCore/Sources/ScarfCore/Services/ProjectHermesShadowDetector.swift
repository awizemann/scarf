import Foundation
#if canImport(os)
import os
#endif

/// Detects when a registered project directory contains its own `.hermes/`
/// subdirectory. Hermes' CLI uses the closest `.hermes/` as `$HERMES_HOME`
/// when invoked from inside such a directory, which **shadows** the user's
/// global Hermes home — credentials, config, sessions, skills, memories
/// all bind to the project-local copy without warning.
///
/// This causes confusing failure modes: the user runs `hermes auth add nous`
/// during setup expecting a global registration, but if their cwd happens to
/// be inside a project that already has a `.hermes/` (e.g. seeded by a
/// previous workflow, copied from another machine, or checked into git),
/// Hermes writes the credentials to the project-local `.hermes/auth.json`.
/// Scarf then reads the global path on every dashboard tick and shows
/// "missing provider" warnings even though the user did sign in successfully.
///
/// The detector enumerates the registered projects on a given server and
/// reports which ones carry a shadowing `.hermes/`. Views surface a yellow
/// banner so the user can consolidate.
public struct ProjectHermesShadowDetector: Sendable {
    public struct Shadow: Sendable, Hashable, Identifiable {
        public var id: String { projectPath }
        /// Project name from the registry (`ProjectEntry.name`).
        public let projectName: String
        /// Absolute path to the project on the target server.
        public let projectPath: String
        /// Absolute path to the shadowing `.hermes/` directory.
        public let shadowPath: String
        /// `true` when the shadow `.hermes/auth.json` exists. Strong signal
        /// that user credentials are landing in the wrong place.
        public let hasAuthJSON: Bool
        /// `true` when the shadow `.hermes/state.db` exists. Hermes wrote
        /// session state to the project-local home — the user's chat
        /// history is invisible to Scarf's global Dashboard for this slice.
        public let hasStateDB: Bool

        public init(
            projectName: String,
            projectPath: String,
            shadowPath: String,
            hasAuthJSON: Bool,
            hasStateDB: Bool
        ) {
            self.projectName = projectName
            self.projectPath = projectPath
            self.shadowPath = shadowPath
            self.hasAuthJSON = hasAuthJSON
            self.hasStateDB = hasStateDB
        }
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectHermesShadowDetector")
    #endif

    private let context: ServerContext
    private let transport: any ServerTransport

    public init(context: ServerContext) {
        self.context = context
        self.transport = context.makeTransport()
    }

    /// Probe every project in `projects` for a shadowing `.hermes/`. Skips
    /// archived projects and projects whose absolute path equals the
    /// resolved Hermes home (rare but possible — a project literally
    /// rooted at `~/.hermes` shouldn't trigger a self-warning).
    public func detect(in projects: [ProjectEntry]) async -> [Shadow] {
        let hermesHome = await context.resolvedUserHome() + "/.hermes"
        var found: [Shadow] = []
        for project in projects where !project.archived {
            // A project nested inside the Hermes home itself is a weird
            // edge case (someone made `~/.hermes/notes` a Scarf project).
            // The project is BELOW the Hermes home, so its `.hermes` is
            // the same dir as `~/.hermes/.hermes` — almost certainly not
            // present and definitely not a shadow.
            if project.path.hasPrefix(hermesHome) { continue }
            let shadowPath = project.path + "/.hermes"
            guard transport.fileExists(shadowPath) else { continue }
            // It's only a shadow if the path is a directory; a stray
            // `.hermes` file would be filtered out here.
            guard transport.stat(shadowPath)?.isDirectory == true else { continue }
            let hasAuth = transport.fileExists(shadowPath + "/auth.json")
            let hasDB   = transport.fileExists(shadowPath + "/state.db")
            #if canImport(os)
            Self.logger.warning(
                "Detected shadow Hermes home at \(shadowPath, privacy: .public) (auth: \(hasAuth), state.db: \(hasDB))"
            )
            #endif
            found.append(Shadow(
                projectName: project.name,
                projectPath: project.path,
                shadowPath: shadowPath,
                hasAuthJSON: hasAuth,
                hasStateDB: hasDB
            ))
        }
        return found
    }

    /// Suggested shell one-liner that consolidates a project shadow into
    /// the global Hermes home AND clears the warning on the next
    /// refresh. Two ordered steps:
    ///
    /// 1. Copy `auth.json` into the global home (only when present)
    ///    **without clobbering an existing one** (`cp -n`). Hermes
    ///    credentials live in this single file; preserving them is the
    ///    load-bearing part of "consolidate" — every other project-local
    ///    file is either replaceable or scoped to the project anyway.
    ///
    ///    **Why `-n` and not a plain `cp`.** A plain `cp` overwrites
    ///    `~/.hermes/auth.json` — the user's PRIMARY, possibly
    ///    differently-scoped credential — with a project-local one, from a
    ///    button labelled "copy fix command". That is a destructive,
    ///    unrecoverable side effect nobody asked for and the UI copy never
    ///    promised. With `-n` the command is purely additive: it fills an
    ///    empty global home, and otherwise leaves it alone. The project's
    ///    own `auth.json` is never lost either way — step 2 renames the
    ///    shadow aside rather than deleting it, so it stays readable in
    ///    `.hermes.scarf-bak.<stamp>/` if the user decides they wanted it.
    ///    The `.help` copy on the Dashboard button states this same "only
    ///    if you don't already have one" contract.
    /// 2. Rename the project-local `.hermes/` to
    ///    `.hermes.scarf-bak.<UTC-stamp>/`. Hermes' CLI stops seeing it
    ///    as `$HERMES_HOME` (it scans for a dir literally named
    ///    `.hermes`), so the global home wins from now on. The
    ///    user's project-local data — `state.db`, `sessions/`,
    ///    `skills/` — survives untouched in the renamed folder, so
    ///    they can inspect/recover/delete it later without us making
    ///    that decision for them.
    ///
    /// **Why not delete instead of rename.** A project's shadow can
    /// hold uncommitted session history the user hasn't audited yet.
    /// `rm -rf` would be unrecoverable; the rename keeps everything
    /// addressable while still removing the shadow effect. The user
    /// can delete the `.bak` once they're confident.
    ///
    /// Returns a single shell line, suitable for the user to paste
    /// into a remote terminal. The rename uses `date -u +%Y%m%d-%H%M%S`
    /// for a deterministic UTC suffix so two consecutive consolidations
    /// don't collide on the same second.
    public static func consolidationCommand(for shadow: Shadow, hermesHome: String) -> String? {
        var parts: [String] = []
        if shadow.hasAuthJSON {
            parts.append("mkdir -p \(shellQuote(hermesHome))")
            // `-n`: never overwrite an existing global auth.json. See the
            // doc comment — clobbering the user's primary credential from a
            // "copy fix command" button is not a fix.
            parts.append("cp -n \(shellQuote(shadow.shadowPath + "/auth.json")) \(shellQuote(hermesHome + "/auth.json"))")
            parts.append("chmod 600 \(shellQuote(hermesHome + "/auth.json"))")
        }
        // The rename is unconditional: even shadows without auth.json
        // still bind as $HERMES_HOME and need to move out of the way.
        // `$(date -u +%Y%m%d-%H%M%S)` runs on the remote shell when
        // the user pastes the command, producing the timestamp at
        // exec time rather than at command-construction time.
        parts.append("mv \(shellQuote(shadow.shadowPath)) \(shellQuote(shadow.shadowPath))\".scarf-bak.$(date -u +%Y%m%d-%H%M%S)\"")
        return parts.joined(separator: " && ")
    }

    /// Single-quote a path for embedding in a `bash -c '…'` string.
    /// POSIX-safe single quotes with escape for embedded quotes
    /// (`'` → `'\\''`). Matches the convention in
    /// `RemoteBackupService.shellQuote`.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
