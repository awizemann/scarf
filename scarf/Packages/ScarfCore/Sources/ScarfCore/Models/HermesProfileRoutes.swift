import Foundation

/// One `profile_routes` rule — a match scope (platform + optional
/// guild/chat/thread ids) mapped to a Hermes profile.
///
/// **Source of truth:** hermes-agent `gateway/profile_routing.py` at tag
/// v2026.8.3 (v0.20.0) — `ProfileRoute` (line 50), `parse_profile_routes`
/// (line 105) — and `docs/profile-routing.md`. The routing feature first
/// shipped in commit 5e65f6d79f "feat(gateway): add profile-based routing
/// for inbound messages" (2026-06-27), first released in tag v2026.7.20 =
/// **Hermes 0.19.0** — hence the `isV019OrLater` floor, not v0.20.
///
/// **Matching is conjunctive.** Every discriminator the rule declares must
/// hold (`matches`, profile_routing.py:74-102): `platform` must be equal,
/// `thread_id` (if set) equal, `guild_id` (if set) equal, and `chat_id` (if
/// set) must equal either the source channel *or* its parent (so a route on
/// a channel also catches threads/forum posts inside it). A field left
/// unset is not a constraint — and because Python treats `""` as falsy in
/// those `if self.<field>` guards, an empty string is *also* "unset". Scarf
/// still omits empty fields from the YAML rather than writing `''`, so the
/// file says exactly what it means.
///
/// **Ranking is by specificity, not list order.** `parse_profile_routes`
/// sorts most-specific-first with an additive weight (`specificity`,
/// profile_routing.py:62-72): `thread_id` 8 + `chat_id` 4 + `guild_id` 2.
/// `match_profile_route` then takes the first match in *that* order. Python's
/// `list.sort` is stable, so rules of equal specificity keep their file
/// order. Any UI must present this ranking rather than implying top-down
/// priority.
public struct HermesProfileRoute: Sendable, Equatable, Identifiable, Hashable {
    /// View identity only — never serialized.
    public var id: UUID
    /// `name` — human-readable identifier used in Hermes logs. Optional on
    /// the Hermes side (defaults to `""`).
    public var name: String
    /// `platform` — required; must equal the source platform exactly
    /// (`discord`, `telegram`, `slack`, …). A rule without it is *skipped*
    /// by `parse_profile_routes` (profile_routing.py:119).
    public var platform: String
    /// `profile` — required target profile id. Normalized + validated by
    /// Hermes; an invalid name means the whole rule is skipped.
    public var profile: String
    /// `guild_id` — optional server/guild constraint. `""` means unset.
    public var guildID: String
    /// `chat_id` — optional channel/group constraint (matches the channel
    /// or a thread whose parent is that channel). `""` means unset.
    public var chatID: String
    /// `thread_id` — optional thread constraint. `""` means unset.
    public var threadID: String
    /// `enabled` — Hermes default `true`; `false` disables the rule without
    /// removing it (profile_routing.py:60, 92).
    public var enabled: Bool
    /// Whether the source YAML actually carried an `enabled:` key. When it
    /// didn't and the rule is enabled, the writer omits the key rather than
    /// materializing Hermes's default into the file.
    public var enabledIsExplicit: Bool
    /// Verbatim lines for keys Hermes wrote that Scarf doesn't model,
    /// dedented to the rule's base indent (nested bodies included). Written
    /// back unchanged so an unmodeled key is never silently dropped.
    public var extraLines: [String]

    public init(
        id: UUID = UUID(),
        name: String = "",
        platform: String = "",
        profile: String = "",
        guildID: String = "",
        chatID: String = "",
        threadID: String = "",
        enabled: Bool = true,
        enabledIsExplicit: Bool = false,
        extraLines: [String] = []
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.profile = profile
        self.guildID = guildID
        self.chatID = chatID
        self.threadID = threadID
        self.enabled = enabled
        self.enabledIsExplicit = enabledIsExplicit
        self.extraLines = extraLines
    }

    /// `user_id` as written in the rule, read from ``extraLines`` (Scarf
    /// does not edit it, so it round-trips there verbatim). `nil` when the
    /// key is absent; `""` when it is present but null or blank.
    ///
    /// Hermes 0.21.4+ treats it as a sender discriminator worth +16 and drops
    /// a rule whose `user_id` is null or blank (`gateway/profile_routing.py:65-70`,
    /// `:140-143` @ `v2026.9.24`); see ``HermesCapabilities/hasProfileRouteUserID``.
    public var userID: String? { extraScalar("user_id") }

