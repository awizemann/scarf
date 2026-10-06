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

    /// Every setup form saves through `commitSave`; the event carries the
    /// form's own platform token and the save bar's verdict, not a second
    /// opinion of it.
    @Test("a platform form's save reports platform_configured with the bar's outcome")
    func platformSaveIsReported() async {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let vm = WebhookSetupViewModel(context: Self.scratchContext(), cliRunner: CLILog().runner())
        vm.load()
        await Self.until { !vm.isLoading }
        vm.save()
        await Self.until { vm.message != nil }

        let reported = tracker.captured.filter { $0.name == "platform_configured" }
        #expect(reported.count == 1)
        #expect(reported.first?.props["platform"] == "webhook")
        #expect(reported.first?.props["outcome"] == UsageEvent.Outcome(vm.messageKind).rawValue)
    }

    /// A refused save never reached the host, so it reports nothing.
    @Test("a save refused before it runs reports nothing")
    func refusedSaveIsSilent() async {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let vm = WebhookSetupViewModel(context: Self.scratchContext(), cliRunner: CLILog().runner())
        vm.load()
        await Self.until { !vm.isLoading }
        vm.loadRefusal = "config.yaml could not be read"
        vm.save()
        #expect(tracker.captured.filter { $0.name == "platform_configured" }.isEmpty)
    }

    /// Cron and the Bots section's Routines drive the same view model; only
    /// Cron may report `config_item_changed {area: cron}`, or every routine
    /// would count twice (it reports `bot_routine_action`).
    @Test("a cron create reports config_item_changed; a bot routine create does not")
    func cronCreateIsReportedOnlyFromCron() async {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let cron = CronViewModel(context: .local, mutationRunner: CLILog().runner())
        let cronDone = Flag()
        cron.createJob(schedule: "every 1h", prompt: "p", name: "n", deliver: "", skills: [],
                       script: "", repeatCount: "", onOutcome: { _ in cronDone.value = true })
        await Self.until { cronDone.value }
        #expect(tracker.captured.filter { $0.name == "config_item_changed" }.map(\.props)
                == [["area": "cron", "action": "created", "outcome": "succeeded"]])

        let routineCron = CronViewModel(context: .local, mutationRunner: CLILog().runner())
        let routines = BotRoutinesViewModel(context: .local, botName: "scout", cron: routineCron)
        #expect(!routines.cron.reportsAnalytics)
        let routineDone = Flag()
        routineCron.createJob(schedule: "every 1h", prompt: "p", name: "n", deliver: "", skills: [],
                              script: "", repeatCount: "", onOutcome: { _ in routineDone.value = true })
        await Self.until { routineDone.value }
        #expect(tracker.captured.filter { $0.name == "config_item_changed" }.count == 1,
                "the routine's create must not add a second cron event")
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
    @Test("only connecting → live counts as a Live Voice use")
    func liveVoiceWentLive() {
        #expect(VoiceLiveController.wentLive(from: .connecting, to: .listening))
        #expect(VoiceLiveController.wentLive(from: .connecting, to: .speaking))
        #expect(!VoiceLiveController.wentLive(from: .listening, to: .speaking))
        #expect(!VoiceLiveController.wentLive(from: .connecting, to: .connecting))
    }

    /// `ScarfCore` emits `connect_*{source: window}` through the string
    /// seam; pin its literal to the documented vocabulary.
    @Test("the window source token matches the vocabulary")
    func windowSourceToken() {
        #expect(UsageEvent.ConnectSource.window.rawValue == "window")
        #expect(UsageEvent.ConnectSource.testProbe.rawValue == "test_probe")
    }
}

}
