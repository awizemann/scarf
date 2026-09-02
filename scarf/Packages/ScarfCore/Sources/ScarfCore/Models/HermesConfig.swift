import Foundation

/// Settings for one of hermes's auxiliary model tasks (vision, compression, approvals, etc.).
/// Every auxiliary task follows the same provider/model/base_url/api_key/timeout pattern.
public struct AuxiliaryModel: Sendable, Equatable {
    public var provider: String
    public var model: String
    public var baseURL: String
    public var apiKey: String
    public var timeout: Int
    /// `auxiliary.<task>.reasoning_effort` (Hermes v0.19+,
    /// hermes_cli/config_defaults.py — every auxiliary task carries this
    /// field). Valid values per `hermes_constants.VALID_REASONING_EFFORTS`:
    /// `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`, plus the
    /// `none` alias (`parse_reasoning_effort` also accepts `false`/
    /// `disabled`) meaning "explicitly disable thinking" as opposed to an
    /// empty string, which means "inherit the provider default". Scarf
    /// stores the raw string and writes it verbatim; validation of the
    /// allowed set lives in `AuxiliaryReasoningEffort`.
    public var reasoningEffort: String
    /// `auxiliary.<task>.max_concurrency` (v0.20.4+) — true-optional cap on
    /// simultaneous calls for this auxiliary task. Currently only
    /// documented for `auxiliary.compression`. `nil` = key absent = legacy
    /// unlimited behavior; distinct from any concrete int.
    public var maxConcurrency: Int?

    public init(
        provider: String,
        model: String,
        baseURL: String,
        apiKey: String,
        timeout: Int,
        reasoningEffort: String = "",
        maxConcurrency: Int? = nil
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.reasoningEffort = reasoningEffort
        self.maxConcurrency = maxConcurrency
    }
    public nonisolated static let empty = AuxiliaryModel(provider: "auto", model: "", baseURL: "", apiKey: "", timeout: 30, reasoningEffort: "", maxConcurrency: nil)
}

/// Valid `auxiliary.<task>.reasoning_effort` values, source-verified against
/// `hermes_constants.VALID_REASONING_EFFORTS` + `parse_reasoning_effort`
/// (hermes-agent HEAD == v2026.8.3 / v0.20.0). `none` is a Scarf-facing
/// alias for Hermes's disable-thinking sentinel (Hermes also accepts
/// `false`/`disabled`, but `none` is what `hermes_constants.py`'s docstring
/// uses and what the picker offers).
public enum AuxiliaryReasoningEffort: String, CaseIterable, Sendable {
    case none, minimal, low, medium, high, xhigh, max, ultra

    /// Empty string means "unset — inherit provider default" and is not a
    /// member of this enum; callers surface it as a separate "Default" row.
    public static let validRawValues: Set<String> = Set(allCases.map(\.rawValue))
}

/// Group of display-related settings mirroring the `display:` block in config.yaml.
public struct DisplaySettings: Sendable, Equatable {
    public var skin: String
    public var compact: Bool
    public var resumeDisplay: String           // "full" | "minimal"
    public var bellOnComplete: Bool
    public var inlineDiffs: Bool
    public var toolProgressCommand: Bool
    public var toolPreviewLength: Int
    public var busyInputMode: String           // e.g. "interrupt"
    /// Static-message translation language. v0.13+. Empty string means
    /// "follow Hermes default" — the picker collapses both empty-string
    /// and `"en"` to "English" in display, but only writes a value when
    /// the user explicitly picks one. Persisted via
    /// `hermes config set display.language <code>`. Supported values per
    /// v0.13 release notes: `en`, `zh`, `ja`, `de`, `es`, `fr`, `uk`, `tr`.
    public var language: String
    /// Hermes v0.14 — `display.timestamps` toggle. When true, the TUI
    /// renders per-message timestamps alongside the agent's output;
    /// ACP-relayed transcripts pick up the agent's own footer
    /// formatting and Scarf doesn't render them separately. Persisted
    /// via `hermes config set display.timestamps <bool>`. Pre-v0.14
    /// hosts ignore the key; Scarf hides the toggle when
    /// `HermesCapabilities.hasDisplayTimestamps` is false.
    public var timestamps: Bool


    public init(
        skin: String,
        compact: Bool,
        resumeDisplay: String,
        bellOnComplete: Bool,
        inlineDiffs: Bool,
        toolProgressCommand: Bool,
        toolPreviewLength: Int,
        busyInputMode: String,
        language: String = "",
        timestamps: Bool = false
    ) {
        self.skin = skin
        self.compact = compact
        self.resumeDisplay = resumeDisplay
        self.bellOnComplete = bellOnComplete
        self.inlineDiffs = inlineDiffs
        self.toolProgressCommand = toolProgressCommand
        self.toolPreviewLength = toolPreviewLength
        self.busyInputMode = busyInputMode
        self.language = language
        self.timestamps = timestamps
    }
    public nonisolated static let empty = DisplaySettings(
        skin: "default",
        compact: false,
        resumeDisplay: "full",
        bellOnComplete: false,
        inlineDiffs: true,
        toolProgressCommand: false,
        toolPreviewLength: 0,
        busyInputMode: "interrupt",
        language: "",
        timestamps: false
    )
}

/// Container/terminal backend options. These map to `terminal.*` keys in config.yaml.
public struct TerminalSettings: Sendable, Equatable {
    public var cwd: String
    public var timeout: Int
    public var envPassthrough: [String]
    public var persistentShell: Bool
    public var dockerImage: String
    public var dockerMountCwdToWorkspace: Bool
    public var dockerForwardEnv: [String]
    public var dockerVolumes: [String]
    /// Hermes v0.14 — extra flags forwarded verbatim to `docker run` for
    /// the docker terminal backend (`terminal.docker_extra_args` in
    /// config.yaml, a list of strings). Empty list means "no extras".
    /// Pre-v0.14 hosts ignore the key; Scarf hides the editor row when
    /// `HermesCapabilities.hasDockerExtraArgs` is false.
    public var dockerExtraArgs: [String]
    public var containerCPU: Int               // 0 = unlimited
    public var containerMemory: Int            // MB, 0 = unlimited
    public var containerDisk: Int              // MB, 0 = unlimited
    public var containerPersistent: Bool
    public var modalImage: String
    public var modalMode: String               // "auto" | other
    public var daytonaImage: String
    public var singularityImage: String


    public init(
        cwd: String,
        timeout: Int,
        envPassthrough: [String],
        persistentShell: Bool,
        dockerImage: String,
        dockerMountCwdToWorkspace: Bool,
        dockerForwardEnv: [String],
        dockerVolumes: [String],
        dockerExtraArgs: [String] = [],
        containerCPU: Int,
        containerMemory: Int,
        containerDisk: Int,
        containerPersistent: Bool,
        modalImage: String,
        modalMode: String,
        daytonaImage: String,
        singularityImage: String
    ) {
        self.cwd = cwd
        self.timeout = timeout
        self.envPassthrough = envPassthrough
        self.persistentShell = persistentShell
        self.dockerImage = dockerImage
        self.dockerMountCwdToWorkspace = dockerMountCwdToWorkspace
        self.dockerForwardEnv = dockerForwardEnv
        self.dockerVolumes = dockerVolumes
        self.dockerExtraArgs = dockerExtraArgs
        self.containerCPU = containerCPU
        self.containerMemory = containerMemory
        self.containerDisk = containerDisk
        self.containerPersistent = containerPersistent
        self.modalImage = modalImage
        self.modalMode = modalMode
        self.daytonaImage = daytonaImage
        self.singularityImage = singularityImage
    }
    public nonisolated static let empty = TerminalSettings(
        cwd: ".",
        timeout: 180,
        envPassthrough: [],
        persistentShell: true,
        dockerImage: "",
        dockerMountCwdToWorkspace: false,
        dockerForwardEnv: [],
        dockerVolumes: [],
        dockerExtraArgs: [],
        containerCPU: 0,
        containerMemory: 0,
        containerDisk: 0,
        containerPersistent: false,
        modalImage: "",
        modalMode: "auto",
        daytonaImage: "",
        singularityImage: ""
    )
}

/// Browser automation tuning (`browser.*`).
public struct BrowserSettings: Sendable, Equatable {
    public var inactivityTimeout: Int
    public var commandTimeout: Int
    public var recordSessions: Bool
    public var allowPrivateURLs: Bool
    public var camofoxManagedPersistence: Bool


    public init(
        inactivityTimeout: Int,
        commandTimeout: Int,
        recordSessions: Bool,
        allowPrivateURLs: Bool,
        camofoxManagedPersistence: Bool
    ) {
        self.inactivityTimeout = inactivityTimeout
        self.commandTimeout = commandTimeout
        self.recordSessions = recordSessions
        self.allowPrivateURLs = allowPrivateURLs
        self.camofoxManagedPersistence = camofoxManagedPersistence
    }
    public nonisolated static let empty = BrowserSettings(
        inactivityTimeout: 120,
        commandTimeout: 30,
        recordSessions: false,
        allowPrivateURLs: false,
        camofoxManagedPersistence: false
    )
}

/// Voice push-to-talk plus TTS/STT provider settings.
public struct VoiceSettings: Sendable, Equatable {
    public var recordKey: String
    public var maxRecordingSeconds: Int
    public var silenceDuration: Double

