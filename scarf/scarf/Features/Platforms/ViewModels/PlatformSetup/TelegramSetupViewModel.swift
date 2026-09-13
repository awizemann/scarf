import Foundation
import ScarfCore
import os

/// Telegram platform setup. Credentials live in `.env` (`TELEGRAM_*`); mention /
/// reactions toggles live in `config.yaml` under `telegram.*`.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram
@Observable
@MainActor
final class TelegramSetupViewModel: PlatformSetupForm {
    let context: ServerContext
    /// C10 test seam — nil in production. See ``PlatformSetupForm``.
    let cliRunner: HermesCLIRunner?
    /// Load/save in-flight flags owned by ``PlatformSetupForm``.
    var isLoading = false
    var isSaving = false
    /// Latched load refusal owned by ``PlatformSetupForm`` — set when a
    /// `.env` / config.yaml read could not be proved, and what makes
    /// `commitSave` refuse rather than publish blanks (P33).
    var loadRefusal: String?
    init(context: ServerContext = .local, cliRunner: HermesCLIRunner? = nil) {
        self.context = context
        self.cliRunner = cliRunner
    }

    // Required
    var botToken: String = ""
    var allowedUsers: String = ""
    // Optional
    var homeChannel: String = ""
    var webhookURL: String = ""
    var webhookPort: String = ""
    var webhookSecret: String = ""
    // Config.yaml toggles
    var requireMention: Bool = true
    var reactions: Bool = false
    /// Hermes v0.15 — top-level `telegram.disable_topic_auto_rename`.
    var disableTopicAutoRename: Bool = false
    /// Hermes v0.15 through v0.21.0 — `platforms.telegram.extra.ignore_root_dm`.
    /// The reader is gone at v0.21.1; the row is gated on
    /// `HermesCapabilities.hasTelegramIgnoreRootDM` and the key is only
    /// WRITTEN inside that window, so a v0.21.1 host's config.yaml keeps
    /// whatever it already had instead of being rewritten with a value
    /// nothing reads.
    var ignoreRootDM: Bool = false
    /// Hermes v0.17 — `platforms.telegram.extra.rich_messages` (Bot API 10.1).
    /// Default flipped true → false at v0.18, so the absent case is resolved
    /// against the host by `HermesConfig.displayTelegramRichMessages`.
    var richMessages: Bool = false
    /// Hermes v0.17 — `platforms.telegram.extra.status_indicator` (opt-in presence label).
    var statusIndicator: Bool = false

    /// Host capabilities, handed in by the view on `load()`. Decides which
    /// version-windowed keys this form renders AND writes; `.empty` (an
    /// unanswered version probe) keeps the pre-flag rendering.
    private(set) var capabilities: HermesCapabilities = .empty

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    /// `capabilities` is REQUIRED, not defaulted: the Reload button used to
    /// call a defaulted `load()` and would have silently reset the stored
    /// value to `.empty`, changing which keys the next save writes.
    func load(capabilities: HermesCapabilities) {
        self.capabilities = capabilities
        // Off the main actor (C10) — see ``PlatformSetupForm``. GW-F6 /
        // audit DI L10: an unreadable `.env` used to arrive as an EMPTY one,
        // so this form rendered blank fields over live values and a Save
        // then commented those keys out. Absent is still an empty form
        // (correct — nothing is set yet); unreadable says so.
        loadSnapshot { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            botToken = env["TELEGRAM_BOT_TOKEN"] ?? ""
            allowedUsers = env["TELEGRAM_ALLOWED_USERS"] ?? ""
            homeChannel = env["TELEGRAM_HOME_CHANNEL"] ?? ""
            webhookURL = env["TELEGRAM_WEBHOOK_URL"] ?? ""
            webhookPort = env["TELEGRAM_WEBHOOK_PORT"] ?? ""
            webhookSecret = env["TELEGRAM_WEBHOOK_SECRET"] ?? ""

            guard let cfg = snapshot.config else { return }
            requireMention = cfg.telegram.requireMention
            reactions = cfg.telegram.reactions
            disableTopicAutoRename = cfg.telegram.disableTopicAutoRename
            ignoreRootDM = cfg.telegram.ignoreRootDM
            richMessages = cfg.displayTelegramRichMessages(capabilities: capabilities)
            statusIndicator = cfg.telegram.statusIndicator
        }
    }

    func save() {
        let envPairs: [String: String] = [
            "TELEGRAM_BOT_TOKEN": botToken,
            "TELEGRAM_ALLOWED_USERS": allowedUsers,
            "TELEGRAM_HOME_CHANNEL": homeChannel,
            "TELEGRAM_WEBHOOK_URL": webhookURL,
            "TELEGRAM_WEBHOOK_PORT": webhookPort,
            "TELEGRAM_WEBHOOK_SECRET": webhookSecret
        ]
        var configKV: [String: String] = [
            "telegram.require_mention": PlatformSetupHelpers.envBool(requireMention),
            "telegram.reactions": PlatformSetupHelpers.envBool(reactions),
            "telegram.disable_topic_auto_rename": PlatformSetupHelpers.envBool(disableTopicAutoRename)
        ]
        // Only write the keys whose row this host actually renders. Writing a
        // key outside its version window would stamp a value the user was
        // never shown (and, for `ignore_root_dm` on v0.21.1+, one nothing
        // reads) over whatever the file already held.
        if capabilities.hasTelegramIgnoreRootDM {
            configKV["platforms.telegram.extra.ignore_root_dm"] = PlatformSetupHelpers.envBool(ignoreRootDM)
        }
        if capabilities.hasTelegramRichMessages {
            configKV["platforms.telegram.extra.rich_messages"] = PlatformSetupHelpers.envBool(richMessages)
            configKV["platforms.telegram.extra.status_indicator"] = PlatformSetupHelpers.envBool(statusIndicator)
        }
        commitSave(envPairs: envPairs, configKV: configKV)
    }
}
