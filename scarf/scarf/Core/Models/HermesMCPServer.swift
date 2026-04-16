import Foundation

enum MCPTransport: String, Sendable, Equatable, CaseIterable, Identifiable {
    case stdio
    case http

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stdio: return "Local (stdio)"
        case .http: return "Remote (HTTP)"
        }
    }
}

struct HermesMCPServer: Identifiable, Sendable, Equatable {
    let name: String
    let transport: MCPTransport
    let command: String?
    let args: [String]
    let url: String?
    let auth: String?
    let env: [String: String]
    let headers: [String: String]
    let timeout: Int?
    let connectTimeout: Int?
    let enabled: Bool
    let toolsInclude: [String]
    let toolsExclude: [String]
    let resourcesEnabled: Bool
    let promptsEnabled: Bool
    let hasOAuthToken: Bool

    var id: String { name }

    var summary: String {
        switch transport {
        case .stdio:
            let argString = args.isEmpty ? "" : " " + args.joined(separator: " ")
            return (command ?? "") + argString
        case .http:
            return url ?? ""
        }
    }
}

struct MCPTestResult: Sendable, Equatable {
    let serverName: String
    let succeeded: Bool
    let output: String
    let tools: [String]
    let elapsed: TimeInterval
}