    // TTS
    public var ttsProvider: String
    public var ttsEdgeVoice: String
    public var ttsElevenLabsVoiceID: String
    public var ttsElevenLabsModelID: String
    public var ttsOpenAIModel: String
    public var ttsOpenAIVoice: String
    public var ttsNeuTTSModel: String
    public var ttsNeuTTSDevice: String
    /// xAI TTS voice identifier. v0.13+ — xAI shipped TTS earlier but the
    /// custom-voice / cloning surface is the v0.13 add-on.
    // TODO(WS-8-Q2): Confirm key name vs `tts.xai.voice` /
    // `tts.xai.voice_id` / a top-level `tts.xai_voice` once a v0.13
    // host is on hand. The setter / YAML reader follow whatever this
    // field name implies.
    public var ttsXAIVoiceID: String
    /// xAI TTS `auto_speech_tags`. v0.15+ — when true, xAI auto-inserts
    /// speech-control tags (emotion / emphasis) into synthesized output.
    /// Config key `tts.xai.auto_speech_tags`, default `false`. Pre-v0.15
    /// hosts ignore the key; Scarf hides the toggle when
    /// `HermesCapabilities.hasXAITTSAutoSpeechTags` is false.
    public var ttsXAIAutoSpeechTags: Bool
    /// xAI TTS advanced params. v0.19+ (`hasXAITTSAdvancedParams`):
    /// `tts.xai.language` (BCP-47 or "auto", default "en"),
    /// `tts.xai.speed` (0.7-1.5, default 1.0),
    /// `tts.xai.optimize_streaming_latency` (0-2, default 0),
    /// `tts.xai.sample_rate` (22050/24000/44100/48000, default 24000),
    /// `tts.xai.bit_rate` (MP3 bitrate, default 128000).
    public var ttsXAILanguage: String
    public var ttsXAISpeed: Double
    public var ttsXAIOptimizeStreamingLatency: Int
    public var ttsXAISampleRate: Int
    public var ttsXAIBitRate: Int
    /// DeepInfra TTS. v0.19+ (`hasDeepInfraTTS`): `tts.deepinfra.model`
    /// (empty = first tts-tagged model from the live catalog),
    /// `tts.deepinfra.voice` (default "default").
    public var ttsDeepInfraModel: String
    public var ttsDeepInfraVoice: String

    // STT
    public var sttEnabled: Bool
    /// `stt.provider` — empty means the key is **absent**, not `local`.
    ///
    /// Hermes v0.20.5 removed the seeded `stt.provider: local` from
    /// `config_defaults.py`: an absent key now means "autodetect ladder", and
    /// any stored value is an explicit pin that disables autodetection. On
    /// pre-v0.20.5 hosts the key was seeded to `local`, so absent there is
    /// simply Hermes' own default. Either way the correct rendering for empty
    /// is "Auto (unset)" — Hermes decides — and the correct write for it is
    /// `hermes config unset stt.provider`, never an empty scalar.
    public var sttProvider: String
    public var sttLocalModel: String
    public var sttLocalLanguage: String
    public var sttOpenAIModel: String
    public var sttMistralModel: String
    /// `stt.openai.language` — per-provider override of the global STT
    /// language hint (empty = auto-detect). Predates version tracking,
    /// like the sibling `sttOpenAIModel`; ungated.
    public var sttOpenAILanguage: String
    /// Global STT language hint applied to every provider unless a
    /// per-provider `language` overrides it. v0.20+ (`hasSTTUnifiedLanguage`).
    /// Default `"en"` (Hermes default as of v2026.7.30; empty restores
    /// auto-detect).
    public var sttLanguage: String
    /// `stt.groq.{model,language}`. v0.20+ (`hasSTTUnifiedLanguage`).
    public var sttGroqModel: String
    public var sttGroqLanguage: String
    /// `stt.local.*` anti-hallucination VAD tuning. v0.20+
    /// (`hasSTTLocalVADTuning`). `vad` defaults true (Silero VAD filter);
    /// the three numeric knobs only take effect when `vad` is enabled.
    public var sttLocalVAD: Bool
    public var sttLocalVADMinSilenceMS: Int
    public var sttLocalNoSpeechProbThreshold: Double
    public var sttLocalLogprobThreshold: Double
    /// `stt.local.unload_after_idle_seconds` — v0.20.4+. `0` (default) =
    /// never unload the local whisper model; a positive value releases it
    /// (freeing VRAM on GPU) after that many idle seconds, reloading on the
    /// next voice message.
    public var sttLocalUnloadAfterIdleSeconds: Int
    /// `stt.cloud_trim_silence` / `stt.cloud_trim_threshold_db` /
    /// `stt.cloud_trim_keep_ms` — v0.20.4+. TOP-LEVEL siblings of
    /// `stt.local.*` (NOT nested under `stt.local`). Client-side ffmpeg
    /// silence trim applied before upload to cloud STT providers
    /// (groq/openai/mistral/xai/elevenlabs/deepinfra). Default: trim on,
    /// threshold -40dB, keep 300ms of each pause.
    public var sttCloudTrimSilence: Bool
    public var sttCloudTrimThresholdDB: Double
    public var sttCloudTrimKeepMS: Int
    /// `wake_word.capture` — v0.20.4+. `"auto"` (default) | `"local"` |
    /// `"client"`. auto = backend PortAudio mic when one exists, else
    /// remote-desktop streams via the `wake.feed` RPC; local = always the
    /// backend mic; client = always desktop-streamed PCM (detection stays
    /// on the backend).
    public var wakeWordCapture: String

    public init(
        recordKey: String,
        maxRecordingSeconds: Int,
        silenceDuration: Double,
        ttsProvider: String,
        ttsEdgeVoice: String,
        ttsElevenLabsVoiceID: String,
        ttsElevenLabsModelID: String,
        ttsOpenAIModel: String,
        ttsOpenAIVoice: String,
        ttsNeuTTSModel: String,
        ttsNeuTTSDevice: String,
        sttEnabled: Bool,
        sttProvider: String,
        sttLocalModel: String,
        sttLocalLanguage: String,
        sttOpenAIModel: String,
        sttMistralModel: String,
        ttsXAIVoiceID: String = "",
        ttsXAIAutoSpeechTags: Bool = false,
        ttsXAILanguage: String = "en",
        ttsXAISpeed: Double = 1.0,
        ttsXAIOptimizeStreamingLatency: Int = 0,
        ttsXAISampleRate: Int = 24000,
        ttsXAIBitRate: Int = 128000,
        ttsDeepInfraModel: String = "",
        ttsDeepInfraVoice: String = "default",
        sttOpenAILanguage: String = "",
        sttLanguage: String = "en",
        sttGroqModel: String = "whisper-large-v3-turbo",
        sttGroqLanguage: String = "",
        sttLocalVAD: Bool = true,
        sttLocalVADMinSilenceMS: Int = 500,
        sttLocalNoSpeechProbThreshold: Double = 0.6,
        sttLocalLogprobThreshold: Double = -1.0,
        sttLocalUnloadAfterIdleSeconds: Int = 0,
        sttCloudTrimSilence: Bool = true,
        sttCloudTrimThresholdDB: Double = -40,
        sttCloudTrimKeepMS: Int = 300,
        wakeWordCapture: String = "auto"
    ) {
        self.recordKey = recordKey
        self.maxRecordingSeconds = maxRecordingSeconds
        self.silenceDuration = silenceDuration
        self.ttsProvider = ttsProvider
        self.ttsEdgeVoice = ttsEdgeVoice
        self.ttsElevenLabsVoiceID = ttsElevenLabsVoiceID
        self.ttsElevenLabsModelID = ttsElevenLabsModelID
        self.ttsOpenAIModel = ttsOpenAIModel
        self.ttsOpenAIVoice = ttsOpenAIVoice
        self.ttsNeuTTSModel = ttsNeuTTSModel
        self.ttsNeuTTSDevice = ttsNeuTTSDevice
        self.ttsXAIVoiceID = ttsXAIVoiceID
        self.ttsXAIAutoSpeechTags = ttsXAIAutoSpeechTags
        self.ttsXAILanguage = ttsXAILanguage
        self.ttsXAISpeed = ttsXAISpeed
        self.ttsXAIOptimizeStreamingLatency = ttsXAIOptimizeStreamingLatency
        self.ttsXAISampleRate = ttsXAISampleRate
        self.ttsXAIBitRate = ttsXAIBitRate
        self.ttsDeepInfraModel = ttsDeepInfraModel
        self.ttsDeepInfraVoice = ttsDeepInfraVoice
        self.sttEnabled = sttEnabled
        self.sttProvider = sttProvider
        self.sttLocalModel = sttLocalModel
        self.sttLocalLanguage = sttLocalLanguage
        self.sttOpenAIModel = sttOpenAIModel
        self.sttMistralModel = sttMistralModel
        self.sttOpenAILanguage = sttOpenAILanguage
        self.sttLanguage = sttLanguage
        self.sttGroqModel = sttGroqModel
        self.sttGroqLanguage = sttGroqLanguage
        self.sttLocalVAD = sttLocalVAD
        self.sttLocalVADMinSilenceMS = sttLocalVADMinSilenceMS
        self.sttLocalNoSpeechProbThreshold = sttLocalNoSpeechProbThreshold
        self.sttLocalLogprobThreshold = sttLocalLogprobThreshold
        self.sttLocalUnloadAfterIdleSeconds = sttLocalUnloadAfterIdleSeconds
        self.sttCloudTrimSilence = sttCloudTrimSilence
        self.sttCloudTrimThresholdDB = sttCloudTrimThresholdDB
        self.sttCloudTrimKeepMS = sttCloudTrimKeepMS
        self.wakeWordCapture = wakeWordCapture
    }
    public nonisolated static let empty = VoiceSettings(
        recordKey: "ctrl+b",
        maxRecordingSeconds: 120,
        silenceDuration: 3.0,
        ttsProvider: "edge",
        ttsEdgeVoice: "en-US-AriaNeural",
        ttsElevenLabsVoiceID: "",
        ttsElevenLabsModelID: "eleven_multilingual_v2",
        ttsOpenAIModel: "gpt-4o-mini-tts",
        ttsOpenAIVoice: "alloy",
        ttsNeuTTSModel: "neuphonic/neutts-air-q4-gguf",
        ttsNeuTTSDevice: "cpu",
        sttEnabled: true,
        // Empty = key absent = Hermes decides (autodetect on v0.20.5+, the
        // seeded `local` default on older hosts). See the field doc.
        sttProvider: "",
        sttLocalModel: "base",
        sttLocalLanguage: "",
        sttOpenAIModel: "whisper-1",
        sttMistralModel: "voxtral-mini-latest",
        ttsXAIVoiceID: "",
        ttsXAIAutoSpeechTags: false
    )
}

