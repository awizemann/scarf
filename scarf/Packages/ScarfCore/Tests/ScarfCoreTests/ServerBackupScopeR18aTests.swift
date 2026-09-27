import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// R18a — Server Backup / Restore against a real Hermes home.
///
/// T7-F2: the home tarball carried everything `hermes backup` leaves out
/// (`hermes_cli/backup.py:46-118` @ v2026.9.24) — the Hermes codebase with
/// its venv, runtime downloads, dependency trees, prior backups, caches and
/// both browser profile stores — and Restore extracted it over the target.
/// T7-F1: GNU tar's exit 1 ("file changed as we read it") failed the backup
/// of any Linux host with a running gateway.
///
/// These run the real backup and the real extract command locally (bsdtar).
/// The same commands were run under GNU tar 1.35 (debian:stable-slim) and
/// BusyBox tar (alpine) in containers for this phase; see the R18a report.
@Suite(.serialized)
struct ServerBackupScopeR18aTests {

    typealias Helpers = ServerBackupRestoreSafetyTests

    static func write(_ home: URL, _ rel: String, _ text: String = "x") throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Paths `hermes backup` leaves out, with a file in each tree.
    static let excluded = [
        "hermes-agent/run_agent.py", "hermes-agent/venv/bin/python", "hermes-agent/.git/HEAD",
        "node/bin/node", "models/w.gguf", "runtimes/llama/server",
        "browser-profile/Default/Cookies", "browser-profiles/cdp/Login Data", "browser_profiles/bu/Cookies",
        "backups/hermes-backup.zip", "checkpoints/c.json",
        "cache/catalog.json", "cache/plugins/index.json",
        "gateway.pid", "cron.pid", ".backup.lock", "state.db.pre-update-emergency-20260901.bak",
        "skills/a/node_modules/m.js", "skills/a/__pycache__/x.cpython-311.pyc", "skills/a/tool.pyc",
        "skills/a/.venv/bin/python", "skills/a/.git/HEAD", "skills/a/.cache/x",
        "profiles/work/models/w.gguf", "profiles/work/node/bin/node", "profiles/work/cache/tmp.json",
        "profiles/work/browser-profile/Cookies", "profiles/work/.venv/lib/x",
    ]

    /// User data that must still ship — including same-named directories
    /// Hermes excludes only at a home's root.
    static let kept = [
        "config.yaml", "SOUL.md", "skills/a/SKILL.md",
        "skills/a/models/keep.bin", "skills/a/hermes-agent/keep.md", "skills/a/cache/keep.md",
        "cache/images/i.png", "cache/citations/ledger.json", "cache/documents/d.pdf",
        "profiles/work/config.yaml", "profiles/work/cache/images/i.png",
        "profiles/work/skills/s/models/keep.bin", "profiles/work/hermes-agent/keep.md",
    ]

    @Test("a backup leaves out what hermes backup leaves out, and keeps the user's data")
    func backupScopeMatchesHermes() async throws {
        let root = try Helpers.scratch("r18a-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        for rel in Self.excluded + Self.kept { try Self.write(home, rel) }
        // Databases: the live one, plus old copies inside excluded trees
        // that must not be snapshotted into the archive either.
        for rel in ["state.db", "profiles/work/state.db", "backups/state.db", "state-snapshots/s1/state.db",
                    "hermes-agent/tests/fixture.db"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            sqlite3_close(try Helpers.openWALWriter(home.appendingPathComponent(rel).path, rows: 3))
        }

        let backup = try await Helpers.backUp(home: home, into: root)
        let tarball = try Helpers.unzipped(backup.archiveURL, in: root)
            .appendingPathComponent(backup.manifest.hermes.tarballPath)
        let listing = Set(try Helpers.capture("/usr/bin/tar", ["-tzf", tarball.path])
            .split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) })

