import Foundation

public actor GatewayACPChannel: ACPChannel {
    private let client: GatewayScarfClient
    private let sessionId: String
    private var closed = false
    private var exitCode: Int32?
    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var stderrContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private let incomingStream: AsyncThrowingStream<String, Error>
    private let stderrStream: AsyncThrowingStream<String, Error>
    private var pollTask: Task<Void, Never>?
    private var lastEventId: String?

    public nonisolated var incoming: AsyncThrowingStream<String, Error> { incomingStream }
    public nonisolated var stderr: AsyncThrowingStream<String, Error> { stderrStream }

    public init(config: GatewayScarfConnectionConfig, executable: String? = nil, args: [String]? = nil, projectDirectory: String? = nil) async throws {
        self.client = config.makeClient()
        let created = try await client.createACPSession(executable: executable, args: args, projectDirectory: projectDirectory)
        self.sessionId = created.acpSessionId
        var incomingCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream { incomingCont = $0 }
        self.incomingContinuation = incomingCont
        var stderrCont: AsyncThrowingStream<String, Error>.Continuation!
        self.stderrStream = AsyncThrowingStream { stderrCont = $0 }
        self.stderrContinuation = stderrCont
        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    public func send(_ line: String) async throws {
        guard !closed else { throw ACPChannelError.writeEndClosed }
        _ = try await client.sendACPLine(sessionId: sessionId, line: line)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        pollTask?.cancel()
        _ = try? await client.closeACPSession(sessionId: sessionId)
        incomingContinuation?.finish()
        stderrContinuation?.finish()
    }

    public var diagnosticID: String? { get async { "gateway:\(sessionId)" } }
    public var lastExitCode: Int32? { get async { exitCode } }

    private func pollOnce() async {
        do {
            let sse = try await client.acpEvents(sessionId: sessionId, lastEventId: lastEventId)
            for event in parseSSE(sse) {
                lastEventId = event.id
                switch event.type {
                case "stdout_line":
                    if let line = event.payload["line"] as? String { incomingContinuation?.yield(line) }
                case "stderr_line":
                    if let line = event.payload["line"] as? String { stderrContinuation?.yield(line) }
                case "exit":
                    if let code = event.payload["exitCode"] as? Int { exitCode = Int32(code) }
                    incomingContinuation?.finish()
                    stderrContinuation?.finish()
                    pollTask?.cancel()
                default:
                    break
                }
            }
        } catch {
            incomingContinuation?.finish(throwing: error)
            stderrContinuation?.finish(throwing: error)
            pollTask?.cancel()
        }
    }
}

private struct GatewayACPEvent {
    let id: String
    let type: String
    let payload: [String: Any]
}

private func parseSSE(_ body: String) -> [GatewayACPEvent] {
    body.components(separatedBy: "\n\n").compactMap { block in
        var id = ""
        var type = "message"
        var dataLines: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("id: ") { id = String(line.dropFirst(4)) }
            else if line.hasPrefix("event: ") { type = String(line.dropFirst(7)) }
            else if line.hasPrefix("data: ") { dataLines.append(String(line.dropFirst(6))) }
        }
        guard !id.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n").data(using: .utf8) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return GatewayACPEvent(id: id, type: type, payload: json)
    }
}
