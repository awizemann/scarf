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
///
/// ## The hazard this type does NOT close
///
/// Moving a shared key onto the bridge source stops THAT key creating a
/// top-level block. It does not stop an UNSHARED one: `hermes config set
/// telegram.reactions …` writes a bare `telegram:` block on a host that had
/// none, `platform_section` then takes that block as the bridge source
/// (`gateway/config_loader.py:171-180` @ `v2026.9.7`), and every nested
/// `platforms.telegram.<shared key>` beside it stops reaching `extra` — a
/// setting the user never touched, turned off by a write to an unrelated
/// key. Every bare `<platform>.<unshared>` key a setup form writes is that
/// shape. Filed rather than closed here, because closing it means either
/// writing the unshared keys nested too (each has its own hard-coded
/// reader) or seeding the new block with what it displaces.
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
    /// The one shape that divergence missed is an EXPLICITLY empty flow map,
    /// `slack: {}`. PyYAML loads that as `{}`, `isinstance({}, dict)` is
    /// `True`, and `platform_section` (`gateway/config_loader.py:175`) takes
    /// it as the top-level block — so the nested `platforms.slack.*` shared
    /// keys are never bridged, exactly as if the block had children. Scarf's
    /// flat parse DOES record it — `maps["slack"] = [:]` — but `isBlock`
    /// asked `?.isEmpty == false`, so an empty one answered false and both
    /// halves resolved to `platforms.slack`: the form read a value the
    /// adapter never sees and wrote back to a section Hermes does not bridge
    /// from. The fix is to stop asking whether the map has
    /// MEMBERS and ask whether the parse recorded one at all:
    /// `parseNestedYAML` sets `maps[path]` for an inline flow map (`{…}`,
    /// empty or not, `HermesYAML.swift:343-354`) and for a block with scalar
    /// children, while a bare `slack:` header records neither — it only
    /// pushes the stack. So `maps[section] != nil` is exactly Hermes's
    /// `isinstance(section, dict)`, empty case included, and the bare header
    /// still loses.
    ///
    /// The `platforms.<p>` fall-through is also the answer for a config that
    /// mentions the platform nowhere: a first-run write has to land
    /// somewhere, and the nested spelling is the modern one Hermes documents.
    /// P57: a FLAT dotted key is not evidence of a block. `slack.enabled: true`
    /// written at the top level is, to PyYAML, the independent mapping key
    /// `"slack.enabled"` — `yaml_cfg.get("slack")` is then `None`,
    /// `isinstance(None, dict)` is `False`, and `platform_section`
    /// (`gateway/config_loader.py:171-180` @ `v2026.9.7`) falls through to
    /// `gateway.platforms.slack` / `platforms.slack`. Scarf's flat parse
    /// records that line as `values["slack.enabled"]`, which matches the
    /// `slack.` descendant prefix below, so `isBlock("slack")` answered TRUE
    /// and the form both READ from and WROTE to a section Hermes does not
    /// bridge from — and the write then CREATED the real top-level block,
    /// silently unbridging every nested shared key beside it. The parser
    /// already tracks these paths for the last-wins purge; ``ParsedYAML``
    /// now surfaces them, and they are excluded from the prefix scan.
    /// Hand-edited configs only: no Scarf writer emits a dotted key.
    ///
    /// P57b: the exclusion is by the dot's DEPTH, not by the prefix match.
    /// P57 excluded every path under a dotted literal, which also excluded a
    /// dotted key nested INSIDE a real block — `slack:` + `  a.b:` + `    c: 1`
    /// is `{"slack": {"a.b": {"c": 1}}}` to PyYAML (probed, 6.0.3), a genuine
    /// `slack` dict that `platform_section` takes as the top-level block,
    /// and post-P57 Scarf answered `platforms.slack` for it. A dotted key is
    /// evidence AGAINST section `S` only when its dot crosses `S`'s own
    /// boundary — i.e. when it was written SHALLOWER than `S` is deep
    /// (``ParsedYAML/dottedLiteralParentDepths``). A dotted key written at or
    /// below `S`'s depth is an ordinary child of a real `S` block.
    public static func bridgeSourcePrefix(platform: String, in parsed: ParsedYAML) -> String {
        func isBlock(_ section: String) -> Bool {
            let dot = section + "."
            let sectionDepth = section.split(separator: ".").count
            // A descendant OF a dotted literal is no better evidence than the
            // literal itself: `slack.enabled:` opened as a block header makes
            // `{"slack.enabled": {…}}`, still not a `slack` dict — but only
            // when that literal was written above `section`'s level.
            func underDottedLiteral(_ key: String) -> Bool {
                parsed.dottedLiteralPaths.contains { literal in
                    guard key == literal || key.hasPrefix(literal + ".") else { return false }
                    return (parsed.dottedLiteralParentDepths[literal] ?? 0) < sectionDepth
                }
            }
            func hasChild<V>(_ table: [String: V]) -> Bool {
                table.keys.contains { $0.hasPrefix(dot) && !underDottedLiteral($0) }
            }
            // The recorded-map test runs under the SAME exclusion. P57b: a
            // dotted key whose path IS the section — `gateway:` + a literal
            // `platforms.slack:` header — records `maps["gateway.platforms.
            // slack"]`, and answering on that alone let the dotted spelling
            // claim the nested section it only looks like. PyYAML reads that
            // file as `{'gateway': {'platforms.slack': {…}}}`, where
            // `gateway["platforms"]` is None.
            if parsed.maps[section] != nil, !underDottedLiteral(section) { return true }
            return hasChild(parsed.values) || hasChild(parsed.lists) || hasChild(parsed.maps)
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
    /// The `(platform, key)` PAIR is matched against ``bridgeResolvedKeys``
    /// rather than accepted as "whatever came before the leaf", so an
    /// unrelated key that happens to end in a shared-key name is never
    /// rewritten — and neither is a key whose reader still expects one
    /// hard-coded spelling on a platform some OTHER key of which does
    /// resolve the bridge. P44 scoped this to the PLATFORM, and that is
    /// exactly what broke `<p>.gateway_restart_notification`, whose reader
    /// (`HermesConfig+YAML.swift:695`, `boolTrueDefault("\(p).…")`) is
    /// hard-coded top-level: the rewrite sent it to `platforms.<p>.…` on
    /// every nested-only config and the toggle became write-only.
    public static func split(key: String) -> (platform: String, sharedKey: String)? {
        var parts = key.split(separator: ".").map(String.init)
        guard let leaf = parts.popLast(), names.contains(leaf) else { return nil }
        if parts.last == "extra" { parts.removeLast() }
        guard let platform = parts.popLast(),
              bridgeResolvedKeys.contains(SharedKeyRef(platform: platform, key: leaf))
        else { return nil }
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
    ///
    /// ## The prefix is resolved against the file AS THE BATCH WILL LEAVE IT
    ///
    /// A batch is not one write: `hermes config set` runs once per pair, and
    /// the pairs a form sends are not all shared keys. `TelegramSetupViewModel`
    /// sends bare `telegram.require_mention` (shared) beside bare
    /// `telegram.reactions` and `telegram.disable_topic_auto_rename` (not
    /// shared, so untouched). Resolved against the PRE-save file — which has
    /// no top-level `telegram:` — `require_mention` moves to
    /// `platforms.telegram.require_mention`, while `reactions` CREATES the
    /// top-level block. On the next load `platform_section` bridges from
    /// `telegram:` and `require_mention` is not in it: the batch invalidated
    /// its own resolution. So a bare `<platform>.<anything>` anywhere in the
    /// batch pins the prefix to `<platform>` for that platform, because the
    /// file will carry that top-level block once the batch lands.
    ///
    /// ## This MOVES, it does not MIGRATE
    ///
    /// The value is written at the resolved spelling and whatever sits at the
    /// source spelling is left behind as a stale shadow. Hermes ignores it —
    /// only the bridge source reaches `extra` — but it is visible in
    /// config.yaml and will re-emerge if the bridge source later changes.
    /// Clearing it is not available: `hermes config` has no delete for an
    /// arbitrary key (`config unset` is the host-default-picker verb, not a
    /// general remove), so Scarf would have to hand-edit config.yaml to do
    /// it. Filed as a task rather than done here.
    public static func resolved(
        _ configKV: [String: String],
        configText: String
    ) -> [String: String] {
        let parsed = HermesYAML.parseNestedYAML(configText)
        // Platforms the batch itself gives a top-level block to.
        //
        // A key this function is about to MOVE does not count: it is not
        // going to be written at its bare spelling, so it creates no block.
        // Counting it was P46b's second half of finding 2 — the toggle's own
        // bare `slack.gateway_restart_notification` pinned the prefix to
        // `slack`, and the rewrite that was supposed to keep the key off a
        // fresh top-level block resolved straight back onto one.
        var batchTopLevel: Set<String> = []
        for key in configKV.keys {
            let parts = key.split(separator: ".")
            guard parts.count == 2, split(key: key) == nil else { continue }
            batchTopLevel.insert(String(parts[0]))
        }
        var prefixes: [String: String] = [:]
        var out: [String: String] = [:]
        for (key, value) in configKV {
            guard let (platform, sharedKey) = split(key: key) else {
                out[key] = value
                continue
            }
            var prefix = prefixes[platform]
            if prefix == nil {
                prefix = batchTopLevel.contains(platform)
                    ? platform
                    : bridgeSourcePrefix(platform: platform, in: parsed)
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

    /// One `(platform, key)` whose reader resolves the bridge source.
    public struct SharedKeyRef: Hashable, Sendable, Comparable {
        public let platform: String
        public let key: String
        public init(platform: String, key: String) {
            self.platform = platform
            self.key = key
        }
        public static func < (a: Self, b: Self) -> Bool {
            (a.platform, a.key) < (b.platform, b.key)
        }
    }

    /// The `(platform, key)` PAIRS whose READER resolves the bridge source,
    /// and therefore the only writes that may be moved onto it.
    ///
    /// Scoping this by PLATFORM was P44's bug. `slack` has a reader that
    /// resolves the bridge for `require_mention` and one that does NOT for
    /// `gateway_restart_notification` (`HermesConfig+YAML.swift:695`, a flat
    /// `boolTrueDefault("slack.gateway_restart_notification")`), so a
    /// platform-scoped allowlist moved a key whose reader could not follow
    /// and `GatewayBehaviorViewModel`'s toggle became write-only on every
    /// nested-only config.
    ///
    /// This list is short on purpose, and the shortness is the finding, not
    /// the fix. `HermesConfig+YAML` reads slack's `require_mention` /
    /// `reply_in_thread`, telegram's `require_mention` and mattermost's
    /// `require_mention` through `sharedPlatformScalar` (P20; mattermost in P51b);
    /// every other shared key is read from ONE hard-coded spelling —
    /// `platforms.signal.extra.require_mention`,
    /// `platforms.whatsapp_cloud.extra.dm_policy` / `.allow_from`,
    /// `discord.require_mention` / `.free_response_channels`,
    /// `matrix.require_mention`,
    /// `whatsapp.unauthorized_dm_behavior` / `.reply_prefix`.
    ///
    /// Rewriting those writes without fixing those reads would trade one
    /// half of the bug for the other: the value would reach Hermes and stop
    /// reaching the form, which is worse than today (the form would then
    /// contradict a setting that IS live). They need the read and the write
    /// moved in the same commit — filed, not smuggled in here.
    ///
    /// `HermesPlatformSharedKeyWriteP44Tests` pins this set against
    /// `HermesConfig+YAML.swift`'s actual `sharedPlatform*` call sites —
    /// both arguments of each — so a reader that adopts the bridge fails the
    /// test until it is added here.
    public static let bridgeResolvedKeys: Set<SharedKeyRef> = [
        SharedKeyRef(platform: "slack", key: "require_mention"),
        SharedKeyRef(platform: "slack", key: "reply_in_thread"),
        SharedKeyRef(platform: "telegram", key: "require_mention"),
        SharedKeyRef(platform: "slack", key: "gateway_restart_notification"),
        SharedKeyRef(platform: "telegram", key: "gateway_restart_notification"),
        SharedKeyRef(platform: "mattermost", key: "require_mention"),
    ]
}
