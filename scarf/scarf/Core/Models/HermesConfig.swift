import Foundation

/// Settings for one of hermes's auxiliary model tasks (vision, compression, approvals, etc.).
/// Every auxiliary task follows the same provider/model/base_url/api_key/timeout pattern.
struct AuxiliaryModel: Sendable, Equatable {
    var provider: String
    var model: String
    var baseURL: String
    var apiKey: String
    var timeout: Int

    static let empty = AuxiliaryModel(provider: "auto", model: "", baseURL: "", apiKey: "", timeout: 30)
}

/// Group of display-related settings mirroring the `display:` block in config.yaml.
struct DisplaySettings: Sendable, Equatable {
    var skin: String
    var compact: Bool
    var resumeDisplay: String           // "full" | "minimal"
    var bellOnComplete: Bool
    var inlineDiffs: Bool
    var toolProgressCommand: Bool
    var toolPreviewLength: Int
    var busyInputMode: String           // e.g. "interrupt"

    static let empty = DisplaySettings(
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
struct TerminalSettings: Sendable, Equatable {
    var cwd: String
    var timeout: Int
    var envPassthrough: [String]
    var persistentShell: Bool
    var dockerImage: String
    var dockerMountCwdToWorkspace: Bool
    var dockerForwardEnv: [String]
    var dockerVolumes: [String]
    var containerCPU: Int               // 0 = unlimited
    var containerMemory: Int            // MB, 0 = unlimited
    var containerDisk: Int              // MB, 0 = unlimited
    var containerPersistent: Bool
    var modalImage: String
    var modalMode: String               // "auto" | other
    var daytonaImage: String
    var singularityImage: String

    static let empty = TerminalSettings(
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
struct BrowserSettings: Sendable, Equatable {
    var inactivityTimeout: Int
    var commandTimeout: Int
    var recordSessions: Bool
    var allowPrivateURLs: Bool
    var camofoxManagedPersistence: Bool

    static let empty = BrowserSettings(
        inactivityTimeout: 120,
        commandTimeout: 30,
        recordSessions: false,
        allowPrivateURLs: false,
        camofoxManagedPersistence: false
    )
}

/// Voice push-to-talk plus TTS/STT provider settings.
struct VoiceSettings: Sendable, Equatable {
    var recordKey: String
    var maxRecordingSeconds: Int
    var silenceDuration: Double

    // TTS
    var ttsProvider: String
    var ttsEdgeVoice: String
    var ttsElevenLabsVoiceID: String
    var ttsElevenLabsModelID: String
    var ttsOpenAIModel: String
    var ttsOpenAIVoice: String
    var ttsNeuTTSModel: String
    var ttsNeuTTSDevice: String

    // STT
    var sttEnabled: Bool
    var sttProvider: String
    var sttLocalModel: String
    var sttLocalLanguage: String
    var sttOpenAIModel: String
    var sttMistralModel: String

    static let empty = VoiceSettings(
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
struct AuxiliarySettings: Sendable, Equatable {
    var vision: AuxiliaryModel
    var webExtract: AuxiliaryModel
    var compression: AuxiliaryModel
    var sessionSearch: AuxiliaryModel
    var skillsHub: AuxiliaryModel
    var approval: AuxiliaryModel
    var mcp: AuxiliaryModel
    var flushMemories: AuxiliaryModel

    static let empty = AuxiliarySettings(
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
struct SecuritySettings: Sendable, Equatable {
    var redactSecrets: Bool
    var redactPII: Bool                 // from privacy.redact_pii
    var tirithEnabled: Bool
    var tirithPath: String
    var tirithTimeout: Int
    var tirithFailOpen: Bool
    var blocklistEnabled: Bool
    var blocklistDomains: [String]

    static let empty = SecuritySettings(
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
struct HumanDelaySettings: Sendable, Equatable {
    var mode: String                    // "off" | "natural" | "custom"
    var minMS: Int
    var maxMS: Int

    static let empty = HumanDelaySettings(mode: "off", minMS: 800, maxMS: 2500)
}

/// Compression / context routing.
struct CompressionSettings: Sendable, Equatable {
    var enabled: Bool
    var threshold: Double
    var targetRatio: Double
    var protectLastN: Int

    static let empty = CompressionSettings(enabled: true, threshold: 0.5, targetRatio: 0.2, protectLastN: 20)
}

struct CheckpointSettings: Sendable, Equatable {
    var enabled: Bool
    var maxSnapshots: Int

    static let empty = CheckpointSettings(enabled: true, maxSnapshots: 50)
}

struct LoggingSettings: Sendable, Equatable {
    var level: String                   // DEBUG | INFO | WARNING | ERROR
    var maxSizeMB: Int
    var backupCount: Int

    static let empty = LoggingSettings(level: "INFO", maxSizeMB: 5, backupCount: 3)
}

struct DelegationSettings: Sendable, Equatable {
    var model: String
    var provider: String
    var baseURL: String
    var apiKey: String
    var maxIterations: Int

    static let empty = DelegationSettings(model: "", provider: "", baseURL: "", apiKey: "", maxIterations: 50)
}

/// Discord-specific platform settings (`discord.*`). Other platforms currently have thinner schemas.
struct DiscordSettings: Sendable, Equatable {
    var requireMention: Bool
    var freeResponseChannels: String
    var autoThread: Bool
    var reactions: Bool

    static let empty = DiscordSettings(requireMention: true, freeResponseChannels: "", autoThread: true, reactions: true)
}

/// Telegram settings under `telegram.*` in config.yaml. Most Telegram tuning is
/// done via environment variables (`TELEGRAM_*`) — this is the subset that lives
/// in the YAML.
struct TelegramSettings: Sendable, Equatable {
    var requireMention: Bool
    var reactions: Bool

    static let empty = TelegramSettings(requireMention: true, reactions: false)
}

/// Slack settings under `platforms.slack.*` (and a couple of top-level keys).
struct SlackSettings: Sendable, Equatable {
    var replyToMode: String         // "off" | "first" | "all"
    var requireMention: Bool
    var replyInThread: Bool
    var replyBroadcast: Bool

    static let empty = SlackSettings(replyToMode: "first", requireMention: true, replyInThread: true, replyBroadcast: false)
}

/// Matrix settings under `matrix.*`.
struct MatrixSettings: Sendable, Equatable {
    var requireMention: Bool
    var autoThread: Bool
    var dmMentionThreads: Bool

    static let empty = MatrixSettings(requireMention: true, autoThread: true, dmMentionThreads: false)
}

/// Mattermost settings. Mattermost is mostly driven by env vars; config.yaml
/// currently just exposes `group_sessions_per_user` at the top level, but we
/// reserve this struct for future expansion so the form has a stable type.
struct MattermostSettings: Sendable, Equatable {
    var requireMention: Bool
    var replyMode: String           // "thread" | "off"

    static let empty = MattermostSettings(requireMention: true, replyMode: "off")
}

/// WhatsApp settings under `whatsapp.*`.
struct WhatsAppSettings: Sendable, Equatable {
    var unauthorizedDMBehavior: String  // "pair" | "ignore"
    var replyPrefix: String

    static let empty = WhatsAppSettings(unauthorizedDMBehavior: "pair", replyPrefix: "")
}

/// Home Assistant filters under `platforms.homeassistant.extra`. Hermes ignores
/// every state change by default; users must opt-in via at least one filter.
struct HomeAssistantSettings: Sendable, Equatable {
    var watchDomains: [String]
    var watchEntities: [String]
    var watchAll: Bool
    var ignoreEntities: [String]
    var cooldownSeconds: Int

    static let empty = HomeAssistantSettings(watchDomains: [], watchEntities: [], watchAll: false, ignoreEntities: [], cooldownSeconds: 30)
}

// MARK: - Root Config

struct HermesConfig: Sendable {
    // Original fields — preserved for zero breakage with existing call sites.
    var model: String
    var provider: String
    var maxTurns: Int
    var personality: String
    var terminalBackend: String
    var memoryEnabled: Bool
    var memoryCharLimit: Int
    var userCharLimit: Int
    var nudgeInterval: Int
    var streaming: Bool
    var showReasoning: Bool
    var verbose: Bool
    var autoTTS: Bool
    var silenceThreshold: Int
    var reasoningEffort: String
    var showCost: Bool
    var approvalMode: String
    var browserBackend: String
    var memoryProvider: String
    var dockerEnv: [String: String]
    var commandAllowlist: [String]
    var memoryProfile: String
    var serviceTier: String
    var gatewayNotifyInterval: Int
    var forceIPv4: Bool
    var contextEngine: String
    var interimAssistantMessages: Bool
    var honchoInitOnSessionStart: Bool

    // Phase 1 additions
    var timezone: String
    var userProfileEnabled: Bool
    var toolUseEnforcement: String      // "auto" | "true" | "false" | comma list
    var gatewayTimeout: Int
    var approvalTimeout: Int
    var fileReadMaxChars: Int
    var cronWrapResponse: Bool
    var prefillMessagesFile: String
    var skillsExternalDirs: [String]

    // Grouped blocks
    var display: DisplaySettings
    var terminal: TerminalSettings
    var browser: BrowserSettings
    var voice: VoiceSettings
    var auxiliary: AuxiliarySettings
    var security: SecuritySettings
    var humanDelay: HumanDelaySettings
    var compression: CompressionSettings
    var checkpoints: CheckpointSettings
    var logging: LoggingSettings
    var delegation: DelegationSettings
    var discord: DiscordSettings
    var telegram: TelegramSettings
    var slack: SlackSettings
    var matrix: MatrixSettings
    var mattermost: MattermostSettings
    var whatsapp: WhatsAppSettings
    var homeAssistant: HomeAssistantSettings

    static let empty = HermesConfig(
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

struct GatewayState: Sendable, Codable {
    let pid: Int?
    let kind: String?
    let gatewayState: String?
    let exitReason: String?
    let platforms: [String: PlatformState]?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case pid, kind
        case gatewayState = "gateway_state"
        case exitReason = "exit_reason"
        case platforms
        case updatedAt = "updated_at"
    }

    var isRunning: Bool {
        gatewayState == "running"
    }

    var statusText: String {
        gatewayState ?? "unknown"
    }
}

struct PlatformState: Sendable, Codable {
    let connected: Bool?
    let error: String?
}
