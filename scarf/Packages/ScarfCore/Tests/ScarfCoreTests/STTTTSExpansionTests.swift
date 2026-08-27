import Testing
@testable import ScarfCore

/// P3c (t-02eae1a0): STT/TTS knob expansion — `stt.language`,
/// `stt.openai.language`, `stt.groq.{model,language}`, `stt.local.*` VAD
/// tuning, `tts.xai.{language,speed,optimize_streaming_latency,sample_rate,
/// bit_rate}`, `tts.deepinfra.{model,voice}`. All values source-verified
/// against `~/.hermes/hermes-agent` at tag v2026.8.3
/// (`hermes_cli/config_defaults.py`).
@Suite struct STTTTSExpansionTests {

    // MARK: - stt.language (global) + stt.groq — v0.20 (hasSTTUnifiedLanguage)

    @Test func sttLanguageParsesAndDefaultsToEn() {
        let cfg = HermesConfig(yaml: "stt:\n  language: es\n")
        #expect(cfg.voice.sttLanguage == "es")
        // config_defaults.py:1516 — default "en".
        #expect(HermesConfig.empty.voice.sttLanguage == "en")
        #expect(HermesConfig(yaml: "stt:\n  enabled: true\n").voice.sttLanguage == "en")
    }

    @Test func sttLanguageEmptyStringRestoresAutoDetect() {
        // Hermes convention: writing "" is a real value (auto-detect), not
        // the same as key-absent (default "en").
        let cfg = HermesConfig(yaml: "stt:\n  language: \"\"\n")
        #expect(cfg.voice.sttLanguage == "")
    }

    @Test func sttGroqModelAndLanguageParseAndDefault() {
        let cfg = HermesConfig(yaml: """
        stt:
          groq:
            model: whisper-large-v3
            language: fr
        """)
        #expect(cfg.voice.sttGroqModel == "whisper-large-v3")
        #expect(cfg.voice.sttGroqLanguage == "fr")
        // config_defaults.py:1529 — default model "whisper-large-v3-turbo",
        // default language "" (auto-detect).
        #expect(HermesConfig.empty.voice.sttGroqModel == "whisper-large-v3-turbo")
        #expect(HermesConfig.empty.voice.sttGroqLanguage == "")
    }

    // MARK: - stt.openai.language — ungated (predates version tracking)

    @Test func sttOpenAILanguageParsesAndDefaultsEmpty() {
        let cfg = HermesConfig(yaml: "stt:\n  openai:\n    language: de\n")
        #expect(cfg.voice.sttOpenAILanguage == "de")
        // config_defaults.py:1534 — default "" (auto-detect).
        #expect(HermesConfig.empty.voice.sttOpenAILanguage == "")
    }

    // MARK: - stt.provider unset — v0.20.5 (no longer seeded)

    /// v0.20.5 removed the seeded `stt.provider: local` from
    /// `config_defaults.py`: an absent key means "autodetect ladder" and any
    /// stored value is an explicit pin. The parser must therefore NOT default
    /// to `local` — an absent key parses to "" so the UI can render it as
    /// "Auto (unset)" instead of a pin the user never made.
    @Test func sttProviderAbsentKeyParsesEmptyRatherThanLocal() {
        #expect(HermesConfig(yaml: "").voice.sttProvider == "")
        #expect(HermesConfig(yaml: "stt:\n  enabled: true\n").voice.sttProvider == "")
        #expect(HermesConfig.empty.voice.sttProvider == "")
    }

    @Test func sttProviderExplicitValueIsPreservedAsAPin() {
        #expect(HermesConfig(yaml: "stt:\n  provider: local\n").voice.sttProvider == "local")
        #expect(HermesConfig(yaml: "stt:\n  provider: groq\n").voice.sttProvider == "groq")
    }

    // MARK: - stt.local.* VAD tuning — v0.20 (hasSTTLocalVADTuning)

    @Test func sttLocalVADTuningParses() {
        let cfg = HermesConfig(yaml: """
        stt:
          local:
            vad: false
            vad_min_silence_ms: 800
            no_speech_prob_threshold: 0.8
            logprob_threshold: -0.5
        """)
        #expect(cfg.voice.sttLocalVAD == false)
        #expect(cfg.voice.sttLocalVADMinSilenceMS == 800)
        #expect(cfg.voice.sttLocalNoSpeechProbThreshold == 0.8)
        #expect(cfg.voice.sttLocalLogprobThreshold == -0.5)
    }

    @Test func sttLocalVADTuningDefaultsMatchHermes() {
        // config_defaults.py:1523-1526.
        let empty = HermesConfig.empty.voice
        #expect(empty.sttLocalVAD == true)
        #expect(empty.sttLocalVADMinSilenceMS == 500)
        #expect(empty.sttLocalNoSpeechProbThreshold == 0.6)
        #expect(empty.sttLocalLogprobThreshold == -1.0)
        let parsed = HermesConfig(yaml: "stt:\n  local:\n    model: base\n").voice
        #expect(parsed.sttLocalVAD == true)
        #expect(parsed.sttLocalVADMinSilenceMS == 500)
        #expect(parsed.sttLocalNoSpeechProbThreshold == 0.6)
        #expect(parsed.sttLocalLogprobThreshold == -1.0)
    }