    /// `bot_profile` as written, read from ``extraLines``. `nil` when absent.
    /// From 0.21.3 a rule only applies to messages received by that
    /// profile's bot; absent, blank or `default` means the default
    /// profile's shared bot (`_bot_profile_key`,
    /// `gateway/profile_routing.py:86-88`, `:101-104` @ `v2026.9.24`); see
    /// ``HermesCapabilities/hasProfileRouteBotScope``.
    public var botProfile: String? { extraScalar("bot_profile") }

    /// The bot this rule is scoped to, when it is not the default profile's.
    public func scopedBotProfile(capabilities: HermesCapabilities) -> String? {
        guard capabilities.hasProfileRouteBotScope,
              let bot = botProfile?.trimmingCharacters(in: .whitespaces),
              !bot.isEmpty, bot != "default" else { return nil }
        return bot
    }

    /// A non-blank `user_id` Hermes matches on, or `nil`.
    private func effectiveUserID(capabilities: HermesCapabilities) -> String? {
        guard capabilities.hasProfileRouteUserID,
              let id = userID?.trimmingCharacters(in: .whitespaces),
              !id.isEmpty else { return nil }
        return id
    }

    /// A top-level `key: value` from ``extraLines`` (dedented to the rule's
    /// own keys, so a top-level key starts at column 0), unquoted.
    private func extraScalar(_ key: String) -> String? {
        for line in extraLines where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces) == key else { continue }
            var raw = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("#") { raw = "" }
            if let first = raw.first, first != "\"", first != "'",
               let hash = raw.range(of: " #") {
                raw = String(raw[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if raw == "null" || raw == "~" || raw == "Null" || raw == "NULL" { return "" }
            return YAMLScalar.unquote(raw)
        }
        return nil
    }

    /// Additive match weight — mirror of `ProfileRoute.specificity`
    /// (`gateway/profile_routing.py:65-70` @ `v2026.9.24`): server 2 +
    /// channel 4 + thread 8, plus 16 for a `user_id` on hosts that match on
    /// it. Higher wins.
    public func specificity(capabilities: HermesCapabilities) -> Int {
        var s = 0
        if !guildID.isEmpty { s += 2 }
        if !chatID.isEmpty { s += 4 }
        if !threadID.isEmpty { s += 8 }
        if effectiveUserID(capabilities: capabilities) != nil { s += 16 }
        return s
    }

    /// Whether `parse_profile_routes` would keep this rule. It drops rules
    /// with a missing `platform`/`profile` or an invalid profile name, and
    /// from 0.21.4 a rule whose `user_id` key is null or blank
    /// (`gateway/profile_routing.py:124-143` @ `v2026.9.24`) — a dropped rule
    /// is silently inert in Hermes, so the UI flags it instead.
    public func isAcceptedByHermes(capabilities: HermesCapabilities) -> Bool {
        rejectionReason(capabilities: capabilities) == nil
    }

    /// Human-readable reason this rule would be dropped, or `nil` when it's
    /// accepted.
    public func rejectionReason(capabilities: HermesCapabilities) -> String? {
        if platform.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Hermes ignores this route: platform is required.")
        }
        if profile.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Hermes ignores this route: profile is required.")
        }
        if !HermesProfileName.isValid(profile) {
            return String(localized: "Hermes ignores this route: “\(profile)” is not a valid profile name (lowercase [a-z0-9][a-z0-9_-]{0,63}, and not a reserved name).")
        }
        if capabilities.hasProfileRouteUserID,
           let id = userID, id.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Hermes ignores this route: user_id is empty. Set a user id or remove the key.")
        }
        return nil
    }

    /// Label of the first field carrying a control character, or `nil` when
    /// every field is clean.
    ///
    /// Round-3 decision 6. Every field on a route is a single-line scalar,
    /// so a tab, line break or other C0/C1 control is always a paste
    /// accident — and it is the one class of input the old
    /// `ProfileRoutesWriter.quoted` (deleted in P32) emitted BARE, which makes PyYAML's
    /// scanner reject the row and Hermes discard the entire config.yaml
    /// layer (`gateway/config.py:773-792` @ `v2026.9.7`). The editor
    /// refuses it up front, in the shape
    /// `MCPServerEditorViewModel.duplicateKey` established, rather than
    /// silently reshaping a value the user cannot see.
    public var controlCharacterFieldLabel: String? {
        for (label, value) in [
            ("Name", name), ("Platform", platform), ("Server / Guild ID", guildID),
            ("Channel / Chat ID", chatID), ("Thread ID", threadID), ("Profile", profile)
        ] where YAMLScalar.containsControlCharacter(value) {
            return label
        }
        return nil
    }

    /// One-line scope summary for list rows (e.g. `discord · server 123 · channel 456`).
    /// On hosts that match on them it also names the sender (`user_id`) and
    /// the receiving bot (`bot_profile`) the rule is limited to.
    public func scopeSummary(capabilities: HermesCapabilities) -> String {
        var parts: [String] = []
        if !platform.isEmpty { parts.append(platform) }
        if let bot = scopedBotProfile(capabilities: capabilities) { parts.append("bot \(bot)") }
        if !guildID.isEmpty { parts.append("server \(guildID)") }
        if !chatID.isEmpty { parts.append("channel \(chatID)") }
        if !threadID.isEmpty { parts.append("thread \(threadID)") }
        if let user = effectiveUserID(capabilities: capabilities) { parts.append("user \(user)") }
        if guildID.isEmpty, chatID.isEmpty, threadID.isEmpty,
           effectiveUserID(capabilities: capabilities) == nil {
            parts.append("any server/channel")
        }
        return parts.joined(separator: " · ")
    }
}

