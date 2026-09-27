import Foundation

/// Top-level manifest for a `.scarfbackup` archive.
///
/// **Archive layout** (`.scarfbackup` is a plain ZIP):
/// ```
/// <name>.scarfbackup
/// ├── manifest.json           — this struct, JSON-encoded
/// ├── hermes.tar.gz            — gzipped tar of `~/.hermes/` (minus exclusions)
/// ├── hermes-databases.tar.gz  — (v2) consistent snapshots of every `*.db`
/// └── projects/
///     ├── <project-id>.tar.gz — one inner tarball per registered project
///     └── ...
/// ```
///
/// **Why two layers (outer ZIP + inner tarballs).** The inner tarballs are
/// produced by streaming `tar -czf - …` over SSH — that's the only way to
/// keep memory bounded for multi-GB hermes homes. The outer ZIP exists so
/// the manifest sits at a fixed, easy-to-inspect location and so users on
/// macOS can double-click in Finder and see the structure. ZIP also has a
/// central directory at the end, which makes "validate without extracting"
/// cheap.
///
/// **What rides along.** Hermes home (state.db + sessions + skills + cron +
/// memories + scarf sidecars + plugins/profiles), each project's full file
/// tree (the user's code), and the manifest itself. **What does NOT ride
/// along by default**: `auth.json` (provider credentials), `mcp-tokens/`
/// (per-host OAuth bearer tokens), `logs/` (size, low restore value),
/// any SQLite `-wal` / `-shm` / `-journal` (in-flight sidecars). From v2 no
/// live `*.db` file is in `hermes.tar.gz` either (state.db, every profile's
/// state.db, kanban.db, response_store.db, cron/executions.db, …): each is
/// captured as a consistent snapshot into its own tarball (`databases`),
/// the way `hermes backup` snapshots every `*.db`
/// (`hermes_cli/backup.py:101-104`, `:590-610` @ v2026.9.24), because
/// copying a live WAL database file is how you get a torn or incomplete
/// copy, and checkpointing it first would be a write to state.db (charter
/// C3). The `options` block records exactly which
/// exclusions were applied so the restore flow can warn the user.
public struct BackupManifest: Codable, Sendable, Equatable {
    /// Bumped when the on-disk shape changes incompatibly. Restores refuse
    /// anything they don't recognize.
    ///
    /// - v1: `state.db` (copied live) inside `hermes.tar.gz`, always
    ///   under a `.hermes/` top-level directory.
    /// - v2: every `*.db` comes from the `databases` snapshot tarball and
    ///   none is in `hermes.tar.gz`; the tarball's top-level directory is
    ///   the source home's own name. A v1-only Scarf would restore a v2
    ///   archive without its sessions and report success, which is why
    ///   this is a version bump and not an optional field.
    public var schemaVersion: Int
    /// Magic string. Lets a future Scarf reject `.zip` files that aren't
    /// our backups before unpacking them as if they were.
    public var kind: String
    /// ISO-8601 UTC timestamp the archive was produced.
    public var createdAt: String
    /// Identifies the server the backup came from. The display name is for
    /// the restore preview sheet; serverID is for de-dupe and lineage.
    public var source: Source
    /// Hermes home tree metadata. Always present (even an empty Hermes
    /// install ships an empty tarball — the restore replaces nothing
    /// rather than refusing).
    public var hermes: HermesTree
    /// One entry per registered project at backup time. Empty array
    /// when the user never registered any projects.
    public var projects: [ProjectEntry]
    /// What was included / excluded from the Hermes tree. Flagged so the
    /// restore preview honestly reports "auth.json was not in this
    /// backup — you'll re-authenticate after restore".
    public var options: Options
    /// The database snapshots (v2). `nil` in v1 archives, and in v2
    /// archives from a home with no `*.db` file at all.
    public var databases: DatabaseSnapshots?

    public init(
        schemaVersion: Int = BackupManifest.currentSchemaVersion,
        kind: String = BackupManifest.kindMagic,
        createdAt: String,
        source: Source,
        hermes: HermesTree,
        projects: [ProjectEntry],
        options: Options,
        databases: DatabaseSnapshots? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.createdAt = createdAt
        self.source = source
        self.hermes = hermes
        self.projects = projects
        self.options = options
        self.databases = databases
    }

    public static let currentSchemaVersion = 2
    /// Every schema this Scarf can restore.
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...2

    /// A gzipped tar of consistent database snapshots, one member per
    /// database at its path relative to the Hermes home (`state.db`,
    /// `profiles/work/state.db`, `kanban.db`, …), each taken on the source
    /// host by a connection that could not write the original.
    public struct DatabaseSnapshots: Codable, Sendable, Equatable {
        /// Path inside the outer ZIP (always `hermes-databases.tar.gz`).
        public var tarballPath: String
        public var tarballSize: Int64
        public var tarballSHA256: String
        /// Every database in the tarball, and how it was captured.
        public var entries: [Entry]
        /// `*.db` files the host had but no method could snapshot (not
        /// SQLite, unreadable, locked past the busy timeout). Not in the
        /// archive; the backup says so rather than shipping a live copy.
        public var skipped: [String]

