import Testing
import Foundation
@testable import ScarfCore

/// v2.5 portable project slash commands. Service is transport-based so
/// these tests use a `LocalTransport`-backed `ServerContext` rooted at a
/// tmp directory (same trick `M5FeatureVMTests` uses for cron / memory).
///
/// The factory-touching tests live in M5 (the canonical `.serialized`
/// suite) — these tests don't install a custom factory, they just rely
/// on `ServerContext` defaulting to LocalTransport for `.local` kinds,
/// so they're safe to run in parallel with everything else.
@Suite struct M9SlashCommandTests {

    // MARK: - Name validation

    @Test func nameValidationAcceptsLowercaseLettersDigitsHyphens() {
        #expect(ProjectSlashCommand.validateName("review") == nil)
        #expect(ProjectSlashCommand.validateName("deploy-staging") == nil)
        #expect(ProjectSlashCommand.validateName("step1") == nil)
    }

    @Test func nameValidationRejectsBadShapes() {
        #expect(ProjectSlashCommand.validateName("") != nil)
        #expect(ProjectSlashCommand.validateName("Review") != nil)       // uppercase
        #expect(ProjectSlashCommand.validateName("1leading") != nil)     // leading digit
        #expect(ProjectSlashCommand.validateName("with space") != nil)
        #expect(ProjectSlashCommand.validateName("under_score") != nil)  // underscore not allowed
        #expect(ProjectSlashCommand.validateName(String(repeating: "a", count: 65)) != nil)
    }

    // MARK: - Frontmatter parsing

