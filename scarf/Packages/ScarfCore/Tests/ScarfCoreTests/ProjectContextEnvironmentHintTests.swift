import Testing
import Foundation
@testable import ScarfCore

/// Coverage for `ProjectContextBlock.renderEnvironmentHint` — the short
/// `HERMES_ENVIRONMENT_HINT` text that replaces the AGENTS.md managed block
/// on Hermes >= v0.16 (#142).
@Suite struct ProjectContextEnvironmentHintTests {

    private let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func input(
        tenant: String? = nil,
        projectId: UUID? = nil,
        configFieldsLine: String = "(none)"
    ) -> ProjectContextBlock.ManagedBlockInput {
        ProjectContextBlock.ManagedBlockInput(
            projectName: "Site Watch",
            projectPath: "/Users/me/Projects/site watch",
            templateId: "awizemann/site-status-checker",
            templateVersion: "1.2.0",
            configFieldsLine: configFieldsLine,
            cronLines: ["`[proj:x] nightly` — schedule `0 0 * * *`, currently enabled"],
            slashCommandNames: ["digest"],
            kanbanTenant: tenant,
            lockFilePresent: true,
            projectId: projectId
        )
    }

    @Test func fullHintNamesProjectTenantAndCronRule() {
        let hint = ProjectContextBlock.renderEnvironmentHint(input(tenant: "site-watch", projectId: projectId))
        #expect(hint.contains("**\"Site Watch\"**"))
        #expect(hint.contains("`/Users/me/Projects/site watch`"))
        #expect(hint.contains("pass `--tenant site-watch` to `hermes kanban create`"))
        #expect(hint.contains("`[proj:11111111-2222-3333-4444-555555555555] `"))
        #expect(hint.contains("--workdir \"/Users/me/Projects/site watch\""))
        #expect(hint.contains("<!-- scarf-slash:<name> -->"))
        #expect(hint.contains("`scarf-template-author`"))
        #expect(hint.contains("`scarf-projects`"))
        #expect(hint.contains("Never write a secret value to disk"))
        let lineCount = hint.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect((8...12).contains(lineCount))
    }

    @Test func tenantAndCronLinesAreOmittedWhenAbsent() {
        let hint = ProjectContextBlock.renderEnvironmentHint(input())
        #expect(!hint.contains("--tenant"))
        #expect(!hint.contains("[proj:"))
        #expect(!hint.contains("--workdir"))
        // An empty tenant is absent, not rendered as a bare `--tenant `.
        #expect(!ProjectContextBlock.renderEnvironmentHint(input(tenant: "")).contains("--tenant"))
        // The unconditional rules survive.
        #expect(hint.contains("<!-- scarf-slash:<name> -->"))
        #expect(hint.contains("`scarf-template-author`"))
    }

    /// The hint is not a file and must not look like one: no managed-block
    /// markers, and none of the per-project state the block carried
    /// (config field names, cron job list, template id, slash names).
    @Test func hintCarriesNoMarkersConfigOrCronState() {
        let hint = ProjectContextBlock.renderEnvironmentHint(input(
            tenant: "t", projectId: projectId,
            configFieldsLine: "`api_token` (secret — name only, value stored in Keychain)"
        ))
        #expect(!hint.contains(ProjectContextBlock.beginMarker))
        #expect(!hint.contains(ProjectContextBlock.endMarker))
        #expect(!hint.contains("scarf-project:"))
        #expect(!hint.contains("api_token"))
        #expect(!hint.contains("nightly"))
        #expect(!hint.contains("site-status-checker"))
        #expect(!hint.contains("/digest"))
    }

    /// The hint lands in Hermes's cached system prompt, so identical inputs
    /// must produce identical bytes.
    @Test func hintIsByteStable() {
        let a = ProjectContextBlock.renderEnvironmentHint(input(tenant: "t", projectId: projectId))
        let b = ProjectContextBlock.renderEnvironmentHint(input(tenant: "t", projectId: projectId))
        #expect(Data(a.utf8) == Data(b.utf8))
        #expect(!a.hasSuffix("\n"))
    }
}