/// Per-task auxiliary model overrides.
///
/// `flush_memories` was removed in Hermes v0.12 but remains alive on
/// pre-v0.12 hosts — the field is preserved here so the YAML parser
/// can round-trip it and `AuxiliaryTab` can render the row when
/// `HermesCapabilities.hasFlushMemoriesAux` is set. On v0.12+ the
/// field stays empty and is never surfaced.
/// `curator` was added in v0.12 — Curator's review fork uses its own
/// model so users can keep main-model spend separate from background
/// maintenance.
public struct AuxiliarySettings: Sendable, Equatable {
    public var vision: AuxiliaryModel
    public var webExtract: AuxiliaryModel
    public var compression: AuxiliaryModel
    public var sessionSearch: AuxiliaryModel
    public var skillsHub: AuxiliaryModel
    public var approval: AuxiliaryModel
    public var mcp: AuxiliaryModel
    /// pre-v0.12 only; on v0.12+ this stays `.empty` and the row is hidden.
    public var flushMemories: AuxiliaryModel
    /// v0.12+; pre-v0.12 Hermes installs ignore this slot.
    public var curator: AuxiliaryModel
    /// `auxiliary.title_generation` — predates Hermes's calendar-version
    /// scheme (present well before the v0.12 line, unlike `curator`), so
    /// this block is read/written ungated like the other long-standing
    /// auxiliary tasks. See `TitleGenerationSettings` for field-level
    /// version notes (`language` is v0.18+).
    public var titleGeneration: TitleGenerationSettings
    /// `auxiliary.background_review.enabled` (v0.20.4+) — NOT
    /// `agent.background_review.enabled`; the real YAML structure nests
    /// `background_review:` under the top-level `auxiliary:` block
    /// (source-verified against `cli-config.yaml.example` @ v2026.8.18).
    /// Default `true`. Post-turn memory/skill self-improvement fork that
    /// runs after a turn when nudge intervals fire; costs tokens. `false`
    /// skips automatic forks (`/refine` still works).
    public var backgroundReviewEnabled: Bool

    public init(
        vision: AuxiliaryModel,
        webExtract: AuxiliaryModel,
        compression: AuxiliaryModel,
        sessionSearch: AuxiliaryModel,
        skillsHub: AuxiliaryModel,
        approval: AuxiliaryModel,
        mcp: AuxiliaryModel,
        flushMemories: AuxiliaryModel,
        curator: AuxiliaryModel,
        titleGeneration: TitleGenerationSettings = .empty,
        backgroundReviewEnabled: Bool = true
    ) {
        self.vision = vision
        self.webExtract = webExtract
        self.compression = compression
        self.sessionSearch = sessionSearch
        self.skillsHub = skillsHub
        self.approval = approval
        self.mcp = mcp
        self.flushMemories = flushMemories
        self.curator = curator
        self.titleGeneration = titleGeneration
        self.backgroundReviewEnabled = backgroundReviewEnabled
    }
    public nonisolated static let empty = AuxiliarySettings(
        vision: .empty,
        webExtract: .empty,
        compression: .empty,
        sessionSearch: .empty,
        skillsHub: .empty,
        approval: .empty,
        mcp: .empty,
        flushMemories: .empty,
        curator: .empty,
        titleGeneration: .empty,
        backgroundReviewEnabled: true
    )
}

/// `auxiliary.title_generation` — the LLM call that names a new chat
/// session. Unlike the other auxiliary tasks it carries two extra fields
/// beyond the standard provider/model/base_url/api_key/timeout/
/// reasoning_effort shape: `enabled` (title generation can be turned off
/// entirely — config_defaults.py defaults it to `True`) and `language`
/// (force titles into a specific language regardless of chat language;
/// v0.18+, added alongside `display.language` — hermes-agent commit
/// cf58f1a520, first released v2026.7.1 = v0.18.0). Kept as its own struct
/// rather than folded into `AuxiliaryModel` so those two fields don't leak
/// into every other auxiliary task's shape.
public struct TitleGenerationSettings: Sendable, Equatable {
    public var enabled: Bool
    public var provider: String
    public var model: String
    public var baseURL: String
    public var apiKey: String
    public var timeout: Int
    public var reasoningEffort: String
    /// v0.18+ — see type doc. Empty means "match the chat's language"
    /// (Hermes default).
    public var language: String
    /// `auxiliary.title_generation.max_concurrency` (v0.20.4+) —
    /// true-optional cap on simultaneous title calls. `nil` = key absent =
    /// legacy unlimited behavior.
    public var maxConcurrency: Int?

    public init(
        enabled: Bool,
        provider: String,
        model: String,
        baseURL: String,
        apiKey: String,
        timeout: Int,
        reasoningEffort: String,
        language: String,
        maxConcurrency: Int? = nil
    ) {
        self.enabled = enabled
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.reasoningEffort = reasoningEffort
        self.language = language
        self.maxConcurrency = maxConcurrency
    }

    public nonisolated static let empty = TitleGenerationSettings(
        enabled: true,
        provider: "auto",
        model: "",
        baseURL: "",
        apiKey: "",
        timeout: 30,
        reasoningEffort: "",
        language: "",
        maxConcurrency: nil
    )
}

/// Security/redaction/firewall config. Website blocklist is nested in YAML.
public struct SecuritySettings: Sendable, Equatable {
    public var redactSecrets: Bool
    public var redactPII: Bool                 // from privacy.redact_pii
    public var tirithEnabled: Bool
    public var tirithPath: String
    public var tirithTimeout: Int
    public var tirithFailOpen: Bool
    public var blocklistEnabled: Bool
    public var blocklistDomains: [String]


    public init(
        redactSecrets: Bool,
        redactPII: Bool,
        tirithEnabled: Bool,
        tirithPath: String,
        tirithTimeout: Int,
        tirithFailOpen: Bool,
        blocklistEnabled: Bool,
        blocklistDomains: [String]
    ) {
        self.redactSecrets = redactSecrets
        self.redactPII = redactPII
        self.tirithEnabled = tirithEnabled
        self.tirithPath = tirithPath
        self.tirithTimeout = tirithTimeout
        self.tirithFailOpen = tirithFailOpen
        self.blocklistEnabled = blocklistEnabled
        self.blocklistDomains = blocklistDomains
    }
    public nonisolated static let empty = SecuritySettings(
        redactSecrets: true,
        redactPII: false,
        tirithEnabled: true,
        tirithPath: "tirith",
        tirithTimeout: 5,
        tirithFailOpen: true,
        blocklistEnabled: false,
        blocklistDomains: []
    )
}

/// Human-delay simulates realistic typing pace (`human_delay.*`).
public struct HumanDelaySettings: Sendable, Equatable {
    public var mode: String                    // "off" | "natural" | "custom"
    public var minMS: Int
    public var maxMS: Int


    public init(
        mode: String,
        minMS: Int,
        maxMS: Int
    ) {
        self.mode = mode
        self.minMS = minMS
        self.maxMS = maxMS
    }
    public nonisolated static let empty = HumanDelaySettings(mode: "off", minMS: 800, maxMS: 2500)
}

/// Compression / context routing.
public struct CompressionSettings: Sendable, Equatable {
    public var enabled: Bool
    public var threshold: Double
    public var targetRatio: Double
    public var protectLastN: Int
    // -- v0.20 tuning keys (config_defaults.py `compression` block) ------
    /// `compression.threshold_tokens` — absolute token cap. Hermes default
    /// is `None` (unset); Scarf uses 0 as the "absent" sentinel. When > 0,
    /// compression triggers at the LOWER of the ratio `threshold` and this
    /// count (Hermes clamps to the model context at apply-time and treats
    /// `<= 0` as off — config.py's `_tt > 0` display guard).
    public var thresholdTokens: Int
    /// `compression.min_tail_user_messages` — real user messages guaranteed
    /// to survive uncompressed in the tail. Hermes default 1.
    public var minTailUserMessages: Int
    /// `compression.idle_compact_after_seconds` — opt-in idle compaction.
    /// 0 (Hermes default) = disabled.
    public var idleCompactAfterSeconds: Int
    /// `compression.progress_notices` — when true, routine compression
    /// progress statuses reach chat gateway platforms. Hermes default false.
    public var progressNotices: Bool


    public init(
        enabled: Bool,
        threshold: Double,
        targetRatio: Double,
        protectLastN: Int,
        thresholdTokens: Int = 0,
        minTailUserMessages: Int = 1,
        idleCompactAfterSeconds: Int = 0,
        progressNotices: Bool = false
    ) {
        self.enabled = enabled
        self.threshold = threshold
        self.targetRatio = targetRatio
        self.protectLastN = protectLastN
        self.thresholdTokens = thresholdTokens
        self.minTailUserMessages = minTailUserMessages
        self.idleCompactAfterSeconds = idleCompactAfterSeconds
        self.progressNotices = progressNotices
    }
    public nonisolated static let empty = CompressionSettings(enabled: true, threshold: 0.5, targetRatio: 0.2, protectLastN: 20)
}

/// `checkpoints.*`. Both fields carry an "absent on disk" sentinel because
/// Hermes v0.21 flipped the server-side defaults (enabled `true` → `false`,
/// max_snapshots `50` → `20`); showing the old defaults for an absent key
/// misreports a v0.21 host's actual behavior. Resolve for display through
/// `HermesConfig.displayCheckpointsEnabled(capabilities:)` /
/// `displayCheckpointsMaxSnapshots(capabilities:)` — never read the raw
/// fields into UI.
public struct CheckpointSettings: Sendable, Equatable {
    /// `nil` = key absent from config.yaml (parse sentinel).
    public var enabled: Bool?
    /// `0` = key absent from config.yaml (parse sentinel). Hermes has no
    /// meaningful `0` here (a zero-snapshot cap is checkpoints-off, which
    /// is what `enabled` expresses), so the collision is inert.
    public var maxSnapshots: Int


