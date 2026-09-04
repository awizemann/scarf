import Testing
import Foundation
import ScarfCore
@testable import scarf

/// `SkillBootstrapService`'s two jobs that run unattended on every launch:
/// the semver gate that decides whether a bundled skill is rewritten, and
/// the denylist pass that deletes skills which lie about Scarf.
///
/// The copy path itself isn't exercised here — it reads `Bundle.main`,
/// which under the test host is the test host. What IS covered is every
/// decision the copy path makes (`semverCompare`, `parseVersion`) plus the
/// prune, which takes a real temp `~/.hermes` through the transport.
struct SkillBootstrapServiceTests {

    private static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Write a skill at `<home>/skills/<relative>/SKILL.md` plus one
    /// companion, so a removal that only unlinks SKILL.md is visible.
    private static func plantSkill(_ relative: String, in home: URL, version: String = "1.0.0") throws -> URL {
        let dir = home.appendingPathComponent("skills/" + relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("---\nname: \(dir.lastPathComponent)\nversion: \(version)\n---\n\nbody\n".utf8)
            .write(to: dir.appendingPathComponent("SKILL.md"))
        try Data("companion\n".utf8).write(to: dir.appendingPathComponent("reference.md"))
        return dir
    }

    // MARK: - Denylist

    @Test("a known-bad skill is removed from the scarf/ namespace, companions and all")
    func pruneRemovesTheDenylistedSkill() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bad = try Self.plantSkill("scarf/scarf-project-workflows", in: home)

        let removed = SkillBootstrapService(context: .local(home: home)).pruneKnownBadSkills()

        #expect(removed == [bad.path])
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }

    /// The pre-v2.10.1 flat layout is the other place Scarf's bootstrap
    /// ever wrote, so it's the other place a bad skill can be hiding.
    @Test("the legacy flat install path is pruned too")
    func prunePicksUpTheLegacyFlatLayout() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let flat = try Self.plantSkill("scarf-project-workflows", in: home)

        let removed = SkillBootstrapService(context: .local(home: home)).pruneKnownBadSkills()

        #expect(removed == [flat.path])
        #expect(!FileManager.default.fileExists(atPath: flat.path))
    }

    /// The blast radius, stated as a test. A denylisted NAME sitting
    /// outside the namespace Scarf owns — in someone else's category
    /// folder — is not ours to delete, and neither is anything else the
    /// user installed.
    @Test("nothing outside Scarf's own namespace is touched")
    func pruneLeavesEveryOtherSkillAlone() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sameNameElsewhere = try Self.plantSkill("mine/scarf-project-workflows", in: home)
        let realSkill = try Self.plantSkill("scarf/scarf-template-author", in: home)
        let userSkill = try Self.plantSkill("scarf/my-own-skill", in: home)

        let removed = SkillBootstrapService(context: .local(home: home)).pruneKnownBadSkills()

        #expect(removed.isEmpty)
        for survivor in [sameNameElsewhere, realSkill, userSkill] {
            #expect(FileManager.default.fileExists(atPath: survivor.appendingPathComponent("SKILL.md").path))
        }
    }

    /// The nastiest shape this pass can meet: the denylisted NAME inside
    /// Scarf's namespace, but as a SYMLINK pointing at a directory the
    /// user owns. Unlinking it is right; following it and deleting what
    /// is on the other side is data loss well outside this pass's remit.
    @Test("a symlinked bad skill is unlinked, never followed")
    func pruneUnlinksASymlinkWithoutDeletingItsTarget() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let victim = home.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("do not delete\n".utf8).write(to: victim.appendingPathComponent("keepme.md"))

        let scarfRoot = home.appendingPathComponent("skills/scarf")
        try FileManager.default.createDirectory(at: scarfRoot, withIntermediateDirectories: true)
        let link = scarfRoot.appendingPathComponent("scarf-project-workflows")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        let removed = SkillBootstrapService(context: .local(home: home)).pruneKnownBadSkills()

        #expect(removed == [link.path])
        // The link is gone…
        #expect(!FileManager.default.fileExists(atPath: link.path))
        // …and everything it pointed at is untouched.
        #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("keepme.md").path))
    }

    /// The steady state — every launch after the first — writes nothing
    /// and reports nothing.
    @Test("pruning an already-clean install is a silent no-op")
    func pruneIsIdempotent() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try Self.plantSkill("scarf/scarf-project-workflows", in: home)
        let service = SkillBootstrapService(context: .local(home: home))

        #expect(service.pruneKnownBadSkills().count == 1)
        #expect(service.pruneKnownBadSkills().isEmpty)
    }

    @Test("the denylist is exactly what we believe it is")
    func denylistContents() {
        #expect(SkillBootstrapService.knownBadSkillNames == ["scarf-project-workflows"])
    }

    // MARK: - Version gating

    /// The gate that makes the v2.0.0 skill rewrite actually reach users
    /// who already have 1.3.0 installed — and leaves a user's newer
    /// hand-edited copy alone.
    @Test("semver gating replaces an older install and never a newer one")
    func semverGate() {
        #expect(SkillBootstrapService.semverCompare("1.3.0", "2.0.0") < 0)
        #expect(SkillBootstrapService.semverCompare("2.0.0", "2.0.0") == 0)
        #expect(SkillBootstrapService.semverCompare("2.1.0", "2.0.0") > 0)
        // Shorter is not newer: 2 == 2.0.0.
        #expect(SkillBootstrapService.semverCompare("2", "2.0.0") == 0)
        #expect(SkillBootstrapService.semverCompare("1.10.0", "1.9.0") > 0)
    }

    @Test("the bundled skill declares the version the gate needs")
    func bundledTemplateAuthorIsVersionTwo() throws {
        // Read the shipped source, not the bundle: the test host has no
        // BuiltinSkills.bundle, and this is the file that gets copied.
        let skill = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .appendingPathComponent("scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md")
        let data = try Data(contentsOf: skill)
        let version = try #require(SkillBootstrapService.parseVersion(data))
        #expect(SkillBootstrapService.semverCompare(version, "2.0.0") >= 0)

        // The instruction that caused the 2026-09-02 corruption is gone as
        // the PRIMARY path: registration is a tool call, and the raw
        // append survives only inside the remote-host fallback.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("project_register"))
        #expect(text.contains("project_update_dashboard"))
        #expect(text.contains("Fallback, remote hosts only"))
        // A flag Hermes's cron parser doesn't define (charter C5).
        #expect(!text.contains("cron list --json"))
    }

    @Test func parseVersionReadsFrontmatterOnly() {
        #expect(SkillBootstrapService.parseVersion(Data("---\nversion: 2.0.0\n---\n".utf8)) == "2.0.0")
        #expect(SkillBootstrapService.parseVersion(Data("---\nname: x\n---\nversion: 9.9.9\n".utf8)) == nil)
        #expect(SkillBootstrapService.parseVersion(Data("no frontmatter\n".utf8)) == nil)
    }
}
