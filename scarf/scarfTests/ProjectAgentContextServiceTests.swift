import Testing
import Foundation
@testable import scarf

/// Exercises the Scarf-managed AGENTS.md marker block logic added in
/// v2.3. Tests operate on isolated temp directories — no dependency
/// on ~/.hermes contents, no cross-suite lock needed.
@Suite struct ProjectAgentContextServiceTests {

    // MARK: - applyBlock pure-text transform

    @Test func applyBlockPrependsWhenNoMarkersPresent() {
        let existing = "# My Template\n\nSome instructions.\n"
        let block = "<!-- scarf-project:begin -->\nhello\n<!-- scarf-project:end -->"
        let result = ProjectAgentContextService.applyBlock(block: block, to: existing)
        #expect(result.hasPrefix("<!-- scarf-project:begin -->"))
        #expect(result.contains("<!-- scarf-project:end -->"))
        #expect(result.contains("# My Template"))
        #expect(result.contains("Some instructions."))
        // Exactly one blank line between block and original content.
        #expect(result.contains("<!-- scarf-project:end -->\n\n# My Template"))
    }

    @Test func applyBlockWritesFreshFileWhenEmpty() {
        let block = "<!-- scarf-project:begin -->\nhello\n<!-- scarf-project:end -->"
        let result = ProjectAgentContextService.applyBlock(block: block, to: "")
        // Empty input → just the block + trailing newline; no weird
        // leading whitespace.
        #expect(result == block + "\n")
    }

    @Test func applyBlockReplacesExistingMarkerRegion() {
        let existing = """
        <!-- scarf-project:begin -->
        old content line 1
        old content line 2
        <!-- scarf-project:end -->

        # Template docs preserved

        Template behavior.
        """
        let newBlock = "<!-- scarf-project:begin -->\nfresh content\n<!-- scarf-project:end -->"
        let result = ProjectAgentContextService.applyBlock(block: newBlock, to: existing)

        #expect(result.contains("fresh content"))
        // Old content is gone.
        #expect(!result.contains("old content line 1"))
        #expect(!result.contains("old content line 2"))
        // Template content outside markers is preserved.
        #expect(result.contains("# Template docs preserved"))
        #expect(result.contains("Template behavior."))
    }

    @Test func applyBlockIsIdempotent() {
        let existing = "# Project\n\nContent.\n"
        let block = "<!-- scarf-project:begin -->\nv1\n<!-- scarf-project:end -->"
        let once = ProjectAgentContextService.applyBlock(block: block, to: existing)
        let twice = ProjectAgentContextService.applyBlock(block: block, to: once)
        #expect(once == twice)
    }

    @Test func applyBlockOrphanedBeginMarkerFallsBackToPrepend() {
        // Stray begin with no end: treat as "no well-formed block,"
        // prepend. Leaves the orphan in place — it was probably
        // hand-typed, not a corrupt Scarf write. Conservative.
        let existing = "<!-- scarf-project:begin -->\nstray text with no end marker\n"
        let block = "<!-- scarf-project:begin -->\nnew\n<!-- scarf-project:end -->"
        let result = ProjectAgentContextService.applyBlock(block: block, to: existing)
        #expect(result.hasPrefix("<!-- scarf-project:begin -->\nnew\n<!-- scarf-project:end -->"))
        #expect(result.contains("stray text with no end marker"))
    }

    // MARK: - renderBlock content

    @Test func renderBlockIncludesProjectIdentity() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = ProjectEntry(name: "My Project", path: dir)
        let svc = ProjectAgentContextService(context: .local)
        let block = svc.renderBlock(for: project)

