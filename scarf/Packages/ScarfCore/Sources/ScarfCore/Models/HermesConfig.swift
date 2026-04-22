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


    public init(
        skin: String,
        compact: Bool,
        resumeDisplay: String,
        bellOnComplete: Bool,
        inlineDiffs: Bool,
        toolProgressCommand: Bool,
        toolPreviewLength: Int,
        busyInputMode: String
    ) {
        self.skin = skin
        self.compact = compact
        self.resumeDisplay = resumeDisplay
        self.bellOnComplete = bellOnComplete
        self.inlineDiffs = inlineDiffs
        self.toolProgressCommand = toolProgressCommand
        self.toolPreviewLength = toolPreviewLength
        self.busyInputMode = busyInputMode
    }
    public nonisolated static let empty = DisplaySettings(
        skin: "default",
        compact: false,
        resumeDisplay: "full",
        bellOnComplete: false,
        inlineDiffs: true,
        toolProgressCommand: false,
        toolPreviewLength: 0,
        busyInputMode: "interrupt"
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
        sttMistralModel: String
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
        sttMistralModel: "voxtral-mini-latest"
    )
}

/// Eight sub-models that share the same provider/model/base_url/api_key/timeout shape.
public struct AuxiliarySettings: Sendable, Equatable {
    public var vision: AuxiliaryModel
    public var webExtract: AuxiliaryModel
    public var compression: AuxiliaryModel
    public var sessionSearch: AuxiliaryModel
    public var skillsHub: AuxiliaryModel
    public var approval: AuxiliaryModel
    public var mcp: AuxiliaryModel
    public var flushMemories: AuxiliaryModel


    public init(
        vision: AuxiliaryModel,
        webExtract: AuxiliaryModel,
        compression: AuxiliaryModel,
        sessionSearch: AuxiliaryModel,
        skillsHub: AuxiliaryModel,
        approval: AuxiliaryModel,
        mcp: AuxiliaryModel,
        flushMemories: AuxiliaryModel
    ) {
        self.vision = vision
        self.webExtract = webExtract
        self.compression = compression
        self.sessionSearch = sessionSearch
        self.skillsHub = skillsHub
        self.approval = approval
        self.mcp = mcp
        self.flushMemories = flushMemories
    }
    public nonisolated static let empty = AuxiliarySettings(
        vision: .empty,
        webExtract: .empty,
        compression: .empty,
        sessionSearch: .empty,
        skillsHub: .empty,
        approval: .empty,
        mcp: .empty,
        flushMemories: .empty
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


    public init(
        requireMention: Bool,
        freeResponseChannels: String,
        autoThread: Bool,
        reactions: Bool
    ) {
        self.requireMention = requireMention
        self.freeResponseChannels = freeResponseChannels
        self.autoThread = autoThread
        self.reactions = reactions
    }
    public nonisolated static let empty = DiscordSettings(requireMention: true, freeResponseChannels: "", autoThread: true, reactions: true)
}

/// Telegram settings under `telegram.*` in config.yaml. Most Telegram tuning is
/// done via environment variables (`TELEGRAM_*`) — this is the subset that lives
/// in the YAML.
public struct TelegramSettings: Sendable, Equatable {
    public var requireMention: Bool
    public var reactions: Bool


    public init(
        requireMention: Bool,
        reactions: Bool
    ) {
        self.requireMention = requireMention
        self.reactions = reactions
    }
    public nonisolated static let empty = TelegramSettings(requireMention: true, reactions: false)
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
    public var prefillMessagesFile: String
    public var skillsExternalDirs: [String]

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
        prefillMessagesFile: String,
        skillsExternalDirs: [String],
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
        homeAssistant: HomeAssistantSettings
    ) {
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
        self.prefillMessagesFile = prefillMessagesFile
        self.skillsExternalDirs = skillsExternalDirs
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
