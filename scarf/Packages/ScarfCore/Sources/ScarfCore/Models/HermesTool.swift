import Foundation

public struct HermesToolset: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let icon: String
    public var enabled: Bool

    public init(
        name: String,
        description: String,
        icon: String,
        enabled: Bool
    ) {
        self.name = name
        self.description = description
        self.icon = icon
        self.enabled = enabled
    }
}

public struct HermesToolPlatform: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let icon: String
    /// First Hermes version that HAS this adapter, or `nil` for a row that
    /// predates every version Scarf supports OR is deliberately left
    /// ungated. A row is hidden on a host below its floor — and on an
    /// undetected one — so the Platforms list never offers a channel the
    /// host cannot listen on (C1). Each floor was found by walking
    /// `gateway/platforms/` and `plugins/platforms/` across EVERY tag, not
    /// by diffing two of them.
    ///
    /// **Which rows carry one** (Alan's round-2 decision 6, 2026-09-10):
    /// every row added in a Scarf parity cycle with a known floor does —
    /// `photon` carried one and `whatsapp_cloud`, the same v0.17 adapter,
    /// did not, and the rest of the `-- v0.1x additions` groups were
    /// ungated the same way. The standing exception is a row that predates
    /// this audit cycle and has no parity-cycle floor attribution —
    /// `bluebubbles`, which shipped as `imessage` from Scarf's own
    /// beginnings: enforcing its 0.9 floor would REMOVE a row users already
    /// see whenever the probe has not answered. The original core roster
    /// (`cli` … `mattermost`) is ungated for the same reason and because
    /// every one of those adapters predates v0.6.0 anyway.
    public let minimumVersion: HermesCapabilities.SemVer?

    public init(
        name: String,
        displayName: String,
        icon: String,
        minimumVersion: HermesCapabilities.SemVer? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.icon = icon
        self.minimumVersion = minimumVersion
    }

    /// Whether this row belongs on `capabilities`' host.
    public func isAvailable(on capabilities: HermesCapabilities) -> Bool {
        guard let minimumVersion else { return true }
        return capabilities.isAtLeast(minimumVersion)
    }

    /// Whether the Platforms list should show this row.
    ///
    /// `isAvailable` plus the widen-for-current escape hatch every other
    /// lossy gate in Scarf carries (`HermesServiceTier.editorStyle`,
    /// `WebToolsBackendRoster.editorStyle`): an `.empty` capabilities value
    /// means the PROBE FAILED, not "old host", and hiding a row the user has
    /// ALREADY configured hides their own config behind a failed probe. So a
    /// configured platform stays listed regardless of floor — they can see
    /// and fix what they set up. An UNconfigured row below the floor stays
    /// hidden, which is the point of the gate: never offer a channel the
    /// host cannot listen on.
    public func isVisible(on capabilities: HermesCapabilities, isConfigured: Bool) -> Bool {
        isConfigured || isAvailable(on: capabilities)
    }
}

