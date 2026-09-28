import Foundation

/// Platform settings Scarf writes to config.yaml that Hermes reads with the
/// `.env` variable FIRST — so a leftover `.env` line makes the form's value
/// inert and the form shows the wrong one (B05 / S07-F4 and its sweep).
///
/// ## The two bands
///
/// - **v0.21.3+ (v2026.9.14).** Commit 3dedb71f2f moved the adapters onto
///   `extra_or_secret` — "explicit env → the profile's YAML `config.extra` →
///   default" (`gateway/platforms/_shared.py:106-128` @ v2026.9.24). Before it
///   these readers took `config.extra` FIRST (e.g. `_extra_or_env_flag`,
///   `plugins/platforms/discord/adapter.py:4554-4560` @ v2026.9.11).
/// - **Every host.** Some settings were ENV-ONLY readers fed by a YAML→env
///   bridge that fills the variable only when it is unset (`if "reactions"
///   in discord_cfg and not os.getenv("DISCORD_REACTIONS")`,
///   `gateway/config.py:829-831` @ v2026.5.7; `discord/adapter.py:9342-9371`
///   @ v2026.7.20). An `.env` line has always won for those.
///
/// ## What a form does with it
///
/// Load: when the variable is set (non-blank) and wins on this host, show
/// ITS value and say so. Save: write config.yaml as before AND comment the
/// `.env` line out — once the line is gone, config.yaml is what every band
/// reads (the bridge then fills the variable from YAML), so one Save makes
/// both bands agree. `hermes config set` never writes these variables, so
/// removing the line cannot fight Hermes.
public enum HermesEnvFirstSettings {

    public enum Band: Sendable, Equatable {
        /// `.env` wins on every supported host.
        case allHosts
        /// `.env` wins from v0.21.3; config.yaml wins below it.
        case fromV0213
    }

    public struct Setting: Sendable, Hashable {
        public let platform: String
        /// The leaf key under the platform (`require_mention`).
        public let key: String
        public let envVar: String
        public let band: Band
        /// Hermes's reader, for the record (`file:line @ v2026.9.24`).
        public let reader: String
    }

    /// Every env-first setting a Scarf form or the gateway-behaviour
    /// allowlist writes. Settings Scarf writes that Hermes reads config-first
    /// are deliberately absent: Slack `require_mention` (`slack/adapter.py:6198-6206`),
    /// Slack `reply_in_thread`/`reply_broadcast` (`:2277`, `:2781`), Discord
    /// `free_response_channels` (`discord/adapter.py:4957-4962`), Signal
    /// `require_mention` (`gateway/platforms/signal.py:194-195`), Email,
    /// Home Assistant, Telegram's `platforms.telegram.extra.*` keys,
    /// WhatsApp Cloud (`extra.get(...) or env`). Ntfy `topic`/`server` are
    /// written to BOTH sides by its form, and its token is cleared in config.
    public static let settings: [Setting] = [
        Setting(platform: "discord", key: "require_mention", envVar: "DISCORD_REQUIRE_MENTION",
                band: .fromV0213, reader: "plugins/platforms/discord/adapter.py:4765-4780"),
        Setting(platform: "discord", key: "reactions", envVar: "DISCORD_REACTIONS",
                band: .allHosts, reader: "plugins/platforms/discord/adapter.py:2935"),
        Setting(platform: "discord", key: "history_backfill", envVar: "DISCORD_HISTORY_BACKFILL",
                band: .fromV0213, reader: "plugins/platforms/discord/adapter.py:5040-5042"),
        Setting(platform: "discord", key: "auto_thread", envVar: "DISCORD_AUTO_THREAD",
                band: .allHosts, reader: "plugins/platforms/discord/adapter.py:6001"),
        Setting(platform: "discord", key: "allowed_channels", envVar: "DISCORD_ALLOWED_CHANNELS",
                band: .allHosts, reader: "plugins/platforms/discord/adapter.py:4845-4866 (\"legacy precedence\")"),
        Setting(platform: "telegram", key: "require_mention", envVar: "TELEGRAM_REQUIRE_MENTION",
                band: .fromV0213, reader: "plugins/platforms/telegram/adapter.py:5713-5735"),
        Setting(platform: "telegram", key: "reactions", envVar: "TELEGRAM_REACTIONS",
                band: .allHosts, reader: "plugins/platforms/telegram/adapter.py:7090"),
        Setting(platform: "telegram", key: "allowed_chats", envVar: "TELEGRAM_ALLOWED_CHATS",
                band: .fromV0213, reader: "plugins/platforms/telegram/adapter.py:5725-5731,5778"),
        Setting(platform: "matrix", key: "require_mention", envVar: "MATRIX_REQUIRE_MENTION",
                band: .fromV0213, reader: "plugins/platforms/matrix/adapter.py:950"),
        Setting(platform: "matrix", key: "auto_thread", envVar: "MATRIX_AUTO_THREAD",
                band: .allHosts, reader: "plugins/platforms/matrix/adapter.py:877"),
        Setting(platform: "matrix", key: "dm_mention_threads", envVar: "MATRIX_DM_MENTION_THREADS",
                band: .allHosts, reader: "plugins/platforms/matrix/adapter.py:879"),
        Setting(platform: "matrix", key: "allowed_rooms", envVar: "MATRIX_ALLOWED_ROOMS",
                band: .fromV0213, reader: "plugins/platforms/matrix/adapter.py:536-539,873"),
        Setting(platform: "mattermost", key: "require_mention", envVar: "MATTERMOST_REQUIRE_MENTION",
                band: .fromV0213, reader: "plugins/platforms/mattermost/adapter.py:503"),
        Setting(platform: "mattermost", key: "allowed_channels", envVar: "MATTERMOST_ALLOWED_CHANNELS",
                band: .fromV0213, reader: "plugins/platforms/mattermost/adapter.py:499"),
        Setting(platform: "slack", key: "allowed_channels", envVar: "SLACK_ALLOWED_CHANNELS",
                band: .fromV0213, reader: "plugins/platforms/slack/adapter.py:6240-6260"),
        Setting(platform: "dingtalk", key: "allowed_chats", envVar: "DINGTALK_ALLOWED_CHATS",
                band: .fromV0213, reader: "plugins/platforms/dingtalk/adapter.py:256-267"),
        Setting(platform: "ntfy", key: "publish_topic", envVar: "NTFY_PUBLISH_TOPIC",
                band: .fromV0213, reader: "plugins/platforms/ntfy/adapter.py:127"),
    ]

