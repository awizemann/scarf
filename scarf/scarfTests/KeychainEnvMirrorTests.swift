import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises the file-only seam of `KeychainEnvMirror` —
/// `mirror(slug:entries:envPath:)` and `unmirror(slug:envPath:)`.
/// These take pre-resolved entries so the suite never touches the
/// macOS Keychain or the user's real `~/.hermes/.env`.
///
/// The Keychain-resolution path (`mirror(project:)`,
/// `resolveSecrets(for:)`) is covered by the manual end-to-end
/// verification in the project plan — putting that under unit tests
/// would either pollute the user's login keychain or require a
/// mock-keychain abstraction that's out of scope for v2.8.
@Suite("KeychainEnvMirror")
struct KeychainEnvMirrorTests {

    // MARK: - derivedSlug

    @Test func derivedSlugSimple() {
        let project = ProjectEntry(name: "Local News", path: "/tmp/x")
        #expect(KeychainEnvMirror.derivedSlug(forProject: project) == "local-news")
    }

    @Test func derivedSlugCollapsesSpecials() {
        let project = ProjectEntry(name: "Foo & Bar (2)", path: "/tmp/x")
        // Anything not [a-z0-9] becomes a separator; runs collapse;
        // trailing separators stripped.
        #expect(KeychainEnvMirror.derivedSlug(forProject: project) == "foo-bar-2")
    }

    @Test func derivedSlugAllSymbolsFallsBackToProject() {
        let project = ProjectEntry(name: "!!!", path: "/tmp/x")
        // Pathological all-symbols name still yields a valid slug.
        #expect(KeychainEnvMirror.derivedSlug(forProject: project) == "project")
    }

    // MARK: - mirror(slug:entries:envPath:) — file shape

    @Test func mirrorWritesBlockToFreshEnv() throws {
        let env = try TempEnv()
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(
            slug: "local-news",
            entries: [("SCARF_LOCAL_NEWS_API_TOKEN", "abc123")],
            envPath: env.path
        )
        let written = try env.read()
        #expect(written.contains("# scarf-secrets:begin local-news"))
        #expect(written.contains("SCARF_LOCAL_NEWS_API_TOKEN=abc123"))
        #expect(written.contains("# scarf-secrets:end local-news"))
    }

    @Test func mirrorEnforcesMode0600() throws {
        let env = try TempEnv()
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(
            slug: "x",
            entries: [("KEY", "value")],
            envPath: env.path
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: env.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(
            perms?.intValue == 0o600,
            "expected mode 0600 on \(env.path); got \(String(describing: perms))"
        )
    }

    @Test func mirrorPreservesUserContent() throws {
        let env = try TempEnv()
        defer { env.cleanup() }
        try env.write("ANTHROPIC_API_KEY=sk-test\n")
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(
            slug: "x",
            entries: [("KEY", "value")],
            envPath: env.path
        )
        let written = try env.read()
        // User content stays intact at the top.
        #expect(written.hasPrefix("ANTHROPIC_API_KEY=sk-test"))
        // Block landed below it.
        #expect(written.contains("# scarf-secrets:begin x"))
    }

    @Test func mirrorEmptyEntriesRemovesBlock() throws {
        // The documented sentinel for "secrets cleared" — empty
        // entries triggers unmirror, not an empty block with
        // dangling markers.
        let env = try TempEnv()
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(
            slug: "x",
            entries: [("KEY", "value")],
            envPath: env.path
        )
        try mirror.mirror(
            slug: "x",
            entries: [],
            envPath: env.path
        )
        let written = try env.read()
        #expect(!written.contains("scarf-secrets"))
    }

    @Test func mirrorMultiProjectIsolated() throws {
        // Mirroring slug A then slug B then re-mirroring A doesn't
        // disturb B's block — the most important multi-project
        // invariant for this file.
        let env = try TempEnv()
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(slug: "alpha", entries: [("A", "1")], envPath: env.path)
        try mirror.mirror(slug: "bravo", entries: [("B", "2")], envPath: env.path)
        let beforeUpdate = try env.read()
        try mirror.mirror(slug: "alpha", entries: [("A", "1-updated")], envPath: env.path)
        let afterUpdate = try env.read()
        #expect(afterUpdate.contains("A=1-updated"))
        #expect(!afterUpdate.contains("A=1\n"))
        // Bravo block byte-identical.
        let beforeBravo = extractBlock(slug: "bravo", from: beforeUpdate)
        let afterBravo = extractBlock(slug: "bravo", from: afterUpdate)
        #expect(beforeBravo != nil)
        #expect(beforeBravo == afterBravo)
    }

    @Test func mirrorIdempotentWhenUnchanged() async throws {
        // Reconcile-on-launch fires this every cold start. If the
        // input hasn't changed, we shouldn't rewrite the file —
        // that bumps mtime and triggers anything watching `.env`.
        let env = try TempEnv()
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(
            slug: "x",
            entries: [("KEY", "value")],
            envPath: env.path
        )
        let mtimeBefore = try env.modificationDate()
        // A gap so a real write would advance mtime to a DISTINCT value.
        // 100 ms, not the second this used to be: APFS timestamps resolve to
        // the nanosecond, so the gap only has to be larger than the clock's
        // granularity, and a second of wall time bought nothing but a second
        // of wall time (round-5 P48).
        try await Task.sleep(nanoseconds: 100_000_000)
        try mirror.mirror(
            slug: "x",
            entries: [("KEY", "value")],
            envPath: env.path
        )
        let mtimeAfter = try env.modificationDate()
        #expect(
            mtimeBefore == mtimeAfter,
            "mtime advanced from \(mtimeBefore) to \(mtimeAfter) — no-op write fired"
        )
    }