    public init(
        enabled: Bool?,
        maxSnapshots: Int
    ) {
        self.enabled = enabled
        self.maxSnapshots = maxSnapshots
    }
    public nonisolated static let empty = CheckpointSettings(enabled: nil, maxSnapshots: 0)
}

public struct LoggingSettings: Sendable, Equatable {
    public var level: String                   // DEBUG | INFO | WARNING | ERROR
    public var maxSizeMB: Int
    public var backupCount: Int


    public init(
        level: String,
        maxSizeMB: Int,
        backupCount: Int
    ) {
        self.level = level
        self.maxSizeMB = maxSizeMB
        self.backupCount = backupCount
    }
    public nonisolated static let empty = LoggingSettings(level: "INFO", maxSizeMB: 5, backupCount: 3)
}

public struct DelegationSettings: Sendable, Equatable {
    public var model: String
    public var provider: String
    public var baseURL: String
    public var apiKey: String
    /// `delegation.max_iterations` — max tool-calling turns per child.
    /// Hermes v0.20.4 (migration 36) raised the server-side default 50→250.
    /// `0` = key absent (parse sentinel); resolve through
    /// `HermesConfig.displayDelegationMaxIterations(capabilities:)`.
    public var maxIterations: Int
    /// `delegation.max_concurrent_children` — max parallel child agents per
    /// batch. Hermes v0.20.4 (migration 37) raised the server-side default
    /// 3→10 (floor 1, no ceiling). `0` = key absent (parse sentinel);
    /// resolve through
    /// `HermesConfig.displayDelegationMaxConcurrentChildren(capabilities:)`.
    public var maxConcurrentChildren: Int

    public init(
        model: String,
        provider: String,
        baseURL: String,
        apiKey: String,
        maxIterations: Int,
        maxConcurrentChildren: Int = 0
    ) {
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxIterations = maxIterations
        self.maxConcurrentChildren = maxConcurrentChildren
    }
    public nonisolated static let empty = DelegationSettings(model: "", provider: "", baseURL: "", apiKey: "", maxIterations: 0, maxConcurrentChildren: 0)
}

/// Discord-specific platform settings (`discord.*`). Other platforms currently have thinner schemas.
public struct DiscordSettings: Sendable, Equatable {
    public var requireMention: Bool
    public var freeResponseChannels: String
    public var autoThread: Bool
    public var reactions: Bool
    /// Hermes v0.14 — when true, the Discord adapter reads recent
    /// channel history on first join so the agent has prior context.
    /// Default `true` matches Hermes's v0.14 server-side default.
    /// Pre-v0.14 hosts ignore the key.
    public var historyBackfill: Bool
    /// Hermes v0.15 — `platforms.discord.extra.allow_any_attachment`.
    /// When true, the adapter forwards any attachment type to the agent
    /// (not just images). Default `false`. Pre-v0.15 hosts ignore the key.
    public var allowAnyAttachment: Bool


    public init(
        requireMention: Bool,
        freeResponseChannels: String,
        autoThread: Bool,
        reactions: Bool,
        historyBackfill: Bool = true,
        allowAnyAttachment: Bool = false
    ) {
        self.requireMention = requireMention
        self.freeResponseChannels = freeResponseChannels
        self.autoThread = autoThread
        self.reactions = reactions
        self.historyBackfill = historyBackfill
        self.allowAnyAttachment = allowAnyAttachment
    }
    public nonisolated static let empty = DiscordSettings(requireMention: true, freeResponseChannels: "", autoThread: true, reactions: true, historyBackfill: true, allowAnyAttachment: false)
}

/// Telegram settings under `telegram.*` in config.yaml. Most Telegram tuning is
/// done via environment variables (`TELEGRAM_*`) — this is the subset that lives
/// in the YAML.
public struct TelegramSettings: Sendable, Equatable {
    public var requireMention: Bool
    public var reactions: Bool
    /// Hermes v0.15 — top-level `telegram.disable_topic_auto_rename`.
    /// When true, the adapter won't auto-rename forum topics. Default
    /// `false`. Pre-v0.15 hosts ignore the key.
    public var disableTopicAutoRename: Bool
    /// Hermes v0.15 — `platforms.telegram.extra.ignore_root_dm`. When
    /// true, the agent ignores DMs sent to the root chat. Default
    /// `false`. Pre-v0.15 hosts ignore the key.
    public var ignoreRootDM: Bool
    /// Hermes v0.17 — `platforms.telegram.extra.rich_messages` (Bot API 10.1
    /// rich formatting). Default `true` (on by default; toggle off to opt out).
    /// Pre-v0.17 hosts ignore the key.
    public var richMessages: Bool
    /// Hermes v0.17 — `platforms.telegram.extra.status_indicator`. When true,
    /// the bot advertises an Online/Offline presence label. Default `false`.
    /// Pre-v0.17 hosts ignore the key.
    public var statusIndicator: Bool


    public init(
        requireMention: Bool,
        reactions: Bool,
        disableTopicAutoRename: Bool = false,
        ignoreRootDM: Bool = false,
        richMessages: Bool = true,
        statusIndicator: Bool = false
    ) {
        self.requireMention = requireMention
        self.reactions = reactions
        self.disableTopicAutoRename = disableTopicAutoRename
        self.ignoreRootDM = ignoreRootDM
        self.richMessages = richMessages
        self.statusIndicator = statusIndicator
    }
    public nonisolated static let empty = TelegramSettings(requireMention: true, reactions: false, disableTopicAutoRename: false, ignoreRootDM: false, richMessages: true, statusIndicator: false)
}

/// Signal settings. Signal credentials live in `.env` (`SIGNAL_*`); v0.15
/// added a group-only `platforms.signal.extra.require_mention` config key.
public struct SignalSettings: Sendable, Equatable {
    /// Hermes v0.15 — `platforms.signal.extra.require_mention`. In group
    /// chats, only respond when @mentioned. Default `false`. Pre-v0.15
    /// hosts ignore the key.
    public var requireMention: Bool


    public init(requireMention: Bool = false) {
        self.requireMention = requireMention
    }
    public nonisolated static let empty = SignalSettings(requireMention: false)
}

/// Slack settings under `platforms.slack.*` (and a couple of top-level keys).
public struct SlackSettings: Sendable, Equatable {
    public var replyToMode: String         // "off" | "first" | "all"
    public var requireMention: Bool
    public var replyInThread: Bool
    public var replyBroadcast: Bool


    public init(
        replyToMode: String,
        requireMention: Bool,
        replyInThread: Bool,
        replyBroadcast: Bool
    ) {
        self.replyToMode = replyToMode
        self.requireMention = requireMention
        self.replyInThread = replyInThread
        self.replyBroadcast = replyBroadcast
    }
    public nonisolated static let empty = SlackSettings(replyToMode: "first", requireMention: true, replyInThread: true, replyBroadcast: false)
}

/// Matrix settings under `matrix.*`.
public struct MatrixSettings: Sendable, Equatable {
    public var requireMention: Bool
    public var autoThread: Bool
    public var dmMentionThreads: Bool


    public init(
        requireMention: Bool,
        autoThread: Bool,
        dmMentionThreads: Bool
    ) {
        self.requireMention = requireMention
        self.autoThread = autoThread
        self.dmMentionThreads = dmMentionThreads
    }
    public nonisolated static let empty = MatrixSettings(requireMention: true, autoThread: true, dmMentionThreads: false)
}

/// Mattermost settings. Mattermost is mostly driven by env vars; config.yaml
/// currently just exposes `group_sessions_per_user` at the top level, but we
/// reserve this struct for future expansion so the form has a stable type.
public struct MattermostSettings: Sendable, Equatable {
    public var requireMention: Bool
    public var replyMode: String           // "thread" | "off"


    public init(
        requireMention: Bool,
        replyMode: String
    ) {
        self.requireMention = requireMention
        self.replyMode = replyMode
    }
    public nonisolated static let empty = MattermostSettings(requireMention: true, replyMode: "off")
}

/// WhatsApp settings under `whatsapp.*`.
public struct WhatsAppSettings: Sendable, Equatable {
    public var unauthorizedDMBehavior: String  // "pair" | "ignore"
    public var replyPrefix: String


    public init(
        unauthorizedDMBehavior: String,
        replyPrefix: String
    ) {
        self.unauthorizedDMBehavior = unauthorizedDMBehavior
        self.replyPrefix = replyPrefix
    }
    public nonisolated static let empty = WhatsAppSettings(unauthorizedDMBehavior: "pair", replyPrefix: "")
}

/// ntfy settings under `platforms.ntfy.extra` (Hermes v0.15, 23rd platform).
/// `topic` + `server` are also settable via env (`NTFY_TOPIC` /
/// `NTFY_SERVER_URL`), which win over config.yaml. `publishTopic`, `token`,
/// and `markdown` live only in the YAML `extra` block. `token` is a bearer
/// token, or `user:pass` for Basic auth — treated as a secret in the UI.
public struct NtfySettings: Sendable, Equatable {
    public var topic: String
    public var server: String
    public var publishTopic: String
    public var token: String
    public var markdown: Bool


    public init(
        topic: String,
        server: String,
        publishTopic: String,
        token: String,
        markdown: Bool
    ) {
        self.topic = topic
        self.server = server
        self.publishTopic = publishTopic
        self.token = token
        self.markdown = markdown
    }
    public nonisolated static let empty = NtfySettings(topic: "", server: "https://ntfy.sh", publishTopic: "", token: "", markdown: false)
}

