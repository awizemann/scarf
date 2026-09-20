import Foundation

/// Hermes's `voice.voice_chat_mode`: how an interactive voice conversation is
/// wired on the host.
///
/// Mirrors `voice_chat_mode()` at `tools/voice_live.py:107-111` @ v2026.9.14
/// exactly: `str(raw or "chained").strip().lower().replace("_", "-")`, and the
/// result is gpt-live only for `gpt-live`, `gptlive` or `live` — every other
/// value (including an absent or empty key) is chained. Scarf must accept the
/// same spellings Hermes does, or a host Hermes treats as gpt-live would hide
/// the entry point (or the reverse).
///
/// Both settings writers spell the key as a LITERAL at the call site
/// (`setSetting("voice.voice_chat_mode", …)` on the Mac,
/// `saveValue(key: "voice.voice_chat_mode", …)` on iOS), so the config-writer
/// parity gate (`AllConfigWritersParityTests`) can read it off the source.
/// The argv is the shared `hermes config set -- <key> <value>`
/// (``HermesConfigSet``), verified at v2026.9.14 for this key (charter C5):
/// `config set` takes two `nargs="?"` positionals
/// (`hermes_cli/subcommands/config.py:24-27`), and because the key's default
/// is a `str` (`config_defaults.py:1132`), `_coerce_config_set_value` stores
/// the value verbatim (`hermes_cli/config.py:3279-3280`).
public enum VoiceChatMode: String, Sendable, CaseIterable, Equatable {
    /// STT → Hermes turn → TTS. Hermes's default
    /// (`hermes_cli/config_defaults.py:1132` @ v2026.9.14).
    case chained
    /// One full-duplex OpenAI voice model that delegates to Hermes.
    case gptLive = "gpt-live"

    /// The canonical value Scarf writes — Hermes's own `GPT_LIVE_MODE` /
    /// `CHAINED_MODE` constants (`tools/voice_live.py:33-34`).
    public var configValue: String { rawValue }

    /// Parse a raw config value the way Hermes does.
    public static func parse(_ raw: String?) -> VoiceChatMode {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed.isEmpty ? VoiceChatMode.chained.rawValue : trimmed)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return ["gpt-live", "gptlive", "live"].contains(normalized) ? .gptLive : .chained
    }
}

/// Which voice engine a window's server resolves to.
public enum VoiceEngineKind: Sendable, Equatable {
    /// ``GPTLiveEngine`` — one full-duplex OpenAI voice, $0.05/min, needs an
    /// OpenAI key on the host and Hermes ≥ 0.21.3.
    case gptLive
    /// ``ChainedVoiceEngine`` — on-device speech in, a normal Hermes turn,
    /// the host's TTS out. Free, and Hermes's default mode.
    case chained
}

/// Whether a voice entry point may be shown for one window's server, and
/// which engine it mounts.
///
/// Three-way since P7 (`documents/plans/2026-09-19-voice-p7-free-voice-path.md`
/// §4): chained used to be `.hidden(.chainedMode)`, which hid the button on
/// the MAJORITY of hosts — chained is Hermes's default and needs no API key.
/// Now it has an engine, so it is shown.
public enum VoiceLiveAvailability: Sendable, Equatable {
    /// Show the entry point, mounting ``GPTLiveEngine``.
    case ready
    /// Show the entry point, mounting ``ChainedVoiceEngine``.
    case chainedReady
    /// Hide it. The reason is for Settings copy and diagnostics only — the
    /// chat composer renders nothing either way (charter C1).
    case hidden(HiddenReason)

    public enum HiddenReason: Sendable, Equatable {
        /// Hermes below v0.20.1 (no `hasHermesSpeechSynthesis`, so not even
        /// the chained path can speak), or the version is undetected.
        case hermesTooOld
    }

    /// The engine this verdict mounts, or `nil` when nothing is available.
    public var engineKind: VoiceEngineKind? {
        switch self {
        case .ready: return .gptLive
        case .chainedReady: return .chained
        case .hidden: return nil
        }
    }

    /// Show the entry point. True for BOTH engines — the composer button is
    /// one button and the verdict picks what it mounts.
    public var isReady: Bool { engineKind != nil }
}

/// The readiness rule, in order:
///
/// 1. `voice.voice_chat_mode` is gpt-live AND `hasGPTLiveVoice`
///    (Hermes ≥ 0.21.3) → ``VoiceLiveAvailability/ready``.
/// 2. `hasHermesSpeechSynthesis` (Hermes ≥ 0.20.1) →
///    ``VoiceLiveAvailability/chainedReady``. This covers chained mode (the
///    default, and an absent key) AND a host asking for gpt-live that is too
///    old for it — the Hermes desktop falls back to chained in exactly that
///    case (`use-composer-voice.ts:214-219` @ v2026.9.14).
/// 3. Otherwise ``VoiceLiveAvailability/HiddenReason/hermesTooOld``.
///
/// No host status probe either way: whether an OpenAI key resolves is
/// discovered when a GPT-Live session starts, and the no-key answer
/// (``VoiceLiveHostError/noKey``) happens before the vendor is ever called,
/// so it costs nothing. Chained needs no key at all.
public enum VoiceLiveReadiness {
    public static func availability(
        capabilities: HermesCapabilities,
        voiceChatMode rawMode: String?
    ) -> VoiceLiveAvailability {
        if VoiceChatMode.parse(rawMode) == .gptLive, capabilities.hasGPTLiveVoice { return .ready }
        guard capabilities.hasHermesSpeechSynthesis else { return .hidden(.hermesTooOld) }
        return .chainedReady
    }

    /// Convenience over a parsed config. `nil` (config not loaded yet, or
    /// unreadable) reads as Hermes's default — chained — which now has an
    /// engine, so a capable host shows the entry point even before the
    /// config is known.
    public static func availability(
        capabilities: HermesCapabilities,
        config: HermesConfig?
    ) -> VoiceLiveAvailability {
        availability(capabilities: capabilities, voiceChatMode: config?.voice.voiceChatMode)
    }
}