public enum KnownPlatforms {
    public static let cli = HermesToolPlatform(name: "cli", displayName: "CLI", icon: "terminal")
    public static let all: [HermesToolPlatform] = [
        cli,
        HermesToolPlatform(name: "telegram", displayName: "Telegram", icon: "paperplane"),
        HermesToolPlatform(name: "discord", displayName: "Discord", icon: "bubble.left.and.bubble.right"),
        HermesToolPlatform(name: "slack", displayName: "Slack", icon: "number"),
        HermesToolPlatform(name: "whatsapp", displayName: "WhatsApp", icon: "phone.bubble"),
        HermesToolPlatform(name: "signal", displayName: "Signal", icon: "lock.shield"),
        HermesToolPlatform(name: "email", displayName: "Email", icon: "envelope"),
        HermesToolPlatform(name: "homeassistant", displayName: "Home Assistant", icon: "house"),
        HermesToolPlatform(name: "webhook", displayName: "Webhook", icon: "arrow.up.right.square"),
        HermesToolPlatform(name: "matrix", displayName: "Matrix", icon: "lock.rectangle.stack"),
        HermesToolPlatform(name: "feishu", displayName: "Feishu", icon: "message.badge.circle"),
        HermesToolPlatform(name: "mattermost", displayName: "Mattermost", icon: "bubble.left.and.exclamationmark.bubble.right"),
        // `bluebubbles` is the id Hermes uses (`Platform.BLUEBUBBLES`,
        // `gateway/platforms/bluebubbles.py`); Scarf shipped it as
        // `imessage`, which is not a Hermes platform id at any version — so
        // the row's `bluebubbles:` config block was invisible to the
        // "Configured" check, which fell back to the env var alone. Renamed
        // in the v0.21.1 B4 sweep rather than adding a SECOND row for the
        // real id, which would have given the same platform two entries
        // (one with the setup form, one without). The old `imessage`
        // spelling is still accepted by `icon(for:)` and by the
        // `PlatformsView` / `identifyingEnvVar` switches.
        // NOT gated, deliberately: this row has shipped in Scarf since long
        // before the roster sweep (as `imessage`), so putting its true 0.9
        // floor on it would REMOVE a row users already see whenever the
        // version probe has not answered yet (C1). The adapter itself lands
        // at v2026.4.13 = 0.9.0.
        HermesToolPlatform(name: "bluebubbles", displayName: "iMessage (BlueBubbles)", icon: "message.fill"),
        // -- v0.12 additions ---------------------------------------------
        // Yuanbao is a native gateway adapter (18th platform); Microsoft
        // Teams ships as a plugin (19th). PlatformDetail surfaces the
        // distinction in the setup copy. Names match Hermes's gateway
        // platform identifiers — Teams is `teams` (plugins/platforms/teams/
        // adapter.py), not `microsoft-teams`.
        HermesToolPlatform(name: "yuanbao", displayName: "Yuanbao 元宝", icon: "bubble.left.and.bubble.right.fill", minimumVersion: HermesCapabilities.yuanbaoPlatformFloor),
        HermesToolPlatform(name: "teams", displayName: "Microsoft Teams", icon: "person.2.fill", minimumVersion: HermesCapabilities.teamsPlatformFloor),
        // -- v0.13 additions ---------------------------------------------
        // Google Chat is the 20th gateway platform. Setup runs through
        // `hermes setup` rather than per-field forms because the auth
        // dance is OAuth-style and lives outside Scarf. Identifier is
        // `google_chat` (snake_case, per plugins/platforms/google_chat/
        // adapter.py) — earlier Scarf releases wrongly used `google-chat`.
        HermesToolPlatform(name: "google_chat", displayName: "Google Chat", icon: "bubble.left.fill", minimumVersion: HermesCapabilities.googleChatPlatformFloor),
        // -- v0.14 additions ---------------------------------------------
        // LINE Messaging API (21st platform, first-class native adapter)
        // and SimpleX Chat (22nd platform, talks to a local
        // `simplex-chat` daemon in WebSocket mode). Identifiers match
        // Hermes's gateway platform names verbatim.
        HermesToolPlatform(name: "line", displayName: "LINE", icon: "bubble.left.and.text.bubble.right", minimumVersion: HermesCapabilities.linePlatformFloor),
        HermesToolPlatform(name: "simplex", displayName: "SimpleX Chat", icon: "lock.shield.fill", minimumVersion: HermesCapabilities.simplexPlatformFloor),
        // -- v0.15 additions ---------------------------------------------
        // ntfy (23rd platform) — pub/sub push via an ntfy.sh-compatible
        // server. Outbound-capable with an optional separate publish
        // topic; auth is an optional bearer token or `user:pass` Basic.
        // Identifier matches Hermes's gateway platform name verbatim.
        HermesToolPlatform(name: "ntfy", displayName: "ntfy", icon: "bell.badge", minimumVersion: HermesCapabilities.ntfyPlatformFloor),
        // -- v0.17 additions ---------------------------------------------
        // WhatsApp Business Cloud API (25th platform) — Meta's hosted webhook
        // path, distinct from the older `whatsapp` web-bridge. (iMessage via
        // Photon was held back here as a moving protocol; it is rostered
        // below as of the v0.21.1 B4 sweep, still without a setup form.)
        HermesToolPlatform(name: "whatsapp_cloud", displayName: "WhatsApp Cloud", icon: "phone.bubble.fill", minimumVersion: HermesCapabilities.whatsAppCloudPlatformFloor),
        // -- v0.19.1 additions -------------------------------------------
        // Buzz — Block's Nostr-based messenger (plugins/platforms/buzz/).
        // User-gated via `allowed_users` (hex pubkeys / npubs), so it has
        // no GatewayAllowlistKind mapping. Filed under "v0.20" until the
        // round-2 walk: the directory first exists at tag v2026.7.30, whose
        // `pyproject.toml` reads `version = "0.19.1"` — the same tag the
        // v0.20 audit mis-read as an unnumbered pre-release.
        HermesToolPlatform(name: "buzz", displayName: "Buzz", icon: "bolt.horizontal.circle", minimumVersion: HermesCapabilities.buzzPlatformFloor),
        // -- v0.21.1 audit finding B4 -------------------------------------
        // Ten platform ids that are REAL and user-configurable at BOTH
        // v2026.8.31 (0.21.0) and v2026.9.7 (0.21.1) but were never in this
        // roster. Sources at tag v2026.9.7: the `Platform` enum in
        // `gateway/config.py:198-224` (sms, dingtalk, api_server,
        // msgraph_webhook, wecom, weixin, qqbot) plus the bundled plugin
        // adapter directories `plugins/platforms/{irc,photon}` (dynamic enum
        // members via `Platform._missing_`). The tenth, `bluebubbles`, was
        // already in the roster under the wrong id — see the rename above.
        //
        // These are NOT release-gated: they exist at every Hermes version
        // Scarf supports, so surfacing them is a bug fix rather than a
        // v0.21.1 surface, and no capability flag applies. Platforms without
        // a per-field setup view fall to `PlatformsView`'s default panel
        // ("No setup form for this platform yet"), which is the same
        // degradation `buzz` has had since v0.19.1.
        //
        // DELIBERATELY EXCLUDED, verified at v2026.9.7:
        //  - `local` (Platform.LOCAL), `relay` (marked EXPERIMENTAL in the
        //    enum comment) and `wecom_callback` — internal/infrastructure
        //    members with no adapter directory of their own and no user
        //    messaging account behind them.
        //  - `a2a` (`plugins/platforms/a2a/`) — agent-to-agent protocol
        //    infrastructure, `requires_env: []`, configured entirely through
        //    `optional_env` bearer tokens/bind host in `hermes config`. This
        //    repeats the explicit v0.20 decision not to roster it.
        //  - `raft` (`plugins/platforms/raft/`) — an experimental external
        //    bridge whose whole config surface is one env var (`RAFT_PROFILE`,
        //    "auto-enables the adapter when set"); it has no token, no
        //    allowlist and no `enabled` key, so a roster row would offer
        //    nothing to configure.
        // Floors, walked across every tag (`git ls-tree` over
        // gateway/platforms + plugins/platforms). dingtalk / sms /
        // api_server land at v2026.3.23 (0.4.0) and wecom at v2026.3.30
        // (0.6.0) — at or below Scarf's oldest supported host, so no gate.
        // The rest carry one, and every floor is a shared
        // `HermesCapabilities.<name>PlatformFloor` constant rather than an
        // inline literal, so the roster row and the evidence for its floor
        // cannot drift: weixin v2026.4.13 (0.9.0), qqbot v2026.4.16 (0.10.0),
        // irc v2026.4.30 (0.12.0), msgraph_webhook v2026.5.16 (0.14.0),
        // photon v2026.6.19 (0.17.0).
        HermesToolPlatform(name: "dingtalk", displayName: "DingTalk", icon: "text.bubble"),
        HermesToolPlatform(name: "sms", displayName: "SMS", icon: "message"),
        HermesToolPlatform(name: "irc", displayName: "IRC", icon: "number.square", minimumVersion: HermesCapabilities.ircPlatformFloor),
        HermesToolPlatform(name: "wecom", displayName: "WeCom", icon: "building.2"),
        HermesToolPlatform(name: "weixin", displayName: "Weixin", icon: "captions.bubble", minimumVersion: HermesCapabilities.weixinPlatformFloor),
        HermesToolPlatform(name: "qqbot", displayName: "QQ Bot", icon: "bubble.right", minimumVersion: HermesCapabilities.qqbotPlatformFloor),
        HermesToolPlatform(name: "msgraph_webhook", displayName: "Microsoft Graph Webhook", icon: "network", minimumVersion: HermesCapabilities.msgraphWebhookPlatformFloor),
        HermesToolPlatform(name: "api_server", displayName: "API Server", icon: "server.rack"),
        // Floor shared with `HermesCapabilities.hasPhotonPlatform` rather than
        // repeated as a literal, so the roster row and the flag cannot drift.
        HermesToolPlatform(name: "photon", displayName: "iMessage via Photon", icon: "antenna.radiowaves.left.and.right", minimumVersion: HermesCapabilities.photonPlatformFloor),
    ]