/// Hermes profile-id rules — mirror of `hermes_cli/profiles.py`
/// `normalize_profile_name` (line 303) + `validate_profile_name` (line 321)
/// at tag v2026.8.3. `parse_profile_routes` runs both on every route's
/// `profile`, so a name these reject makes Hermes drop the whole rule.
public enum HermesProfileName {
    /// `_PROFILE_ID_RE` (profiles.py:37) — Hermes writes it `^…$`, but ICU's
    /// `$` matches before a trailing newline (SEC-L1), so `"work\n"` passed
    /// and was serialized into config.yaml verbatim. `\A…\z` is a deliberate
    /// divergence: stricter than Hermes (which strips before matching), never
    /// looser — callers here validate the raw string they go on to use.
    private static let idPattern = "\\A[a-z0-9][a-z0-9_-]{0,63}\\z"
    /// `_RESERVED_NAMES` (profiles.py:247). `default` is listed there but
    /// `validate_profile_name` returns early for it — it's a valid alias.
    private static let reserved: Set<String> = ["hermes", "test", "tmp", "root", "sudo"]

    /// `normalize_profile_name` — trims, case-folds `default`, lowercases
    /// everything else. Returns `nil` for an empty name (Python raises).
    public static func normalized(_ raw: String) -> String? {
        let stripped = raw.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return nil }
        if stripped.lowercased() == "default" { return "default" }
        return stripped.lowercased()
    }

    /// Whether Hermes would accept this profile name after normalization.
    public static func isValid(_ raw: String) -> Bool {
        guard let name = normalized(raw) else { return false }
        if name == "default" { return true }
        guard name.range(of: idPattern, options: .regularExpression) != nil else { return false }
        return !reserved.contains(name)
    }
}

/// The `profile_routes` block as it exists in a given `config.yaml`, plus
/// the surrounding facts the editor needs.
public struct HermesProfileRoutes: Sendable, Equatable {
    /// Where Hermes reads the list from. `gateway/config_loader.py:76`
    /// bridges it in `"none"` mode (`_bridge_lookup:100-104` at `v2026.9.7`),
    /// which prefers the **top-level** `profile_routes:` and only falls back
    /// to `gateway.profile_routes:` when the top-level key is null/absent — so an
    /// editor must write back to whichever form is live, or its edits are
    /// shadowed.
    public enum Location: String, Sendable, Equatable {
        /// Top-level `profile_routes:` — present and therefore authoritative.
        case topLevel
        /// Nested `gateway.profile_routes:` — the form `hermes config set`
        /// would write, and Scarf's default for a fresh block.
        case gateway
        /// Neither form present.
        case absent
        /// A live block exists but is written in a shape Scarf's scanner
        /// won't rewrite (a populated flow list, `profile_routes: [{…}]`).
        /// Editing anything else would silently shadow it, so the editor
        /// goes read-only instead.
        case unsupported
    }

    /// Routes in file order.
    public var routes: [HermesProfileRoute]
    /// Which form the routes were read from.
    public var location: Location
    /// `multiplex_profiles` (top-level or `gateway.multiplex_profiles`, same
    /// top-level-wins precedence — `gateway/config.py:708-710`). Routing is
    /// gated on it: with multiplexing off, `_profile_name_for_source`
    /// returns `None` before matching (`gateway/run.py:4211-4212` @
    /// `v2026.9.7`) and the whole route list is inert.
    public var multiplexProfiles: Bool
    /// Whether `multiplex_profiles` was found in the **top-level** form. When
    /// it is, `hermes config set gateway.multiplex_profiles …` is shadowed —
    /// the toggle would appear to do nothing — so the UI explains instead of
    /// offering a control that can't win.
    public var multiplexIsTopLevel: Bool
    /// Whether the `multiplex_profiles` spelling in effect carries a value at
    /// all. From v0.21.4 Hermes keeps an unset key `None` so its boot verdict
    /// can tell "the default applies" from "the operator chose"
    /// (`gateway/config.py:781` @ `v2026.9.21`) — see ``multiplexStatus(capabilities:)``.
    public var multiplexIsSet: Bool
    /// The value in effect is an explicit boolish `false` (`false`, `no`,
    /// `off`, `0`). From v0.21.4 that spelling is RETIRED — resolved exactly
    /// like an unset key (`hermes_cli/gateway_multiplex_mode.py:146`, `:154`
    /// @ `v2026.9.21`). An unrecognised token is NOT this: v0.21.4 coerces it
    /// with `_coerce_bool(…, True)` (`gateway/config.py:781`).
    public var multiplexIsExplicitFalse: Bool
    /// `gateway.standalone` is truthy in this config — the v0.21.5
    /// per-profile shim that keeps a NAMED profile's gateway out of the host
    /// multiplexer (`hermes_cli/profiles.py:979-1031` @ `v2026.9.24`, which
    /// reads only the `gateway:` section's key and ignores it on the default
    /// profile, `:976`). Parsed on every host; only surfaced where
    /// ``HermesCapabilities/hasGatewayStandaloneProfiles``.
    public var gatewayStandalone: Bool

