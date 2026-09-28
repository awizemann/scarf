import Foundation

/// A platform setting Hermes reads from BOTH `.env` and config.yaml, with the
/// env var able to override config.yaml. Hermes's own docs tell users to set
/// these in `~/.hermes/.env` (e.g. `website/docs/user-guide/messaging/
/// discord.md:304-316`, `telegram.md:239,1329` @ v2026.9.24), so a form that
/// shows and saves only config.yaml can show a value the gateway is not using
/// and save a change that has no effect. ``resolve(envValue:configValue:capabilities:)``
/// answers "what does the gateway use, and does `.env` decide it".
public struct PlatformEnvSetting: Sendable, Equatable {
    /// How the adapter turns the raw env/config text into a Bool.
    public enum Parse: Sendable, Equatable {
        /// On unless the lowercased value is one of these words.
        case offWords(Set<String>)
        /// On only when the lowercased value is `true`/`1`/`yes`/`on`.
        case onWords
    }

    public let envKey: String
    public let parse: Parse
    public let defaultValue: Bool
    /// The env var won over config.yaml on every Hermes version, not just
    /// from v0.21.3: the adapter read `os.getenv(...)` directly and the
    /// config value only reached it through a first-writer-wins env bridge.
    public let envAlwaysWins: Bool

    public init(envKey: String, parse: Parse, defaultValue: Bool, envAlwaysWins: Bool) {
        self.envKey = envKey
        self.parse = parse
        self.defaultValue = defaultValue
        self.envAlwaysWins = envAlwaysWins
    }

    /// The effective value and whether `.env` is what decides it.
    ///
    /// - `configValue`: nil when the key is ABSENT from config.yaml.
    ///
    /// A blank env value counts as unset (`extra_or_secret`). From v0.21.3
    /// (or always, for ``envAlwaysWins`` settings) a non-blank env value
    /// wins; otherwise config.yaml wins when the key is there, and the env
    /// var is the fallback for an absent key on every version.
    public func resolve(
        envValue: String?, configValue: Bool?, capabilities: HermesCapabilities
    ) -> (value: Bool, fromEnv: Bool) {
        let env = Self.nonBlank(envValue)
        if let env, envAlwaysWins || capabilities.hasEnvFirstPlatformSettings {
            return (parsed(env), true)
        }
        if let configValue { return (configValue, false) }
        if let env { return (parsed(env), true) }
        return (defaultValue, false)
    }

    public func parsed(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch parse {
        case .offWords(let words): return !words.contains(text)
        case .onWords: return ["true", "1", "yes", "on"].contains(text)
        }
    }

    /// Every `.env` key B13 resolves — what the iOS Settings read keeps.
    public static let envKeys: Set<String> = [
        discordRequireMention.envKey, discordReactions.envKey, discordAutoThread.envKey,
        discordHistoryBackfill.envKey, telegramRequireMention.envKey, telegramReactions.envKey,
        PlatformEnvAllowlist.discordAllowedChannels.envKey, PlatformEnvAllowlist.telegramAllowedChats.envKey
    ]

