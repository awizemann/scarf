import Testing
import Foundation
import ScarfCore
@testable import scarf

/// End-to-end coverage for the dogfooding-templates harness.
///
/// Two suites live here:
///
/// 1. `HackerNewsDigestTemplateE2ETests` — exercises the shipped
///    `awizemann/hackernews-digest` bundle the way Scarf will at install
///    time: unpack, parse, validate the manifest + dashboard + cron
///    against the same `ProjectTemplateService` the app uses, then build
///    a `TemplateInstallPlan` and assert the resulting plan would write
///    the right files in the right places. Mirrors
///    `ProjectTemplateExampleTemplateTests.siteStatusCheckerParsesAndPlans`
///    so each shipped template gets the same regression net.
///
/// 2. `ScarfHermesHomeOverrideE2ETests` — proves the `SCARF_HERMES_HOME`
///    env-var override (added in `HermesProfileResolver`) actually steers
///    `ServerContext.local.paths`. This is the seam the Layer-B XCUITest
///    relies on to drive Scarf against an isolated Hermes home; if it
///    silently regresses, UI tests would suddenly start writing into the
///    user's real `~/.hermes`. Running it here keeps that invariant
///    visible from the unit-test target.
@Suite struct HackerNewsDigestTemplateE2ETests {

    /// Parse + plan the shipped HN Digest bundle, assert its shape, and
    /// confirm the cron prompt + dashboard contract are intact.
    @Test func hackernewsDigestParsesAndPlans() throws {
        let bundle = try Self.locateExample(author: "awizemann", name: "hackernews-digest")

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }

        // Manifest shape — mirror the install-time invariants the catalog
        // validator enforces, so this test fails locally before a bad
        // bundle escapes to PR.
        #expect(inspection.manifest.id == "awizemann/hackernews-digest")
        #expect(inspection.manifest.name == "HackerNews Daily Digest")
        #expect(inspection.manifest.schemaVersion == 2)
        #expect(inspection.manifest.contents.dashboard)
        #expect(inspection.manifest.contents.agentsMd)
        #expect(inspection.manifest.contents.cron == 1)
        #expect(inspection.manifest.contents.config == 3)
        #expect(inspection.manifest.contents.skills == nil)
        #expect(inspection.manifest.contents.memory == nil)
        #expect(inspection.cronJobs.count == 1)
        #expect(inspection.cronJobs.first?.name == "Daily HN digest")
        #expect(inspection.cronJobs.first?.schedule == "0 8 * * *")

        // Config schema — three fields with the constraints the README
        // promises. The validator catches missing fields; this catches
        // wrong constraints (e.g. a default that drifts away from the
        // text in README.md, or a maxItems someone bumped without
        // updating the surrounding docs).
        let schema = try #require(inspection.manifest.config)
        #expect(schema.fields.count == 3)
        let topicsField = try #require(schema.field(for: "topics"))
        #expect(topicsField.type == .list)
        #expect(topicsField.itemType == "string")
        #expect(topicsField.required == false)
        #expect(topicsField.maxItems == 20)
        let minScoreField = try #require(schema.field(for: "min_score"))
        #expect(minScoreField.type == .number)
        #expect(minScoreField.minNumber == 1)
        #expect(minScoreField.maxNumber == 1000)
        let maxItemsField = try #require(schema.field(for: "max_items"))
        #expect(maxItemsField.type == .number)
        #expect(maxItemsField.minNumber == 5)
        #expect(maxItemsField.maxNumber == 50)
        #expect(schema.modelRecommendation?.preferred == "claude-haiku-4")

        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: scratch)

        #expect(plan.projectDir.hasSuffix("awizemann-hackernews-digest"))
        #expect(plan.skillsFiles.isEmpty)
        #expect(plan.memoryAppendix == nil)
        #expect(plan.cronJobs.count == 1)
        #expect(plan.configSchema?.fields.count == 3)
        #expect(plan.manifestCachePath?.hasSuffix("/.scarf/manifest.json") == true)

        let destinations = plan.projectFiles.map(\.destinationPath)
        #expect(destinations.contains { $0.hasSuffix("/.scarf/config.json") })
        #expect(destinations.contains { $0.hasSuffix("/.scarf/manifest.json") })
        #expect(destinations.contains { $0.hasSuffix("/.scarf/dashboard.json") })

        // Cron-job name gets the template tag prefix so users can
        // identify + remove it from the Cron sidebar later.
        #expect(plan.cronJobs.first?.name == "[tmpl:awizemann/hackernews-digest] Daily HN digest")

        // The bundled dashboard.json must decode cleanly against the
        // same struct the app renders with — catches drift between
        // template-author conventions and the runtime renderer.
        let dashboardPath = inspection.unpackedDir + "/dashboard.json"
        let dashboardData = try Data(contentsOf: URL(fileURLWithPath: dashboardPath))
        let dashboard = try JSONDecoder().decode(ProjectDashboard.self, from: dashboardData)
        #expect(dashboard.title == "HackerNews Digest")
        #expect(dashboard.theme?.accent == "orange")
        // Three sections: Today's Digest (3 stat widgets), Top Stories
        // (1 list widget), How to Use (1 text widget). No webview —
        // this template intentionally doesn't expose a Site tab.
        #expect(dashboard.sections.count == 3)

        let statsSection = dashboard.sections[0]
        #expect(statsSection.title == "Today's Digest")
        let statTitles = statsSection.widgets.filter { $0.type == "stat" }.map(\.title)
        #expect(statTitles.contains("Top Story Score"))
        #expect(statTitles.contains("Items Tracked"))
        #expect(statTitles.contains("Last Run"))

        // The agent's contract: cron prompt references the four nouns
        // the dashboard + log files depend on. If any reference goes
        // missing, AGENTS.md and the prompt have desynced and the
        // agent will run against stale assumptions.
        let cronPrompt = inspection.cronJobs.first?.prompt ?? ""
        #expect(cronPrompt.contains("config.json"))
        #expect(cronPrompt.contains("min_score"))
        #expect(cronPrompt.contains("max_items"))
        #expect(cronPrompt.contains("topics"))
        #expect(cronPrompt.contains("dashboard.json"))
        #expect(cronPrompt.contains("digest.md"))
        #expect(cronPrompt.contains("hacker-news.firebaseio.com"))
        // {{PROJECT_DIR}} stays unresolved in the bundle — the installer
        // substitutes it at install time. A baked absolute path here
        // would follow every install to every user's machine.
        #expect(cronPrompt.contains("{{PROJECT_DIR}}"))
    }

    nonisolated private static func locateExample(author: String, name: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("templates/\(author)/\(name)/\(name).scarftemplate")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        throw ProjectTemplateError.requiredFileMissing("templates/\(author)/\(name)/\(name).scarftemplate")
    }
}