    public init(
        routes: [HermesProfileRoute] = [],
        location: Location = .absent,
        multiplexProfiles: Bool = false,
        multiplexIsTopLevel: Bool = false,
        multiplexIsSet: Bool = false,
        multiplexIsExplicitFalse: Bool = false,
        gatewayStandalone: Bool = false
    ) {
        self.routes = routes
        self.location = location
        self.multiplexProfiles = multiplexProfiles
        self.multiplexIsTopLevel = multiplexIsTopLevel
        self.multiplexIsSet = multiplexIsSet
        self.multiplexIsExplicitFalse = multiplexIsExplicitFalse
        self.gatewayStandalone = gatewayStandalone
    }

    /// What `multiplex_profiles` means for routing on the connected host.
    public enum MultiplexStatus: Sendable, Equatable {
        /// Routing runs: pre-v0.21.4 the key is truthy; from v0.21.4 it is
        /// set to something other than a boolish `false`, which the boot
        /// verdict takes without the `implicit_multiplex_blocker` check
        /// (`resolve_multiplex_mode`, `gateway_multiplex_mode.py:143-144` @
        /// `v2026.9.21`). From v0.21.5 the one exception is a named profile
        /// with `gateway.standalone: true`, which `standalone_launcher_decision`
        /// keeps standalone before the key is even read (`:240-242` @
        /// `v2026.9.24`).
        case on
        /// Pre-v0.21.4 only: absent or falsy, so `_profile_name_for_source`
        /// returns before matching and every route is inert.
        case off
        /// v0.21.4+: the key is unset, so multiplexing is the default — but a
        /// REQUEST the gateway grants only when `implicit_multiplex_blocker`
        /// finds nothing (single profile, s6 host, a profile still running
        /// its own gateway, a duplicate bot token). Not "always on".
        case defaultOn
        /// v0.21.4+: an explicit `false`, retired and resolved like
        /// ``defaultOn``. v0.21.5 also rewrites it to `true` on the next
        /// gateway start (``HermesCapabilities/hasMultiplexOptOutRewrite``).
        case retiredOptOut
    }

    /// Below ``HermesCapabilities/hasMultiplexByDefault`` this is exactly the
    /// pre-v0.21.4 reading — ``multiplexProfiles`` on or off — so an older
    /// host renders byte-identically.
    public func multiplexStatus(capabilities: HermesCapabilities) -> MultiplexStatus {
        guard capabilities.hasMultiplexByDefault else {
            return multiplexProfiles ? .on : .off
        }
        if multiplexIsExplicitFalse { return .retiredOptOut }
        return multiplexIsSet ? .on : .defaultOn
    }

    public static let empty = HermesProfileRoutes()

    /// The order Hermes actually evaluates rules in: most specific first,
    /// ties broken by file order (Python's `list.sort` is stable —
    /// profile_routing.py:149). Swift's `sorted(by:)` is *not* guaranteed
    /// stable, so the file index is folded into the comparison explicitly.
    ///
    /// Rules Hermes would drop (`isAcceptedByHermes == false`) are excluded,
    /// because they never take part in matching.
    ///
    /// The ranking is the host's: `user_id` only counts (+16) from 0.21.4.
    /// A `bot_profile` does not change the rank; it narrows which bot's
    /// messages the rule sees, which the row's scope summary names.
    public func effectiveOrder(capabilities: HermesCapabilities) -> [HermesProfileRoute] {
        routes.enumerated()
            .filter { $0.element.isAcceptedByHermes(capabilities: capabilities) }
            .map { (offset: $0.offset, route: $0.element,
                    weight: $0.element.specificity(capabilities: capabilities)) }
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.offset < $1.offset
            }
            .map(\.route)
    }
}
