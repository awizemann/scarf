import Testing
import Foundation
@testable import ScarfCore

/// Pure mapping tests for `GatewayAllowlistKind`. Locks down the (platform →
/// kind) table so a refactor doesn't accidentally drop a platform.
@Suite struct GatewayAllowlistKindTests {

    @Test func mapsKnownPlatformsToCorrectKind() {
        #expect(GatewayAllowlistKind.kind(for: "slack")      == .channels)
        #expect(GatewayAllowlistKind.kind(for: "mattermost") == .channels)
        #expect(GatewayAllowlistKind.kind(for: "telegram")   == .chats)
        #expect(GatewayAllowlistKind.kind(for: "matrix")     == .rooms)
        // v0.16: Hermes reads `dingtalk.allowed_chats`, not allowed_rooms.
        // Reachable from the UI only since the v0.21.1 B4 roster sweep put
        // `dingtalk` into `KnownPlatforms.all`.
        #expect(GatewayAllowlistKind.kind(for: "dingtalk")   == .chats)
        // v0.21.1 B4: `discord.allowed_channels` is real and enforced
        // (plugins/platforms/discord/adapter.py:4620-4622 / :5675-5677 at
        // tag v2026.9.7, identical at v2026.8.31). The long-standing
        // "KNOWN GAP" nil is gone.
        #expect(GatewayAllowlistKind.kind(for: "discord")    == .channels)
    }

    /// The nine other platforms added to `KnownPlatforms` by the v0.21.1 B4
    /// sweep gate access by USER (`allowed_users` / `allow_from`) or by
    /// network ACL (`allowed_source_cidrs`), never by a destination list —
    /// each verified in its adapter at tag `v2026.9.7`. Mapping any of them
    /// to a kind would make the editor write a key Hermes never reads.
    @Test func v0211RosterAdditionsHaveNoDestinationAllowlist() {
        for platform in [
            "sms",              // allowed_users_env="SMS_ALLOWED_USERS"
            "irc",              // extra.allowed_users
            "photon",           // allowed_users_env="PHOTON_ALLOWED_USERS"
            "wecom",            // allow_from / group_allow_from
            "weixin",           // allow_from / group_allow_from
            "bluebubbles",      // no allowed_* recipient list at all
            "qqbot",            // no allowed_* recipient list at all
            "api_server",       // no allowed_* recipient list at all
            "msgraph_webhook",  // allowed_source_cidrs — a network ACL
        ] {
            #expect(
                GatewayAllowlistKind.kind(for: platform) == nil,
                "\(platform) has no chat/channel/room allowlist in Hermes"
            )
        }
    }

    @Test func googleChatHasNoAllowlist() {
        // The google_chat adapter never reads allowed_channels at any
        // Hermes version — it gates via GOOGLE_CHAT_ALLOWED_USERS. All
        // spellings (real id + legacy Scarf misspellings) must map to nil.
        #expect(GatewayAllowlistKind.kind(for: "google_chat") == nil)
        #expect(GatewayAllowlistKind.kind(for: "google-chat") == nil)
        #expect(GatewayAllowlistKind.kind(for: "googlechat")  == nil)
    }

    @Test func returnsNilForPlatformsWithoutAllowlist() {
        #expect(GatewayAllowlistKind.kind(for: "cli")            == nil)
        // whatsapp gates senders via allow_from / dm_policy, NOT an
        // allowed_chats list — writing whatsapp.allowed_chats is a silent
        // no-op (verified vs v0.17 gateway/platforms/whatsapp.py), so it is
        // intentionally excluded from this chat-id allowlist editor.
        #expect(GatewayAllowlistKind.kind(for: "whatsapp")       == nil)
        #expect(GatewayAllowlistKind.kind(for: "yuanbao")        == nil)
        #expect(GatewayAllowlistKind.kind(for: "teams")          == nil)
        // Buzz (v0.20) gates via allowed_users, not a channels allowlist.
        #expect(GatewayAllowlistKind.kind(for: "buzz")           == nil)
        #expect(GatewayAllowlistKind.kind(for: "signal")         == nil)
        #expect(GatewayAllowlistKind.kind(for: "homeassistant")  == nil)
        #expect(GatewayAllowlistKind.kind(for: "")               == nil)
        #expect(GatewayAllowlistKind.kind(for: "unknown")        == nil)
    }

    @Test func yamlKeyMatchesHermesContract() {
        #expect(GatewayAllowlistKind.channels.yamlKey == "allowed_channels")
        #expect(GatewayAllowlistKind.chats.yamlKey    == "allowed_chats")
        #expect(GatewayAllowlistKind.rooms.yamlKey    == "allowed_rooms")
    }

    @Test func nounsAreUserFacingSafe() {
        #expect(GatewayAllowlistKind.channels.noun == "channel")
        #expect(GatewayAllowlistKind.chats.noun    == "chat")
        #expect(GatewayAllowlistKind.rooms.noun    == "room")
        #expect(GatewayAllowlistKind.channels.pluralNoun == "channels")
        #expect(GatewayAllowlistKind.chats.pluralNoun    == "chats")
        #expect(GatewayAllowlistKind.rooms.pluralNoun    == "rooms")
    }

    @Test func placeholdersAreNonEmpty() {
        // Smoke test — placeholder strings are advisory; we just don't want
        // them silently emptied during a refactor.
        #expect(!GatewayAllowlistKind.channels.inputPlaceholder.isEmpty)
        #expect(!GatewayAllowlistKind.chats.inputPlaceholder.isEmpty)
        #expect(!GatewayAllowlistKind.rooms.inputPlaceholder.isEmpty)
    }

    /// v0.21.1 B5: `gateway_restart_notification` defaults TRUE upstream
    /// (`gateway/config.py` `PlatformConfig`), so the model's default must
    /// be `true` — a `false` default renders the toggle off on a host that
    /// is pinging, and one save writes the `false` the user never chose.
    @Test func restartNotificationDefaultsTrueLikeHermes() {
        #expect(GatewayPlatformSettings().gatewayRestartNotification == true)
        #expect(GatewayPlatformSettings.empty.gatewayRestartNotification == true)
        #expect(GatewayPlatformSettings().busyAckEnabled == true)
    }

    @Test func gatewayPlatformSettingsItemsForKind() {
        let s = GatewayPlatformSettings(
            allowedChannels: ["C01"],
            allowedChats: ["@user"],
            allowedRooms: ["!room:matrix.org"]
        )
        #expect(s.items(for: .channels) == ["C01"])
        #expect(s.items(for: .chats)    == ["@user"])
        #expect(s.items(for: .rooms)    == ["!room:matrix.org"])
    }
}
