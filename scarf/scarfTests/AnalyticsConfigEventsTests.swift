import Foundation
import ScarfCore
import Testing
@testable import scarf

/// The 3.6 setup/configuration events, driven through their real doors.
///
/// Nested in the serialized connection-events tree: these install a
/// `CapturingUsageTracker` into the process-wide seam.
extension AnalyticsConnectionEventsTests {

@Suite("Analytics configuration events", .serialized)
@MainActor
struct AnalyticsConfigEventsTests {
    private typealias CLILog = MainActorBlockingWritesP11Tests.CLILog

    @MainActor private final class Flag { var value = false }

    private static func until(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-config-events-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return ServerContext.local(home: home)
    }

    /// Every setup form saves through `commitSave` (driven here through the
    /// Feishu form); the event carries the
    /// form's own platform token and the save bar's verdict, not a second
    /// opinion of it.
    @Test("a platform form's save reports platform_configured with the bar's outcome")
    func platformSaveIsReported() async {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let vm = FeishuSetupViewModel(context: Self.scratchContext(), cliRunner: CLILog().runner())
        vm.load()
        await Self.until { !vm.isLoading }
        vm.save()
        #expect(vm.isSaving)
        // `isSaving` clears in the same callback that records the event.
        await Self.until { !vm.isSaving }

        // Filtered to this form's token: the recorder is process-wide, and
        // suites outside the serialized tree save other platforms' forms
        // concurrently. No other test drives the Feishu form.
        let reported = tracker.captured.filter {
            $0.name == "platform_configured" && $0.props["platform"] == "feishu"
        }
        #expect(reported.count == 1)
        #expect(reported.first?.props["outcome"] == UsageEvent.Outcome(vm.messageKind).rawValue)
    }

    /// A refused save never reached the host, so it reports nothing.
    @Test("a save refused before it runs reports nothing")
    func refusedSaveIsSilent() async {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let vm = FeishuSetupViewModel(context: Self.scratchContext(), cliRunner: CLILog().runner())
        vm.load()
        await Self.until { !vm.isLoading }
        vm.loadRefusal = "config.yaml could not be read"
        vm.save()
        // The refusal is synchronous: a save that ran would already show
        // `isSaving` here (and record later, from its callback).
        #expect(!vm.isSaving, "a refused save must not start")
        #expect(tracker.captured.filter {
            $0.name == "platform_configured" && $0.props["platform"] == "feishu"
        }.isEmpty)
    }

    /// Cron and the Bots section's Routines drive the same view model; only
    /// Cron may report `config_item_changed {area: cron}`, or every routine
    /// would count twice (it reports `bot_routine_action`).
    @Test("a cron create reports config_item_changed; a bot routine create does not")
    func cronCreateIsReportedOnlyFromCron() async {
        // Captured through the view model's own seam, not the process-wide
        // recorder: other suites drive cron verbs concurrently.
        final class Box { var events: [UsageEvent] = [] }

        let cronEvents = Box()
        let cron = CronViewModel(context: .local, mutationRunner: CLILog().runner())
        cron.recordAnalytics = { cronEvents.events.append($0) }
        let cronDone = Flag()
        cron.createJob(schedule: "every 1h", prompt: "p", name: "n", deliver: "", skills: [],
                       script: "", repeatCount: "", onOutcome: { _ in cronDone.value = true })
        await Self.until { cronDone.value }
        await Self.until { !cronEvents.events.isEmpty }
        #expect(cronEvents.events.map(\.name) == ["config_item_changed"])
        #expect(cronEvents.events.first?.props.mapValues(\.usageEventToken)
                == ["area": "cron", "action": "created", "outcome": "succeeded"])

        let routineEvents = Box()
        let routineCron = CronViewModel(context: .local, mutationRunner: CLILog().runner())
        routineCron.recordAnalytics = { routineEvents.events.append($0) }
        let routines = BotRoutinesViewModel(context: .local, botName: "scout", cron: routineCron)
        #expect(!routines.cron.reportsAnalytics)
        let routineDone = Flag()
        routineCron.createJob(schedule: "every 1h", prompt: "p", name: "n", deliver: "", skills: [],
                              script: "", repeatCount: "", onOutcome: { _ in routineDone.value = true })
        await Self.until { routineDone.value }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(routineEvents.events.isEmpty, "a routine's create must not report a cron event")
    }

    @Test("run-now verdicts map to outcomes without claiming what wasn't proven")
    func runNowOutcome() {
        #expect(CronViewModel.analyticsOutcome(.ran) == .succeeded)
        #expect(CronViewModel.analyticsOutcome(.started) == .succeeded)
        #expect(CronViewModel.analyticsOutcome(.stillRunning) == .unconfirmed)
        #expect(CronViewModel.analyticsOutcome(.alreadyRunning("x")) == .unconfirmed)
        #expect(CronViewModel.analyticsOutcome(.refused("x")) == .failed)
        #expect(CronViewModel.analyticsOutcome(.failed("x")) == .failed)
    }

    @Test("the save bar's three kinds map one-to-one onto the outcome tokens")
    func outcomeFromKind() {
        #expect(UsageEvent.Outcome(OutcomeMessage.Kind.success) == .succeeded)
        #expect(UsageEvent.Outcome(OutcomeMessage.Kind.unconfirmed) == .unconfirmed)
        #expect(UsageEvent.Outcome(OutcomeMessage.Kind.failure) == .failed)
    }

    /// `voice_used {kind: live}` is a session that actually went live — not
    /// a start that failed or was cancelled while connecting.
    @Test("only a step from before-live into live counts as a Live Voice use")
    func liveVoiceWentLive() {
        #expect(VoiceLiveController.wentLive(from: .connecting, to: .listening))
        // The chained engine goes live inside one synchronous start().
        #expect(VoiceLiveController.wentLive(from: .idle, to: .listening))
        #expect(!VoiceLiveController.wentLive(from: .idle, to: .connecting))
        #expect(VoiceLiveController.wentLive(from: .connecting, to: .speaking))
        #expect(!VoiceLiveController.wentLive(from: .listening, to: .speaking))
        #expect(!VoiceLiveController.wentLive(from: .connecting, to: .connecting))
    }

}

}
