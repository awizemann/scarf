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
    /// The profile that OWNS the cron store these jobs are created in — the
    /// window's profile, not the bot's. `hermes cron` has one store per
    /// profile and runs every job as that profile, so this is the value the
    /// delegation wrapper is decided against (see ``BotRoutineDelegation``).
    /// Derived from the context's home the same way every other per-profile
    /// discriminator is (`HermesProfileScope.profileName(forHome:)`), with a
    /// root home meaning the `default` profile. This is correct on local
    /// hosts too: `HermesPathSet.defaultLocalHome` already resolves
    /// `~/.hermes/active_profile`, so a Mac running under profile `work` has
    /// a `<root>/profiles/work` home and is identified as such.
    let storeProfile: String

    init(context: ServerContext, botName: String, cron: CronViewModel? = nil) {
        self.botName = botName
        self.storeProfile = HermesProfileScope.profileName(forHome: context.paths.home)
            ?? HermesProfileScope.defaultProfileName
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
    /// **The prompt is not the user's instruction verbatim** when the bot
    /// differs from the cron store's own profile. `hermes cron` runs every
    /// job as the profile that owns the store, so the raw instruction would
    /// execute with the *window* profile's memory, skills and credentials
    /// under the bot's name. ``BotRoutineDelegation`` wraps it in the exact
    /// `hermes -p <bot> chat …` delegation form Hermes Desktop uses
    /// (`cron.tsx:270-286`), marker included, so the two clients produce
    /// interchangeable jobs.
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
        let fields = Self.routineFields(
            botName: botName,
            storeProfile: storeProfile,
            title: title,
            instruction: prompt,
            hasCronBotChatDelivery: hasCronBotChatDelivery
        )
        cron.createJob(
            schedule: schedule,
            prompt: fields.prompt,
            name: fields.name,
            deliver: fields.deliver,
            skills: [],
            script: "",
            repeatCount: ""
        )
    }

    /// The three values `createRoutine` hands `CronViewModel.createJob`.
    /// Single source of truth for both the live call above and the argv
    /// helper below — neither re-derives them.
    nonisolated static func routineFields(
        botName: String,
        storeProfile: String,
        title: String,
        instruction: String,
        hasCronBotChatDelivery: Bool
    ) -> (name: String, prompt: String, deliver: String) {
        (
            name: BotRoutinePrefix.routineName(forBot: botName, title: title),
            prompt: BotRoutineDelegation.prompt(
                bot: botName,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                instruction: instruction,
                storeProfile: storeProfile
            ),
            deliver: hasCronBotChatDelivery ? "bot-chat:\(botName)" : ""
        )
    }

    /// The exact argv `createRoutine` produces, without needing a live
    /// `CronViewModel`/transport to observe it. Composed by calling the
    /// PRODUCTION builders — `routineFields` above and
    /// `CronViewModel.createJobArguments` — so a test asserting this is
    /// asserting the command line Scarf actually runs, not a parallel
    /// re-implementation of it.
    nonisolated static func createRoutineArguments(
        botName: String,
        storeProfile: String,
        title: String,
        schedule: String,
        prompt: String,
        hasCronBotChatDelivery: Bool
    ) -> [String] {
        let fields = routineFields(
            botName: botName,
            storeProfile: storeProfile,
            title: title,
            instruction: prompt,
            hasCronBotChatDelivery: hasCronBotChatDelivery
        )
        return CronViewModel.createJobArguments(
            schedule: schedule,
            prompt: fields.prompt,
            name: fields.name,
            deliver: fields.deliver,
            skills: [],
            script: "",
            repeatCount: ""
        )
    }
}
