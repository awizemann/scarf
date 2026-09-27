import Testing
import Foundation
@testable import ScarfCore

/// S14-F7: the local Logs tail must keep following `agent.log` across
/// Hermes's rename-based rotation (`RotatingFileHandler`,
/// `hermes_logging.py:21-35` @ v2026.9.24) and across truncation. It held
/// one `FileHandle` for good, so after a rotation it read the renamed
/// `agent.log.1` forever and showed nothing new.
@Suite struct HermesLogLocalFollowTests {

    static func line(_ n: Int) -> String {
        "2026-09-26 12:00:\(String(format: "%02d", n % 60)),000 INFO hermes.agent: line \(n)\n"
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func withLog(_ body: (URL, HermesLogService) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r05-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("agent.log")
        try Data((0..<3).map(line).joined().utf8).write(to: log)
        let service = HermesLogService(context: .local(home: dir))
        await service.openLog(path: log.path)
        _ = await service.readLastLines(count: 100)
        await service.seekToEnd()
        try await body(log, service)
        await service.closeLog()
    }

    @Test("new lines after a rotation are still followed, with the old file's tail drained first")
    func followsAcrossRotation() async throws {
        try await Self.withLog { log, service in
            try Self.append(Self.line(3), to: log)
            #expect(await service.readNewLines().map(\.message) == ["line 3"])

            // One last line into the old file, then Hermes's rotation:
            // rename away, fresh file in its place.
            try Self.append(Self.line(4), to: log)
            try FileManager.default.moveItem(at: log, to: log.appendingPathExtension("1"))
            try Data((Self.line(5) + Self.line(6)).utf8).write(to: log)

            #expect(await service.readNewLines().map(\.message) == ["line 4", "line 5", "line 6"])
            try Self.append(Self.line(7), to: log)
            #expect(await service.readNewLines().map(\.message) == ["line 7"])
        }
    }

    @Test("a truncated log is re-read from its start")
    func followsAcrossTruncation() async throws {
        try await Self.withLog { log, service in
            let handle = try FileHandle(forWritingTo: log)
            try handle.truncate(atOffset: 0)
            try handle.close()
            try Self.append(Self.line(9), to: log)
            #expect(await service.readNewLines().map(\.message) == ["line 9"])
        }
    }

    @Test("no change means no re-read")
    func quietLogStaysQuiet() async throws {
        try await Self.withLog { _, service in
            #expect(await service.readNewLines().isEmpty)
            #expect(await service.readNewLines().isEmpty)
        }
    }
}
