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
