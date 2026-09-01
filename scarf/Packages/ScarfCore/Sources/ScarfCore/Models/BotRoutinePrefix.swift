import Foundation

/// The job-NAME namespace Hermes Desktop uses to scope a `hermes cron` job
/// to one bot profile.
///
/// **Verified format** (v0.21.0 audit,
/// `apps/desktop/src/plugins/hermes-bots/cron.tsx:73`):
///
/// ```
/// const BOT_TAG_RE = /^\[bot:([a-z0-9][a-z0-9_-]*)\]\s*/i
/// ```
///
/// i.e. a job is "this bot's routine" exactly when its `name` starts with
/// `[bot:<slug>] ` — literal brackets, lowercase `bot:`, a profile-shaped
/// slug (`^[a-z0-9][a-z0-9_-]*`, matched case-insensitively by the regex's
/// `/i` flag), then any run of whitespace (including none) before the human
/// title. The same shape is echoed at `cron.tsx:970`
/// (`` `[bot:${profile}] ${title}` ``, the compose side) and cross-checked by
/// the plugin's own fixtures (`cron-jobs-view.test.ts`,
/// `cron-load.test.ts`, `cron-create-dialog.test.tsx`). Hermes profile ids
/// are already constrained to `^[a-z0-9][a-z0-9_-]{0,63}$`
/// (`HermesProfileScope.isValidName`), so in practice the slug never needs
/// the regex's case-insensitivity — but Scarf mirrors the regex exactly
/// rather than special-casing that away, so a hand-edited or third-party
/// job name is classified identically to how Hermes Desktop's own Routines
/// pane would classify it.
public enum BotRoutinePrefix {
    /// Mirrors `BOT_TAG_RE` byte-for-byte (case-insensitive whole match).
    private static let regex: NSRegularExpression = {
        // swiftlint:disable:next force_try — a hand-authored literal pattern; a failure here is a coding error, not a runtime condition.
        try! NSRegularExpression(pattern: "^\\[bot:([a-z0-9][a-z0-9_-]*)\\]\\s*", options: [.caseInsensitive])
    }()

    /// The bot slug a cron job's `name` is tagged for, or `nil` when the
    /// name isn't tagged at all — including a name that merely *contains*
    /// `[bot:...]` somewhere other than at the start, an empty bracket
    /// (`[bot:]`), or a slug with characters the regex's character class
    /// doesn't allow (brackets, spaces, unicode — e.g. `[bot:résearch]` or
    /// `[bot:研究]` never match, exactly as an untagged job wouldn't).
    public nonisolated static func taggedBot(inJobName name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, options: [], range: range),
              match.range(at: 1).location != NSNotFound,
              let botRange = Range(match.range(at: 1), in: name)
        else { return nil }
        return String(name[botRange])
    }

    /// Whether `jobName` is namespaced for `bot`. Case-insensitive slug
    /// comparison, matching the regex's own `/i` flag — a hand-edited job
    /// named `[bot:Research]` still belongs to profile `research`.
    public nonisolated static func matches(jobName: String, bot: String) -> Bool {
        guard let tagged = taggedBot(inJobName: jobName), !bot.isEmpty else { return false }
        return tagged.caseInsensitiveCompare(bot) == .orderedSame
    }

    /// Compose `"[bot:<name>] <title>"` for `cron create --name` /
    /// `cron edit --name`, mirroring the desktop plugin's own compose side
    /// (`cron.tsx:970`) exactly — same literal brackets, same single space,
    /// no additional trimming beyond the title's own whitespace.
    public nonisolated static func routineName(forBot bot: String, title: String) -> String {
        "[bot:\(bot)] \(title.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// The *instruction* half of a bot routine — the delegation wrapper that
/// makes a cron job execute as its bot rather than as whichever profile owns
/// the cron store.
///
/// **The bug this fixes.** `hermes cron` jobs live in ONE profile's store and
/// run as THAT profile. Scoping a job to a bot by name alone (`[bot:x] …`,
/// see ``BotRoutinePrefix``) is presentation only: the prompt still executes
/// with the store profile's memory, skills, credentials and SOUL. Scarf was
/// creating routines in the window profile's store with the raw instruction,
/// so every routine ran as the wrong agent.
///
/// **Verified format** (v0.21.0 audit,
/// `apps/desktop/src/plugins/hermes-bots/cron.tsx:74` and `:270-286`):
///
/// ```ts
/// const SAFE_ROUTINE_MARKER = '[bot-mode:routine:v2] '
///
/// export function routinePrompt(bot, title, instruction, activeProfile) {
///   if (normalizedProfileName(bot) && normalizedProfileName(bot) === normalizedProfileName(activeProfile)) {
///     return instruction
///   }
///   return (
///     `${SAFE_ROUTINE_MARKER}You are running the scheduled routine "${title}" for agent '${bot}'. ` +
///     `Execute it AS that agent so the run lands in its own history: run this in the terminal and relay the output:\n\n` +
///     `hermes -p ${shellQuote(bot)} chat -c ${shellQuote(`Routine: ${title}`)} -q ${shellQuote(`[Scheduled routine] ${instruction}`)}\n\n` +
///     `If the command fails, report the error instead.`
///   )
/// }
/// ```
///
/// Mirrored **byte for byte**, including the marker string, the curly-free
/// straight quotes, the two blank lines, and `shellQuote`'s POSIX
/// `'"'"'` escape (`cron.tsx:254-256`) — so a routine Scarf creates is
/// indistinguishable from one Hermes Desktop created, and Hermes Desktop's
/// own Routines pane recognizes it (and vice versa). Change nothing here
/// without re-reading that source.
public enum BotRoutineDelegation {

    /// `SAFE_ROUTINE_MARKER` — note the trailing space, which is part of it.
    public static let marker = "[bot-mode:routine:v2] "

    /// `normalizedProfileName` (`cron.tsx:250-252`): trim, lowercase.
    public nonisolated static func normalizedProfileName(_ profile: String?) -> String {
        (profile ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `shellQuote` (`cron.tsx:254-256`): POSIX single-quoting where an
    /// embedded `'` becomes `'"'"'`.
    public nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Whether a routine for `bot` needs the delegation wrapper in a cron
    /// store owned by `storeProfile`. False only when the two name the same
    /// profile — then the job already runs as the right agent and the raw
    /// instruction is what the desktop writes.
    public nonisolated static func requiresDelegation(bot: String, storeProfile: String?) -> Bool {
        let normalized = normalizedProfileName(bot)
        guard !normalized.isEmpty else { return true }
        return normalized != normalizedProfileName(storeProfile)
    }

    /// The prompt to hand `cron create` — `routinePrompt` exactly.
    public nonisolated static func prompt(
        bot: String,
        title: String,
        instruction: String,
        storeProfile: String?
    ) -> String {
        guard requiresDelegation(bot: bot, storeProfile: storeProfile) else { return instruction }
        return marker
            + "You are running the scheduled routine \"\(title)\" for agent '\(bot)'. "
            + "Execute it AS that agent so the run lands in its own history: "
            + "run this in the terminal and relay the output:\n\n"
            + "hermes -p \(shellQuote(bot)) chat -c \(shellQuote("Routine: \(title)")) "
            + "-q \(shellQuote("[Scheduled routine] \(instruction)"))\n\n"
            + "If the command fails, report the error instead."
    }
}
