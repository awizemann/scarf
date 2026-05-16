import Foundation
import ScarfCore

/// Drives the Gateway Scarf connection sheet. This is the HTTP replacement for
/// the old remote-server SSH fields: users enter the gateway base URL and the
/// bearer token, Scarf persists them to Application Support, and the client can
/// load the same config at launch.
@Observable
@MainActor
final class GatewayScarfSettingsViewModel {
    var baseURL: String = ""
    var token: String = ""
    var isTesting: Bool = false
    var isSaving: Bool = false
    var testResult: TestResult?
    var saveError: String?
    private(set) var savedConfig: GatewayScarfConnectionConfig?

    enum TestResult: Equatable {
        case success(serviceName: String, hermesVersion: String, capabilities: String)
        case failure(message: String)
    }

    init() {
        do {
            if let config = try GatewayScarfConnectionConfig.load(environment: [:]) {
                baseURL = config.baseURL.absoluteString
                token = config.token
            }
        } catch {
            testResult = .failure(message: "Couldn't read existing gateway config: \(Self.describe(error))")
        }
    }

    var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeConfig() throws -> GatewayScarfConnectionConfig {
        try GatewayScarfConnectionConfig(baseURLString: baseURL, token: token)
    }

    func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let config = try makeConfig()
            let snapshot = try await config.makeClient().health()
            let caps = [
                snapshot.capabilities.chat ? "chat" : nil,
                snapshot.capabilities.sessions ? "sessions" : nil,
                snapshot.capabilities.cron ? "cron" : nil,
                snapshot.capabilities.skills ? "skills" : nil,
                snapshot.capabilities.logs ? "logs" : nil,
                snapshot.capabilities.projectContext ? "projects" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            testResult = .success(
                serviceName: snapshot.service.name,
                hermesVersion: snapshot.hermes.version ?? "Hermes available",
                capabilities: caps.isEmpty ? "No advertised capabilities" : caps
            )
        } catch {
            testResult = .failure(message: Self.describe(error))
        }
    }

    func save() throws {
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        do {
            let config = try makeConfig()
            try config.save()
            savedConfig = config
        } catch {
            saveError = Self.describe(error)
            throw error
        }
    }

    private static func describe(_ error: Error) -> String {
        if let gateway = error as? GatewayScarfClientError {
            switch gateway {
            case .invalidURL(let value):
                return "Invalid gateway URL: \(value)"
            case .nonHTTPResponse:
                return "Gateway did not return an HTTP response."
            case .httpStatus(let status, let message):
                return "Gateway returned HTTP \(status): \(message)"
            }
        }
        return error.localizedDescription
    }
}
