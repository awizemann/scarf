import Foundation

public protocol GatewayScarfTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionGatewayScarfTransport: GatewayScarfTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayScarfClientError.nonHTTPResponse
        }
        return (data, http)
    }
}

public struct GatewayScarfConnectionConfig: Codable, Sendable, Equatable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(baseURLString: String, token: String) throws {
        let trimmedBase = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase), url.scheme != nil, url.host != nil else {
            throw GatewayScarfClientError.invalidURL(baseURLString)
        }
        self.init(baseURL: url, token: token)
    }

    public func makeClient(transport: any GatewayScarfTransport = URLSessionGatewayScarfTransport()) -> GatewayScarfClient {
        GatewayScarfClient(baseURL: baseURL, token: token, transport: transport)
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL = defaultConfigFileURL()
    ) throws -> GatewayScarfConnectionConfig? {
        if let base = environment["GATEWAY_SCARF_BASE_URL"] ?? environment["GATEWAY_SCARF_INTEGRATION_BASE_URL"],
           let token = environment["GATEWAY_SCARF_TOKEN"] ?? environment["GATEWAY_SCARF_INTEGRATION_TOKEN"],
           !base.isEmpty,
           !token.isEmpty {
            return try GatewayScarfConnectionConfig(baseURLString: base, token: token)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(GatewayScarfConnectionConfig.self, from: data)
    }

    public static func defaultConfigFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("scarf/gateway-scarf.json")
    }

    public func save(to fileURL: URL = defaultConfigFileURL()) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public struct GatewayScarfClient: Sendable {
    public let baseURL: URL
    public let token: String
    private let transport: any GatewayScarfTransport
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        baseURL: URL,
        token: String,
        transport: any GatewayScarfTransport = URLSessionGatewayScarfTransport()
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func health() async throws -> GatewayScarfHealthSnapshot {
        try await get("/v1/health")
    }

    public func capabilities() async throws -> GatewayScarfCapabilitiesSnapshot {
        try await get("/v1/capabilities")
    }

    public func cronJobs() async throws -> [HermesCronJob] {
        let response: GatewayScarfCronJobsResponse = try await get("/v1/cron/jobs")
        return response.jobs
    }

    public func skills() async throws -> [GatewayScarfSkill] {
        let response: GatewayScarfSkillsResponse = try await get("/v1/skills")
        return response.skills
    }

    public func logs(source: String = "gateway", lines: Int = 200) async throws -> GatewayScarfLogTail {
        try await get("/v1/logs?source=\(Self.percentEncode(source))&lines=\(lines)")
    }

    public func createSession(title: String? = nil, projectDirectory: String? = nil) async throws -> GatewayScarfSession {
        let body = GatewayScarfCreateSessionRequest(projectDirectory: projectDirectory, title: title)
        return try await post("/v1/sessions", body: body, expectedStatus: 201)
    }

    public func sendMessage(sessionId: String, text: String) async throws -> GatewayScarfMessageResponse {
        let body = GatewayScarfMessageRequest(text: text)
        return try await post("/v1/sessions/\(Self.percentEncode(sessionId))/messages", body: body)
    }

    public func cancelSession(sessionId: String) async throws -> GatewayScarfActionResponse {
        try await post("/v1/sessions/\(Self.percentEncode(sessionId))/cancel", body: EmptyBody(), expectedStatus: 202)
    }

    public func closeSession(sessionId: String) async throws -> GatewayScarfActionResponse {
        let request = try makeRequest(path: "/v1/sessions/\(Self.percentEncode(sessionId))", method: "DELETE")
        let (data, response) = try await transport.data(for: request)
        return try decode(GatewayScarfActionResponse.self, from: data, response: response, expectedStatus: 200)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = try makeRequest(path: path, method: "GET")
        let (data, response) = try await transport.data(for: request)
        return try decode(T.self, from: data, response: response, expectedStatus: 200)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, expectedStatus: Int = 200) async throws -> Response {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await transport.data(for: request)
        return try decode(Response.self, from: data, response: response, expectedStatus: expectedStatus)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw GatewayScarfClientError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse, expectedStatus: Int) throws -> T {
        guard response.statusCode == expectedStatus else {
            let errorPayload = try? decoder.decode(GatewayScarfErrorEnvelope.self, from: data)
            throw GatewayScarfClientError.httpStatus(response.statusCode, errorPayload?.error.message ?? String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

public enum GatewayScarfClientError: Error, Equatable {
    case invalidURL(String)
    case nonHTTPResponse
    case httpStatus(Int, String)
}

public struct GatewayScarfHealthSnapshot: Codable, Sendable, Equatable {
    public let service: GatewayScarfServiceInfo
    public let status: String
    public let hermes: GatewayScarfHermesInfo
    public let capabilities: GatewayScarfCapabilities
    public let problems: [GatewayScarfProblem]
}

public struct GatewayScarfCapabilitiesSnapshot: Codable, Sendable, Equatable {
    public let capabilities: GatewayScarfCapabilities
    public let raw: GatewayScarfRawCapabilities
    public let problems: [GatewayScarfProblem]
}

public struct GatewayScarfServiceInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let time: String
}

public struct GatewayScarfHermesInfo: Codable, Sendable, Equatable {
    public let available: Bool
    public let version: String?
    public let executable: String
    public let home: String
}

public struct GatewayScarfCapabilities: Codable, Sendable, Equatable {
    public let chat: Bool
    public let sessions: Bool
    public let cron: Bool
    public let skills: Bool
    public let logs: Bool
    public let projectContext: Bool
}

public struct GatewayScarfRawCapabilities: Codable, Sendable, Equatable {
    public let hermesVersion: String?
    public let hermesExecutable: String
}

public struct GatewayScarfProblem: Codable, Sendable, Equatable {
    public let code: String
    public let severity: String
    public let message: String
}

public struct GatewayScarfSession: Codable, Sendable, Equatable {
    public let sessionId: String
    public let title: String?
    public let createdAt: String
    public let status: String
    public let project: GatewayScarfProjectContext?
}

public struct GatewayScarfProjectContext: Codable, Sendable, Equatable {
    public let directory: String
    public let contextFiles: [String]
}

public struct GatewayScarfMessageResponse: Codable, Sendable, Equatable {
    public let sessionId: String
    public let response: String
}

public struct GatewayScarfActionResponse: Codable, Sendable, Equatable {
    public let sessionId: String?
    public let status: String
}

public struct GatewayScarfSkill: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    public let path: String
    public let files: [String]
    public let requiredConfig: [String]
    public let allowedTools: [String]?
    public let relatedSkills: [String]?
    public let dependencies: [String]?
    public let description: String
    public let enabled: Bool
    public let pinned: Bool
}

public struct GatewayScarfLogTail: Codable, Sendable, Equatable {
    public let source: String
    public let path: String
    public let lines: [String]
}

private struct GatewayScarfCronJobsResponse: Codable {
    let jobs: [HermesCronJob]
}

private struct GatewayScarfSkillsResponse: Codable {
    let skills: [GatewayScarfSkill]
}

private struct GatewayScarfCreateSessionRequest: Codable {
    let projectDirectory: String?
    let title: String?
}

private struct GatewayScarfMessageRequest: Codable {
    let text: String
}

private struct EmptyBody: Codable {}

private struct GatewayScarfErrorEnvelope: Codable {
    let error: GatewayScarfError
}

private struct GatewayScarfError: Codable {
    let code: String
    let message: String
}
