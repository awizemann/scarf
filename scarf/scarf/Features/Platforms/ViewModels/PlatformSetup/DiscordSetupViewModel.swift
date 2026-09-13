import Foundation
import ScarfCore
import os

/// Discord setup. Bot token + user IDs in `.env`, behavior knobs in `discord.*`.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord
@Observable
@MainActor
final class DiscordSetupViewModel: PlatformSetupForm {
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

    var botToken: String = ""
    var allowedUsers: String = ""
    var homeChannel: String = ""
    var homeChannelName: String = ""
    var allowBots: String = "none"        // "none" | "mentions" | "all"
    var replyToMode: String = "first"     // "off" | "first" | "all"

    // config.yaml — these mirror the existing `HermesConfig.discord` block so we
    // stay consistent with whatever the Settings UI shows.
    var requireMention: Bool = true
    var freeResponseChannels: String = ""
    var autoThread: Bool = true
    var reactions: Bool = true
    /// Hermes v0.14 — when joining a thread or channel for the first
    /// time, read recent history so the agent knows what's been said.
    /// Default is `true` to match Hermes's v0.14 server-side default.
    /// Capability-gated by the host UI on `hasDiscordHistoryBackfill`.
    var historyBackfill: Bool = true
    /// `platforms.discord.extra.allow_any_attachment` — live only on a
    /// v0.15–v0.17 host. Capability-gated by the view AND by `save` on
    /// `hasDiscordAllowAnyAttachment`, which is a WINDOW: the adapter stopped
    /// calling its own getter at v2026.7.1 (0.18.0) and the tag's docs call
    /// the key a no-op. See the flag for the tag-by-tag walk.
    var allowAnyAttachment: Bool = false

    /// The host's capability set, captured at `load` and read by `save` —
    /// Telegram's shape (`TelegramSetupViewModel.swift:57`). The form writes
    /// only the version-windowed keys whose ROW it renders.
    private(set) var capabilities: HermesCapabilities = .empty

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    let allowBotsOptions = ["none", "mentions", "all"]
    let replyToModeOptions = ["off", "first", "all"]

    /// Off the main actor (C10) — see ``PlatformSetupForm``. The `.env` read
    /// distinguishes absent (empty form — nothing is set yet) from unreadable
    /// (GW-F6 / DI L10: the form used to render blanks over live values and a
    /// Save then commented those keys out).
    /// `capabilities` is REQUIRED, not defaulted — the addendum's "a
    /// parameter that IS the fix gets no default". The Reload button calls
    /// this too, and a defaulted overload would silently reset the stored
    /// value to `.empty` and change which keys the next Save writes.
    func load(capabilities: HermesCapabilities) {
        self.capabilities = capabilities
        loadSnapshot { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            botToken = env["DISCORD_BOT_TOKEN"] ?? ""
            allowedUsers = env["DISCORD_ALLOWED_USERS"] ?? ""
            homeChannel = env["DISCORD_HOME_CHANNEL"] ?? ""
            homeChannelName = env["DISCORD_HOME_CHANNEL_NAME"] ?? ""
            allowBots = env["DISCORD_ALLOW_BOTS"] ?? "none"
            replyToMode = env["DISCORD_REPLY_TO_MODE"] ?? "first"

            guard let cfg = snapshot.config?.discord else { return }
            requireMention = cfg.requireMention
            freeResponseChannels = cfg.freeResponseChannels
            autoThread = cfg.autoThread
            reactions = cfg.reactions
            historyBackfill = cfg.historyBackfill
            allowAnyAttachment = cfg.allowAnyAttachment
        }
    }

    func save() {
        let envPairs: [String: String] = [
            "DISCORD_BOT_TOKEN": botToken,
            "DISCORD_ALLOWED_USERS": allowedUsers,
            "DISCORD_HOME_CHANNEL": homeChannel,
            "DISCORD_HOME_CHANNEL_NAME": homeChannelName,
            "DISCORD_ALLOW_BOTS": allowBots == "none" ? "" : allowBots, // default is "none", don't persist
            "DISCORD_REPLY_TO_MODE": replyToMode == "first" ? "" : replyToMode
        ]
        var configKV: [String: String] = [
            "discord.require_mention": PlatformSetupHelpers.envBool(requireMention),
            "discord.free_response_channels": freeResponseChannels,
            "discord.auto_thread": PlatformSetupHelpers.envBool(autoThread),
            "discord.reactions": PlatformSetupHelpers.envBool(reactions)
        ]
        // Only the keys whose row this host actually renders, Telegram's rule
        // (`TelegramSetupViewModel.swift:108-118`). Both of these were written
        // unconditionally while the VIEW gated their rows, so a pre-v0.14 host
        // got a `history_backfill` it never showed the user, and every
        // v0.18+ host got an `allow_any_attachment` nothing reads — stamped
        // over whatever the file already held, from a toggle that was never
        // on screen.
        if capabilities.hasDiscordHistoryBackfill {
            configKV["discord.history_backfill"] = PlatformSetupHelpers.envBool(historyBackfill)
        }
        if capabilities.hasDiscordAllowAnyAttachment {
            configKV["platforms.discord.extra.allow_any_attachment"] = PlatformSetupHelpers.envBool(allowAnyAttachment)
        }
        commitSave(envPairs: envPairs, configKV: configKV)
    }
}
