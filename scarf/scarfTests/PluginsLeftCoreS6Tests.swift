import Testing
import Foundation
@testable import scarf
import ScarfCore

// S6 (Hermes v0.22.5 parity) — features that left core for catalog plugins.

private func caps(_ major: Int, _ minor: Int, _ patch: Int) -> HermesCapabilities {
    HermesCapabilities(
        versionLine: "hermes \(major).\(minor).\(patch)",
        semver: HermesCapabilities.SemVer(major: major, minor: minor, patch: patch),
        dateVersion: nil
    )
}

@Suite("S6 · left-core memory providers need their catalog plugin")
@MainActor
struct MemoryProviderPluginS6Tests {
    /// `plugins/memory/{honcho,mem0,openviking,supermemory}` gone at v0.21.6,
    /// `holographic` at v0.21.7; retaindb/byterover still in core at v0.22.5.
    @Test func providersMapToTheirPluginOnlyFromTheirFloor() {
        let old = caps(0, 21, 5)
        let v0216 = caps(0, 21, 6)
        let v0217 = caps(0, 21, 7)
        for name in ["honcho", "mem0", "openviking", "supermemory", "hindsight"] {
            #expect(SettingsViewModel.memoryProviderPlugin(name, capabilities: old) == nil)
            #expect(SettingsViewModel.memoryProviderPlugin(name, capabilities: v0216) == name)
        }
        #expect(SettingsViewModel.memoryProviderPlugin("holographic", capabilities: v0216) == nil)
        #expect(SettingsViewModel.memoryProviderPlugin("holographic", capabilities: v0217) == "holographic")
        for name in ["", "retaindb", "byterover"] {
            #expect(SettingsViewModel.memoryProviderPlugin(name, capabilities: caps(0, 22, 5)) == nil)
        }
    }
}

@Suite("S6 · Spotify login moved to the spotify plugin")
@MainActor
struct SpotifyPluginLoginS6Tests {
    /// `hermes auth spotify` → `hermes spotify login`
    /// (`hermes_cli/left_core_migration.py:247-252` @ v0.21.7). The plugin's
    /// argparse is not in the Hermes repo, so no flag is passed (C5).
    @Test func pluginLoginTakesNoUnverifiedFlags() {
        #expect(SpotifyAuthFlow.argv(clientID: nil, pluginLogin: true) == ["spotify", "login"])
        #expect(SpotifyAuthFlow.argv(clientID: "0123456789abcdef0123456789abcdef", pluginLogin: true)
            == ["spotify", "login"])
        // Older hosts are unchanged.
        #expect(SpotifyAuthFlow.argv(clientID: "abc12345", pluginLogin: false)
            == ["auth", "spotify", "--client-id=abc12345"])
    }

    @Test func remoteLineUsesThePluginCommand() {
        let ctx = ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box.example", user: "alan")))
        let line = SpotifyAuthFlow.remoteCommandLine(for: ctx, pluginLogin: true)
        #expect(line.contains("'spotify' 'login'"), "\(line)")
        #expect(line.contains("'-L' '43827:127.0.0.1:43827'"))
        #expect(!line.contains("--no-browser"))
        #expect(!line.contains("'auth' 'spotify'"))
        #expect(SpotifyAuthFlow.remoteCommandLine(for: ctx).contains("'auth' 'spotify' '--no-browser'"))
    }
}
