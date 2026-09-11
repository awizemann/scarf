import Foundation

/// Where a gateway platform's `_SHARED_KEYS` live in `config.yaml` — the ONE
/// answer both the reader and the writers use.
///
/// ## The contract, walked at `v2026.9.7`
///
/// `platform_section` (`gateway/config_loader.py:171-180`) picks ONE section
/// per platform: *"a top-level `<name>:` block wins; otherwise the block under
/// `gateway.platforms` / `platforms`"*. `bridge_platform_shared_keys`
/// (`:249-283`) then copies that section's `_SHARED_KEYS` members (`:197-213`
/// — `require_mention`, `reply_in_thread`, `dm_policy`, `allow_from`,
/// `reply_prefix`, `unauthorized_dm_behavior`, … ) into the platform's
/// `extra` with `extra.update(bridged)` (`:283`).
///
/// The consequence that costs a save: a top-level block does NOT out-rank the
/// nested one key by key — it **replaces it as the bridge source**. With
/// `slack:` present at the top level, a `platforms.slack.require_mention` is
/// never bridged and never reaches the adapter, which reads it from `extra`
/// alone (`_slack_require_mention`, `plugins/platforms/slack/adapter.py:5917-5926`).
/// Scarf's form reported "Saved" and the setting did not move (`t-6fa3fc84`).
///
/// The general platform block still merges from every spelling
/// (`merge_platform_sections`, `:121-160`) — but that merge does NOT include
/// a bare top-level `<name>:` block (`:149-152`), and it is not what feeds
/// `extra` for a shared key. So the two questions are genuinely separate, and
/// only shared keys need this type.
///
/// ## Why this is a WRITE-side type as much as a read-side one
///
/// `HermesConfig+YAML.sharedPlatformScalar` has modelled the read since P20.
/// The writers did not, which is the half `t-6fa3fc84` filed: a form that
/// reads through Hermes's precedence and writes through a hard-coded spelling
/// shows the user a value it cannot change. `platformSetupKey` is the writer's
/// side of the same resolution, in the shape `SettingsViewModel
/// .setMultiplexProfiles` uses for `multiplex_profiles` — write to whichever
/// spelling is IN EFFECT.
public enum HermesPlatformSharedKeys {

    /// `_SHARED_KEYS` verbatim (`gateway/config_loader.py:197-213` @
    /// `v2026.9.7`), names only — the per-platform narrowings (`allowed_chats`
    /// and friends are Telegram-only; `channel_skill_bindings` is
    /// Discord/Slack) and the transforms do not change WHERE the key is read
    /// from, which is all this type answers.
    ///
    /// Membership is what tells a writer whether it must resolve the bridge
    /// source at all: a non-shared key (`reply_to_mode`, `reply_broadcast`,
    /// tokens) keeps its own literal spelling.
    public static let names: Set<String> = [
        "unauthorized_dm_behavior", "notice_delivery",
        "reply_prefix", "reply_in_thread", "cron_continuable_surface",
        "require_mention", "send_read_receipts",
        "allowed_chats", "group_allowed_chats", "allowed_topics",
        "free_response_channels", "mention_patterns", "exclusive_bot_mentions",
        "observe_unmentioned_group_messages",
        "dm_policy", "allow_from", "allow_admin_from", "user_allowed_commands",
        "group_policy", "group_allow_from", "group_allow_admin_from",
        "group_user_allowed_commands",
        "channel_skill_bindings", "channel_prompts",
        "gateway_restart_notification", "typing_indicator", "typing_status_text",
    ]

    /// The dotted prefix Hermes bridges `platform`'s shared keys FROM, given
    /// a parsed `config.yaml`.
    ///
    /// Mirrors `platform_section`'s two steps exactly: a top-level block
    /// wins, else `gateway.platforms.<p>`, else `platforms.<p>`. "Is a
    /// block" is Hermes's own `isinstance(…, dict)` test — a bare `slack:`
    /// with no children is `None` to PyYAML and is NOT a dict, which here is
    /// "the flat parse has no `slack.*` key and no `slack` map".
    ///
    /// The `platforms.<p>` fall-through is also the answer for a config that
    /// mentions the platform nowhere: a first-run write has to land
    /// somewhere, and the nested spelling is the modern one Hermes documents.
    public static func bridgeSourcePrefix(platform: String, in parsed: ParsedYAML) -> String {
        func isBlock(_ section: String) -> Bool {
            if parsed.maps[section]?.isEmpty == false { return true }
            let dot = section + "."
            return parsed.values.keys.contains { $0.hasPrefix(dot) }
                || parsed.lists.keys.contains { $0.hasPrefix(dot) }
                || parsed.maps.keys.contains { $0.hasPrefix(dot) }
        }
        if isBlock(platform) { return platform }
        if isBlock("gateway.platforms.\(platform)") { return "gateway.platforms.\(platform)" }
        return "platforms.\(platform)"
    }