        #expect(block.contains(ProjectAgentContextService.beginMarker))
        #expect(block.contains(ProjectAgentContextService.endMarker))
        #expect(block.contains("\"My Project\""))
        #expect(block.contains(dir))
        #expect(block.contains("dashboard.json"))
    }

    @Test func renderBlockOmitsTemplateSectionForBareProject() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = ProjectEntry(name: "Bare", path: dir)
        let svc = ProjectAgentContextService(context: .local)
        let block = svc.renderBlock(for: project)
        #expect(!block.contains("**Template:**"))
        #expect(block.contains("**Configuration fields:** (none)"))
    }

    @Test func renderBlockIncludesTemplateWhenManifestPresent() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let scarfDir = dir + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)
        // Minimal valid v1 manifest — no config schema.
        let manifest = """
        {
          "schemaVersion": 1,
          "id": "author/example",
          "name": "Example",
          "version": "1.2.3",
          "description": "…",
          "contents": { "dashboard": true, "agentsMd": true }
        }
        """
        try manifest.data(using: .utf8)!.write(to: URL(fileURLWithPath: scarfDir + "/manifest.json"))

        let project = ProjectEntry(name: "Example", path: dir)
        let svc = ProjectAgentContextService(context: .local)
        let block = svc.renderBlock(for: project)
        #expect(block.contains("**Template:** `author/example` v1.2.3"))
    }

    @Test func renderBlockListsConfigFieldNamesNotValues() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let scarfDir = dir + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)
        // Schema-bearing manifest with one string field and one secret.
        let manifest = """
        {
          "schemaVersion": 2,
          "id": "x/y",
          "name": "Y",
          "version": "1.0.0",
          "description": "…",
          "contents": { "dashboard": true, "agentsMd": true, "config": 2 },
          "config": {
            "schema": [
              { "key": "site_url", "type": "string", "label": "Site URL", "required": true },
              { "key": "api_token", "type": "secret", "label": "API Token", "required": true }
            ]
          }
        }
        """
        try manifest.data(using: .utf8)!.write(to: URL(fileURLWithPath: scarfDir + "/manifest.json"))

        // A config.json with a "secret" VALUE — the block must NOT
        // echo this value. If it does, secrets leak into an agent-
        // readable file, which is exactly the thing to avoid.
        let configJSON = """
        {
          "schemaVersion": 2,
          "templateId": "x/y",
          "values": {
            "site_url": { "type": "string", "value": "https://example.com" },
            "api_token": { "type": "keychainRef", "uri": "keychain://com.scarf.template.x-y/api_token:abc123" }
          },
          "updatedAt": "2026-04-24T00:00:00Z"
        }
        """
        try configJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: scarfDir + "/config.json"))

        let project = ProjectEntry(name: "Y", path: dir)
        let svc = ProjectAgentContextService(context: .local)
        let block = svc.renderBlock(for: project)

        // Field names present with type hints.
        #expect(block.contains("`site_url`"))
        #expect(block.contains("`api_token`"))
        #expect(block.contains("(secret — name only, value stored in Keychain)"))
        // CRITICAL: no VALUES appear — not the site URL, not the
        // keychain ref. The block is safe to drop into an agent
        // context.
        #expect(!block.contains("https://example.com"))
        #expect(!block.contains("keychain://"))
        #expect(!block.contains("abc123"))
    }

    // MARK: - refresh end-to-end (temp dir on local filesystem)

    @Test func refreshCreatesAGENTSMdWhenMissing() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = ProjectEntry(name: "Fresh", path: dir)

        try ProjectAgentContextService(context: .local).refresh(for: project)

        let agentsMd = dir + "/AGENTS.md"
        #expect(FileManager.default.fileExists(atPath: agentsMd))
        let contents = try String(contentsOf: URL(fileURLWithPath: agentsMd))
        #expect(contents.contains(ProjectAgentContextService.beginMarker))
        #expect(contents.contains(ProjectAgentContextService.endMarker))
        #expect(contents.contains("\"Fresh\""))
    }

    @Test func refreshPreservesUserContentBelow() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let agentsMd = dir + "/AGENTS.md"
        let userContent = "# Template\n\nDo the thing.\n"
        try userContent.data(using: .utf8)!.write(to: URL(fileURLWithPath: agentsMd))

        let project = ProjectEntry(name: "Preserved", path: dir)
        try ProjectAgentContextService(context: .local).refresh(for: project)

        let after = try String(contentsOf: URL(fileURLWithPath: agentsMd))
        #expect(after.contains(ProjectAgentContextService.beginMarker))
        #expect(after.contains("# Template"))
        #expect(after.contains("Do the thing."))
        // Block goes FIRST; user content follows.
        let beginIdx = after.range(of: ProjectAgentContextService.beginMarker)!.lowerBound
        let userIdx = after.range(of: "# Template")!.lowerBound
        #expect(beginIdx < userIdx)
    }

    @Test func refreshIsFullyIdempotent() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = ProjectEntry(name: "Twice", path: dir)
        let svc = ProjectAgentContextService(context: .local)
        try svc.refresh(for: project)
        let first = try Data(contentsOf: URL(fileURLWithPath: dir + "/AGENTS.md"))
        try svc.refresh(for: project)
        let second = try Data(contentsOf: URL(fileURLWithPath: dir + "/AGENTS.md"))
        #expect(first == second)
    }

    @Test func refreshRewritesStaleBlock() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let agentsMd = dir + "/AGENTS.md"
        // Pre-seed a stale Scarf block with a different project name
        // and a user section below.
        let seed = """
        <!-- scarf-project:begin -->
        Old stale content — project was called "Something Else".
        <!-- scarf-project:end -->

        # Template
        """
        try seed.data(using: .utf8)!.write(to: URL(fileURLWithPath: agentsMd))

        let project = ProjectEntry(name: "Current Name", path: dir)
        try ProjectAgentContextService(context: .local).refresh(for: project)

        let after = try String(contentsOf: URL(fileURLWithPath: agentsMd))
        #expect(after.contains("\"Current Name\""))
        #expect(!after.contains("Something Else"))
        #expect(after.contains("# Template"))
    }

    // MARK: - Helpers

    nonisolated static func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-project-context-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
