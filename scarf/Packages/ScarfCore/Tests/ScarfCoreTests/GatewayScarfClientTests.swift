import Foundation
import Testing
@testable import ScarfCore

@Suite struct GatewayScarfClientTests {
    @Test func healthDecodesGatewaySnapshotAndSendsBearerToken() async throws {
        let transport = RecordingGatewayTransport { request in
            #expect(request.url?.path == "/v1/health")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (200, #"{"service":{"name":"gateway-scarf","version":"0.1.0","time":"2026-05-16T12:00:00Z"},"status":"ok","hermes":{"available":true,"version":"Hermes Agent v-test","executable":"/usr/bin/hermes","home":"/tmp/hermes"},"capabilities":{"chat":true,"sessions":true,"cron":true,"skills":true,"logs":true,"projectContext":true},"problems":[]}"#)
        }
        let client = GatewayScarfClient(baseURL: URL(string: "http://127.0.0.1:8765")!, token: "test-token", transport: transport)

        let health = try await client.health()

        #expect(health.status == "ok")
        #expect(health.service.name == "gateway-scarf")
        #expect(health.hermes.available == true)
        #expect(health.capabilities.chat == true)
    }

    @Test func cronJobsDecodeScarfCompatibleScheduleShape() async throws {
        let transport = RecordingGatewayTransport { request in
            #expect(request.url?.path == "/v1/cron/jobs")
            return (200, #"{"jobs":[{"id":"job-1","name":"Morning","prompt":"hello","skills":[],"model":null,"schedule":{"kind":"cron","display":"daily","expression":"0 9 * * *"},"enabled":true,"state":"scheduled","deliver":"origin","next_run_at":"2026-05-17T09:00:00Z","last_run_at":null,"last_error":null,"workdir":"/tmp/project","no_agent":false}]}"#)
        }
        let client = GatewayScarfClient(baseURL: URL(string: "http://127.0.0.1:8765")!, token: "test-token", transport: transport)

        let jobs = try await client.cronJobs()

        #expect(jobs.count == 1)
        #expect(jobs[0].id == "job-1")
        #expect(jobs[0].schedule.expression == "0 9 * * *")
        #expect(jobs[0].workdir == "/tmp/project")
    }

    @Test func createSessionAndSendMessageRoundTrip() async throws {
        let transport = RecordingGatewayTransport { request in
            if request.url?.path == "/v1/sessions" {
                #expect(request.httpMethod == "POST")
                return (201, #"{"sessionId":"ses_123","title":"From Scarf","createdAt":"2026-05-16T12:00:00Z","status":"idle","project":{"directory":"/tmp/project","contextFiles":["AGENTS.md"]}}"#)
            }
            if request.url?.path == "/v1/sessions/ses_123/messages" {
                #expect(request.httpMethod == "POST")
                return (200, #"{"sessionId":"ses_123","response":"pong"}"#)
            }
            return (404, #"{"error":{"code":"not_found","message":"nope"}}"#)
        }
        let client = GatewayScarfClient(baseURL: URL(string: "http://127.0.0.1:8765")!, token: "test-token", transport: transport)

        let session = try await client.createSession(title: "From Scarf", projectDirectory: "/tmp/project")
        let response = try await client.sendMessage(sessionId: session.sessionId, text: "ping")

        #expect(session.sessionId == "ses_123")
        #expect(session.project?.contextFiles == ["AGENTS.md"])
        #expect(response.response == "pong")
    }

    @Test func liveGatewaySmokeWhenEnvironmentIsSet() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["GATEWAY_SCARF_INTEGRATION_BASE_URL"],
              let token = env["GATEWAY_SCARF_INTEGRATION_TOKEN"],
              let baseURL = URL(string: base) else {
            return
        }
        let client = GatewayScarfClient(baseURL: baseURL, token: token)

        let health = try await client.health()
        let jobs = try await client.cronJobs()
        let skills = try await client.skills()
        let logs = try await client.logs(source: "gateway", lines: 5)

        #expect(health.service.name == "gateway-scarf")
        #expect(health.capabilities.sessions == true)
        #expect(jobs.count >= 0)
        #expect(skills.count >= 0)
        #expect(logs.source == "gateway")
    }
}

private final class RecordingGatewayTransport: GatewayScarfTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = try handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}
