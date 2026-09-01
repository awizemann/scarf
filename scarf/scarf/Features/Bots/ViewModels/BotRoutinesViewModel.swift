import Foundation
import ScarfCore
import os

/// Per-bot Routines — the `automation` slot's cron half. Reuses W7's
/// `CronViewModel` wholesale (list load, pause/resume/run-now, terminal-state
/// + capability gates, delete, create) rather than reforking any of its CLI
/// argv or capability logic; this type's only job is to FILTER that shared
/// job list down to the one bot and to compose the `[bot:<name>]` name
/// prefix on create.
@Observable
@MainActor
final class BotRoutinesViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "BotRoutinesViewModel")

    /// The shared cron view model. Exposed (not just wrapped) so a future
    /// caller can still reach the full W7 surface (run history, incidents,
    /// doctor) without this type re-exposing every method.
    let cron: CronViewModel
    let botName: String

    /// Test seam: production always builds a real `CronViewModel` against
    /// the bot's own context; tests inject one already wired to a fake
    /// `HermesFileService`... which isn't possible either, so tests instead
    /// exercise `BotRoutinePrefix` and argv composition directly (see
    /// `createRoutineArguments`). This initializer still accepts an
    /// injected `CronViewModel` so a caller sharing one instance across
    /// several bots (unusual, but not precluded) can do so.
    init(context: ServerContext, botName: String, cron: CronViewModel? = nil) {
        self.botName = botName
        self.cron = cron ?? CronViewModel(context: context)
    }

    /// Mirrored from the environment capability store by the view, same
    /// shape as `CronView`/`BotsView`. `CronViewModel.isV0206OrLater` is
    /// what gates the terminal-job pre-check and the Resume & Run Now
    /// affordance — set it here so those W7 gates keep working unmodified.
    var isV0206OrLater: Bool {
        get { cron.isV0206OrLater }
        set { cron.isV0206OrLater = newValue }
    }

    /// This bot's routines, filtered from the FULL job list by the verified
    /// `[bot:<name>] ` prefix — never a separate fetch, so a job Hermes
    /// Desktop would show under this bot is exactly the set Scarf shows.
    var routines: [HermesCronJob] {
        cron.jobs.filter { BotRoutinePrefix.matches(jobName: $0.name, bot: botName) }
    }

    var isLoading: Bool { cron.isLoading }
    var message: String? { cron.message }

    func load(force: Bool = false) {
        cron.load(force: force)
    }

    // MARK: - Row actions (verbs are CronViewModel's own — not reforked)

    func pause(_ job: HermesCronJob) { cron.pauseJob(job) }
    func resume(_ job: HermesCronJob) { cron.resumeJob(job) }
    func resumeAndRunNow(_ job: HermesCronJob) { cron.resumeAndRunNow(job) }
    func runNow(_ job: HermesCronJob) { cron.runNow(job) }
    func delete(_ job: HermesCronJob) { cron.deleteJob(job) }

    /// Same local pre-check `CronView` uses to decide whether to show
    /// Resume vs. Resume & Run Now — delegated straight to `CronViewModel`
    /// so this pane never drifts from the terminal-state rule it encodes.
    func refusesTerminalJobLocally(_ job: HermesCronJob) -> Bool {
        cron.refusesTerminalJobLocally(job)
    }

    // MARK: - Create

    /// `cron create --name "[bot:<name>] <title>" <schedule> <prompt>
    /// [--deliver bot-chat:<profile>]`.
    ///
    /// Delivery is gated on `hasCronBotChatDelivery` (W7, `isV0206OrLater`):
    /// on a host below that floor `bot-chat:` delivery isn't a Hermes concept
    /// yet, so the sheet falls back to no `--deliver` at all (the job still
    /// runs; its output just isn't routed anywhere) and the caller shows a
    /// note rather than silently dropping the field.
    func createRoutine(
        title: String,
        schedule: String,
        prompt: String,
        hasCronBotChatDelivery: Bool
    ) {
        let name = BotRoutinePrefix.routineName(forBot: botName, title: title)
        let deliver = hasCronBotChatDelivery ? "bot-chat:\(botName)" : ""
        cron.createJob(
            schedule: schedule,
            prompt: prompt,
            name: name,
            deliver: deliver,
            skills: [],
            script: "",
            repeatCount: ""
        )
    }

    /// Pure argv-shape helper, exposed for tests: what `createRoutine` would
    /// hand `CronViewModel.createJob` — i.e. the exact `--name`/`--deliver`
    /// Scarf composes, without needing a live `CronViewModel`/transport to
    /// observe it. Mirrors `CronViewModel.createJob`'s own flag order.
    nonisolated static func createRoutineArguments(
        botName: String,
        title: String,
        schedule: String,
        prompt: String,
        hasCronBotChatDelivery: Bool
    ) -> [String] {
        let name = BotRoutinePrefix.routineName(forBot: botName, title: title)
        var args = ["cron", "create", "--name", name]
        if hasCronBotChatDelivery {
            args += ["--deliver", "bot-chat:\(botName)"]
        }
        args.append(schedule)
        if !prompt.isEmpty { args.append(prompt) }
        return args
    }
}