    @Test func parseExtractsRequiredFields() throws {
        let raw = """
        ---
        name: review
        description: Code-review the current branch
        ---
        Review {{argument}}.
        """
        let cmd = try #require(
            ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/review.md")
        )
        #expect(cmd.name == "review")
        #expect(cmd.description == "Code-review the current branch")
        #expect(cmd.body.contains("Review {{argument}}."))
    }

    @Test func parseExtractsOptionalFields() throws {
        let raw = """
        ---
        name: deploy
        description: Deploy
        argumentHint: <env>
        model: claude-sonnet-4.5
        tags:
          - ops
          - deploy
        ---
        Deploy to {{argument}}.
        """
        let cmd = try #require(
            ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/deploy.md")
        )
        #expect(cmd.argumentHint == "<env>")
        #expect(cmd.model == "claude-sonnet-4.5")
        #expect(cmd.tags == ["ops", "deploy"])
    }

    @Test func parseRejectsMissingFrontmatter() {
        let raw = "Just a body, no frontmatter.\n"
        #expect(ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/x.md") == nil)
    }

    @Test func parseRejectsMissingRequiredFields() {
        let raw = """
        ---
        name: only
        ---
        Body.
        """
        // Missing description → nil.
        #expect(ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/x.md") == nil)
    }

    // MARK: - Argument substitution

    @Test func expandSubstitutesPlainArgument() {
        let cmd = ProjectSlashCommand(
            name: "x",
            description: "x",
            body: "Hello {{argument}}, how are you?",
            sourcePath: ""
        )
        let svc = ProjectSlashCommandService(context: .local)
        let result = svc.expand(cmd, withArgument: "world")
        #expect(result.contains("Hello world, how are you?"))
        #expect(result.hasPrefix("<!-- scarf-slash:x -->\n"))
    }

    @Test func expandUsesDefaultWhenArgumentEmpty() {
        let cmd = ProjectSlashCommand(
            name: "x",
            description: "x",
            body: "Focus: {{argument | default: \"general\"}}.",
            sourcePath: ""
        )
        let svc = ProjectSlashCommandService(context: .local)
        let empty = svc.expand(cmd, withArgument: "")
        #expect(empty.contains("Focus: general."))
        let provided = svc.expand(cmd, withArgument: "performance")
        #expect(provided.contains("Focus: performance."))
    }

    @Test func expandReplacesMultipleOccurrences() {
        let cmd = ProjectSlashCommand(
            name: "x",
            description: "x",
            body: "{{argument}} and {{argument}} again.",
            sourcePath: ""
        )
        let svc = ProjectSlashCommandService(context: .local)
        let result = svc.expand(cmd, withArgument: "foo")
        #expect(result.contains("foo and foo again."))
    }

    // MARK: - Round-trip on disk

    @Test func saveAndLoadRoundTripPreservesFields() async throws {
        let tmp = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let ctx = ServerContext.local
        let svc = ProjectSlashCommandService(context: ctx)
        let original = ProjectSlashCommand(
            name: "review",
            description: "Code-review the branch",
            argumentHint: "<focus>",
            model: "claude-sonnet-4.5",
            tags: ["code-review"],
            body: "Review {{argument}}.\n",
            sourcePath: ""
        )
        try svc.save(original, at: tmp)

        let loaded = svc.loadCommands(at: tmp)
        #expect(loaded.count == 1)
        let r = try #require(loaded.first)
        #expect(r.name == "review")
        #expect(r.description == "Code-review the branch")
        #expect(r.argumentHint == "<focus>")
        #expect(r.model == "claude-sonnet-4.5")
        #expect(r.tags == ["code-review"])
        #expect(r.body.contains("Review {{argument}}."))
    }

    @Test func loadCommandsHandlesMissingDirGracefully() {
        let tmp = NSTemporaryDirectory() + "scarf-slash-missing-\(UUID().uuidString)"
        let svc = ProjectSlashCommandService(context: .local)
        // Dir doesn't exist → empty list, no throw.
        #expect(svc.loadCommands(at: tmp) == [])
    }

    @Test func deleteRemovesFileAndIsIdempotent() async throws {
        let tmp = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let svc = ProjectSlashCommandService(context: .local)
        let cmd = ProjectSlashCommand(
            name: "tmp", description: "x", body: "x\n", sourcePath: ""
        )
        try svc.save(cmd, at: tmp)
        #expect(svc.loadCommands(at: tmp).count == 1)

        try svc.delete(named: "tmp", at: tmp)
        #expect(svc.loadCommands(at: tmp).isEmpty)
        // Deleting something already gone is a no-op.
        try svc.delete(named: "tmp", at: tmp)
    }

    @Test func saveRejectsInvalidName() async throws {
        let tmp = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let svc = ProjectSlashCommandService(context: .local)
        let bad = ProjectSlashCommand(
            name: "BadName", description: "x", body: "x\n", sourcePath: ""
        )
        do {
            try svc.save(bad, at: tmp)
            Issue.record("expected save to throw on uppercase name")
        } catch {
            // Expected
        }
    }

    // MARK: - ProjectContextBlock surfacing

    @Test func contextBlockListsSlashCommandsWhenPresent() {
        let block = ProjectContextBlock.renderMinimalBlock(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            slashCommandNames: ["review", "deploy-staging"]
        )
        #expect(block.contains("Project slash commands:"))
        #expect(block.contains("`/review`"))
        #expect(block.contains("`/deploy-staging`"))
        // Marker contract held: the block still has begin/end markers.
        #expect(block.hasPrefix("<!-- scarf-project:begin -->"))
        #expect(block.hasSuffix("<!-- scarf-project:end -->"))
    }

    @Test func contextBlockOmitsSlashCommandLineWhenEmpty() {
        let none = ProjectContextBlock.renderMinimalBlock(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            slashCommandNames: nil
        )
        #expect(!none.contains("Project slash commands:"))
        let emptyArr = ProjectContextBlock.renderMinimalBlock(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            slashCommandNames: []
        )
        #expect(!emptyArr.contains("Project slash commands:"))
    }

    @Test func contextBlockIsIdempotent() {
        let a = ProjectContextBlock.renderMinimalBlock(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            slashCommandNames: ["b", "a"] // unsorted on input
        )
        let b = ProjectContextBlock.renderMinimalBlock(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            slashCommandNames: ["a", "b"] // pre-sorted
        )
        // Output is sorted internally — both inputs render identically.
        #expect(a == b)
    }

    // MARK: - Helpers

    static func makeTempProject() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-slash-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return dir
    }
}