/// WhatsApp Business Cloud API settings under `platforms.whatsapp_cloud.extra.*`
/// (Hermes v0.17, 25th platform — Meta's hosted webhook path, distinct from the
/// older `whatsapp` web-bridge). All keys live in config.yaml; `accessToken`,
/// `appSecret`, and `verifyToken` are secrets (the Cloud API stores creds in the
/// YAML `extra` block, not `.env`). `dmPolicy` gates direct messages — set it to
/// `allowlist` for `allowFrom` to take effect.
public struct WhatsAppCloudSettings: Sendable, Equatable {
    public var phoneNumberID: String
    public var accessToken: String
    public var verifyToken: String
    public var appSecret: String
    public var appID: String
    public var wabaID: String
    public var apiVersion: String
    public var dmPolicy: String        // "open" | "allowlist"
    public var allowFrom: String       // CSV sender IDs (active when dmPolicy = allowlist)

    public init(
        phoneNumberID: String,
        accessToken: String,
        verifyToken: String,
        appSecret: String,
        appID: String,
        wabaID: String,
        apiVersion: String,
        dmPolicy: String,
        allowFrom: String
    ) {
        self.phoneNumberID = phoneNumberID
        self.accessToken = accessToken
        self.verifyToken = verifyToken
        self.appSecret = appSecret
        self.appID = appID
        self.wabaID = wabaID
        self.apiVersion = apiVersion
        self.dmPolicy = dmPolicy
        self.allowFrom = allowFrom
    }
    public nonisolated static let empty = WhatsAppCloudSettings(phoneNumberID: "", accessToken: "", verifyToken: "", appSecret: "", appID: "", wabaID: "", apiVersion: "v20.0", dmPolicy: "open", allowFrom: "")
}

/// Home Assistant filters under `platforms.homeassistant.extra`. Hermes ignores
/// every state change by default; users must opt-in via at least one filter.
public struct HomeAssistantSettings: Sendable, Equatable {
    public var watchDomains: [String]
    public var watchEntities: [String]
    public var watchAll: Bool
    public var ignoreEntities: [String]
    public var cooldownSeconds: Int


    public init(
        watchDomains: [String],
        watchEntities: [String],
        watchAll: Bool,
        ignoreEntities: [String],
        cooldownSeconds: Int
    ) {
        self.watchDomains = watchDomains
        self.watchEntities = watchEntities
        self.watchAll = watchAll
        self.ignoreEntities = ignoreEntities
        self.cooldownSeconds = cooldownSeconds
    }
    public nonisolated static let empty = HomeAssistantSettings(watchDomains: [], watchEntities: [], watchAll: false, ignoreEntities: [], cooldownSeconds: 30)
}

/// Bitwarden Secrets Manager settings (`secrets.bitwarden.*`, Hermes v0.15).
/// A single bootstrap token (whose env-var NAME is `accessTokenEnv`; the
/// token itself lives in `~/.hermes/.env`, never in config) lets Hermes
/// resolve per-provider API keys from a Bitwarden Secrets Manager project,
/// replacing per-provider keys in config/.env. Pre-v0.15 hosts ignore the
/// block; Scarf hides the whole Secrets tab when
/// `HermesCapabilities.hasBitwarden` is false.
public struct BitwardenSettings: Sendable, Equatable {
    public var enabled: Bool
    /// Name of the env var holding the bootstrap access token (default
    /// `"BWS_ACCESS_TOKEN"`). The token VALUE lives in `~/.hermes/.env`,
    /// not in config.yaml.
    public var accessTokenEnv: String
    public var projectID: String
    /// When true, Bitwarden-resolved secrets override existing
    /// per-provider keys already present in config/.env.
    public var overrideExisting: Bool
    /// Empty = US Cloud; `https://vault.bitwarden.eu` = EU; or a
    /// self-hosted URL.
    public var serverURL: String
    public var cacheTTLSeconds: Int
    public var autoInstall: Bool
    /// `secrets.bitwarden.encrypted_cache` (v0.20+, gated on
    /// `HermesCapabilities.hasBitwardenEncryptedCache`). See
    /// `BitwardenEncryptedCacheSettings` for details.
    public var encryptedCache: BitwardenEncryptedCacheSettings


    public init(
        enabled: Bool = false,
        accessTokenEnv: String = "BWS_ACCESS_TOKEN",
        projectID: String = "",
        overrideExisting: Bool = false,
        serverURL: String = "",
        cacheTTLSeconds: Int = 300,
        autoInstall: Bool = true,
        encryptedCache: BitwardenEncryptedCacheSettings = .empty
    ) {
        self.enabled = enabled
        self.accessTokenEnv = accessTokenEnv
        self.projectID = projectID
        self.overrideExisting = overrideExisting
        self.serverURL = serverURL
        self.cacheTTLSeconds = cacheTTLSeconds
        self.autoInstall = autoInstall
        self.encryptedCache = encryptedCache
    }
    public nonisolated static let empty = BitwardenSettings(
        enabled: false,
        accessTokenEnv: "BWS_ACCESS_TOKEN",
        projectID: "",
        overrideExisting: false,
        serverURL: "",
        cacheTTLSeconds: 300,
        autoInstall: true,
        encryptedCache: .empty
    )
}

/// `secrets.bitwarden.encrypted_cache` (Hermes v0.20+, hermes-agent commit
/// `1384087729` "fix(secrets): add encrypted Bitwarden stale cache", first
/// released v2026.7.30). Optional encrypted last-good fallback for
/// network/timeout outages: when enabled, successful BWS fetches write
/// AES-GCM encrypted cache material under `~/.hermes/cache/`. If a later
/// startup can't reach Bitwarden due to NETWORK/TIMEOUT, Hermes may use
/// this cache for up to `maxStaleSeconds`. Auth failures never fall back.
/// `maxStaleSeconds: 0` is Hermes's own default and means "no stale
/// fallback" — a meaningful value, not an empty/unset sentinel.
public struct BitwardenEncryptedCacheSettings: Sendable, Equatable {
    public var enabled: Bool
    public var maxStaleSeconds: Int

    public init(enabled: Bool = false, maxStaleSeconds: Int = 0) {
        self.enabled = enabled
        self.maxStaleSeconds = maxStaleSeconds
    }
    public nonisolated static let empty = BitwardenEncryptedCacheSettings(enabled: false, maxStaleSeconds: 0)
}

/// `secrets.command.*` — an any-CLI vault helper secret source (Hermes
/// v0.20+, hermes-agent commit `3d5dd8efa5` "feat(secrets): add `command`
/// secret source + unified secrets.provider selector", first released
/// v2026.7.30). Unlike Bitwarden/1Password this isn't defaulted in
/// `config_defaults.py`'s `secrets` dict — it's a dynamically-registered
/// source with its own `config_schema()`
/// (`agent/secret_sources/command.py`). `command` is run via `/bin/sh -c`
/// with the same trust level as the user's own `.env` file — the
/// requested secret key is passed only via an env var to the child, never
/// interpolated into the shell string; the helper must print a
/// `KEY=VALUE` blob on stdout. `overrideExisting` defaults to `false`
/// (unlike Bitwarden/1Password) since a local helper isn't a central
/// rotation authority.
public struct CommandSecretsSettings: Sendable, Equatable {
    public var enabled: Bool
    public var command: String
    public var helperTimeoutSeconds: Double
    public var overrideExisting: Bool

    public init(
        enabled: Bool = false,
        command: String = "",
        helperTimeoutSeconds: Double = 3.0,
        overrideExisting: Bool = false
    ) {
        self.enabled = enabled
        self.command = command
        self.helperTimeoutSeconds = helperTimeoutSeconds
        self.overrideExisting = overrideExisting
    }
    public nonisolated static let empty = CommandSecretsSettings(
        enabled: false,
        command: "",
        helperTimeoutSeconds: 3.0,
        overrideExisting: false
    )
}

/// `telemetry.shared_metrics` (Hermes v0.20+, hermes_cli/config_defaults.py
/// — Relay pipeline, landed via commits `3bd338d2a9`, `64faff6768`,
/// `056e7df0e0`, `9baa8cc96c`, `36185bf2e2`, `43d994986e`,
/// `841a5a744a`/`14bed44c8c` (revert+reapply), all first released
/// v2026.7.30). Privacy-safe aggregate metrics written only to this
/// profile's local telemetry directory — collection is opt-in and no
/// remote sink exists. Default `enabled: false`.
public struct TelemetrySettings: Sendable, Equatable {
    public var sharedMetricsEnabled: Bool

    public init(sharedMetricsEnabled: Bool = false) {
        self.sharedMetricsEnabled = sharedMetricsEnabled
    }
    public nonisolated static let empty = TelemetrySettings(sharedMetricsEnabled: false)
}

/// `database.*` — SQLite journal/WAL sizing pragmas applied by every
/// Hermes database opener (Hermes v0.20+; `journal_mode` via commit
/// `91351b7b7` "fix(state): make journal mode canonical and behaviorally
/// verified", `wal_autocheckpoint`/`journal_size_limit` via commit
/// `9d4bfd5e3` "fix(config): register WAL sizing pragmas in
/// DEFAULT_CONFIG" — both first released v2026.7.30).
///
/// `journalMode`: closed enum in practice — `hermes_state.resolve_journal_mode()`
/// lower-cases + validates against `{"wal", "delete"}` and falls back to
/// `"wal"` for anything else, so Scarf offers only these two documented
/// values via a picker rather than free text.
///
/// `walAutocheckpoint` / `journalSizeLimit`: optional ints (pages / bytes).
/// `nil` = SQLite/Hermes default (autocheckpoint 1000 pages, no size
/// limit) — verified in `hermes_state.py` which reads
/// `database.get("wal_autocheckpoint")` / `database.get("journal_size_limit")`
/// directly (`None` when absent) and only applies a PRAGMA when the value
/// is a concrete int. This is the empty-string-vs-unset hazard: `nil` is
/// meaningfully different from `0`, so both are modeled as true optionals
/// and written via `SettingsViewModel.unsetSetting` when cleared, never
/// via an empty-string sentinel.
public struct DatabaseSettings: Sendable, Equatable {
    public var journalMode: String
    public var walAutocheckpoint: Int?
    public var journalSizeLimit: Int?