/// Smoke-tests the SCARF_HERMES_HOME override at the `ServerContext.local`
/// integration point. The unit-level resolver tests live in
/// `HermesProfileResolverOverrideTests`; this exercises the same seam from
/// the surface every Scarf service actually reads — `ServerContext.paths`.
@Suite(.serialized)
struct ScarfHermesHomeOverrideE2ETests {

    private static let envKey = "SCARF_HERMES_HOME"

    @Test func overrideSteersServerContextPaths() throws {
        let snapshot = TestRegistryLock.acquireAndSnapshot()
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer {
            restore(saved)
            TestRegistryLock.restore(snapshot)
        }

        let tmp = NSTemporaryDirectory().appending("scarf-e2e-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        // Sentinel marker so the override is honored. Without this,
        // `HermesProfileResolver.scarfHermesHomeOverride()` ignores the
        // env var to protect the user's real `~/.hermes`.
        try Data().write(to: URL(fileURLWithPath: tmp + "/" + HermesProfileResolver.testHomeMarkerFilename))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        setenv(Self.envKey, tmp, 1)

        // Every derived path in HermesPathSet is computed off `home`, so
        // proving `home` flips is enough to guarantee state.db, config.yaml,
        // sessions/, cron/, scarf/projects.json, et al. all redirect.
        // We assert the registry path explicitly because that's the one
        // most likely to clobber the user's real ~/.hermes if the
        // override regresses.
        let paths = ServerContext.local.paths
        #expect(paths.home == tmp)
        #expect(paths.projectsRegistry == tmp + "/scarf/projects.json")
        #expect(paths.cronJobsJSON == tmp + "/cron/jobs.json")
        #expect(paths.configYAML == tmp + "/config.yaml")
    }

    @Test func overrideUnsetReturnsToProductionHome() {
        let snapshot = TestRegistryLock.acquireAndSnapshot()
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer {
            restore(saved)
            TestRegistryLock.restore(snapshot)
        }

        unsetenv(Self.envKey)
        HermesProfileResolver.invalidateCache()

        // Without the override, `paths.home` resolves to the user's real
        // Hermes home (or the active profile under it). We don't assert
        // an exact path — we'd be encoding the test machine's username —
        // but we do assert the shape: an absolute path ending in
        // `/.hermes` (default profile) or containing `/profiles/`
        // (named profile).
        let paths = ServerContext.local.paths
        #expect(paths.home.hasPrefix("/"))
        #expect(paths.home.hasSuffix("/.hermes") || paths.home.contains("/.hermes/profiles/"))
    }

    private func restore(_ saved: String?) {
        if let saved {
            setenv(Self.envKey, saved, 1)
        } else {
            unsetenv(Self.envKey)
        }
        HermesProfileResolver.invalidateCache()
    }
}