        for rel in Self.excluded {
            #expect(!listing.contains(".hermes/" + rel), "\(rel) shipped")
        }
        for top in ["hermes-agent", "node", "models", "runtimes", "browser-profile", "browser-profiles",
                    "browser_profiles", "backups", "state-snapshots", "checkpoints"] {
            #expect(!listing.contains { $0 == ".hermes/" + top || $0.hasPrefix(".hermes/" + top + "/") },
                    "\(top)/ shipped")
        }
        for rel in Self.kept {
            #expect(listing.contains(".hermes/" + rel), "\(rel) missing: \(listing.sorted())")
        }
        let dbs = try #require(backup.manifest.databases)
        #expect(Set(dbs.entries.map(\.path)) == ["state.db", "profiles/work/state.db"],
                "copies inside excluded trees are not snapshotted")
    }

    /// An archive made before R18a carries the trees; the extract command
    /// must not write them over the target (its installed Hermes, its
    /// runtimes, a browser credential store), and must not write the
    /// source's pid/state files either.
    @Test("restore does not extract an older archive's Hermes install, runtimes or browser profiles")
    func restoreSkipsOlderArchivesTrees() async throws {
        let root = try Helpers.scratch("r18a-extract")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/.hermes")
        for rel in Self.excluded + Self.kept + ["gateway_state.json", "processes.json", "state.db-wal",
                                                "profiles/work/state.db-wal", "skills/a/deep/x.db-journal"] {
            try Self.write(source, rel)
        }
        let tarball = root.appendingPathComponent("hermes.tar.gz")
        try Helpers.run("/usr/bin/tar", ["-czf", tarball.path, "-C", source.deletingLastPathComponent().path, ".hermes"])

        let target = root.appendingPathComponent("dst/hermes-home")
        // The target's own install must survive untouched.
        try Self.write(target, "hermes-agent/run_agent.py", "TARGET")
        let command = RemoteRestoreService.hermesExtractCommand(
            hermesHome: target.path, archiveLeaf: ".hermes", databases: ["state.db", "profiles/work/state.db"])
        let result = try await LocalTransport().asyncRunProcess(
            executable: "/bin/bash", args: ["-c", command],
            stdin: try Data(contentsOf: tarball), timeout: 60)
        #expect(result.exitCode == 0, "\(result.stderrString)")

        func exists(_ rel: String) -> Bool {
            FileManager.default.fileExists(atPath: target.appendingPathComponent(rel).path)
        }
        #expect(try String(contentsOf: target.appendingPathComponent("hermes-agent/run_agent.py"), encoding: .utf8) == "TARGET")
        for rel in Self.excluded where !rel.hasPrefix("hermes-agent/") && !rel.hasPrefix("cache/") && !rel.hasPrefix("profiles/work/cache/") {
            #expect(!exists(rel), "\(rel) extracted")
        }
        for rel in ["hermes-agent/venv/bin/python", "gateway_state.json", "processes.json",
                    "state.db-wal", "profiles/work/state.db-wal", "skills/a/deep/x.db-journal"] {
            #expect(!exists(rel), "\(rel) extracted")
        }
        for rel in Self.kept {
            #expect(exists(rel), "\(rel) missing")
        }
    }

    @Test("extract patterns reach every depth on BusyBox tar's start-anchored matching")
    func extractPatternsAreDepthEnumerated() {
        let command = RemoteRestoreService.hermesExtractCommand(
            hermesHome: "/h", archiveLeaf: ".hermes", databases: ["profiles/work/state.db"])
        #expect(command.contains("--exclude='.hermes/*.db-wal'"))
        #expect(command.contains("--exclude='.hermes/*/*/*.db-wal'"))
        #expect(command.contains("--exclude='.hermes/*/*/*/node_modules'"))
        #expect(command.contains("--exclude='.hermes/hermes-agent'"))
        #expect(command.contains("--exclude='.hermes/profiles/work/models'"))
        // Never a wildcard for a root-scoped tree: `*` crosses `/` in GNU
        // tar and bsdtar and would reach a skill's own models/.
        #expect(!command.contains("*/models'"))
        #expect(!command.contains("*/hermes-agent'"))
        #expect(!command.contains("*/node'"))
    }

    // MARK: - T7-F1: GNU tar's exit 1

    /// A fake `tar` first on PATH: `--version` names the flavour, anything
    /// else exits with `rc`.
    static func runFilter(flavour: String, rc: Int32) async throws -> Int32 {
        let bin = try Helpers.scratch("r18a-tar")
        defer { try? FileManager.default.removeItem(at: bin) }
        let fake = bin.appendingPathComponent("tar")
        try Data("""
            #!/bin/sh
            if [ "$1" = --version ]; then echo '\(flavour)'; exit 0; fi
            exit \(rc)
            """.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let command = "PATH=\(RemoteBackupService.shellQuote(bin.path)):$PATH; "
            + RemoteBackupService.tarCommand(workDir: "/", target: "x", excludes: [])
        let result = try await LocalTransport().asyncRunProcess(
            executable: "/bin/bash", args: ["-c", command], stdin: nil, timeout: 30)
        return result.exitCode
    }

    @Test("GNU tar's exit 1 is a complete archive; exit 2 and other tars' 1 still fail")
    func tarExitOneIsGNUsFileChangedWarning() async throws {
        #expect(try await Self.runFilter(flavour: "tar (GNU tar) 1.35", rc: 1) == 0)
        #expect(try await Self.runFilter(flavour: "tar (GNU tar) 1.35", rc: 0) == 0)
        #expect(try await Self.runFilter(flavour: "tar (GNU tar) 1.35", rc: 2) == 2)
        #expect(try await Self.runFilter(flavour: "BusyBox v1.36.1 (2024-06-10) multi-call binary.", rc: 1) == 1)
        #expect(try await Self.runFilter(flavour: "bsdtar 3.5.3 - libarchive 3.7.4", rc: 1) == 1)
    }

    @Test("the version row keeps the banner's version line")
    func versionHeadline() {
        let banner = """
        Hermes Agent v0.21.5 (2026.9.24)
        Install directory: /home/a/.hermes/hermes-agent
        Install method: git
        Python: 3.11.9
        OpenAI SDK: 1.99.0
        Update available: 3 commits behind — run 'hermes update'
        """
        #expect(RemoteBackupService.versionHeadline(banner) == "Hermes Agent v0.21.5 (2026.9.24)")
        #expect(RemoteBackupService.versionHeadline("motd line\n" + banner) == "Hermes Agent v0.21.5 (2026.9.24)")
        #expect(RemoteBackupService.versionHeadline("hermes 0.9.0\n") == "hermes 0.9.0")
        #expect(RemoteBackupService.versionHeadline(" \n") == nil)
    }
}
