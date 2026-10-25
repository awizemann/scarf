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

/// Records every argv the injected runner sees.
private final class ArgvLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func append(_ args: [String]) { lock.lock(); calls.append(args); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}

@Suite("S6 · plugin install dependency consent and readiness")
@MainActor
struct PluginDependencyConsentS6Tests {
    private static let refusedInstall = """
    weather declares Python dependencies:
      - requests>=2
    Non-interactive install — skipping dependency install. Run `hermes plugins enable` when ready to prepare them.
    ✗ Cannot enable weather: dependency install skipped (non-interactive)
    The plugin stays installed but disabled; re-enable after resolving the conflict.
    Plugin installed but not enabled. Run `hermes plugins enable weather` to activate.
    """

    /// A scratch local home — a version-cache key no other test shares —
    /// primed so `cached(for:)` answers without a probe.
    private static func context(primedAt caps: HermesCapabilities?) -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-s6-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: home)
        if let caps { HermesVersionCache.shared.primeForTesting(caps, for: ctx) }
        return ctx
    }

    private static func awaitMessage(on vm: PluginsViewModel) async -> String? {
        for _ in 0..<400 {
            if let message = vm.message, !message.hasPrefix("Installing") { return message }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return vm.message
    }

    /// v0.21.6+: the refusal is a failure and arms the consent dialog with
    /// the INSTALLED name.
    @Test func flaggedHostArmsTheConsentDialog() async {
        let vm = PluginsViewModel(context: Self.context(primedAt: caps(0, 22, 5)),
                                  cliRunner: { _, _ in (Self.refusedInstall, 0) })
        vm.install("https://github.com/acme/weather", enable: true)
        let message = await Self.awaitMessage(on: vm)
        #expect(message?.contains("not enabled: dependency install skipped") == true)
        #expect(vm.messageIsFailure)
        #expect(vm.pendingDependencyConsent == "weather")
    }

    /// Below the `hasPluginInstallDepsConsent` floor (and with the version
    /// unknown) the new arm stays unreachable — the old verdict stands (C1).
    @Test func unflaggedHostKeepsTheOldVerdict() async {
        for primed in [caps(0, 21, 5), nil] {
            let vm = PluginsViewModel(context: Self.context(primedAt: primed),
                                      cliRunner: { _, _ in (Self.refusedInstall, 0) })
            vm.install("weather", enable: true)
            let message = await Self.awaitMessage(on: vm)
            #expect(message == "Installed (not enabled)")
            #expect(vm.pendingDependencyConsent == nil)
        }
    }

    /// The consent follow-up is `plugins enable`, never a forced re-install:
    /// `--force` would also accept a caution scan verdict and re-clone.
    @Test func consentRunsPlainEnable() async {
        let log = ArgvLog()
        let vm = PluginsViewModel(context: Self.context(primedAt: caps(0, 22, 5)),
                                  cliRunner: { args, _ in log.append(args); return ("✓ Plugin weather enabled.\n", 0) })
        vm.pendingDependencyConsent = "weather"
        vm.enableWithDependencyConsent("weather")
        for _ in 0..<400 where log.all.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let first = log.all.first ?? []
        #expect(first == ["plugins", "enable", "--", "weather"])
        #expect(!first.contains("--force"))
        #expect(!first.contains("--yes-deps"))
        #expect(!first.contains("install"))
        #expect(vm.pendingDependencyConsent == nil)
    }

    @Test func readinessNeedsEnabledUnlessActivatedByConfig() {
        let vm = PluginsViewModel(context: Self.context(primedAt: nil), cliRunner: { _, _ in ("", 0) })
        func plugin(_ name: String, _ activation: HermesPluginActivation) -> HermesPlugin {
            HermesPlugin(name: name, source: name, activation: activation,
                         description: "", version: "", path: "", toolOverride: false)
        }
        vm.plugins = [plugin("spotify", .enabled), plugin("homeassistant", .disabled),
                      plugin("singularity", .notEnabled), plugin("honcho", .notEnabled)]
        #expect(vm.isPluginReady("spotify"))
        #expect(!vm.isPluginReady("homeassistant"))
        #expect(!vm.isPluginReady("singularity"))
        #expect(vm.pluginActivation("homeassistant") == .disabled)
        #expect(vm.isPluginReady("honcho", activatesByConfig: true))
        #expect(!vm.isPluginReady("mem0", activatesByConfig: true))
        #expect(vm.pluginActivation("mem0") == nil)
    }
}

@Suite("S6 · Spotify login moved to the spotify plugin")
@MainActor
struct SpotifyPluginLoginS6Tests {
    /// `hermes auth spotify` → `hermes spotify login`
    /// (`hermes_cli/left_core_migration.py:247-252` @ v0.21.7); the plugin's
    /// `spotify_cli.py:9-14` takes `--client-id` / `--no-browser` at every
    /// pinned sha (682b22d0, a4e311e4, 4d492b1d).
    @Test func pluginLoginCarriesTheClientIDOnlyWhenGiven() {
        #expect(SpotifyAuthFlow.argv(clientID: nil, pluginLogin: true) == ["spotify", "login"])
        #expect(SpotifyAuthFlow.argv(clientID: "", pluginLogin: true) == ["spotify", "login"])
        #expect(SpotifyAuthFlow.argv(clientID: "0123456789abcdef0123456789abcdef", pluginLogin: true)
            == ["spotify", "login", "--client-id=0123456789abcdef0123456789abcdef"])
        // Older hosts are unchanged.
        #expect(SpotifyAuthFlow.argv(clientID: "abc12345", pluginLogin: false)
            == ["auth", "spotify", "--client-id=abc12345"])
    }

    @Test func remoteLineUsesThePluginCommand() {
        let ctx = ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box.example", user: "alan")))
        let line = SpotifyAuthFlow.remoteCommandLine(for: ctx, pluginLogin: true)
        #expect(line.contains("'spotify' 'login' '--no-browser'"), "\(line)")
        #expect(line.contains("'-L' '43827:127.0.0.1:43827'"))
        #expect(!line.contains("'auth' 'spotify'"))
        #expect(SpotifyAuthFlow.remoteCommandLine(for: ctx).contains("'auth' 'spotify' '--no-browser'"))
    }
}
