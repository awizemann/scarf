import Testing
import Foundation
@testable import ScarfCore

/// Coverage for the unified Scarf-managed AGENTS.md block renderer
/// (`ProjectContextBlock.renderManagedBlock` + its `cronLines` /
/// `configFieldsLine` formatters). This is the single rendering source of
/// truth for both the Mac app and ScarfGo (iOS), so the iOS agent now
/// sees the SAME project context the Mac agent does — crucially the
/// project's registered cron jobs, which the old iOS minimal block
/// omitted entirely. See
/// `.memory/architecture/scarfgo-ios-does-not-load-project-context-process-cwd-gap.md`.
@Suite struct ProjectContextBlockManagedTests {

    private let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func cron(
        name: String,
        display: String? = nil,
        expression: String? = nil,
        kind: String = "cron",
        enabled: Bool = true
    ) -> HermesCronJob {
        HermesCronJob(
            id: name,
            name: name,
            prompt: "do work",
            schedule: CronSchedule(kind: kind, display: display, expression: expression),
            enabled: enabled,
            state: "active"
        )
    }

    // MARK: - cronLines (filtering + formatting)

    @Test func cronLinesIncludeOnlyProjectAndTemplateTaggedJobs() {
        let jobs = [
            cron(name: "[proj:\(projectId.uuidString)] nightly digest", display: "0 0 * * *"),
            cron(name: "[tmpl:author/example] weekly report", display: "0 9 * * 1"),
            cron(name: "unrelated global job", display: "* * * * *"),
            cron(name: "[proj:99999999-0000-0000-0000-000000000000] other project", display: "0 0 * * *"),
        ]
        let lines = ProjectContextBlock.cronLines(from: jobs, projectId: projectId, templateId: "author/example")
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("nightly digest") })
        #expect(lines.contains { $0.contains("weekly report") })
        #expect(!lines.contains { $0.contains("unrelated global job") })
        #expect(!lines.contains { $0.contains("other project") })
    }

    @Test func cronLineFormatsScheduleAndPausedState() {
        let lines = ProjectContextBlock.cronLines(
            from: [cron(name: "[proj:\(projectId.uuidString)] backup", display: "every day at 3am", enabled: false)],
            projectId: projectId,
            templateId: nil
        )
        #expect(lines == ["`[proj:\(projectId.uuidString)] backup` — schedule `every day at 3am`, currently paused"])
    }

    @Test func cronLineSchedulePrefersDisplayThenExpressionThenKind() {
        let exprOnly = ProjectContextBlock.cronLines(
            from: [cron(name: "[proj:\(projectId.uuidString)] a", display: nil, expression: "*/5 * * * *")],
            projectId: projectId, templateId: nil
        )
        #expect(exprOnly[0].contains("schedule `*/5 * * * *`"))

        let kindOnly = ProjectContextBlock.cronLines(
            from: [cron(name: "[proj:\(projectId.uuidString)] b", display: nil, expression: nil, kind: "interval")],
            projectId: projectId, templateId: nil
        )
        #expect(kindOnly[0].contains("schedule `interval`"))
    }

    @Test func cronLinesEmptyWhenNothingAttributed() {
        let lines = ProjectContextBlock.cronLines(
            from: [cron(name: "global only", display: "* * * * *")],
            projectId: projectId, templateId: nil
        )
        #expect(lines.isEmpty)
    }

    // MARK: - configFieldsLine (secret-safe)

    @Test func configFieldsLineRendersNoneWhenEmpty() {
        #expect(ProjectContextBlock.configFieldsLine(fields: []) == "(none)")
    }

    @Test func configFieldsLineTagsSecretsByNameOnly() {
        let line = ProjectContextBlock.configFieldsLine(fields: [
            (key: "site_url", isSecret: false),
            (key: "api_token", isSecret: true),
        ])
        #expect(line == "`site_url`, `api_token` (secret — name only, value stored in Keychain)")
    }

    // MARK: - renderManagedBlock (full block)

    @Test func managedBlockSurfacesCronJobsToTheAgent() {
        let block = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Self-Learning Agent",
            projectPath: "/srv/sla",
            configFieldsLine: "(none)",
            cronLines: ProjectContextBlock.cronLines(
                from: [cron(name: "[proj:\(projectId.uuidString)] retrain", display: "0 2 * * *")],
                projectId: projectId, templateId: nil
            )
        ))
        #expect(block.contains("**Registered cron jobs:**"))
        #expect(block.contains("retrain"))
        #expect(block.contains("schedule `0 2 * * *`"))
        // Identity + markers intact.
        #expect(block.hasPrefix(ProjectContextBlock.beginMarker))
        #expect(block.hasSuffix(ProjectContextBlock.endMarker))
        #expect(block.contains("\"Self-Learning Agent\""))
    }

    @Test func managedBlockStatesNoneWhenNoCron() {
        let block = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Bare", projectPath: "/srv/bare", configFieldsLine: "(none)"
        ))
        #expect(block.contains("**Registered cron jobs:** (none attributed to this project)"))
        #expect(!block.contains("**Template:**"))
    }

    @Test func managedBlockIncludesTemplateKanbanAndLockWhenPresent() {
        let block = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Full",
            projectPath: "/srv/full",
            templateId: "author/example",
            templateVersion: "1.2.3",
            configFieldsLine: "`token` (secret — name only, value stored in Keychain)",
            kanbanTenant: "full-board",
            lockFilePresent: true
        ))
        #expect(block.contains("**Template:** `author/example` v1.2.3"))
        #expect(block.contains("**Kanban tenant:** `full-board`"))
        #expect(block.contains("--tenant full-board"))
        #expect(block.contains("**Uninstall manifest:**"))
        // Static platform reference is always present.
        #expect(block.contains("### Scarf platform reference"))
    }

    /// The platform reference points the agent at the `scarf-projects`
    /// tools before it points it at any file. An agent that reads this
    /// block and still hand-appends to the registry is the 2026-09-02
    /// corruption again, so the steer is pinned here rather than left to
    /// the skill alone — the block is injected on every project chat,
    /// the skill only when it activates.
    @Test func managedBlockPrefersTheProjectToolsOverHandEditing() {
        let block = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Tools", projectPath: "/srv/tools", configFieldsLine: "(none)"
        ))
        #expect(block.contains("`scarf-projects`"))
        for tool in [
            "project_list", "project_get", "project_register",
            "project_update_dashboard", "project_add_slash_command", "project_validate",
        ] {
            #expect(block.contains(tool), "platform reference should name \(tool)")
        }
        #expect(block.contains("PREFER its tools"))
        // The skill lives under the `scarf/` category folder as of
        // v2.10.1; the block used to advertise the pre-migration flat
        // path, which resolves to nothing on a current install.
        #expect(block.contains("~/.hermes/skills/scarf/scarf-template-author/SKILL.md"))
        #expect(!block.contains("~/.hermes/skills/scarf-template-author/SKILL.md"))
    }

    @Test func managedBlockIsPureAndIdempotent() {
        let input = ProjectContextBlock.ManagedBlockInput(
            projectName: "Idem", projectPath: "/srv/idem", configFieldsLine: "(none)",
            slashCommandNames: ["b", "a"]
        )
        #expect(ProjectContextBlock.renderManagedBlock(input) == ProjectContextBlock.renderManagedBlock(input))
    }
}
