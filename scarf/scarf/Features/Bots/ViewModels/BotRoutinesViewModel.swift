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

    /// Typed outcome for ``message``, forwarded from `CronViewModel` rather
    /// than sniffed out of the string. The pane used to paint every message
    /// in `ScarfColor.success` — so "Failed: …" and `friendlyCronFailure`
    /// text, which travel down this same channel, announced a broken routine
    /// in green and then auto-cleared (go/no-go blocking condition 1).
    var messageOutcome: CronViewModel.MessageOutcome { cron.messageOutcome }
    var messageIsFailure: Bool { cron.messageOutcome == .failure }

    func dismissMessage() { cron.dismissMessage() }

    func load(force: Bool = false) {
        cron.load(force: force)
    }

    // MARK: - Row actions (verbs are CronViewModel's own — not reforked)

    func pause(_ job: HermesCronJob) { cron.pauseJob(job) }
    func resume(_ job: HermesCronJob) { cron.resumeJob(job) }
    func resumeAndRunNow(_ job: HermesCronJob) { cron.resumeAndRunNow(job) }
    func runNow(_ job: HermesCronJob) { cron.runNow(job) }
    func delete(_ job: HermesCronJob) {
        cron.deleteJob(job) { succeeded in
            Analytics.record(.botRoutineAction(action: .deleted, outcome: .init(succeeded: succeeded)))
        }
    }

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
            repeatCount: "",
            onOutcome: { succeeded in
                Analytics.record(.botRoutineAction(action: .created, outcome: .init(succeeded: succeeded)))
            }
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

    /// Mirrors Hermes Desktop's `routineInputError` (`hermes-bots/cron.tsx:258-268`
    /// at v0.21.0): a title or instruction containing NUL (U+0000) is rejected
    /// before it ever reaches argv — the shell/CLI boundary can't carry it,
    /// and the two clients should refuse identically rather than Scarf
    /// silently truncating or erroring later at the transport. Also refuses
    /// an empty prompt, which Hermes Desktop's create sheet disables the
    /// submit button on (A1-L7): a routine with no instruction runs the
    /// agent with nothing to do.
    nonisolated static func routineInputError(title: String, instruction: String) -> String? {
        if title.contains("\0") {
            return "Job name cannot contain NUL (U+0000)."
        }
        if instruction.contains("\0") {
            return "Job instruction cannot contain NUL (U+0000)."
        }
        if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Prompt can't be empty."
        }
        return nil
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