    // MARK: - unmirror(slug:envPath:)

    @Test func unmirrorRemovesBlock() throws {
        let env = try TempEnv()
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(slug: "x", entries: [("KEY", "value")], envPath: env.path)
        try mirror.unmirror(slug: "x", envPath: env.path)
        let written = try env.read()
        #expect(!written.contains("scarf-secrets"))
    }

    @Test func unmirrorNoOpWhenFileMissing() throws {
        // Brand-new install with no env file: unmirror on uninstall
        // shouldn't throw or create an empty file.
        let env = try TempEnv(initialContents: nil)
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.unmirror(slug: "x", envPath: env.path)
        #expect(!FileManager.default.fileExists(atPath: env.path))
    }

    @Test func unmirrorPreservesOtherProjectBlocks() throws {
        let env = try TempEnv()
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(slug: "alpha", entries: [("A", "1")], envPath: env.path)
        try mirror.mirror(slug: "bravo", entries: [("B", "2")], envPath: env.path)
        try mirror.unmirror(slug: "alpha", envPath: env.path)
        let written = try env.read()
        #expect(!written.contains("# scarf-secrets:begin alpha"))
        #expect(written.contains("# scarf-secrets:begin bravo"))
        #expect(written.contains("B=2"))
    }

    @Test func unmirrorNoOpWhenSlugAbsent() throws {
        // Removing a project that never had secrets shouldn't alter
        // the file.
        let env = try TempEnv(initialContents: "USER=x\n")
        defer { env.cleanup() }
        let mirror = KeychainEnvMirror(context: .local)
        try mirror.unmirror(slug: "neverwashere", envPath: env.path)
        let written = try env.read()
        #expect(written == "USER=x\n")
    }

    // MARK: - Test helpers

    private func extractBlock(slug: String, from text: String) -> String? {
        let begin = "# scarf-secrets:begin \(slug)"
        let end = "# scarf-secrets:end \(slug)"
        guard let beginRange = text.range(of: begin),
              let endRange = text.range(
                of: end,
                range: beginRange.upperBound..<text.endIndex
              ) else { return nil }
        return String(text[beginRange.lowerBound..<endRange.upperBound])
    }
}

// MARK: - TempEnv

/// One-shot wrapper around a temp directory with a `.env` file.
/// The basename `.env` is what the LocalTransport's mode-0600
/// heuristic keys on, so writes through this path get the same
/// permission treatment as the real `~/.hermes/.env`.
private struct TempEnv {
    let directory: URL
    let path: String

    init(initialContents: String? = "") throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-keychain-env-mirror-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let envURL = directory.appendingPathComponent(".env")
        path = envURL.path
        if let initialContents {
            try initialContents.write(to: envURL, atomically: true, encoding: .utf8)
        }
    }

    func read() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func write(_ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func modificationDate() throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let date = attrs[.modificationDate] as? Date else {
            throw NSError(
                domain: "TempEnv",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no mtime on \(path)"]
            )
        }
        return date
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
