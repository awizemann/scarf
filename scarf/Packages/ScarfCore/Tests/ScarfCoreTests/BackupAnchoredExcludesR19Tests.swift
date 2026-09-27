import Testing
import Foundation
@testable import ScarfCore

/// R19: a root-only exclude (`models/`, `node/`, `hermes-agent/`,
/// `cache/<entry>`, `logs/`, …) must never match the same name deeper in the
/// home. Tar matches exclude patterns unanchored, so the old `<leaf>/models`
/// also dropped `<leaf>/skills/ml/<leaf>/models/` whenever the home's own
/// name recurred below it — with the official Docker home `/opt/data`, a
/// skill's `data/models/` vanished from the backup and from the restore.
///
/// These run the real backup and restore locally (bsdtar). The same
/// commands were run under GNU tar 1.35 (debian:stable-slim) and BusyBox tar
/// 1.37 (alpine) in containers for this phase; see the R19 report.
@Suite(.serialized)
struct BackupAnchoredExcludesR19Tests {

    typealias Helpers = ServerBackupRestoreSafetyTests

    static func write(_ home: URL, _ rel: String, _ text: String = "x") throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Hermes leaves these out at a home's root (`_in_excluded_root_dir`,
    /// `backup.py:84-93` @ v2026.9.24; `logs` is the backup option).
    static let rootOnly = [
        "models/w.gguf", "node/bin/node", "runtimes/llama/server", "browser_profiles/bu/Cookies",
        "hermes-agent/run_agent.py", "cache/tmp/t.json", "logs/agent.log",
    ]

    /// The same names below the root are the user's data — here under a
    /// directory named like the home itself. (Not `backups`: Hermes leaves
    /// that out at any depth.)
    static func nested(_ leaf: String) -> [String] {
        ["skills/ml/\(leaf)/models/keep.bin", "skills/ml/\(leaf)/node/keep.js",
         "skills/ml/\(leaf)/runtimes/keep", "skills/ml/\(leaf)/browser_profiles/keep",
         "skills/ml/\(leaf)/hermes-agent/keep.md", "skills/ml/\(leaf)/cache/tmp/keep",
         "skills/ml/\(leaf)/logs/keep.log", "skills/ml/models/keep2.bin",
         "config.yaml", "cache/images/i.png"]
    }

    @Test("a home named like a folder inside it keeps that folder's files", arguments: ["data", ".hermes", "models"])
    func nestedSameNamedTreesSurvive(leaf: String) async throws {
        let root = try Helpers.scratch("r19-anchor")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("opt").appendingPathComponent(leaf)
        for rel in Self.rootOnly + Self.nested(leaf) { try Self.write(home, rel) }

        let backup = try await Helpers.backUp(home: home, into: root)
        #expect(backup.manifest.hermes.memberRoot == ".")
        let tarball = try Helpers.unzipped(backup.archiveURL, in: root)
            .appendingPathComponent(backup.manifest.hermes.tarballPath)
        let listing = Set(try Helpers.capture("/usr/bin/tar", ["-tzf", tarball.path])
            .split(separator: "\n").map(String.init))
        for rel in Self.rootOnly {
            #expect(!listing.contains("./" + rel), "\(rel) shipped")
        }
        for rel in Self.nested(leaf) {
            #expect(listing.contains("./" + rel), "\(rel) dropped: \(listing.sorted())")
        }

        // Restore over a target with its own installed Hermes and runtimes.
        let target = root.appendingPathComponent("dst").appendingPathComponent(leaf)
        try Self.write(target, "hermes-agent/run_agent.py", "TARGET")
        try Self.write(target, "models/own.gguf", "TARGET")
        let service = RemoteRestoreService(context: .local(home: target))
        _ = try await service.run(
            inspection: try await service.inspect(archiveURL: backup.archiveURL),
            options: .init(targetProjectsRoot: root.appendingPathComponent("projects").path),
            progress: { _ in })
        for rel in Self.nested(leaf) {
            #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(rel).path), "\(rel) not restored")
        }
        #expect(try String(contentsOf: target.appendingPathComponent("hermes-agent/run_agent.py"), encoding: .utf8) == "TARGET")
        #expect(try String(contentsOf: target.appendingPathComponent("models/own.gguf"), encoding: .utf8) == "TARGET")
    }

