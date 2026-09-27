import Testing
import Foundation
@testable import ScarfCore

/// `ProjectCronAttribution` — which cron jobs belong to which project.
///
/// The case this exists for: two projects installed from the SAME template.
/// Template jobs used to be named `[tmpl:<id>] <name>` only, so each project
/// claimed both installs' jobs (cockpit panel, AGENTS.md block, and archive
/// paused the other project's jobs too). New installs add the project tag.
@Suite struct ProjectCronAttributionTests {

    static let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    @Test func templateJobNameInsertsTheProjectTagAfterTheTemplateTag() {
        let name = ProjectCronAttribution.templateJobName(
            "[tmpl:author/example] nightly", templateId: "author/example", projectID: Self.a
        )
        #expect(name == "[tmpl:author/example] [proj:\(Self.a.uuidString)] nightly")
        // A name without the template tag is left alone.
        #expect(ProjectCronAttribution.templateJobName(
            "plain", templateId: "author/example", projectID: Self.a
        ) == "plain")
    }

    @Test func aTaggedTemplateJobBelongsOnlyToItsOwnProject() {
        let jobA = ProjectCronAttribution.templateJobName(
            "[tmpl:author/example] nightly", templateId: "author/example", projectID: Self.a
        )
        #expect(ProjectCronAttribution.isAttributed(jobName: jobA, projectID: Self.a, templateId: "author/example"))
        #expect(!ProjectCronAttribution.isAttributed(jobName: jobA, projectID: Self.b, templateId: "author/example"))
    }

    @Test func projectTagAndLegacyTemplateTagStillAttribute() {
        #expect(ProjectCronAttribution.isAttributed(
            jobName: "[proj:\(Self.a.uuidString)] refresh", projectID: Self.a, templateId: nil
        ))
        #expect(!ProjectCronAttribution.isAttributed(
            jobName: "[proj:\(Self.a.uuidString)] refresh", projectID: Self.b, templateId: nil
        ))
        // Legacy: no project tag, so the template id is all there is.
        #expect(ProjectCronAttribution.isAttributed(
            jobName: "[tmpl:author/example] nightly", projectID: Self.b, templateId: "author/example"
        ))
        // A template id that is a prefix of another id doesn't match it.
        #expect(!ProjectCronAttribution.isAttributed(
            jobName: "[tmpl:author/example-2] nightly", projectID: Self.b, templateId: "author/example"
        ))
        #expect(!ProjectCronAttribution.isAttributed(
            jobName: "[tmpl:author/example] nightly", projectID: Self.b, templateId: nil
        ))
    }

    /// End to end through the readers: two projects from one template, each
    /// with its own tagged job, plus one legacy job. The record, the AGENTS.md
    /// block's cron list and archive's attribution all agree.
    @Test func twoInstallsOfOneTemplateEachClaimOnlyTheirOwnJobs() throws {
        try ProjectStoreTests.withTempHome { ctx, projectsRoot in
            let dirA = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "a")
            let dirB = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "b")
            let manifest = """
            {"schemaVersion": 1, "id": "author/example", "name": "Example", "version": "1.0.0",
             "description": "x", "contents": {"dashboard": true, "agentsMd": true}}
            """
            try ProjectStoreTests.write(manifest, to: dirA + "/.scarf/manifest.json")
            try ProjectStoreTests.write(manifest, to: dirB + "/.scarf/manifest.json")

            let nameA = ProjectCronAttribution.templateJobName(
                "[tmpl:author/example] nightly", templateId: "author/example", projectID: Self.a
            )
            let nameB = ProjectCronAttribution.templateJobName(
                "[tmpl:author/example] nightly", templateId: "author/example", projectID: Self.b
            )
            try FileManager.default.createDirectory(
                atPath: ctx.paths.home + "/cron", withIntermediateDirectories: true
            )
            func job(_ id: String, _ name: String) -> String {
                """
                {"id": "\(id)", "name": "\(name)", "prompt": "p",
                 "schedule": {"kind": "cron", "expression": "0 0 * * *"},
                 "enabled": true, "state": "scheduled"}
                """
            }
            try ProjectStoreTests.write(
                "{\"jobs\": [\(job("job-a", nameA)), \(job("job-b", nameB)), \(job("job-legacy", "[tmpl:author/example] old"))]}",
                to: ctx.paths.cronJobsJSON
            )

            let entryA = ProjectEntry(name: "A", path: dirA, uuid: Self.a)
            let entryB = ProjectEntry(name: "B", path: dirB, uuid: Self.b)
            let store = ProjectStore(context: ctx)
            #expect(Set(store.derive(from: entryA).cronJobIds) == ["job-a", "job-legacy"])
            #expect(Set(store.derive(from: entryB).cronJobIds) == ["job-b", "job-legacy"])

            let lifecycle = ProjectLifecycleService(context: ctx)
            #expect(Set(lifecycle.runnableCronJobIDs(for: entryA) ?? []) == ["job-a", "job-legacy"])
            #expect(Set(lifecycle.runnableCronJobIDs(for: entryB) ?? []) == ["job-b", "job-legacy"])

            let jobs = try JSONDecoder().decode(
                CronJobsFile.self, from: Data(contentsOf: URL(fileURLWithPath: ctx.paths.cronJobsJSON))
            ).jobs
            let lines = ProjectContextBlock.cronLines(from: jobs, projectId: Self.a, templateId: "author/example")
            #expect(lines.count == 2)
            #expect(lines.contains { $0.contains(nameA) })
            #expect(!lines.contains { $0.contains(nameB) })
        }
    }
}
