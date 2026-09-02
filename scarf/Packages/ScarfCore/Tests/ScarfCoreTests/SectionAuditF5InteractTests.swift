import Testing
import Foundation
@testable import ScarfCore

/// Section-audit fix package F5 — INTERACT-SMALLS. Pure-value coverage for
/// the three fixes that have a testable core: the ANSI strip in the Skills
/// hub banner, the install-override validator, and skills-path containment.
@Suite("Section audit F5 — interact smalls")
struct SectionAuditF5InteractTests {

    // MARK: - ANSI strip (SkillsViewModel.firstSignificantLine)

    /// The banner used to print raw SGR codes: the pattern was written as
    /// a RAW Swift string `#"\u{001B}\[[0-9;]*m"#`, so Swift did no escape
    /// processing and ICU received the literal characters `\u{001B}` —
    /// not an ESC byte.
    @Test("ANSI SGR sequences are stripped from the hub banner line")
    func stripsRealANSISequence() {
        let esc = "\u{001B}"
        let output = "\(esc)[0;32mSkill not found\(esc)[0m"
        #expect(SkillsViewModel.firstSignificantLine(output) == "Skill not found")
    }

    @Test("Multiple SGR runs and a reset on a later line are all stripped")
    func stripsMultipleSequences() {
        let esc = "\u{001B}"
        let output = """
        \(esc)[1m\(esc)[31mError:\(esc)[0m registry \(esc)[4munreachable\(esc)[0m
        second line
        """
        #expect(SkillsViewModel.firstSignificantLine(output) == "Error: registry unreachable")
    }

    /// Pins the diagnosis, not just the symptom: the exact pre-fix literal
    /// is applied here directly and must fail to strip a real ESC — proof
    /// the old pattern could never have matched.
    @Test("The pre-fix raw-string pattern would not have matched a real ESC")
    func oldBrokenPatternDoesNotMatch() {
        let esc = "\u{001B}"
        let input = "\(esc)[0;32mgreen\(esc)[0m"
        let brokenPattern = #"\u{001B}\[[0-9;]*m"#
        let result = input.replacingOccurrences(
            of: brokenPattern,
            with: "",
            options: .regularExpression
        )
        #expect(result == input, "the broken literal must leave the ESC sequence intact")
        // …while the shipped code strips it.
        #expect(SkillsViewModel.firstSignificantLine(input) == "green")
    }

    @Test("Box-drawing chrome is still skipped and plain output is untouched")
    func skipsBoxDrawingAndPassesPlainText() {
        #expect(SkillsViewModel.firstSignificantLine("╭──────────╮\nreal message\n") == "real message")
        #expect(SkillsViewModel.firstSignificantLine("plain") == "plain")
        #expect(SkillsViewModel.firstSignificantLine("") == "")
    }

    // MARK: - Install override validation

    @Test("Absent or unsupplied overrides are acceptable — the flag is omitted")
    func absentOverridesAreFine() {
        #expect(SkillInstallValidator.problem(with: nil, field: .name) == nil)
        #expect(SkillInstallValidator.problem(with: "", field: .name) == nil)
        #expect(SkillInstallValidator.problem(with: nil, field: .category) == nil)
        #expect(SkillInstallValidator.isAcceptable(nil, field: .category))
    }