    /// Active `KEY=value` lines of a `.env` text for `keys` (comments and
    /// commented-out lines skipped, one layer of quotes stripped).
    public static func envValues(fromEnvText text: String?, keys: Set<String>) -> [String: String] {
        guard let text else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    static func nonBlank(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }

    // MARK: - Discord (`plugins/platforms/discord/adapter.py` @ v2026.9.24)

    /// `_discord_require_mention` (:4778-4780). Env-first from v0.21.3; at
    /// v2026.9.11 config.extra was read first (:4554-4568).
    public static let discordRequireMention = PlatformEnvSetting(
        envKey: "DISCORD_REQUIRE_MENTION", parse: .offWords(["false", "0", "no", "off"]),
        defaultValue: true, envAlwaysWins: false)
    /// `_reactions_enabled` (:2933-2935). Before v0.21.3 the adapter read
    /// only `os.getenv("DISCORD_REACTIONS")` (v2026.9.11 :2747-2749), so
    /// `.env` won on every version.
    public static let discordReactions = PlatformEnvSetting(
        envKey: "DISCORD_REACTIONS", parse: .offWords(["false", "0", "no", "off"]),
        defaultValue: true, envAlwaysWins: true)
    /// Auto-thread (:6001). Env-only before v0.21.3 (v2026.9.11 :5729).
    public static let discordAutoThread = PlatformEnvSetting(
        envKey: "DISCORD_AUTO_THREAD", parse: .onWords, defaultValue: true, envAlwaysWins: true)
    /// `_discord_history_backfill` (:5040-5042). Before v0.21.3 config.extra
    /// never carried the key, so `.env` decided when it was set (v2026.9.11
    /// :4774-4779, bridge :7011-7012).
    public static let discordHistoryBackfill = PlatformEnvSetting(
        envKey: "DISCORD_HISTORY_BACKFILL", parse: .onWords, defaultValue: true, envAlwaysWins: true)

    // MARK: - Telegram (`plugins/platforms/telegram/adapter.py` @ v2026.9.24)

    /// `_telegram_require_mention` (:5733-5735) via `_extra_bool`
    /// (:5713-5723). Env-first from v0.21.3.
    public static let telegramRequireMention = PlatformEnvSetting(
        envKey: "TELEGRAM_REQUIRE_MENTION", parse: .onWords, defaultValue: false, envAlwaysWins: false)
    /// `_reactions_enabled` (:7082-7093). Env-only before v0.21.3 (v2026.9.11
    /// :6356-6358), so `.env` won on every version.
    public static let telegramReactions = PlatformEnvSetting(
        envKey: "TELEGRAM_REACTIONS", parse: .offWords(["false", "0", "no"]),
        defaultValue: false, envAlwaysWins: true)
}

/// A platform allowlist Hermes reads from `.env` or config.yaml — the list
/// counterpart of ``PlatformEnvSetting``.
public struct PlatformEnvAllowlist: Sendable, Equatable {
    public let envKey: String
    public let envAlwaysWins: Bool

    /// `DISCORD_ALLOWED_CHANNELS`: `_gate_raw` reads env first on every
    /// version (`discord/adapter.py:4845-4866` @ v2026.9.24, :4627-4647 @
    /// v2026.9.11).
    public static let discordAllowedChannels = PlatformEnvAllowlist(
        envKey: "DISCORD_ALLOWED_CHANNELS", envAlwaysWins: true)
    /// `TELEGRAM_ALLOWED_CHATS`: `_extra_str_set` (`telegram/adapter.py:
    /// 5725-5731,5778` @ v2026.9.24) — env-first from v0.21.3.
    public static let telegramAllowedChats = PlatformEnvAllowlist(
        envKey: "TELEGRAM_ALLOWED_CHATS", envAlwaysWins: false)

    /// The allowlist for a platform whose `.env` spelling Scarf handles.
    public static func forPlatform(_ platform: String) -> PlatformEnvAllowlist? {
        switch platform {
        case "discord": return .discordAllowedChannels
        case "telegram": return .telegramAllowedChats
        default: return nil
        }
    }

    /// Env value → entries: a JSON list literal (`decode_json_list_literal`,
    /// `gateway/platforms/_shared.py` @ v2026.9.24) or the adapters'
    /// comma-separated form.
    public static func items(fromEnv raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["),
           let list = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [Any] {
            return list.map { "\($0)".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The effective list and whether `.env` decides it. `configItems` is
    /// nil when config.yaml has no list for the platform.
    public func resolve(
        envValue: String?, configItems: [String]?, capabilities: HermesCapabilities
    ) -> (items: [String], fromEnv: Bool) {
        let env = PlatformEnvSetting.nonBlank(envValue).map(Self.items(fromEnv:))
        if let env, !env.isEmpty, envAlwaysWins || capabilities.hasEnvFirstPlatformSettings {
            return (env, true)
        }
        if let configItems, !configItems.isEmpty { return (configItems, false) }
        if let env, !env.isEmpty { return (env, true) }
        return (configItems ?? [], false)
    }
}
