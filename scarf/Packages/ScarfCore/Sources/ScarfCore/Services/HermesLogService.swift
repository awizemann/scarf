import Foundation

public struct LogEntry: Identifiable, Sendable {
    public let id: Int
    public let timestamp: String
    public let level: LogLevel
    public let sessionId: String?
    public let logger: String
    public let message: String
    public let raw: String


    public init(
        id: Int,
        timestamp: String,
        level: LogLevel,
        sessionId: String?,
        logger: String,
        message: String,
        raw: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.sessionId = sessionId
        self.logger = logger
        self.message = message
        self.raw = raw
    }
    public enum LogLevel: String, Sendable, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case critical = "CRITICAL"

        var color: String {
            switch self {
            case .debug: return "secondary"
            case .info: return "primary"
            case .warning: return "orange"
            case .error: return "red"
            case .critical: return "red"
            }
        }
    }
}

public actor HermesLogService {
    /// Local file handle for local contexts. `nil` when following a remote
    /// log or when no log is open.
    private var localHandle: FileHandle?
    private var currentPath: String?
    private var entryCounter = 0

    /// Remote-tail state. Streaming exec via `transport.streamLines(...)`
    /// yields one stdout line per element; the pump task pushes them into
    /// `remoteTailBuffer` for `readNewLines()` to drain. The task is
    /// cancelled on `closeLog()` and when re-opening to a different path.
    private var remoteTailTask: Task<Void, Never>?
    private var remoteTailBuffer: [LogEntry] = []

    public let context: ServerContext
    private let transport: any ServerTransport

    public init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    public func openLog(path: String) {
        closeLog()
        currentPath = path
        if context.isRemote {
            // Streaming tail via the transport's `streamLines`. This works
            // on every platform: Mac/Linux drive it through a local `ssh`
            // subprocess; iOS drives it through a Citadel exec channel.
            // We don't hold a FileHandle anymore — the AsyncThrowingStream
            // owns the lifecycle and our pump Task pulls lines off it.
            let stream = transport.streamLines(
                executable: "/usr/bin/tail",
                args: ["-n", String(QueryDefaults.logLineLimit), "-F", path]
            )
            remoteTailTask = Task { [weak self] in
                do {
                    for try await line in stream {
                        await self?.appendRemoteTailLine(line)
                    }
                } catch {
                    // Transient disconnects / command failures: surface once
                    // and stop. Callers typically re-open the log on retry.
                    #if DEBUG
                    print("[Scarf] remote tail ended: \(error.localizedDescription)")
                    #endif
                }
            }
        } else {
            localHandle = FileHandle(forReadingAtPath: path)
        }
    }

    public func closeLog() {
        do {
            try localHandle?.close()
        } catch {
            print("[Scarf] Failed to close log handle: \(error.localizedDescription)")
        }
        localHandle = nil
        currentPath = nil
        remoteTailTask?.cancel()
        remoteTailTask = nil
        remoteTailBuffer.removeAll(keepingCapacity: false)
    }

    public func readLastLines(count: Int = QueryDefaults.logLineLimit) -> [LogEntry] {
        guard let path = currentPath else { return [] }
        if context.isRemote {
            // For the initial load we bypass the streaming tail and run a
            // one-shot `tail -n <count>` for a clean bounded read.
            let result = try? transport.runProcess(
                executable: "/usr/bin/tail",
                args: ["-n", String(count), path],
                stdin: nil,
                timeout: 30
            )
            let content = result?.stdoutString ?? ""
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            return lines.map { parseLine($0) }
        }
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let content = String(data: data, encoding: .utf8) ?? ""
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let lastLines = Array(lines.suffix(count))
        return lastLines.map { parseLine($0) }
    }

    public func readNewLines() -> [LogEntry] {
        if context.isRemote {
            // Drain whatever the streaming tail has accumulated since the
            // last call. The async pump task above does the line framing
            // and parsing; we just hand the batch back.
            guard !remoteTailBuffer.isEmpty else { return [] }
            let batch = remoteTailBuffer
            remoteTailBuffer.removeAll(keepingCapacity: true)
            return batch
        }
        guard let handle = localHandle else { return [] }
        let data = handle.availableData
        guard !data.isEmpty else { return [] }
        let chunk = String(data: data, encoding: .utf8) ?? ""
        let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.map { parseLine($0) }
    }

    public func seekToEnd() {
        // Only meaningful for local FileHandles — remote tail starts at the
        // end implicitly after `readLastLines` drained the initial load.
        if !context.isRemote {
            localHandle?.seekToEndOfFile()
        }
    }

    /// Called from the remote-tail pump Task when the AsyncStream yields a
    /// line. Parses and enqueues into the buffer that `readNewLines()`
    /// drains on the next poll from the ViewModel's timer.
    private func appendRemoteTailLine(_ line: String) {
        guard !line.isEmpty else { return }
        remoteTailBuffer.append(parseLine(line))
    }

    private func parseLine(_ line: String) -> LogEntry {
        entryCounter += 1
        // Format (v0.9.0+): YYYY-MM-DD HH:MM:SS,MMM LEVEL [session_id] logger: message
        // Session tag is optional — earlier Hermes releases and out-of-session lines omit it.
        let pattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s+(DEBUG|INFO|WARNING|ERROR|CRITICAL)\s+(?:\[([^\]]+)\]\s+)?(\S+?):\s+(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            let timestamp = String(line[Range(match.range(at: 1), in: line)!])
            let levelStr = String(line[Range(match.range(at: 2), in: line)!])
            let sessionId: String? = {
                let range = match.range(at: 3)
                guard range.location != NSNotFound, let r = Range(range, in: line) else { return nil }
                return String(line[r])
            }()
            let logger = String(line[Range(match.range(at: 4), in: line)!])
            let message = String(line[Range(match.range(at: 5), in: line)!])
            return LogEntry(
                id: entryCounter,
                timestamp: timestamp,
                level: LogEntry.LogLevel(rawValue: levelStr) ?? .info,
                sessionId: sessionId,
                logger: logger,
                message: message,
                raw: line
            )
        }
        return LogEntry(id: entryCounter, timestamp: "", level: .info, sessionId: nil, logger: "", message: line, raw: line)
    }
}