    public init(
        journalMode: String = "wal",
        walAutocheckpoint: Int? = nil,
        journalSizeLimit: Int? = nil
    ) {
        self.journalMode = journalMode
        self.walAutocheckpoint = walAutocheckpoint
        self.journalSizeLimit = journalSizeLimit
    }
    public nonisolated static let empty = DatabaseSettings(journalMode: "wal", walAutocheckpoint: nil, journalSizeLimit: nil)
}

// MARK: - Root Config

public struct HermesConfig: Sendable {
    // Original fields — preserved for zero breakage with existing call sites.
    public var model: String
    public var provider: String
    public var maxTurns: Int
    public var personality: String

    /// Sentinel/marker value for "no turn ceiling". Doubles as the parse
    /// sentinel for an absent `agent.max_turns` key and as the value Scarf
    /// writes for an explicit unlimited pin — Hermes v0.20.5's
    /// `resolve_turn_limit` accepts `0` (alongside `none`/`unlimited`/`inf`/
    /// `-1`) as unlimited, so the two collapse to the same meaning there.
    public static let maxTurnsUnlimited = 0

    /// Capability-appropriate display value for `agent.max_turns`.
    ///
    /// `maxTurns == 0` means either the key is absent from config.yaml (parse
    /// sentinel) or it is explicitly `0`. The effective server default for an
    /// absent key is:
    ///   * v0.20.5+ — **unlimited** (`config_defaults.py` stopped seeding a
    ///     ceiling; `TURN_LIMIT_UNLIMITED`), reported here as
    ///     `maxTurnsUnlimited` (0),
    ///   * v0.20.0–v0.20.4 — 500,
    ///   * older — 60.
    ///
    /// Display-only — callers must never write the resolved value back to
    /// config.yaml. A returned `0` must be rendered as "Unlimited", never as
    /// the number zero; use `displayMaxTurnsText(capabilities:)`.
    ///
    /// Note the deliberate ambiguity on pre-v0.20.5 hosts: an explicit
    /// `agent.max_turns: 0` there is indistinguishable from an absent key and
    /// shows as 500/60. Scarf never writes 0 on those hosts (the steppers cap
    /// the low end at 1 unless `isV0205OrLater`), so the only way to reach that
    /// state is a hand-edited config on a host that has no unlimited semantics
    /// anyway.
    public func displayMaxTurns(capabilities: HermesCapabilities) -> Int {
        if maxTurns > 0 { return maxTurns }
        if capabilities.isV0205OrLater { return Self.maxTurnsUnlimited }
        return capabilities.isV020OrLater ? 500 : 60
    }

    /// Lowest `agent.gateway_turn_lease_timeout` any supported host accepts as
    /// a meaningful value — v0.21's own default. Steppers use it as the floor
    /// so the v0.21 default is expressible (the old 60-second floor could not
    /// represent it, which meant a v0.21 host's default silently snapped up to
    /// 60 the first time the user touched the control).
    public static let gatewayTurnLeaseTimeoutMinimum = 5

    /// Effective `agent.gateway_turn_lease_timeout` for display: the on-disk
    /// value when one is set, otherwise the connected host's own default —
    /// **5** on v0.21.0+ (`config_defaults.py:68` at v2026.8.31), **1800** on
    /// every older supported host.
    ///
    /// Display-only; callers must never write the resolved value back.
    /// Unknown host version resolves to the older 1800 rather than 5: an
    /// unknown host is more likely to be an old one, and over-stating the
    /// wait is the benign direction (under-stating it would suggest turns are
    /// being rejected far sooner than they are).
    public func displayGatewayTurnLeaseTimeout(capabilities: HermesCapabilities) -> Int {
        if gatewayTurnLeaseTimeout > 0 { return gatewayTurnLeaseTimeout }
        return capabilities.isV021OrLater ? 5 : 1800
    }

    /// Effective `checkpoints.enabled` for display: the on-disk value when
    /// the key is present, otherwise the connected host's own default —
    /// **false** on v0.21.0+, **true** on every older supported host
    /// (v0.21 flipped auto-checkpointing to opt-in).
    ///
    /// Display-only; callers must never write the resolved value back. An
    /// unknown host version resolves to the older `true`, matching the
    /// `displayGatewayTurnLeaseTimeout` convention (unknown host is more
    /// likely to be an old one).
    public func displayCheckpointsEnabled(capabilities: HermesCapabilities) -> Bool {
        if let enabled = checkpoints.enabled { return enabled }
        return !capabilities.isV021OrLater
    }

    /// Effective `checkpoints.max_snapshots` for display: the on-disk value
    /// when set, otherwise the host default — **20** on v0.21.0+, **50** on
    /// older hosts. Display-only.
    public func displayCheckpointsMaxSnapshots(capabilities: HermesCapabilities) -> Int {
        if checkpoints.maxSnapshots > 0 { return checkpoints.maxSnapshots }
        return capabilities.isV021OrLater ? 20 : 50
    }

    /// Effective `delegation.max_iterations` for display: the on-disk value
    /// when set, otherwise the host default — **250** on v0.20.4+ (migration
    /// 36 raised it), **50** on older hosts. Display-only.
    public func displayDelegationMaxIterations(capabilities: HermesCapabilities) -> Int {
        if delegation.maxIterations > 0 { return delegation.maxIterations }
        return capabilities.isV0204OrLater ? 250 : 50
    }

    /// Effective `delegation.max_concurrent_children` for display: the
    /// on-disk value when set, otherwise the host default — **10** on
    /// v0.20.4+ (migration 37 raised it), **3** on older hosts. The row is
    /// itself gated on `isV0204OrLater`, so the pre-v0.20.4 branch only
    /// matters for non-UI readers. Display-only.
    public func displayDelegationMaxConcurrentChildren(capabilities: HermesCapabilities) -> Int {
        if delegation.maxConcurrentChildren > 0 { return delegation.maxConcurrentChildren }
        return capabilities.isV0204OrLater ? 10 : 3
    }

    /// Human-readable form of `displayMaxTurns(capabilities:)` — "Unlimited"
    /// for the no-ceiling case, the plain number otherwise.
    public func displayMaxTurnsText(capabilities: HermesCapabilities) -> String {
        let value = displayMaxTurns(capabilities: capabilities)
        return value == Self.maxTurnsUnlimited ? "Unlimited" : String(value)
    }
    public var terminalBackend: String
    public var memoryEnabled: Bool
    public var memoryCharLimit: Int
    public var userCharLimit: Int
    public var nudgeInterval: Int
    public var streaming: Bool
    public var showReasoning: Bool
    public var autoTTS: Bool
    public var silenceThreshold: Int
    public var reasoningEffort: String
    public var showCost: Bool
    public var approvalMode: String
    /// `browser.cloud_provider` — the browser automation provider Hermes
    /// dispatches to. Valid ids: `local`, `camofox`, and the plugin-provided
    /// `browser-use` / `browserbase` / `firecrawl`.
    ///
    /// Empty means the key is absent, which Hermes treats as auto-detect
    /// (Browser Use, then Browserbase, by credentials) rather than as
    /// `local`. A present-but-empty `cloud_provider: ""` also parses to `""`
    /// here but Hermes normalizes it to `local` — writers must therefore
    /// remove the key (`hermes config unset`) rather than write an empty
    /// scalar. Scarf never writes the empty form.
    ///
    /// NOTE: Scarf <= 2.18.1 read and wrote `browser.backend`, which has
    /// never been a Hermes key in any released version — see the v0.20
    /// compatibility note. Stale `browser.backend` values are deliberately
    /// NOT read back here; surfacing them would imply an inert key is live.
    public var browserCloudProvider: String
    public var memoryProvider: String
    public var dockerEnv: [String: String]
    public var commandAllowlist: [String]
    public var memoryProfile: String
    public var serviceTier: String
    public var gatewayNotifyInterval: Int
    public var forceIPv4: Bool
    public var contextEngine: String
    public var interimAssistantMessages: Bool
    public var honchoInitOnSessionStart: Bool

    // Phase 1 additions
    public var timezone: String
    public var userProfileEnabled: Bool
    public var toolUseEnforcement: String      // "auto" | "true" | "false" | comma list
    public var gatewayTimeout: Int
    /// `agent.cron_drain_timeout` (v0.20.4+) — cron-only floor under
    /// gateway stop/restart drain (seconds), distinct from
    /// `agent.restart_drain_timeout` (default 0). Default 30.
    public var cronDrainTimeout: Int
    /// `agent.gateway_turn_lease_timeout` (v0.20.4+) — max seconds an alias
    /// routing key waits for an active turn holding the same resolved
    /// session lease before Hermes rejects the inbound message (with a
    /// resend notice) rather than running it unserialized.
    ///
    /// `0` here is the **key-absent sentinel**, not a real value, because the
    /// upstream default changed at v0.21.0 (v2026.8.31): 1800 → 5 seconds,
    /// with the rationale that Telegram dispatches updates sequentially so an
    /// inline lease waiter also stalls unrelated topics. Baking either number
    /// in at parse time would show one host generation's default for the
    /// other. Non-positive values on disk mean "fall back to the built-in
    /// default" in Hermes too, so the sentinel and the on-disk semantics
    /// agree. Display surfaces resolve it via
    /// `displayGatewayTurnLeaseTimeout(capabilities:)`; nothing writes the
    /// resolved value back unless the user edits the stepper.
    public var gatewayTurnLeaseTimeout: Int
    public var approvalTimeout: Int
    public var fileReadMaxChars: Int
    public var cronWrapResponse: Bool
    /// v0.17 — `curator.consolidate`: the LLM skill-consolidation pass is
    /// opt-in (deterministic pruning stays on regardless). Absent key → `false`.
    public var curatorConsolidate: Bool
    /// v0.17 — `max_concurrent_sessions`: cap on simultaneously-active chat
    /// sessions. `0` = unbounded (matches an absent/None key in Hermes).
    public var maxConcurrentSessions: Int
    public var prefillMessagesFile: String
    public var skillsExternalDirs: [String]

