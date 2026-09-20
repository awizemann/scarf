import Testing
import Foundation
@testable import ScarfCore

/// v0.21.3 (v2026.9.14): GPT-Live voice chat mode. `tools/voice_live.py`
/// first ships at that tag (commit f923faa0b8; `pyproject.toml:5` reads
/// 0.21.3; absent at v2026.9.11). The Live Voice entry point also needs the
/// host's `voice.voice_chat_mode` to parse as gpt-live.
@Suite struct HermesGPTLiveVoiceTests {
    // MARK: the v0.21.3 four-test group (parse, all-on, degradation, patch-still-on)

    @Test func parseV0213ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 3))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 14))
        #expect(caps.detected)
    }

    @Test func v0213FlagsAllOnForV0213Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        #expect(caps.isV0213OrLater)
        #expect(caps.hasGPTLiveVoice)
    }

    /// Alan's own dev install reports 0.21.2 while carrying voice_live.py;
    /// the version floor still hides the feature there (C1 wants the flag).
    @Test func v0212HostHidesEveryV0213Flag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        #expect(caps.isV0212OrLater)
        #expect(!caps.isV0213OrLater)
        #expect(!caps.hasGPTLiveVoice)
        #expect(!HermesCapabilities.empty.hasGPTLiveVoice)
    }

    @Test func laterReleasesStillEnableTheV0213Flag() {
        for line in ["Hermes Agent v0.21.4 (2026.9.20)", "Hermes Agent v0.22.0 (2026.10.1)", "Hermes Agent v1.0.0 (2027.1.1)"] {
            #expect(HermesCapabilities.parseLine(line).hasGPTLiveVoice, "\(line)")
        }
    }

    @Test func v0213HostStillEnablesTheV0212Flag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        #expect(caps.isV0212OrLater)
        #expect(caps.hasBackupKeep)
        #expect(caps.hasHermesSpeechSynthesis)
    }

    // MARK: voice_chat_mode parsing — tools/voice_live.py:107-111 @ v2026.9.14

    @Test(arguments: [
        "gpt-live", "gpt_live", "GPT-Live", "  gpt-live  ", "gptlive", "GPTLIVE", "live", "Live", "LIVE",
    ])
    func hermesGPTLiveSpellingsParseAsGPTLive(_ raw: String) {
        #expect(VoiceChatMode.parse(raw) == .gptLive)
    }

    @Test(arguments: [
        "", "   ", "chained", "Chained", "gpt live", "gpt-live-1", "openai", "realtime", "true", "gpt--live", "g-p-t-live",
    ])
    func everythingElseIsChained(_ raw: String) {
        #expect(VoiceChatMode.parse(raw) == .chained)
    }

    @Test func absentKeyIsChained() {
        #expect(VoiceChatMode.parse(nil) == .chained)
    }

    /// The argv both settings writers issue (their keys are literals so the
    /// config-writer parity gate can read them): the shared builder with the
    /// canonical values Hermes's own constants spell.
    @Test func configSetArgvIsTheVerifiedShape() {
        #expect(HermesConfigSet.argv(key: "voice.voice_chat_mode", value: VoiceChatMode.gptLive.configValue)
                == ["config", "set", "--", "voice.voice_chat_mode", "gpt-live"])
        #expect(HermesConfigSet.argv(key: "voice.voice_chat_mode", value: VoiceChatMode.chained.configValue)
                == ["config", "set", "--", "voice.voice_chat_mode", "chained"])
    }

    // MARK: the gating matrix

    @Test func gatingMatrix() {
        let new = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        let old = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        let rows: [(HermesCapabilities, String?, VoiceLiveAvailability)] = [
            (new, "gpt-live", .ready),
            (new, "gpt_live", .ready),
            (new, "live", .ready),
            // P7: chained has an engine now, so it is shown, not hidden —
            // and v0.21.2 clears the chained floor (v0.20.1) either way.
            (new, "chained", .chainedReady),
            (new, nil, .chainedReady),
            (new, "", .chainedReady),
            (old, "gpt-live", .chainedReady),
            (old, "chained", .chainedReady),
            (.empty, "gpt-live", .hidden(.hermesTooOld)),
        ]
        for (caps, mode, expected) in rows {
            #expect(VoiceLiveReadiness.availability(capabilities: caps, voiceChatMode: mode) == expected,
                    "\(caps.versionLine) / \(mode ?? "nil")")
        }
    }

    @Test func parsedConfigDrivesTheGate() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        let live = HermesConfig(yaml: "voice:\n  voice_chat_mode: gpt_live\n")
        let chained = HermesConfig(yaml: "voice:\n  record_key: ctrl+b\n")
        #expect(VoiceLiveReadiness.availability(capabilities: caps, config: live) == .ready)
        #expect(VoiceLiveReadiness.availability(capabilities: caps, config: chained) == .chainedReady)
        #expect(VoiceLiveReadiness.availability(capabilities: caps, config: nil) == .chainedReady)
    }

    /// C1: below v0.21.3 the ScarfGo setter refuses without spawning a
    /// process (the context points at a server that doesn't exist, so any
    /// spawn would fail differently).
    @MainActor
    @Test func iOSSetterRefusesBelowTheFloorWithoutSpawning() async {
        let vm = IOSSettingsViewModel(context: ServerContext(
            id: UUID(), displayName: "nowhere",
            kind: .ssh(SSHConfig(host: "invalid.invalid"))))
        let old = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        do {
            try await vm.saveVoiceChatMode(.gptLive, capabilities: old)
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription.contains("0.21.3"))
        }
        #expect(!vm.isSaving)
    }
}
