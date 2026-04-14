import Foundation

struct LogEntry: Identifiable, Sendable {
    let id: Int
    let timestamp: String
    let level: LogLevel
    let sessionId: String?
    let logger: String
    let message: String
    let raw: String

    enum LogLevel: String, Sendable, CaseIterable {
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

actor HermesLogService {
    private var fileHandle: FileHandle?
    private var currentPath: String?
    private var entryCounter = 0

    func openLog(path: String) {
        closeLog()
        currentPath = path
        fileHandle = FileHandle(forReadingAtPath: path)
    }

    func closeLog() {
        do {
            try fileHandle?.close()
        } catch {
            print("[Scarf] Failed to close log handle: \(error.localizedDescription)")
        }
        fileHandle = nil
        currentPath = nil
    }

    func readLastLines(count: Int = QueryDefaults.logLineLimit) -> [LogEntry] {
        guard let path = currentPath,
              let data = FileManager.default.contents(atPath: path) else { return [] }
        let content = String(data: data, encoding: .utf8) ?? ""
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let lastLines = Array(lines.suffix(count))
        return lastLines.map { parseLine($0) }
    }

    func readNewLines() -> [LogEntry] {
        guard let handle = fileHandle else { return [] }
        let data = handle.availableData
        guard !data.isEmpty else { return [] }
        let content = String(data: data, encoding: .utf8) ?? ""
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.map { parseLine($0) }
    }

    func seekToEnd() {
        fileHandle?.seekToEndOfFile()
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