    /// Per-platform toolset allowlists as written by `hermes setup tools`.
    /// Keyed by platform (`cli`, `slack`, …) to enabled toolset identifiers
    /// (`browser`, `messaging`, `nous-tools`, …). Hermes v0.10.0's Tool
    /// Gateway; enabling `nous-tools` here is how subscribers opt-in per
    /// platform. Scarf reads for display; edits go through Hermes CLI.
    public var platformToolsets: [String: [String]]

    // -- Hermes v0.12 additions ----------------------------------------
    // Defaults match the Hermes v0.12 defaults so that an absent key in
    // config.yaml looks identical to a freshly-installed v0.12 host.

    /// `prompt_caching.cache_ttl` — `"5m"` (default) or `"1h"`. Hermes
    /// v0.12 added the 1-hour ceiling for users with prompt-cache-heavy
    /// workloads (long agent loops with stable system prompts).
    public var cacheTTL: String
    /// `display.runtime_footer.enabled` — opt-in compact footer on the
    /// final reply of a turn (e.g. `model · 68% · ~/projects`). Off by
    /// default; useful for cost auditing and screen-recording demos.
    ///
    /// Read and written under the real key only. A long-dead fallback read of
    /// `agent.runtime_metadata_footer` was removed here: that key never
    /// existed in ANY supported Hermes version, so the fallback could only
    /// ever fire on a config some pre-v0.13 Scarf wrote and nothing has
    /// written since — while costing a wrong-key read on every parse.
    public var runtimeMetadataFooter: Bool
    /// `display.busy_ack_enabled` — GLOBAL "agent is working…" ack toggle.
    /// Hermes reads only this key (gateway/run.py); there is no working
    /// per-platform variant. Default `true` matches the server default.
    public var displayBusyAckEnabled: Bool
    /// `web.backend` — the shared Web Tools backend (all supported
    /// hosts). v0.13+ hosts treat it as the fallback the per-capability
    /// overrides below inherit from when unset.
    public var webToolsBackend: String
    /// v0.13+: `web.search_backend` — per-capability override for
    /// `web_search`. SearXNG is search-only and can land here. "" means
    /// inherit `web.backend`.
    public var webToolsSearchBackend: String
    /// v0.13+: `web.extract_backend` — per-capability override for
    /// `web_extract`. "" means inherit `web.backend`.
    public var webToolsExtractBackend: String

    // -- Hermes v0.13 additions ----------------------------------------
    // Per-platform Messaging Gateway settings dictionary keyed by Hermes
    // platform identifier (`slack`, `telegram`, `matrix`, `mattermost`,
    // `whatsapp`, `dingtalk`). Populated only for platforms
    // whose `gateway.platforms.<platform>.*` block exists in config.yaml —
    // platforms without an explicit block don't appear in the dictionary.
    // Editing surfaces (per-platform setup forms) read with a `?? .empty`
    // fallback so a missing entry behaves identically to an all-default
    // entry.
    public var gatewayPlatforms: [String: GatewayPlatformSettings]

    /// `image_gen.model` (v0.13+) — overrides the per-provider default
    /// image-gen model. Empty string means "let Hermes pick the
    /// provider default". Hermes v0.12 advertised this key but ignored
    /// it; Scarf's `AuxiliaryTab` only renders the picker when
    /// `HermesCapabilities.hasImageGenModel` is `true`.
    public var imageGenModel: String

    /// `openrouter.response_cache.enabled` (v0.13+) — when true, Hermes
    /// asks OpenRouter to cache responses for repeat prompts within a
    /// session. Off by default in Scarf's parser per WS-6 plan
    /// recommendation. UI gated on
    /// `HermesCapabilities.hasOpenRouterResponseCache`.
    // TODO(WS-6-Q1): the exact YAML key shape is provisional. Verify
    // against a v0.13 host's `hermes config check` output before
    // shipping (see WS-6-plan §Open Questions #1). Candidate alternative
    // shapes: `providers.openrouter.response_cache_enabled` or
    // `prompt_caching.openrouter.enabled`.
    public var openrouterResponseCacheEnabled: Bool

    /// `model.base_url` / `model.api_key` / `model.api_mode` — the
    /// local/custom-endpoint trio the model picker's Local tab manages
    /// (Ollama, LM Studio, vLLM, llama.cpp, custom). Read back so the
    /// picker round-trips an existing local setup into its fields.
    /// Empty string == key absent or explicitly cleared — the Hermes
    /// v0.17 reader treats both identically (see `LocalModelConfigPlan`).
    public var modelBaseURL: String
    public var modelAPIKey: String
    public var modelAPIMode: String
    /// `model.context_length` — the fourth local-managed key. The picker
    /// never writes it (clear-only; see `LocalModelConfigPlan`), but the
    /// current value is read back so a provider switch knows whether a
    /// stale CLI-set override exists to scrub. Kept as the raw scalar
    /// string ("" = absent; "0" = cleared; Hermes ignores non-positive).
    public var modelContextLength: String

    // Grouped blocks
    public var display: DisplaySettings
    public var terminal: TerminalSettings
    public var browser: BrowserSettings
    public var voice: VoiceSettings
    public var auxiliary: AuxiliarySettings
    public var security: SecuritySettings
    public var humanDelay: HumanDelaySettings
    public var compression: CompressionSettings
    public var checkpoints: CheckpointSettings
    public var logging: LoggingSettings
    public var delegation: DelegationSettings
    public var discord: DiscordSettings
    public var telegram: TelegramSettings
    public var slack: SlackSettings
    public var matrix: MatrixSettings
    public var mattermost: MattermostSettings
    public var whatsapp: WhatsAppSettings
    public var homeAssistant: HomeAssistantSettings
    /// Hermes v0.15 — ntfy (23rd platform). See `NtfySettings`.
    public var ntfy: NtfySettings
    /// Hermes v0.17 — WhatsApp Business Cloud API (25th platform). See
    /// `WhatsAppCloudSettings`.
    public var whatsappCloud: WhatsAppCloudSettings
    /// Hermes v0.15 — Signal group-only `require_mention`. See `SignalSettings`.
    public var signal: SignalSettings
    /// Hermes v0.15 — Bitwarden Secrets Manager bootstrap. See `BitwardenSettings`.
    public var bitwarden: BitwardenSettings

    // -- Hermes v0.20 additions ----------------------------------------
    /// `agent.reasoning_overrides` (v0.20+) — dict mapping a model-name
    /// spelling to a reasoning-effort level; takes precedence over the
    /// global `agent.reasoning_effort` when the active model matches
    /// (spelling-tolerant variant matching, hermes_constants.py
    /// `resolve_per_model_reasoning_effort`). `hermes config set` cannot
    /// write dicts, so writes go through `PowerSettingsWriter` direct-YAML.
    public var reasoningOverrides: [String: String]
    /// `model_catalog.excluded_providers` (v0.20+) — provider IDs hidden
    /// from model pickers and built-in resolution (inventory.py:100,
    /// case-insensitive on the Hermes side). List — direct-YAML writes.
    public var excludedProviders: [String]
    /// `approvals.smart_policy` (v0.20+, hermes_cli/config_defaults.py:2053
    /// — landed at commit bd1db5460a, first released v2026.7.30; the next
    /// numbered Hermes minor after that calendar tag is v0.20.0 =
    /// v2026.8.3, so this is gated `isV020OrLater` rather than v0.19).
    /// Free-form operator policy text appended to the smart-approval
    /// guardian's system prompt (trusted channel) when non-empty — e.g.
    /// "Always ESCALATE commands touching /etc". Empty means "no extra
    /// policy" (Hermes default).
    public var approvalSmartPolicy: String
    /// `secrets.command.*` (v0.20+, `agent/secret_sources/command.py`
    /// `config_schema()`, first released v2026.7.30). See
    /// `CommandSecretsSettings`. Not defaulted in `config_defaults.py`
    /// (dynamically-registered secret source), so Scarf's own struct
    /// default stands in for "absent block".
    public var commandSecrets: CommandSecretsSettings
    /// `telemetry.shared_metrics` (v0.20+, hermes_cli/config_defaults.py,
    /// Relay pipeline, first released v2026.7.30). See `TelemetrySettings`.
    public var telemetry: TelemetrySettings
    /// `database.*` — SQLite journal/WAL sizing pragmas (v0.20+,
    /// hermes_cli/config_defaults.py, first released v2026.7.30). See
    /// `DatabaseSettings`.
    public var database: DatabaseSettings

    /// `profile_routes` / `gateway.profile_routes` (v0.19+) — inbound
    /// gateway messages routed to different Hermes profiles by
    /// platform/guild/channel/thread. A list of maps, so `hermes config set`
    /// can't express it; writes go through `ProfileRoutesWriter` direct-YAML.
    /// See `HermesProfileRoutes` for the matching + ranking semantics.
    public var profileRoutes: HermesProfileRoutes

    /// `gateway.multiplex_profile_allowlist` (v0.20.4+, gateway/config.py) —
    /// top-level key inside the `gateway:` block, a sibling of
    /// `gateway.multiplex_profiles`. `nil` means the key is absent from
    /// config.yaml — historical serve-all behavior (no allowlist, every
    /// profile is reachable). An empty array `[]` means only the `"default"`
    /// profile is allowed. `"default"` is implicitly always allowed even
    /// when not listed. A malformed value (not a list, or a list containing
    /// invalid entries) fails safe upstream to serving only `"default"`, so
    /// Scarf's parser normalizes that case to `[]` rather than `nil`.
    public var multiplexProfileAllowlist: [String]?