    /// ``bridgeSourcePrefix(platform:in:)`` from raw `config.yaml` text.
    /// An unreadable or absent file is the empty string, which resolves to
    /// the `platforms.<p>` default — the same answer a fresh host gives.
    public static func bridgeSourcePrefix(platform: String, configText: String) -> String {
        bridgeSourcePrefix(platform: platform, in: HermesYAML.parseNestedYAML(configText))
    }

    /// Split a config.yaml key into `(platform, sharedKey)` when it is a
    /// `_SHARED_KEYS` member of a known platform, in any of the four
    /// spellings Scarf's setup forms write: `<p>.<key>`,
    /// `platforms.<p>.<key>`, `platforms.<p>.extra.<key>` and
    /// `gateway.platforms.<p>.<key>`. `nil` for everything else.
    ///
    /// The platform segment is matched against ``bridgeResolvedPlatforms``
    /// rather than accepted as "whatever came before the leaf", so an
    /// unrelated key that happens to end in a shared-key name is never
    /// rewritten — and neither is a platform whose reader still expects one
    /// hard-coded spelling.
    public static func split(key: String) -> (platform: String, sharedKey: String)? {
        var parts = key.split(separator: ".").map(String.init)
        guard let leaf = parts.popLast(), names.contains(leaf) else { return nil }
        if parts.last == "extra" { parts.removeLast() }
        guard let platform = parts.popLast(), bridgeResolvedPlatforms.contains(platform) else { return nil }
        // What is left must be one of the recognised prefixes — nothing,
        // `platforms`, or `gateway.platforms`.
        switch parts {
        case [], ["platforms"], ["gateway", "platforms"]: return (platform, leaf)
        default: return nil
        }
    }

    /// Rewrite a setup form's `hermes config set` batch so every
    /// `_SHARED_KEYS` member lands on the section Hermes will actually bridge
    /// it from, leaving every other key exactly as written.
    ///
    /// This is `t-6fa3fc84`'s fix, applied in ONE place rather than in each
    /// of the fifteen forms: the forms keep spelling their keys literally
    /// (which is also what keeps them visible to the write/read parity gate),
    /// and the shared executor — which is already the single `config set`
    /// site — resolves the spelling in effect against the config.yaml on the
    /// host at save time. Resolving at SAVE time rather than at load time is
    /// deliberate: a form can sit open across a `hermes setup` run that adds
    /// the top-level block.
    ///
    /// A rewrite that would collide with a key the batch already spells
    /// correctly is dropped rather than overwriting it — two entries setting
    /// one key would be two `config set` spawns racing on one line.
    public static func resolved(
        _ configKV: [String: String],
        configText: String
    ) -> [String: String] {
        let parsed = HermesYAML.parseNestedYAML(configText)
        var prefixes: [String: String] = [:]
        var out: [String: String] = [:]
        for (key, value) in configKV {
            guard let (platform, sharedKey) = split(key: key) else {
                out[key] = value
                continue
            }
            var prefix = prefixes[platform]
            if prefix == nil {
                prefix = bridgeSourcePrefix(platform: platform, in: parsed)
                prefixes[platform] = prefix
            }
            let target = (prefix ?? "platforms.\(platform)") + "." + sharedKey
            if target != key, configKV[target] != nil {
                out[key] = value          // the batch already spells it right
            } else {
                out[target] = value
            }
        }
        return out
    }

    /// The platforms whose READER resolves the bridge source, and therefore
    /// the only ones whose WRITER may be moved onto it.
    ///
    /// This list is short on purpose, and the shortness is the finding, not
    /// the fix. `HermesConfig+YAML` reads slack's `require_mention` /
    /// `reply_in_thread` and telegram's `require_mention` through
    /// `sharedPlatformScalar` (P20); every other platform's shared keys are
    /// read from ONE hard-coded spelling —
    /// `platforms.signal.extra.require_mention`,
    /// `platforms.whatsapp_cloud.extra.dm_policy` / `.allow_from`,
    /// `discord.require_mention` / `.free_response_channels`,
    /// `matrix.require_mention`, `mattermost.require_mention`,
    /// `whatsapp.unauthorized_dm_behavior` / `.reply_prefix`.
    ///
    /// Rewriting those writes without fixing those reads would trade one
    /// half of the bug for the other: the value would reach Hermes and stop
    /// reaching the form, which is worse than today (the form would then
    /// contradict a setting that IS live). They need the read and the write
    /// moved in the same commit — filed, not smuggled in here.
    ///
    /// `HermesPlatformSharedKeyWriteP44Tests` pins this set against
    /// `HermesConfig+YAML.swift`'s actual `sharedPlatform*` call sites, so a
    /// reader that adopts the bridge fails the test until it is added here.
    public static let bridgeResolvedPlatforms: Set<String> = ["slack", "telegram"]
}