    /// The setting a written config key refers to, whatever its spelling:
    /// `discord.require_mention`, `platforms.discord.require_mention` or
    /// `platforms.discord.extra.require_mention`.
    public static func setting(forConfigKey configKey: String) -> Setting? {
        var parts = configKey.split(separator: ".").map(String.init)
        if parts.first == "platforms" { parts.removeFirst() }
        guard parts.count >= 2 else { return nil }
        let platform = parts[0]
        let rest = Array(parts.dropFirst())
        let leaf = rest.first == "extra" ? rest.dropFirst().joined(separator: ".") : rest.joined(separator: ".")
        return settings.first { $0.platform == platform && $0.key == leaf }
    }

    /// Whether `.env` decides this setting on a host with `capabilities`.
    public static func envWins(_ setting: Setting, envValue: String?, capabilities: HermesCapabilities) -> Bool {
        // A blank value is unset (`_shared.py:123-125`; the bridge's
        // `not os.getenv(...)` treats "" as unset too).
        guard let envValue, !envValue.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch setting.band {
        case .allHosts: return true
        case .fromV0213: return capabilities.isV0213OrLater
        }
    }

    /// The `.env` value that decides `configKey` on this host, or nil when
    /// config.yaml (or the default) does.
    public static func winningEnvValue(
        configKey: String, env: [String: String], capabilities: HermesCapabilities
    ) -> String? {
        guard let setting = setting(forConfigKey: configKey) else { return nil }
        let value = env[setting.envVar]
        return envWins(setting, envValue: value, capabilities: capabilities) ? value : nil
    }

    /// `.env` variables to comment out on a Save that writes `configKeys`:
    /// every managed setting whose variable has a line (any value).
    public static func envLinesToRemove(configKeys: some Sequence<String>, env: [String: String]) -> [String] {
        var out: [String] = []
        for key in configKeys {
            if let s = setting(forConfigKey: key), env[s.envVar] != nil, !out.contains(s.envVar) {
                out.append(s.envVar)
            }
        }
        return out.sorted()
    }

    /// Hermes's "on unless false/0/no/off" reading (`require_mention` et al.).
    public static func denyFalse(_ raw: String) -> Bool {
        !["false", "0", "no", "off"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Hermes's "on only for true/1/yes/on" reading.
    public static func truthy(_ raw: String) -> Bool {
        ["true", "1", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Comma-separated list, trimmed, blanks dropped.
    public static func csv(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A minimal `.env` reader for surfaces without `HermesEnvService`
    /// (iOS): `KEY=value` / `export KEY=value`, `#` comments, one level of
    /// matching quotes. Only used to ask "is this variable set, and to what".
    public static func parseEnv(_ text: String?) -> [String: String] {
        guard let text else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}
