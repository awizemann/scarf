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

    /// Additive match weight — verbatim mirror of `ProfileRoute.specificity`
    /// (profile_routing.py:62-72). Higher wins.
    public var specificity: Int {
        var s = 0
        if !guildID.isEmpty { s += 2 }
        if !chatID.isEmpty { s += 4 }
        if !threadID.isEmpty { s += 8 }
        return s
    }

    /// Whether `parse_profile_routes` would keep this rule. It drops rules
    /// with a missing `platform`/`profile` (line 119) or an invalid profile
    /// name (line 134) — a dropped rule is silently inert in Hermes, so the
    /// UI flags it instead.
    public var isAcceptedByHermes: Bool {
        !platform.trimmingCharacters(in: .whitespaces).isEmpty
            && HermesProfileName.isValid(profile)
    }

    /// Human-readable reason this rule would be dropped, or `nil` when it's
    /// accepted.
    public var rejectionReason: String? {
        if platform.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Hermes ignores this route: platform is required."
        }
        if profile.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Hermes ignores this route: profile is required."
        }
        if !HermesProfileName.isValid(profile) {
            return "Hermes ignores this route: “\(profile)” is not a valid profile name (lowercase [a-z0-9][a-z0-9_-]{0,63}, and not a reserved name)."
        }
        return nil
    }

    /// One-line scope summary for list rows (e.g. `discord · server 123 · channel 456`).
    public var scopeSummary: String {
        var parts: [String] = []
        if !platform.isEmpty { parts.append(platform) }
        if !guildID.isEmpty { parts.append("server \(guildID)") }
        if !chatID.isEmpty { parts.append("channel \(chatID)") }
        if !threadID.isEmpty { parts.append("thread \(threadID)") }
        if parts.count <= 1 { parts.append("any server/channel") }
        return parts.joined(separator: " · ")
    }
}

/// Hermes profile-id rules — mirror of `hermes_cli/profiles.py`
/// `normalize_profile_name` (line 303) + `validate_profile_name` (line 321)
/// at tag v2026.8.3. `parse_profile_routes` runs both on every route's
/// `profile`, so a name these reject makes Hermes drop the whole rule.
public enum HermesProfileName {
    /// `_PROFILE_ID_RE` (profiles.py:37).
    private static let idPattern = "^[a-z0-9][a-z0-9_-]{0,63}$"
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
    /// Where Hermes reads the list from. `gateway/config.py:1356-1360`
    /// prefers the **top-level** `profile_routes:` and only falls back to
    /// `gateway.profile_routes:` when the top-level key is absent — so an
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
    /// top-level-wins precedence — gateway/config.py:1345-1352). Routing is
    /// gated on it: with multiplexing off, `_profile_name_for_source`
    /// returns `None` before matching (gateway/run.py:23923) and the whole
    /// route list is inert.
    public var multiplexProfiles: Bool
    /// Whether `multiplex_profiles` was found in the **top-level** form. When
    /// it is, `hermes config set gateway.multiplex_profiles …` is shadowed —
    /// the toggle would appear to do nothing — so the UI explains instead of
    /// offering a control that can't win.
    public var multiplexIsTopLevel: Bool

    public init(
        routes: [HermesProfileRoute] = [],
        location: Location = .absent,
        multiplexProfiles: Bool = false,
        multiplexIsTopLevel: Bool = false
    ) {
        self.routes = routes
        self.location = location
        self.multiplexProfiles = multiplexProfiles
        self.multiplexIsTopLevel = multiplexIsTopLevel
    }

    public static let empty = HermesProfileRoutes()

    /// The order Hermes actually evaluates rules in: most specific first,
    /// ties broken by file order (Python's `list.sort` is stable —
    /// profile_routing.py:149). Swift's `sorted(by:)` is *not* guaranteed
    /// stable, so the file index is folded into the comparison explicitly.
    ///
    /// Rules Hermes would drop (`isAcceptedByHermes == false`) are excluded,
    /// because they never take part in matching.
    public var effectiveOrder: [HermesProfileRoute] {
        routes.enumerated()
            .filter { $0.element.isAcceptedByHermes }
            .sorted {
                if $0.element.specificity != $1.element.specificity {
                    return $0.element.specificity > $1.element.specificity
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }
}