    public init(
        model: String,
        provider: String,
        maxTurns: Int,
        personality: String,
        terminalBackend: String,
        memoryEnabled: Bool,
        memoryCharLimit: Int,
        userCharLimit: Int,
        nudgeInterval: Int,
        streaming: Bool,
        showReasoning: Bool,
        autoTTS: Bool,
        silenceThreshold: Int,
        reasoningEffort: String,
        showCost: Bool,
        approvalMode: String,
        browserCloudProvider: String,
        memoryProvider: String,
        dockerEnv: [String: String],
        commandAllowlist: [String],
        memoryProfile: String,
        serviceTier: String,
        gatewayNotifyInterval: Int,
        forceIPv4: Bool,
        contextEngine: String,
        interimAssistantMessages: Bool,
        honchoInitOnSessionStart: Bool,
        timezone: String,
        userProfileEnabled: Bool,
        toolUseEnforcement: String,
        gatewayTimeout: Int,
        cronDrainTimeout: Int = 30,
        gatewayTurnLeaseTimeout: Int = 0,
        approvalTimeout: Int,
        fileReadMaxChars: Int,
        cronWrapResponse: Bool,
        curatorConsolidate: Bool = false,
        maxConcurrentSessions: Int = 0,
        prefillMessagesFile: String,
        skillsExternalDirs: [String],
        platformToolsets: [String: [String]],
        display: DisplaySettings,
        terminal: TerminalSettings,
        browser: BrowserSettings,
        voice: VoiceSettings,
        auxiliary: AuxiliarySettings,
        security: SecuritySettings,
        humanDelay: HumanDelaySettings,
        compression: CompressionSettings,
        checkpoints: CheckpointSettings,
        logging: LoggingSettings,
        delegation: DelegationSettings,
        discord: DiscordSettings,
        telegram: TelegramSettings,
        slack: SlackSettings,
        matrix: MatrixSettings,
        mattermost: MattermostSettings,
        whatsapp: WhatsAppSettings,
        homeAssistant: HomeAssistantSettings,
        cacheTTL: String = "5m",
        runtimeMetadataFooter: Bool = false,
        displayBusyAckEnabled: Bool = true,
        gatewayPlatforms: [String: GatewayPlatformSettings] = [:],
        imageGenModel: String = "",
        openrouterResponseCacheEnabled: Bool = false,
        webToolsBackend: String = "",
        webToolsSearchBackend: String = "",
        webToolsExtractBackend: String = "",
        ntfy: NtfySettings = .empty,
        whatsappCloud: WhatsAppCloudSettings = .empty,
        signal: SignalSettings = .empty,
        bitwarden: BitwardenSettings = .empty,
        modelBaseURL: String = "",
        modelAPIKey: String = "",
        modelAPIMode: String = "",
        modelContextLength: String = "",
        reasoningOverrides: [String: String] = [:],
        excludedProviders: [String] = [],
        approvalSmartPolicy: String = "",
        commandSecrets: CommandSecretsSettings = .empty,
        telemetry: TelemetrySettings = .empty,
        database: DatabaseSettings = .empty,
        profileRoutes: HermesProfileRoutes = .empty,
        multiplexProfileAllowlist: [String]? = nil
    ) {
        self.cacheTTL = cacheTTL
        self.runtimeMetadataFooter = runtimeMetadataFooter
        self.displayBusyAckEnabled = displayBusyAckEnabled
        self.gatewayPlatforms = gatewayPlatforms
        self.imageGenModel = imageGenModel
        self.openrouterResponseCacheEnabled = openrouterResponseCacheEnabled
        self.webToolsBackend = webToolsBackend
        self.webToolsSearchBackend = webToolsSearchBackend
        self.webToolsExtractBackend = webToolsExtractBackend
        self.model = model
        self.provider = provider
        self.maxTurns = maxTurns
        self.personality = personality
        self.terminalBackend = terminalBackend
        self.memoryEnabled = memoryEnabled
        self.memoryCharLimit = memoryCharLimit
        self.userCharLimit = userCharLimit
        self.nudgeInterval = nudgeInterval
        self.streaming = streaming
        self.showReasoning = showReasoning
        self.autoTTS = autoTTS
        self.silenceThreshold = silenceThreshold
        self.reasoningEffort = reasoningEffort
        self.showCost = showCost
        self.approvalMode = approvalMode
        self.browserCloudProvider = browserCloudProvider
        self.memoryProvider = memoryProvider
        self.dockerEnv = dockerEnv
        self.commandAllowlist = commandAllowlist
        self.memoryProfile = memoryProfile
        self.serviceTier = serviceTier
        self.gatewayNotifyInterval = gatewayNotifyInterval
        self.forceIPv4 = forceIPv4
        self.contextEngine = contextEngine
        self.interimAssistantMessages = interimAssistantMessages
        self.honchoInitOnSessionStart = honchoInitOnSessionStart
        self.timezone = timezone
        self.userProfileEnabled = userProfileEnabled
        self.toolUseEnforcement = toolUseEnforcement
        self.gatewayTimeout = gatewayTimeout
        self.cronDrainTimeout = cronDrainTimeout
        self.gatewayTurnLeaseTimeout = gatewayTurnLeaseTimeout
        self.approvalTimeout = approvalTimeout
        self.fileReadMaxChars = fileReadMaxChars
        self.cronWrapResponse = cronWrapResponse
        self.curatorConsolidate = curatorConsolidate
        self.maxConcurrentSessions = maxConcurrentSessions
        self.prefillMessagesFile = prefillMessagesFile
        self.skillsExternalDirs = skillsExternalDirs
        self.platformToolsets = platformToolsets
        self.display = display
        self.terminal = terminal
        self.browser = browser
        self.voice = voice
        self.auxiliary = auxiliary
        self.security = security
        self.humanDelay = humanDelay
        self.compression = compression
        self.checkpoints = checkpoints
        self.logging = logging
        self.delegation = delegation
        self.discord = discord
        self.telegram = telegram
        self.slack = slack
        self.matrix = matrix
        self.mattermost = mattermost
        self.whatsapp = whatsapp
        self.homeAssistant = homeAssistant
        self.ntfy = ntfy
        self.whatsappCloud = whatsappCloud
        self.signal = signal
        self.bitwarden = bitwarden
        self.modelBaseURL = modelBaseURL
        self.modelAPIKey = modelAPIKey
        self.modelAPIMode = modelAPIMode
        self.modelContextLength = modelContextLength
        self.reasoningOverrides = reasoningOverrides
        self.excludedProviders = excludedProviders
        self.approvalSmartPolicy = approvalSmartPolicy
        self.commandSecrets = commandSecrets
        self.telemetry = telemetry
        self.database = database
        self.profileRoutes = profileRoutes
        self.multiplexProfileAllowlist = multiplexProfileAllowlist
    }
    public nonisolated static let empty = HermesConfig(
        model: "unknown",
        provider: "unknown",
        maxTurns: 0,
        personality: "default",
        terminalBackend: "local",
        memoryEnabled: false,
        memoryCharLimit: 0,
        userCharLimit: 0,
        nudgeInterval: 0,
        streaming: true,
        showReasoning: false,
        autoTTS: true,
        silenceThreshold: 200,
        reasoningEffort: "medium",
        showCost: false,
        approvalMode: "manual",
        browserCloudProvider: "",
        memoryProvider: "",
        dockerEnv: [:],
        commandAllowlist: [],
        memoryProfile: "",
        serviceTier: "normal",
        gatewayNotifyInterval: 600,
        forceIPv4: false,
        contextEngine: "compressor",
        interimAssistantMessages: true,
        honchoInitOnSessionStart: false,
        timezone: "",
        userProfileEnabled: true,
        toolUseEnforcement: "auto",
        gatewayTimeout: 1800,
        approvalTimeout: 60,
        fileReadMaxChars: 100_000,
        cronWrapResponse: true,
        prefillMessagesFile: "",
        skillsExternalDirs: [],
        platformToolsets: [:],
        display: .empty,
        terminal: .empty,
        browser: .empty,
        voice: .empty,
        auxiliary: .empty,
        security: .empty,
        humanDelay: .empty,
        compression: .empty,
        checkpoints: .empty,
        logging: .empty,
        delegation: .empty,
        discord: .empty,
        telegram: .empty,
        slack: .empty,
        matrix: .empty,
        mattermost: .empty,
        whatsapp: .empty,
        homeAssistant: .empty
    )
}

// Hand-written `init(from:)` so Swift 6 doesn't synthesize a
// MainActor-isolated Decodable conformance (which would fail to be used from
// `HermesFileService.loadGatewayState()`, a nonisolated method).
public struct GatewayState: Sendable, Codable {
    public nonisolated let pid: Int?
    public nonisolated let kind: String?
    public nonisolated let gatewayState: String?
    public nonisolated let exitReason: String?
    public nonisolated let platforms: [String: PlatformState]?
    public nonisolated let updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case pid, kind
        case gatewayState = "gateway_state"
        case exitReason = "exit_reason"
        case platforms
        case updatedAt = "updated_at"
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pid          = try c.decodeIfPresent(Int.self, forKey: .pid)
        self.kind         = try c.decodeIfPresent(String.self, forKey: .kind)
        self.gatewayState = try c.decodeIfPresent(String.self, forKey: .gatewayState)
        self.exitReason   = try c.decodeIfPresent(String.self, forKey: .exitReason)
        self.platforms    = try c.decodeIfPresent([String: PlatformState].self, forKey: .platforms)
        self.updatedAt    = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(gatewayState, forKey: .gatewayState)
        try c.encodeIfPresent(exitReason, forKey: .exitReason)
        try c.encodeIfPresent(platforms, forKey: .platforms)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    public nonisolated var isRunning: Bool {
        gatewayState == "running"
    }

    public nonisolated var statusText: String {
        gatewayState ?? "unknown"
    }
}

public struct PlatformState: Sendable, Codable {
    public nonisolated let connected: Bool?
    public nonisolated let error: String?

    public enum CodingKeys: String, CodingKey { case connected, error }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.connected = try c.decodeIfPresent(Bool.self, forKey: .connected)
        self.error     = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(connected, forKey: .connected)
        try c.encodeIfPresent(error, forKey: .error)
    }
}
