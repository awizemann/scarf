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
public enum VoiceChatMode: String, Sendable, CaseIterable, Equatable {
    /// STT → Hermes turn → TTS. Hermes's default
    /// (`hermes_cli/config_defaults.py:1132` @ v2026.9.14).
    case chained
    /// One full-duplex OpenAI voice model that delegates to Hermes.
    case gptLive = "gpt-live"

    /// The dotted config key (`hermes_cli/config_defaults.py:1132`).
    public static let configKey = "voice.voice_chat_mode"

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

    /// `hermes config set -- voice.voice_chat_mode <value>` — the argv both
    /// platforms' settings writers issue (charter C5). Verified at
    /// v2026.9.14: `config set` takes two `nargs="?"` positionals
    /// (`hermes_cli/subcommands/config.py:24-27`), and because the key's
    /// default is a `str` (`config_defaults.py:1132`),
    /// `_coerce_config_set_value` stores the value verbatim
    /// (`hermes_cli/config.py:3279-3280`). Judge the result with
    /// ``HermesConfigSet/judge(output:exitCode:)`` — never by exit code.
    public func configSetArgv() -> [String] {
        HermesConfigSet.argv(key: Self.configKey, value: configValue)
    }
}

/// Whether the Live Voice entry point may be shown for one window's server.
public enum VoiceLiveAvailability: Sendable, Equatable {
    /// Show and enable the entry point.
    case ready
    /// Hide it. The reason is for Settings copy and diagnostics only — the
    /// chat composer renders nothing either way (charter C1).
    case hidden(HiddenReason)

    public enum HiddenReason: Sendable, Equatable {
        /// Hermes below v0.21.3, or the version is undetected.
        case hermesTooOld
        /// The host runs a capable Hermes but `voice.voice_chat_mode` is
        /// chained (Hermes's default). Settings can offer the switch.
        case chainedMode
    }

    public var isReady: Bool { self == .ready }
}

/// The single readiness rule for Live Voice (Alan's decision, t-a4665c6e):
/// `hasGPTLiveVoice` (Hermes ≥ 0.21.3) AND the parsed
/// `voice.voice_chat_mode` is gpt-live. No host status probe: whether an
/// OpenAI key resolves on the host is discovered when a session starts, and
/// the no-key answer (``VoiceLiveHostError/noKey``) happens before the
/// vendor is ever called, so it costs nothing.
public enum VoiceLiveReadiness {
    public static func availability(
        capabilities: HermesCapabilities,
        voiceChatMode rawMode: String?
    ) -> VoiceLiveAvailability {
        guard capabilities.hasGPTLiveVoice else { return .hidden(.hermesTooOld) }
        guard VoiceChatMode.parse(rawMode) == .gptLive else { return .hidden(.chainedMode) }
        return .ready
    }

    /// Convenience over a parsed config. `nil` (config not loaded yet, or
    /// unreadable) reads as Hermes's default — chained — so the entry point
    /// stays hidden until the config is actually known.
    public static func availability(
        capabilities: HermesCapabilities,
        config: HermesConfig?
    ) -> VoiceLiveAvailability {
        availability(capabilities: capabilities, voiceChatMode: config?.voice.voiceChatMode)
    }
}