    /// Matches Hermes's `_VALID_NAME_RE = ^[a-z][a-z0-9_-]*$`
    /// (`hermes_cli/skills_hub.py`).
    @Test(
        "Names matching Hermes's own regex pass",
        arguments: ["productivity", "swift-testing-expert", "web_perf", "a", "skill9", "x9-_z"]
    )
    func acceptsValidNames(_ value: String) {
        #expect(SkillInstallValidator.problem(with: value, field: .name) == nil,
                "\(value) should be accepted as a name")
    }

    /// Matches `_VALID_CATEGORY_RE = ^[a-z][a-z0-9_/-]*$` — note `/` IS
    /// legal here (nested buckets) and is not legal in a name.
    @Test(
        "Categories matching Hermes's own regex pass, including nested buckets",
        arguments: ["productivity", "cloudflare/workers", "a/b/c", "mlops"]
    )
    func acceptsValidCategories(_ value: String) {
        #expect(SkillInstallValidator.problem(with: value, field: .category) == nil,
                "\(value) should be accepted as a category")
    }

    @Test("Names are rejected with the reason Hermes would have given")
    func rejectsInvalidNames() {
        #expect(SkillInstallValidator.problem(with: "   ", field: .name) == .empty)
        #expect(SkillInstallValidator.problem(with: "a/b", field: .name) == .separatorNotAllowed)
        #expect(SkillInstallValidator.problem(with: "back\\slash", field: .name) == .separatorNotAllowed)
        #expect(SkillInstallValidator.problem(with: "..", field: .name) == .relativePathComponent)
        #expect(SkillInstallValidator.problem(with: ".", field: .name) == .relativePathComponent)
        // Uppercase, a leading digit and a leading dash all fail the anchor.
        #expect(SkillInstallValidator.problem(with: "MySkill", field: .name) == .mustStartWithLowercaseLetter)
        #expect(SkillInstallValidator.problem(with: "9lives", field: .name) == .mustStartWithLowercaseLetter)
        #expect(SkillInstallValidator.problem(with: "-y", field: .name) == .mustStartWithLowercaseLetter)
        #expect(SkillInstallValidator.problem(with: ".hidden", field: .name) == .mustStartWithLowercaseLetter)
        // Interior violations. `.` is NOT in Hermes's name class.
        #expect(SkillInstallValidator.problem(with: "v2.7", field: .name) == .disallowedCharacter("."))
        #expect(SkillInstallValidator.problem(with: "two words", field: .name) == .disallowedCharacter(" "))
        #expect(SkillInstallValidator.problem(with: "semi;colon", field: .name) == .disallowedCharacter(";"))
        #expect(SkillInstallValidator.problem(with: "shout\u{0007}", field: .name)
                == .disallowedCharacter("\u{0007}"))
        #expect(SkillInstallValidator.problem(with: "camelCase", field: .name) == .disallowedCharacter("C"))
    }

    @Test("Hermes's sentinel names are rejected")
    func rejectsReservedNames() {
        for reserved in ["skill", "readme", "index", "unnamed-skill"] {
            #expect(SkillInstallValidator.problem(with: reserved, field: .name)
                    == .reservedName(reserved))
        }
        // Only the exact word is reserved.
        #expect(SkillInstallValidator.problem(with: "readme-writer", field: .name) == nil)
    }

    /// The security half: Hermes applies `_VALID_CATEGORY_RE` only to the
    /// value it PROMPTS for. A `--category` flag is interpolated into
    /// `skills/{category}/{name}/` unchecked, so a traversal typed here
    /// would write outside the skills root. Scarf must catch it.
    @Test("A traversal in the category is rejected — Hermes does not check the flag")
    func rejectsCategoryTraversal() {
        #expect(SkillInstallValidator.problem(with: "..", field: .category) == .relativePathComponent)
        #expect(SkillInstallValidator.problem(with: "../../etc", field: .category)
                == .relativePathComponent)
        #expect(SkillInstallValidator.problem(with: "good/../../bad", field: .category)
                == .relativePathComponent)
        #expect(SkillInstallValidator.problem(with: "a/./b", field: .category)
                == .relativePathComponent)
        // A leading slash makes the first segment empty, so it fails the anchor.
        #expect(SkillInstallValidator.problem(with: "/etc", field: .category)
                == .mustStartWithLowercaseLetter)
        #expect(SkillInstallValidator.isAcceptable("../evil", field: .category) == false)
    }

    @Test("Surrounding whitespace is trimmed, not treated as a rejection")
    func trimsBeforeValidating() {
        #expect(SkillInstallValidator.problem(with: "  productivity  ", field: .name) == nil)
        #expect(SkillInstallValidator.problem(with: "  a/b  ", field: .category) == nil)
    }

    @Test("Every problem carries a non-empty explanation for the sheet")
    func problemsExplainThemselves() {
        let problems: [SkillInstallValidator.Problem] = [
            .empty, .relativePathComponent, .separatorNotAllowed,
            .mustStartWithLowercaseLetter, .disallowedCharacter(";"), .reservedName("skill"),
        ]
        for problem in problems {
            #expect(!problem.userMessage.isEmpty)
        }
    }

    // MARK: - Skills path containment

    @Test("A path inside the skills dir is accepted; a lexical escape is not")
    func lexicalContainment() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let skillsDir = (root as NSString).appendingPathComponent("skills")
        try FileManager.default.createDirectory(
            atPath: skillsDir, withIntermediateDirectories: true
        )

        let inside = (skillsDir as NSString).appendingPathComponent("local/demo/SKILL.md")
        #expect(SkillsViewModel.skillPathIsContained(inside, skillsDir: skillsDir))
        #expect(SkillsViewModel.skillPathIsContained("/etc/passwd", skillsDir: skillsDir) == false)
        #expect(
            SkillsViewModel.skillPathIsContained(
                skillsDir + "/../../etc/passwd", skillsDir: skillsDir
            ) == false
        )
    }

    /// The fix itself: a skill file that is a SYMLINK pointing outside the
    /// skills root passes the lexical prefix check (its own path really is
    /// under the root) but must be rejected, because `transport.writeFile`
    /// would write through the link.
    @Test("A symlink leading outside the skills dir is rejected")
    func rejectsSymlinkEscape() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let skillsDir = (root as NSString).appendingPathComponent("skills")
        let outsideDir = (root as NSString).appendingPathComponent("outside")
        try fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        let secret = (outsideDir as NSString).appendingPathComponent("auth.json")
        try "{}".write(toFile: secret, atomically: true, encoding: .utf8)

        let link = (skillsDir as NSString).appendingPathComponent("SKILL.md")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: secret)

        // Lexically contained…
        #expect(link.hasPrefix(skillsDir))
        // …but rejected once both sides are symlink-resolved.
        #expect(SkillsViewModel.skillPathIsContained(link, skillsDir: skillsDir) == false)
    }

    /// A symlink that stays inside the root is legitimate and must keep
    /// working — the check rejects escape, not indirection.
    @Test("A symlink that stays inside the skills dir is still accepted")
    func allowsInternalSymlink() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let skillsDir = (root as NSString).appendingPathComponent("skills")
        let real = (skillsDir as NSString).appendingPathComponent("real")
        try fm.createDirectory(atPath: real, withIntermediateDirectories: true)
        let target = (real as NSString).appendingPathComponent("SKILL.md")
        try "# skill".write(toFile: target, atomically: true, encoding: .utf8)

        let link = (skillsDir as NSString).appendingPathComponent("alias.md")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(SkillsViewModel.skillPathIsContained(link, skillsDir: skillsDir))
    }

    /// A not-yet-created file (the editor saving a new file) and a REMOTE
    /// skills tree (nothing local to stat) must both still pass — the
    /// existence gate is exactly what `containedFilePath` would have got
    /// wrong here.
    @Test("A non-existent path and a non-local skills dir still pass")
    func toleratesMissingAndRemotePaths() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let skillsDir = (root as NSString).appendingPathComponent("skills")
        try FileManager.default.createDirectory(
            atPath: skillsDir, withIntermediateDirectories: true
        )
        let newFile = (skillsDir as NSString).appendingPathComponent("local/brand-new/SKILL.md")
        #expect(SkillsViewModel.skillPathIsContained(newFile, skillsDir: skillsDir))

        // Remote-style root that does not exist on this machine.
        let remoteRoot = "/home/someone/.hermes/skills"
        #expect(
            SkillsViewModel.skillPathIsContained(remoteRoot + "/local/demo/SKILL.md",
                                                 skillsDir: remoteRoot)
        )
        #expect(SkillsViewModel.skillPathIsContained("/etc/passwd", skillsDir: remoteRoot) == false)
    }

    private func makeTempDir() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("f5-interact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
