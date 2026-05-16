import Foundation

public struct GatewayServerTransport: ServerTransport {
    public let contextID: ServerID
    public let config: GatewayScarfConnectionConfig
    public let isRemote: Bool = true

    private let client: GatewayScarfClient

    public init(contextID: ServerID, config: GatewayScarfConnectionConfig) {
        self.contextID = contextID
        self.config = config
        self.client = config.makeClient()
    }

    public func readFile(_ path: String) throws -> Data {
        let response: GatewayFileReadResponse = try sync { try await client.readFile(path: path) }
        if response.encoding == "base64" {
            return Data(base64Encoded: response.data) ?? Data()
        }
        return Data(response.data.utf8)
    }

    public func writeFile(_ path: String, data: Data) throws {
        _ = try sync { try await client.writeFile(path: path, data: data) } as GatewayFileWriteResponse
    }

    public func fileExists(_ path: String) -> Bool {
        (try? statFile(path).exists) ?? false
    }

    public func stat(_ path: String) -> FileStat? {
        guard let payload = try? statFile(path), payload.exists, let stat = payload.stat else { return nil }
        return FileStat(size: stat.size, mtime: parseDate(stat.mtime), isDirectory: stat.isDirectory)
    }

    public func listDirectory(_ path: String) throws -> [String] {
        let response: GatewayFileListResponse = try sync { try await client.listDirectory(path: path) }
        return response.entries.map { $0.name }
    }

    public func createDirectory(_ path: String) throws {
        _ = try sync { try await client.createDirectory(path: path) } as GatewayStatusPathResponse
    }

    public func removeFile(_ path: String) throws {
        _ = try sync { try await client.deleteFile(path: path) } as GatewayStatusPathResponse
    }

    public func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
        let response: GatewayProcessRunResponse = try sync {
            try await client.runProcess(executable: executable, args: args, stdin: stdin, timeout: timeout)
        }
        return response.processResult
    }

    #if !os(iOS)
    public func makeProcess(executable: String, args: [String]) -> Process {
        fatalError("GatewayServerTransport cannot expose Foundation.Process; use GatewayACPChannel or runProcess instead")
    }
    #endif

    public func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try runProcess(executable: executable, args: args, stdin: nil, timeout: nil)
                    for line in result.stdoutString.split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(String(line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func streamRawBytes(executable: String, args: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try runProcess(executable: executable, args: args, stdin: nil, timeout: nil)
                    continuation.yield(result.stdout)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        let response = try await client.runScript(script: script, timeout: timeout)
        return response.processResult
    }

    public func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream<WatchEvent> { continuation in
            let task = Task {
                var last: String?
                while !Task.isCancelled {
                    if let snapshot: GatewayWatchSnapshotResponse = try? await client.watchSnapshot(paths: paths) {
                        if let last, last != snapshot.signature {
                            continuation.yield(.anyChanged)
                        }
                        last = snapshot.signature
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func statFile(_ path: String) throws -> GatewayFileStatResponse {
        try sync { try await client.statFile(path: path) }
    }

    private func parseDate(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
    }
}

private final class SyncResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func sync<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = SyncResultBox<T>()
    Task {
        do { box.result = Result.success(try await operation()) }
        catch { box.result = Result.failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.result!.get()
}

private extension GatewayProcessRunResponse {
    var processResult: ProcessResult {
        ProcessResult(
            exitCode: Int32(exitCode),
            stdout: Data(base64Encoded: stdout) ?? Data(),
            stderr: Data(base64Encoded: stderr) ?? Data()
        )
    }
}