    /// The rows the Platforms list and the Tools tab's platform menu should
    /// offer, in roster order.
    ///
    /// ONE seam for both surfaces. P23 gated the Platforms list and left the
    /// Tools picker on the raw roster, so a 0.14 host hid `ntfy` in one place
    /// while the other still offered to shell
    /// `hermes tools enable … --platform ntfy` at an adapter the host does not
    /// have (charter C5). `isConfigured` is a closure rather than a `Set` so a
    /// caller can answer it from whatever it already holds.
    public static func visible(
        on capabilities: HermesCapabilities,
        isConfigured: (String) -> Bool
    ) -> [HermesToolPlatform] {
        all.filter { $0.isVisible(on: capabilities, isConfigured: isConfigured($0.name)) }
    }

    /// Snap a selection back when the visible roster no longer contains it.
    ///
    /// The roster NARROWS after the fact: both surfaces deliberately render
    /// every row until the detached read has told them which platforms are
    /// configured (`hasLoadedConfiguredPlatforms` / `hasLoadedPlatforms`), so
    /// a user can select a sub-floor row in that window and keep it — the
    /// Platforms detail pane switches on the selected NAME with no visibility
    /// check, and the Tools picker's selection is what `toggleTool` passes to
    /// `hermes tools enable … --platform <name>` (charter C5). Neither
    /// selection binding can CLEAR itself: both can only ever be set from the
    /// visible list.
    ///
    /// Round-3 decision 8 is "snap back", and the snap target is `cli` — the
    /// one row that is unfloored, always configured, and already both
    /// surfaces' initial selection.
    public static func reconcile(
        selection: HermesToolPlatform,
        against visible: [HermesToolPlatform]
    ) -> HermesToolPlatform {
        visible.contains { $0.name == selection.name } ? selection : cli
    }

