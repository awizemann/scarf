import Foundation

struct HermesConfig: Sendable {
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
        memoryProvider: ""
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