        public struct Entry: Codable, Sendable, Equatable {
            /// Relative to the Hermes home, e.g. `profiles/work/state.db`.
            public var path: String
            /// Which host tool produced the snapshot.
            public var method: String

            public init(path: String, method: String) {
                self.path = path
                self.method = method
            }
        }

        public init(tarballPath: String, tarballSize: Int64, tarballSHA256: String, entries: [Entry], skipped: [String]) {
            self.tarballPath = tarballPath
            self.tarballSize = tarballSize
            self.tarballSHA256 = tarballSHA256
            self.entries = entries
            self.skipped = skipped
        }
    }
    public static let kindMagic = "scarf-server-backup"

    public struct Source: Codable, Sendable, Equatable {
        public var serverID: String
        public var displayName: String
        public var host: String
        public var user: String?
        /// Output of `hermes --version` on the source host at backup
        /// time. Restore warns if the target installs an older version
        /// (state.db schema differences could break things silently).
        public var hermesVersion: String?

        public init(serverID: String, displayName: String, host: String, user: String?, hermesVersion: String?) {
            self.serverID = serverID
            self.displayName = displayName
            self.host = host
            self.user = user
            self.hermesVersion = hermesVersion
        }
    }

    public struct HermesTree: Codable, Sendable, Equatable {
        /// Absolute path of `~/.hermes/` on the source host (e.g.
        /// `/root/.hermes` or `/home/alan/.hermes`). Used by restore to
        /// detect path drift when targeting a different user account.
        public var homePath: String
        /// Path inside the outer ZIP (always `hermes.tar.gz`).
        public var tarballPath: String
        /// Compressed bytes — for the preview sheet's size summary.
        public var tarballSize: Int64
        /// Hex SHA-256 of the inner tarball. Restore verifies before
        /// extracting; corruption surfaces as a single bad path
        /// rather than a half-extracted home.
        public var tarballSHA256: String
        /// The tarball's top-level member: ``dotMemberRoot`` (`./…`,
        /// archived from inside the home) from R19 on; absent in older
        /// archives, whose members are `<home's own directory name>/…`.
        /// Restore re-roots an older tarball before extracting it, so its
        /// root-only excludes can be anchored.
        public var memberRoot: String?

        public static let dotMemberRoot = "."

        public init(
            homePath: String, tarballPath: String, tarballSize: Int64, tarballSHA256: String,
            memberRoot: String? = nil
        ) {
            self.homePath = homePath
            self.tarballPath = tarballPath
            self.tarballSize = tarballSize
            self.tarballSHA256 = tarballSHA256
            self.memberRoot = memberRoot
        }
    }

    public struct ProjectEntry: Codable, Sendable, Equatable {
        /// Stable UUID for the project. Used to namespace the inner
        /// tarball so a project with `name = "scratch"` in two
        /// different directories doesn't collide.
        public var id: String
        public var name: String
        /// Absolute path on the source host. Restore re-anchors this if
        /// the target has a different home (e.g. backup from `/root`,
        /// restore to `/home/ubuntu`).
        public var path: String
        /// Path inside the outer ZIP (e.g. `projects/<id>.tar.gz`).
        public var tarballPath: String
        public var tarballSize: Int64
        public var tarballSHA256: String

        public init(id: String, name: String, path: String, tarballPath: String, tarballSize: Int64, tarballSHA256: String) {
            self.id = id
            self.name = name
            self.path = path
            self.tarballPath = tarballPath
            self.tarballSize = tarballSize
            self.tarballSHA256 = tarballSHA256
        }
    }

    public struct Options: Codable, Sendable, Equatable {
        public var includeAuth: Bool
        public var includeMcpTokens: Bool
        public var includeLogs: Bool
        /// Legacy v1 flag. v1 Scarf set it to true whenever it had run
        /// `PRAGMA wal_checkpoint(TRUNCATE)` on the live database, even
        /// when that checkpoint was partial, so a v1 `true` proves
        /// nothing. Scarf no longer writes state.db (charter C3) and
        /// always records `false`; ``BackupManifest/databases`` says how
        /// state.db was actually captured.
        public var checkpointedWAL: Bool

        public init(includeAuth: Bool, includeMcpTokens: Bool, includeLogs: Bool, checkpointedWAL: Bool) {
            self.includeAuth = includeAuth
            self.includeMcpTokens = includeMcpTokens
            self.includeLogs = includeLogs
            self.checkpointedWAL = checkpointedWAL
        }

        public static let safeDefault = Options(
            includeAuth: false,
            includeMcpTokens: false,
            includeLogs: false,
            checkpointedWAL: false
        )
    }
}

/// Canonical layout strings — referenced by both the producer and the
/// consumer so the on-disk paths stay in sync.
public enum BackupArchiveLayout {
    public static let manifestPath = "manifest.json"
    public static let hermesTarballPath = "hermes.tar.gz"
    public static let databasesTarballPath = "hermes-databases.tar.gz"
    public static let projectsTarballPrefix = "projects/"
    public static let archiveExtension = "scarfbackup"

    /// Returns `projects/<id>.tar.gz`. The id is the `ProjectEntry.id`
    /// (stable UUID), not the project name — names are renamed all the
    /// time and would collide.
    public static func projectTarballPath(for id: String) -> String {
        projectsTarballPrefix + id + ".tar.gz"
    }
}
