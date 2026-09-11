import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Whole-surface audit P20 — the Mac-target half: the two writers whose key
/// choice was wrong, and the two voice pickers whose rosters were short.
///
/// Hermes claims verified at tag `v2026.9.7`, with floors walked across all 32
/// `v2026.*` tags.
@Suite struct SettingsP20ConfigDefaultsTests {

    private static func caps(_ version: String) -> HermesCapabilities {
        HermesCapabilities.parse("Hermes Agent v\(version) (2026.1.1)")
    }

    // MARK: - `multiplex_profiles` writes to the key in effect

    /// Records the argv of every `hermes` invocation the VM makes. The
    /// runner closure is `@Sendable` and runs detached, hence the lock.
    private final class ArgvLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
        var runner: HermesCLIRunner {
            { [self] args, _ in
                lock.lock(); _calls.append(args); lock.unlock()
                return ("", 0)
            }
        }
    }

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p20-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    /// Drives the REAL `setMultiplexProfiles` with `config` parsed from
    /// `yaml`, and returns the config key it wrote through `hermes config set`.
    @MainActor
    private static func multiplexWriteKey(for yaml: String) async -> String? {
        let log = ArgvLog()
        let vm = SettingsViewModel(context: scratchContext(), cliRunner: log.runner)
        vm.config = HermesConfig(yaml: yaml)
        vm.setMultiplexProfiles(true)
        // The write rides `SettingsViewModel.writeChain` through two detached
        // hops; under the full parallel `scarfTests` run those can take well
        // over 10 s to be scheduled, so the bound is generous — it is only
        // ever waited out on the failure path.
        let deadline = Date().addingTimeInterval(120)
        while log.calls.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // P39: `config set -- <key> <value>`.
        guard let argv = log.calls.first, argv.count >= 5,
              argv[0] == "config", argv[1] == "set", argv[2] == "--" else { return nil }
        return argv[3]
    }

    /// `GatewayConfig.from_dict` resolves this as `data.get("multiplex_profiles")`
    /// and only falls through to `nested_gateway.get(...)` when that is `None`
    /// (`gateway/config.py:708-710` @ v2026.9.7). So with a non-null top-level
    /// key present, unconditionally writing `gateway.multiplex_profiles`
    /// changed a key the host never reads: the save toast said "Saved" and
    /// routing stayed off.
    ///
    /// Driven through the real writer and the injected runner (not a key
    /// helper the writer might stop calling) so it fails whenever the
    /// production key choice regresses. Fails before P20, which always wrote
    /// the `gateway.` spelling.
    @Test func multiplexWriteTargetsTheKeyInEffect() async {
        // Top-level key set → that spelling is what Hermes reads.
        #expect(await Self.multiplexWriteKey(for: "multiplex_profiles: false\n") == "multiplex_profiles")
        // Only the nested spelling → keep writing there.
        #expect(await Self.multiplexWriteKey(for: "gateway:\n  multiplex_profiles: false\n") == "gateway.multiplex_profiles")
        // Nothing set at all → the nested spelling Scarf has always written.
        #expect(await Self.multiplexWriteKey(for: "") == "gateway.multiplex_profiles")
        // A NULL top-level key is not "in effect" — Hermes falls through to
        // the nested one — so the write must too.
        #expect(await Self.multiplexWriteKey(
            for: "multiplex_profiles: null\ngateway:\n  multiplex_profiles: false\n"
        ) == "gateway.multiplex_profiles")
    }

    // MARK: - Voice provider rosters (product decision 4)

    /// Hermes's `BUILTIN_TTS_PROVIDERS`
    /// (`tools/tts_command_provider.py:269` @ v2026.9.7) carries eleven names;
    /// Scarf's picker offered nine, so a config pinned to `gemini` or
    /// `kittentts` had no selectable row. Both have been in the roster since
    /// tag v2026.4.23 (v0.11.0) — neither name occurs in `tools/tts_tool.py`
    /// at v2026.4.16 (v0.10.0) — so they are floor-gated at v0.11.0, and
    /// `deepinfra` at v0.19.0 (v2026.7.20).
    @Test func ttsRosterMatchesHermesBuiltinsOnATargetHost() {
        let all = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.21.1"))
        #expect(Set(all) == Set([
            "edge", "elevenlabs", "openai", "minimax", "mistral",
            "neutts", "piper", "xai", "gemini", "kittentts", "deepinfra",
        ]))
    }

    /// C1: a pre-floor host must not be offered a provider it cannot dispatch.
    @Test func ttsRosterIsFloorGated() {
        let old = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.10.0"))
        #expect(!old.contains("gemini"))
        #expect(!old.contains("kittentts"))
        #expect(!old.contains("deepinfra"))
        let v011 = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.11.0"))
        #expect(v011.contains("gemini"))
        #expect(v011.contains("kittentts"))
        #expect(!v011.contains("deepinfra"))
        // An UNDETECTED host is below every floor.
        let unknown = SettingsViewModel.ttsProviders(capabilities: .empty)
        #expect(!unknown.contains("gemini"))
    }

    /// The existing picker convention: a stored value outside the roster is
    /// APPENDED rather than dropped, so a plugin-registered provider
    /// (`PluginContext.register_tts_provider`) renders as a real selection
    /// instead of a blank the next save would overwrite.
    @Test func ttsRosterAppendsAnUnrecognisedStoredValue() {
        let out = SettingsViewModel.ttsProviders(
            capabilities: Self.caps("0.21.1"), current: "my-plugin-tts"
        )
        #expect(out.last == "my-plugin-tts")
        // A recognised value is not duplicated.
        let dedup = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.21.1"), current: "edge")
        #expect(dedup.filter { $0 == "edge" }.count == 1)
    }

    /// `BUILTIN_STT_PROVIDERS` (`tools/transcription_common.py:45` @
    /// v2026.9.7) gains `elevenlabs` and `deepinfra` at tag v2026.7.20
    /// (v0.19.0); v2026.7.7.2 (v0.18.2) has neither.
    @Test func sttRosterAddsTheV019CloudProvidersBehindTheirFloor() {
        let target = SettingsViewModel.sttProviders(capabilities: Self.caps("0.21.1")).map(\.id)
        #expect(target.contains("elevenlabs"))
        #expect(target.contains("deepinfra"))
        let old = SettingsViewModel.sttProviders(capabilities: Self.caps("0.18.2")).map(\.id)
        #expect(!old.contains("elevenlabs"))
        #expect(!old.contains("deepinfra"))
        // `local_command` is a mechanism, not a pickable provider.
        #expect(!target.contains("local_command"))
        // The "Auto (unset)" row stays first on every host.
        #expect(target.first == "")
    }

    /// Same append rule as the TTS picker.
    @Test func sttRosterAppendsAnUnrecognisedStoredValue() {
        let out = SettingsViewModel.sttProviders(
            capabilities: Self.caps("0.21.1"), current: "my-plugin-stt"
        )
        #expect(out.last?.id == "my-plugin-stt")
        #expect(out.last?.label == "my-plugin-stt")
    }
}