    // MARK: - tts.xai advanced params — v0.19 (hasXAITTSAdvancedParams)

    @Test func ttsXAIAdvancedParamsParse() {
        let cfg = HermesConfig(yaml: """
        tts:
          xai:
            language: pt-BR
            speed: 1.3
            optimize_streaming_latency: 2
            sample_rate: 44100
            bit_rate: 64000
        """)
        #expect(cfg.voice.ttsXAILanguage == "pt-BR")
        #expect(cfg.voice.ttsXAISpeed == 1.3)
        #expect(cfg.voice.ttsXAIOptimizeStreamingLatency == 2)
        #expect(cfg.voice.ttsXAISampleRate == 44100)
        #expect(cfg.voice.ttsXAIBitRate == 64000)
    }

    @Test func ttsXAIAdvancedParamsDefaultsMatchHermes() {
        // config_defaults.py:1459-1464.
        let empty = HermesConfig.empty.voice
        #expect(empty.ttsXAILanguage == "en")
        #expect(empty.ttsXAISpeed == 1.0)
        #expect(empty.ttsXAIOptimizeStreamingLatency == 0)
        #expect(empty.ttsXAISampleRate == 24000)
        #expect(empty.ttsXAIBitRate == 128000)
    }

    @Test func ttsXAITextNormalizationKeyIsNeverSurfaced() {
        // hermes-agent commit 5c6499ce4d briefly added tts.xai.text_normalization,
        // then commit 6bb8a0aef1 dropped it before any tagged release shipped
        // it ("not honored by the xAI TTS backend") — Scarf must not have a
        // field for it. A stray key in a hand-edited config must not crash
        // the parser or leak into any other field.
        let cfg = HermesConfig(yaml: "tts:\n  xai:\n    text_normalization: true\n    speed: 1.2\n")
        #expect(cfg.voice.ttsXAISpeed == 1.2)
    }

    // MARK: - tts.deepinfra — v0.19 (hasDeepInfraTTS)

    @Test func ttsDeepInfraModelAndVoiceParseAndDefault() {
        let cfg = HermesConfig(yaml: """
        tts:
          deepinfra:
            model: some/tts-model
            voice: custom
        """)
        #expect(cfg.voice.ttsDeepInfraModel == "some/tts-model")
        #expect(cfg.voice.ttsDeepInfraVoice == "custom")
        // config_defaults.py:1498-1499 — model "" (first catalog match),
        // voice "default".
        #expect(HermesConfig.empty.voice.ttsDeepInfraModel == "")
        #expect(HermesConfig.empty.voice.ttsDeepInfraVoice == "default")
    }

    // MARK: - Capability boundary tests (below floor vs at/above floor)

    @Test func sttUnifiedLanguageGatesAtV020() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.30)").hasSTTUnifiedLanguage)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)").hasSTTUnifiedLanguage)
    }

    @Test func sttLocalVADTuningGatesAtV020() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.30)").hasSTTLocalVADTuning)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)").hasSTTLocalVADTuning)
    }

    @Test func xaiTTSAdvancedParamsGatesAtV019() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasXAITTSAdvancedParams)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasXAITTSAdvancedParams)
    }

    @Test func deepInfraTTSGatesAtV019() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasDeepInfraTTS)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasDeepInfraTTS)
    }

    // MARK: - Writer round-trip (SettingsViewModel.setSetting shells `hermes
    // config set`, so there is no bespoke YAML writer to test here — these
    // keys are all plain scalars. Round-trip is exercised via the reader
    // tests above plus VoiceSettings.init defaults.)

    @Test func voiceSettingsInitDefaultsMatchHermesForAllNewFields() {
        let v = VoiceSettings.empty
        #expect(v.sttLanguage == "en")
        #expect(v.sttGroqModel == "whisper-large-v3-turbo")
        #expect(v.sttGroqLanguage == "")
        #expect(v.sttOpenAILanguage == "")
        #expect(v.sttLocalVAD == true)
        #expect(v.sttLocalVADMinSilenceMS == 500)
        #expect(v.sttLocalNoSpeechProbThreshold == 0.6)
        #expect(v.sttLocalLogprobThreshold == -1.0)
        #expect(v.ttsXAILanguage == "en")
        #expect(v.ttsXAISpeed == 1.0)
        #expect(v.ttsXAIOptimizeStreamingLatency == 0)
        #expect(v.ttsXAISampleRate == 24000)
        #expect(v.ttsXAIBitRate == 128000)
        #expect(v.ttsDeepInfraModel == "")
        #expect(v.ttsDeepInfraVoice == "default")
    }
}
