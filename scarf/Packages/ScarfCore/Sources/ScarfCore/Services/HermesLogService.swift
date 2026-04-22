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
    private var fileHandle: FileHandle?
    private var currentPath: String?
    private var entryCounter = 0

    /// Remote tailing state. When set, we're reading from `ssh host tail -F`
    /// instead of a local file. Process stdout pipe drives `readNewLines()`;
    /// process lifecycle is the actor's responsibility.
    private var remoteTailProcess: Process?
    private var remoteTailBuffer: String = ""

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
            // Spawn `ssh host tail -F` and pipe stdout into our buffer. `-F`
            // follows the file through rotations — important for remote
            // log rotation setups (logrotate).
            let proc = transport.makeProcess(
                executable: "/usr/bin/tail",
                args: ["-n", String(QueryDefaults.logLineLimit), "-F", path]
            )
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                remoteTailProcess = proc
                fileHandle = outPipe.fileHandleForReading
            } catch {
                print("[Scarf] Failed to start remote tail: \(error.localizedDescription)")
                remoteTailProcess = nil
                fileHandle = nil
            }
        } else {
            fileHandle = FileHandle(forReadingAtPath: path)
        }
    }

    public func closeLog() {
        do {
            try fileHandle?.close()
        } catch {
            print("[Scarf] Failed to close log handle: \(error.localizedDescription)")
        }
        fileHandle = nil
        currentPath = nil
        if let proc = remoteTailProcess, proc.isRunning {
            proc.terminate()
        }
        remoteTailProcess = nil
        remoteTailBuffer = ""
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
        guard let handle = fileHandle else { return [] }
        let data = handle.availableData
        guard !data.isEmpty else { return [] }
        let chunk = String(data: data, encoding: .utf8) ?? ""
        if context.isRemote {
            // Remote tail emits bytes as they arrive — not line-aligned.
            // Buffer partials across reads so we don't split a line mid-way.
            remoteTailBuffer += chunk
            guard let lastNewline = remoteTailBuffer.lastIndex(of: "\n") else {
                return []
            }
            let complete = String(remoteTailBuffer[..<lastNewline])
            remoteTailBuffer = String(remoteTailBuffer[remoteTailBuffer.index(after: lastNewline)...])
            let lines = complete.components(separatedBy: "\n").filter { !$0.isEmpty }
            return lines.map { parseLine($0) }
        }
        let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.map { parseLine($0) }
    }

    public func seekToEnd() {
        // Only meaningful for local FileHandles — remote tail starts at the
        // end implicitly after `readLastLines` drained the initial load.
        if !context.isRemote {
            fileHandle?.seekToEndOfFile()
        }
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
