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

            // No early return on a missing config half: the `.env` side of
            // the four env-overridable toggles must still show (P37 finding
            // 5's shape). The latched `loadRefusal` still refuses the Save.
            let cfg = snapshot.config?.discord
            let caps = capabilities
            var fromEnv = Set<String>()
            envLines = Set(Self.envSettings.map(\.setting.envKey).filter { env[$0] != nil })
            func resolve(_ spec: PlatformEnvSetting, _ key: String, _ configValue: Bool?) -> Bool {
                let r = spec.resolve(envValue: env[spec.envKey], configValue: configValue, capabilities: caps)
                if r.fromEnv { fromEnv.insert(spec.envKey) }
                return r.value
            }
            func present(_ key: String, _ value: Bool?) -> Bool? {
                cfg?.presentKeys.contains(key) == true ? value : nil
            }
            requireMention = resolve(.discordRequireMention, "require_mention",
                                     present("require_mention", cfg?.requireMention))
            autoThread = resolve(.discordAutoThread, "auto_thread", present("auto_thread", cfg?.autoThread))
            reactions = resolve(.discordReactions, "reactions", present("reactions", cfg?.reactions))
            historyBackfill = resolve(.discordHistoryBackfill, "history_backfill",
                                      present("history_backfill", cfg?.historyBackfill))
            envDecides = fromEnv
            guard let cfg else { return }
            freeResponseChannels = cfg.freeResponseChannels
            allowAnyAttachment = cfg.allowAnyAttachment
        }
    }

    /// The four toggles an env var can override, with their config.yaml key.
    static let envSettings: [(setting: PlatformEnvSetting, configKey: String)] = [
        (.discordRequireMention, "discord.require_mention"),
        (.discordAutoThread, "discord.auto_thread"),
        (.discordReactions, "discord.reactions"),
        (.discordHistoryBackfill, "discord.history_backfill")
    ]

    /// Env keys with a line in `.env` (any value). A Save removes them.
    private(set) var envLines: Set<String> = []
    /// Env keys whose `.env` value is what the gateway uses right now.
    private(set) var envDecides: Set<String> = []

    /// Caption under a toggle while `.env` holds its env var.
    func envCaption(for envKey: String) -> String? {
        PlatformSetupHelpers.envOverrideCaption(
            envKey: envKey, hasLine: envLines.contains(envKey), decides: envDecides.contains(envKey))
    }

    /// The `.env` pairs, config.yaml keys and moved `.env` lines a Save writes.
    func savePlan() -> (env: [String: String], config: [String: String], envUnsetAfterConfig: [String]) {
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
        return (envPairs, configKV, Self.envLinesToMove(envLines, configKV: configKV))
    }

    func save() {
        let plan = savePlan()
        commitSave(envPairs: plan.env, configKV: plan.config,
                   envUnsetAfterConfig: plan.envUnsetAfterConfig)
    }

    /// `.env` lines to drop once config.yaml holds the value: only for a
    /// toggle this Save actually writes (a hidden `history_backfill` row on
    /// a pre-v0.14 host keeps its line). Removed only AFTER every config
    /// write succeeded (`saveForm`), so a failed Save keeps the copy Hermes
    /// still reads — the Mattermost pattern (B05).
    static func envLinesToMove(_ lines: Set<String>, configKV: [String: String]) -> [String] {
        envSettings
            .filter { lines.contains($0.setting.envKey) && configKV.keys.contains($0.configKey) }
            .map(\.setting.envKey)
    }
}
