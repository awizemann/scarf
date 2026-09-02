import Testing
import Foundation
@testable import scarf

/// Containment coverage for `WidgetPathResolver` — the boundary every
/// file-reading dashboard widget (`markdown_file`, `log_tail`, local
/// `image`) resolves its `path` through.
///
/// The `path` field comes out of `.scarf/dashboard.json`, which the agent
/// writes, and it points into a project tree the agent also writes. So this
/// is an untrusted-input boundary, and the repo convention for those
/// (`.memory/conventions/path-containment-for-untrusted-dirs-must-resolve-symlinks-not-just-normalize-lexically`)
/// requires a symlink-resolved check, not just a lexical one — the symlink
/// case below is the escape that a lexical `hasPrefix` waves straight
/// through.
@Suite struct WidgetPathResolverTests {

    // MARK: - Helpers

    /// A real on-disk project root. Realpath'd: `/var` and `/tmp` are
    /// themselves symlinks on macOS, and the test wants to reason about
    /// containment, not about the harness's own prefix.
    private func makeTempRoot() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-widgetpath-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/reports", withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    private func success(_ result: Result<String, WidgetPathResolver.ResolveError>) -> String? {
        if case .success(let path) = result { return path }
        return nil
    }

    private func failure(_ result: Result<String, WidgetPathResolver.ResolveError>) -> WidgetPathResolver.ResolveError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: - The symlink escape (the reason this file exists)

    /// A symlink planted INSIDE the project that points at a file outside it
    /// is refused. Purely lexical containment passes this path (nothing in
    /// the string leaves the root), and `transport.readFile` then reads
    /// THROUGH the link — an arbitrary-file read with the project root as
    /// the only apparent boundary.
    @Test func rejectsSymlinkEscapingTheProjectRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outside = NSTemporaryDirectory() + "scarf-outside-" + UUID().uuidString + ".md"
        try Data("TOP SECRET".utf8).write(to: URL(fileURLWithPath: outside))
        defer { try? FileManager.default.removeItem(atPath: outside) }

        try FileManager.default.createSymbolicLink(
            atPath: root + "/reports/weekly.md",
            withDestinationPath: outside
        )

        let result = WidgetPathResolver.resolve("reports/weekly.md", projectRoot: root)
        #expect(failure(result) == .escapesProject)
    }

    /// A symlinked DIRECTORY that points outside is refused too — the escape
    /// works just as well one level up from the file.
    @Test func rejectsSymlinkedDirectoryEscapingTheProjectRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outsideDir = NSTemporaryDirectory() + "scarf-outside-dir-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        try Data("TOP SECRET".utf8).write(to: URL(fileURLWithPath: outsideDir + "/notes.md"))
        defer { try? FileManager.default.removeItem(atPath: outsideDir) }

        try FileManager.default.createSymbolicLink(atPath: root + "/linked", withDestinationPath: outsideDir)

        let result = WidgetPathResolver.resolve("linked/notes.md", projectRoot: root)
        #expect(failure(result) == .escapesProject)
    }

    // MARK: - Legitimate in-project symlinks still work

    /// A symlink that stays INSIDE the project resolves normally. This is the
    /// adversarial half of the fix: hardening containment must not break the
    /// ordinary case of a project that symlinks one of its own files
    /// (monorepo shared docs, a `latest.log` → `run-3.log` pointer).
    @Test func allowsSymlinkThatStaysInsideTheProject() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try Data("# real".utf8).write(to: URL(fileURLWithPath: root + "/reports/run-3.md"))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/latest.md",
            withDestinationPath: root + "/reports/run-3.md"
        )

        let result = WidgetPathResolver.resolve("latest.md", projectRoot: root)
        #expect(success(result) == root + "/latest.md")
    }

    /// A relative in-project symlink (the common form) is allowed as well.
    @Test func allowsRelativeSymlinkThatStaysInsideTheProject() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try Data("# real".utf8).write(to: URL(fileURLWithPath: root + "/reports/run-3.md"))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/reports/latest.md",
            withDestinationPath: "run-3.md"
        )

        let result = WidgetPathResolver.resolve("reports/latest.md", projectRoot: root)
        #expect(success(result) == root + "/reports/latest.md")
    }

    /// A project root that itself lives under a symlinked prefix still
    /// serves its own files — the "resolve BOTH sides" half of the rule.
    /// (`/var` → `/private/var` on macOS is exactly this case.)
    @Test func allowsProjectRootReachedThroughASymlinkedPrefix() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("# real".utf8).write(to: URL(fileURLWithPath: root + "/reports/weekly.md"))

        let alias = NSTemporaryDirectory() + "scarf-alias-" + UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: root)
        defer { try? FileManager.default.removeItem(atPath: alias) }

        let result = WidgetPathResolver.resolve("reports/weekly.md", projectRoot: alias)
        #expect(failure(result) == nil)
    }

    /// A file that doesn't exist yet still resolves — the widget's own read
    /// error is the right place to report a missing file, not a security
    /// refusal. (This is why the resolver can't just call
    /// `MiniAppAssetResolver.containedFilePath`, which requires existence.)
    @Test func allowsPathThatDoesNotExistYet() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = WidgetPathResolver.resolve("reports/not-written-yet.md", projectRoot: root)
        #expect(success(result) == root + "/reports/not-written-yet.md")
    }

    /// A remote project root (nothing under that path on THIS machine)
    /// resolves lexically instead of being refused — widgets read through
    /// `ServerContext`'s transport and the root may live on an SSH host.
    @Test func remoteStyleRootWithNoLocalCounterpartStillResolves() {
        let root = "/home/deploy/projects/atlas-" + UUID().uuidString
        let result = WidgetPathResolver.resolve("reports/weekly.md", projectRoot: root)
        #expect(success(result) == root + "/reports/weekly.md")
    }

    // MARK: - Lexical rules (unchanged, pinned)

    @Test func rejectsParentEscape() {
        let result = WidgetPathResolver.resolve("../../.hermes/auth.json", projectRoot: "/scarf-test-root/proj")
        #expect(failure(result) == .escapesProject)
    }

    @Test func rejectsParentEscapeMidPath() {
        let result = WidgetPathResolver.resolve("reports/../../secrets.md", projectRoot: "/scarf-test-root/proj")
        #expect(failure(result) == .escapesProject)
    }

    @Test func rejectsAbsolutePath() {
        let result = WidgetPathResolver.resolve("/etc/passwd", projectRoot: "/scarf-test-root/proj")
        #expect(failure(result) == .absolutePath)
    }

    @Test func rejectsMissingPathAndMissingProject() {
        #expect(failure(WidgetPathResolver.resolve(nil, projectRoot: "/scarf-test-root/proj")) == .missingPath)
        #expect(failure(WidgetPathResolver.resolve("", projectRoot: "/scarf-test-root/proj")) == .missingPath)
        #expect(failure(WidgetPathResolver.resolve("a.md", projectRoot: nil)) == .noProject)
        #expect(failure(WidgetPathResolver.resolve("a.md", projectRoot: "")) == .noProject)
    }

    @Test func stripsLeadingDotSlash() {
        let result = WidgetPathResolver.resolve("./reports/weekly.md", projectRoot: "/scarf-test-root/proj")
        #expect(success(result) == "/scarf-test-root/proj/reports/weekly.md")
    }
}
