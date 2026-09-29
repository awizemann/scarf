import Testing
import Foundation
import ScarfCore
@testable import scarf

/// #142 P6: the cockpit's Context panel and cron warning follow the SAME
/// confirmed-capabilities gate as the chat start — the managed block on an
/// unknown or older host, the environment hint (and the "tasks will be
/// Untagged" cron warning) on a confirmed v0.16+ — and switch when the
/// version probe answers after the cockpit opened.
@Suite(.serialized) struct ProjectCockpitEnvironmentHintTests {
    typealias AAE = ChatViewModelAutoAcceptEditsTests

    static let tenant = "scarf:demo"
    static let block = "\(ProjectContextBlock.beginMarker)\nOLD-SCARF-BLOCK\n\(ProjectContextBlock.endMarker)"

    /// Answers whatever `next` holds; lets a test flip the host's version
    /// between probes.
    final class ProbeAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var _caps: HermesCapabilities
        init(_ caps: HermesCapabilities) { _caps = caps }
        var caps: HermesCapabilities {
            get { lock.withLock { _caps } }
            set { lock.withLock { _caps = newValue } }
        }
    }

    /// A project with a Kanban tenant, an old block in AGENTS.md, and one
    /// attributed cron job whose prompt creates tasks without `--tenant`.
    static func fixture() throws -> (home: TempHermesHome, entry: ProjectEntry, jobID: String) {
        let home = try TempHermesHome()
        let root = home.path + "/proj"
        try FileManager.default.createDirectory(atPath: root + "/.scarf", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home.context.paths.scarfDir, withIntermediateDirectories: true)
        try "# Mine\n\n\(block)\n".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let entry = ProjectEntry(name: "Demo", path: root)
        let store = ProjectStore(context: home.context)
        var record = store.derive(from: entry)
        record.board = tenant
        try store.save(record)
        let jobID = "job-1"
        try FileManager.default.createDirectory(
            atPath: (home.context.paths.cronJobsJSON as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let jobs = """
        {"jobs": [
          {"id": "\(jobID)", "name": "\(ProjectCronAttribution.projectTag(record.id)) Nightly triage",
           "prompt": "Run hermes kanban create for each new issue.",
           "schedule": {"kind": "cron", "expression": "0 0 * * *"}, "enabled": true, "state": "scheduled"},
          {"id": "job-2", "name": "\(ProjectCronAttribution.projectTag(record.id)) Tagged",
           "prompt": "Run hermes kanban create --tenant \(tenant) for each new issue.",
           "schedule": {"kind": "cron", "expression": "0 0 * * *"}, "enabled": true, "state": "scheduled"}
        ]}
        """
        try jobs.write(toFile: home.context.paths.cronJobsJSON, atomically: true, encoding: .utf8)
        return (home, entry, jobID)
    }

    @MainActor
    static func store(_ answer: ProbeAnswer, context: ServerContext, suite: String) async -> HermesCapabilitiesStore {
        let cache = HermesVersionCache(
            defaults: UserDefaults(suiteName: suite)!,
            probe: { _ in answer.caps },
            retryDelays: []
        )
        let store = HermesCapabilitiesStore(context: context, cache: cache)
        _ = await store.confirmedCapabilities()
        return store
    }

    /// C1: a host whose version the probe could not confirm shows the block
    /// from the project's files, and no cron warning.
    @Test @MainActor func unknownVersionHostShowsTheBlock() async throws {
        let (home, entry, _) = try Self.fixture()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.cockpit-hint.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = await Self.store(ProbeAnswer(.empty), context: home.context, suite: suite)

        let vm = ProjectCockpitViewModel(context: home.context, project: entry)
        vm.capabilitiesStore = store
        await vm.load()

        #expect(vm.contextIsEnvironmentHint == false)
        #expect(vm.contextBlock?.contains("OLD-SCARF-BLOCK") == true)
        #expect(vm.cronJobs.count == 2)
        #expect(vm.cronTenantFixes.isEmpty, "no warning off the hint path")
    }

    /// No store at all is the same as unknown.
    @Test @MainActor func noCapabilityStoreShowsTheBlock() async throws {
        let (home, entry, _) = try Self.fixture()
        defer { home.cleanup() }
        let vm = ProjectCockpitViewModel(context: home.context, project: entry)
        await vm.load()
        #expect(vm.contextIsEnvironmentHint == false)
        #expect(vm.contextBlock?.contains("OLD-SCARF-BLOCK") == true)
        #expect(vm.cronTenantFixes.isEmpty)
    }

    /// A confirmed v0.16 host shows the hint and flags only the job whose
    /// prompt creates tasks without `--tenant`.
    @Test @MainActor func v016HostShowsTheHintAndWarnsOnTheUntenantedJob() async throws {
        let (home, entry, jobID) = try Self.fixture()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.cockpit-hint.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = await Self.store(
            ProbeAnswer(.parseLine("Hermes Agent v0.16.0 (2026.6.5)")), context: home.context, suite: suite)

        let vm = ProjectCockpitViewModel(context: home.context, project: entry)
        vm.capabilitiesStore = store
        await vm.load()

        #expect(vm.contextIsEnvironmentHint)
        #expect(vm.contextBlock?.contains("OLD-SCARF-BLOCK") == false)
        #expect(vm.contextBlock?.contains(Self.tenant) == true)
        #expect(Array(vm.cronTenantFixes.keys) == [jobID])
        let fix = try #require(vm.cronTenantFixes[jobID])
        #expect(fix.tenant == Self.tenant)
        #expect(fix.suggestedPrompt == "Run hermes kanban create --tenant \(Self.tenant) for each new issue.")
    }

    /// The probe fails when the cockpit opens (block), then a re-detect
    /// confirms v0.16: `capabilitiesChanged()` — what the view's onChange
    /// calls — switches the panel without any file changing. A second call
    /// with nothing new reads nothing.
    @Test @MainActor func aLateConfirmedProbeSwitchesToTheHint() async throws {
        let (home, entry, jobID) = try Self.fixture()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.cockpit-hint.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let answer = ProbeAnswer(.empty)
        let store = await Self.store(answer, context: home.context, suite: suite)

        let vm = ProjectCockpitViewModel(context: home.context, project: entry)
        vm.capabilitiesStore = store
        await vm.load()
        #expect(vm.contextIsEnvironmentHint == false)

        answer.caps = .parseLine("Hermes Agent v0.16.0 (2026.6.5)")
        await store.refresh()
        await vm.capabilitiesChanged()
        #expect(vm.contextIsEnvironmentHint, "the confirmed probe did not switch the panel")
        #expect(vm.contextBlock?.contains("OLD-SCARF-BLOCK") == false)
        #expect(vm.cronTenantFixes[jobID] != nil)

        let loads = vm.facetLoadCount
        await vm.capabilitiesChanged()
        #expect(vm.facetLoadCount == loads, "an unchanged answer re-read every facet")
    }
}
