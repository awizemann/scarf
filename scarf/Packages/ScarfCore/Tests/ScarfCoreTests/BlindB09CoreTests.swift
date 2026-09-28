import Testing
import Foundation
@testable import ScarfCore

/// Blind re-audit B09 — ScarfCore halves of S15-F2 and S11-projects-core-F3.
@Suite struct BlindB09CoreTests {

    // MARK: - S15-F2: hints only name things the user can do

    /// Saved servers can't be edited on the Mac (t-83d2fe). The pill used to
    /// send the user to "Manage Servers → Edit", which doesn't exist.
    @Test func pillHintsPointAtRemoveAndReAdd() {
        for cause in [ConnectionStatusViewModel.DegradedCause.homeMissing, .profileActive(name: "work")] {
            let hint = ConnectionStatusViewModel.describe(cause: cause, hermesHome: "~/.hermes").hint
            #expect(!hint.contains("Edit"))
            #expect(hint.contains("remove this server"))
            #expect(hint.contains("Hermes data directory"))
        }
    }

    // MARK: - S11-F3: the local git chip finds a real git

    @Test func localGitPrefersTheLoginShellPATH() {
        let found = GitBranchService.localGitExecutable(
            searchPath: "/nix/bin:/opt/homebrew/bin",
            isExecutable: { $0 == "/nix/bin/git" || $0 == "/usr/bin/git" },
            developerToolsInstalled: { true })
        #expect(found == "/nix/bin/git")
    }

    @Test func localGitFallsBackToTheStandardDirectories() {
        let found = GitBranchService.localGitExecutable(
            searchPath: nil,
            isExecutable: { $0 == "/usr/local/bin/git" },
            developerToolsInstalled: { false })
        #expect(found == "/usr/local/bin/git")
    }

    /// Running Apple's `/usr/bin/git` stub without the developer tools pops
    /// an install dialog; the chip lookup runs for every project chat, so it
    /// must never be what triggers that.
    @Test func theSystemStubIsSkippedWithoutDeveloperTools() {
        let without = GitBranchService.localGitExecutable(
            searchPath: "/usr/bin:/bin",
            isExecutable: { $0 == "/usr/bin/git" },
            developerToolsInstalled: { false })
        #expect(without == nil)
        let with = GitBranchService.localGitExecutable(
            searchPath: "/usr/bin:/bin",
            isExecutable: { $0 == "/usr/bin/git" },
            developerToolsInstalled: { true })
        #expect(with == "/usr/bin/git")
    }

    /// End to end on this Mac: a scratch repo on a named branch reads back
    /// through the local transport. Skipped where no usable git exists.
    @Test func localBranchLookupReadsARealRepo() async throws {
        guard let git = GitBranchService.localGitExecutable(searchPath: ProcessInfo.processInfo.environment["PATH"])
        else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b09-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: git)
        proc.arguments = ["-C", dir.path, "init", "-q", "-b", "scarf-b09"]
        try proc.run()
        proc.waitUntilExit()
        try #require(proc.terminationStatus == 0)

        // `rev-parse --abbrev-ref HEAD` on a fresh repo with no commits
        // prints "HEAD" on some git versions; `symbolic-ref` would not, but
        // the service asks rev-parse, so make one commit first.
        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: git)
        commit.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t",
                            "commit", "-q", "--allow-empty", "-m", "init"]
        try commit.run()
        commit.waitUntilExit()
        try #require(commit.terminationStatus == 0)

        let branch = await GitBranchService(context: .local).branch(at: dir.path)
        #expect(branch == "scarf-b09")
    }
}