    public static func icon(for platform: String) -> String {
        switch platform {
        case "cli": return "terminal"
        case "telegram": return "paperplane"
        case "discord": return "bubble.left.and.bubble.right"
        case "slack": return "number"
        case "whatsapp": return "phone.bubble"
        case "signal": return "lock.shield"
        case "email": return "envelope"
        case "homeassistant": return "house"
        case "webhook": return "arrow.up.right.square"
        case "matrix": return "lock.rectangle.stack"
        case "feishu": return "message.badge.circle"
        case "mattermost": return "bubble.left.and.exclamationmark.bubble.right"
        // `bluebubbles` is the real Hermes id; `imessage` is the legacy
        // Scarf spelling, kept so old callers still resolve.
        case "bluebubbles", "imessage": return "message.fill"
        case "yuanbao": return "bubble.left.and.bubble.right.fill"
        // Legacy hyphenated spellings accepted for callers still holding
        // pre-fix identifiers (Scarf < v0.20 parity used them wrongly).
        case "teams", "microsoft-teams": return "person.2.fill"
        case "google_chat", "google-chat", "googlechat": return "bubble.left.fill"
        case "line": return "bubble.left.and.text.bubble.right"
        case "simplex": return "lock.shield.fill"
        case "ntfy": return "bell.badge"
        case "whatsapp_cloud": return "phone.bubble.fill"
        case "buzz": return "bolt.horizontal.circle"
        // -- v0.21.1 audit finding B4 -------------------------------------
        case "dingtalk": return "text.bubble"
        case "sms": return "message"
        case "irc": return "number.square"
        case "wecom": return "building.2"
        case "weixin": return "captions.bubble"
        case "qqbot": return "bubble.right"
        case "msgraph_webhook": return "network"
        case "api_server": return "server.rack"
        case "photon": return "antenna.radiowaves.left.and.right"
        default: return "bubble.left"
        }
    }
}