    /// An archive made before R19 (`<leaf>/…` members, no `memberRoot`) is
    /// re-rooted on the Mac before extraction: its nested same-named trees
    /// restore, its root runtime trees still don't overwrite the target's,
    /// and owners, symlinks and hardlinks come through.
    @Test func anOlderLeafRootedArchiveRestoresItsNestedTrees() async throws {
        let root = try Helpers.scratch("r19-old")
        defer { try? FileManager.default.removeItem(at: root) }
        let leaf = "data"
        let stage = root.appendingPathComponent("stage/\(leaf)")
        for rel in Self.rootOnly + Self.nested(leaf) { try Self.write(stage, rel) }
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("links"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: stage.appendingPathComponent("links/cfg").path, withDestinationPath: "../config.yaml")
        try FileManager.default.linkItem(
            at: stage.appendingPathComponent("config.yaml"), to: stage.appendingPathComponent("links/hard.yaml"))

        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tarball = work.appendingPathComponent(BackupArchiveLayout.hermesTarballPath)
        try Helpers.run("/usr/bin/tar", ["-czf", tarball.path, "-C", stage.deletingLastPathComponent().path, leaf])
        let manifest = BackupManifest(
            schemaVersion: 2,
            createdAt: "2026-09-01T00:00:00Z",
            source: .init(serverID: "s", displayName: "Old", host: "h", user: nil, hermesVersion: nil),
            hermes: .init(homePath: "/opt/\(leaf)", tarballPath: BackupArchiveLayout.hermesTarballPath,
                          tarballSize: 0, tarballSHA256: try Helpers.sha256(tarball)),
            projects: [],
            options: .init(includeAuth: false, includeMcpTokens: false, includeLogs: false, checkpointedWAL: false)
        )
        #expect(manifest.hermes.memberRoot == nil)
        try JSONEncoder().encode(manifest).write(to: work.appendingPathComponent(BackupArchiveLayout.manifestPath))
        let archive = root.appendingPathComponent("old.scarfbackup")
        try await RemoteBackupService.zipDirectory(workDir: work, into: archive)

        let target = root.appendingPathComponent("dst/\(leaf)")
        try Self.write(target, "hermes-agent/run_agent.py", "TARGET")
        let service = RemoteRestoreService(context: .local(home: target))
        _ = try await service.run(
            inspection: try await service.inspect(archiveURL: archive),
            options: .init(targetProjectsRoot: root.appendingPathComponent("projects").path),
            progress: { _ in })

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: target.appendingPathComponent(rel).path) }
        for rel in Self.nested(leaf) { #expect(exists(rel), "\(rel) not restored") }
        for rel in ["models/w.gguf", "node/bin/node", "runtimes/llama/server", "browser_profiles/bu/Cookies"] {
            #expect(!exists(rel), "\(rel) restored over the target")
        }
        #expect(try String(contentsOf: target.appendingPathComponent("hermes-agent/run_agent.py"), encoding: .utf8) == "TARGET")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("links/cfg").path)
                == "../config.yaml", "symlink targets are not rewritten")
        let a = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("config.yaml").path)
        let b = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("links/hard.yaml").path)
        #expect(a[.systemFileNumber] as? Int == b[.systemFileNumber] as? Int, "the hardlink still points into the home")
    }

    /// The re-root keeps every header, and a leaf with regex characters is
    /// matched literally.
    @Test func rerootMatchesTheLeafLiterally() async throws {
        let root = try Helpers.scratch("r19-reroot")
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("s/.h[1]*$")
        try Self.write(stage, "config.yaml")
        try Self.write(stage, "skills/.h[1]*$/keep")
        try Self.write(root.appendingPathComponent("s/xh[1]*$"), "other")
        let tarball = root.appendingPathComponent("t.tgz")
        try Helpers.run("/usr/bin/tar", ["-czf", tarball.path, "-C", root.appendingPathComponent("s").path, ".h[1]*$", "xh[1]*$"])
        let out = try #require(try await RemoteRestoreService.rerootHomeTarball(tarball, leaf: ".h[1]*$", workDir: root))
        let names = Set(try Helpers.capture("/usr/bin/tar", ["-tzf", out.path]).split(separator: "\n").map(String.init))
        #expect(names.contains("./config.yaml"))
        #expect(names.contains("./skills/.h[1]*$/keep"), "only the leading leaf is rewritten")
        #expect(names.contains("xh[1]*$/other"), "a member that isn't under the leaf is left alone")
    }
}
