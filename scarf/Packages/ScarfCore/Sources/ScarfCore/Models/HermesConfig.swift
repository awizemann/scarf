import Foundation

/// Settings for one of hermes's auxiliary model tasks (vision, compression, approvals, etc.).
/// Every auxiliary task follows the same provider/model/base_url/api_key/timeout pattern.
public struct AuxiliaryModel: Sendable, Equatable {
    public var provider: String
    public var model: String
    public var baseURL: String
    public var apiKey: String
    public var timeout: Int


    public init(
        provider: String,
        model: String,
        baseURL: String,
        apiKey: String,
        timeout: Int
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
    }
    public nonisolated static let empty = AuxiliaryModel(provider: "auto", model: "", baseURL: "", apiKey: "", timeout: 30)
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
    /// xAI TTS model identifier. v0.13+. Mirrors the elevenlabs shape.
    public var ttsXAIModel: String
    /// xAI TTS `auto_speech_tags`. v0.15+ — when true, xAI auto-inserts
    /// speech-control tags (emotion / emphasis) into synthesized output.
    /// Config key `tts.xai.auto_speech_tags`, default `false`. Pre-v0.15
    /// hosts ignore the key; Scarf hides the toggle when
    /// `HermesCapabilities.hasXAITTSAutoSpeechTags` is false.
    public var ttsXAIAutoSpeechTags: Bool

    // STT
    public var sttEnabled: Bool
    public var sttProvider: String
    public var sttLocalModel: String
    public var sttLocalLanguage: String
    public var sttOpenAIModel: String
    public var sttMistralModel: String


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
        ttsXAIModel: String = "",
        ttsXAIAutoSpeechTags: Bool = false
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
        self.ttsXAIModel = ttsXAIModel
        self.ttsXAIAutoSpeechTags = ttsXAIAutoSpeechTags
        self.sttEnabled = sttEnabled
        self.sttProvider = sttProvider
        self.sttLocalModel = sttLocalModel
        self.sttLocalLanguage = sttLocalLanguage
        self.sttOpenAIModel = sttOpenAIModel
        self.sttMistralModel = sttMistralModel
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
        sttProvider: "local",
        sttLocalModel: "base",
        sttLocalLanguage: "",
        sttOpenAIModel: "whisper-1",
        sttMistralModel: "voxtral-mini-latest",
        ttsXAIVoiceID: "",
        ttsXAIModel: "",
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


    public init(
        vision: AuxiliaryModel,
        webExtract: AuxiliaryModel,
        compression: AuxiliaryModel,
        sessionSearch: AuxiliaryModel,
        skillsHub: AuxiliaryModel,
        approval: AuxiliaryModel,
        mcp: AuxiliaryModel,
        flushMemories: AuxiliaryModel,
        curator: AuxiliaryModel
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
        curator: .empty
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


    public init(
        enabled: Bool,
        threshold: Double,
        targetRatio: Double,
        protectLastN: Int
    ) {
        self.enabled = enabled
        self.threshold = threshold
        self.targetRatio = targetRatio
        self.protectLastN = protectLastN
    }
    public nonisolated static let empty = CompressionSettings(enabled: true, threshold: 0.5, targetRatio: 0.2, protectLastN: 20)
}

public struct CheckpointSettings: Sendable, Equatable {
    public var enabled: Bool
    public var maxSnapshots: Int


    public init(
        enabled: Bool,
        maxSnapshots: Int
    ) {
        self.enabled = enabled
        self.maxSnapshots = maxSnapshots
    }
    public nonisolated static let empty = CheckpointSettings(enabled: true, maxSnapshots: 50)
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
    public var maxIterations: Int


    public init(
        model: String,
        provider: String,
        baseURL: String,
        apiKey: String,
        maxIterations: Int
    ) {
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxIterations = maxIterations
    }
    public nonisolated static let empty = DelegationSettings(model: "", provider: "", baseURL: "", apiKey: "", maxIterations: 50)
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


    public init(
        enabled: Bool = false,
        accessTokenEnv: String = "BWS_ACCESS_TOKEN",
        projectID: String = "",
        overrideExisting: Bool = false,
        serverURL: String = "",
        cacheTTLSeconds: Int = 300,
        autoInstall: Bool = true
    ) {
        self.enabled = enabled
        self.accessTokenEnv = accessTokenEnv
        self.projectID = projectID
        self.overrideExisting = overrideExisting
        self.serverURL = serverURL
        self.cacheTTLSeconds = cacheTTLSeconds
        self.autoInstall = autoInstall
    }
    public nonisolated static let empty = BitwardenSettings(
        enabled: false,
        accessTokenEnv: "BWS_ACCESS_TOKEN",
        projectID: "",
        overrideExisting: false,
        serverURL: "",
        cacheTTLSeconds: 300,
        autoInstall: true
    )
}

// MARK: - Root Config

public struct HermesConfig: Sendable {
    // Original fields — preserved for zero breakage with existing call sites.
    public var model: String
    public var provider: String
    public var maxTurns: Int
    public var personality: String
    public var terminalBackend: String
    public var memoryEnabled: Bool
    public var memoryCharLimit: Int
    public var userCharLimit: Int
    public var nudgeInterval: Int
    public var streaming: Bool
    public var showReasoning: Bool
    public var verbose: Bool
    public var autoTTS: Bool
    public var silenceThreshold: Int
    public var reasoningEffort: String
    public var showCost: Bool
    public var approvalMode: String
    public var browserBackend: String
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
    /// `redaction.enabled` — flipped from `true` to `false` as the
    /// upstream default in v0.12 because the substitution corrupted
    /// patches and API payloads. Surface a toggle so users with hard
    /// redaction requirements can opt back in.
    public var redactionEnabled: Bool
    /// `agent.runtime_metadata_footer` — opt-in compact footer on each
    /// final reply (provider/model/cost/turn count). Off by default;
    /// useful for cost auditing and screen-recording demos.
    public var runtimeMetadataFooter: Bool
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
    // `whatsapp`, `dingtalk`, `google-chat`). Populated only for platforms
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
        verbose: Bool,
        autoTTS: Bool,
        silenceThreshold: Int,
        reasoningEffort: String,
        showCost: Bool,
        approvalMode: String,
        browserBackend: String,
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
        redactionEnabled: Bool = false,
        runtimeMetadataFooter: Bool = false,
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
        modelAPIMode: String = ""
    ) {
        self.cacheTTL = cacheTTL
        self.redactionEnabled = redactionEnabled
        self.runtimeMetadataFooter = runtimeMetadataFooter
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
        self.verbose = verbose
        self.autoTTS = autoTTS
        self.silenceThreshold = silenceThreshold
        self.reasoningEffort = reasoningEffort
        self.showCost = showCost
        self.approvalMode = approvalMode
        self.browserBackend = browserBackend
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
        verbose: false,
        autoTTS: true,
        silenceThreshold: 200,
        reasoningEffort: "medium",
        showCost: false,
        approvalMode: "manual",
        browserBackend: "",
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
