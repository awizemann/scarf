import Testing
import Foundation
@testable import ScarfCore

/// Exercises M3's changes to the `ServerTransport` surface: the new
/// `streamLines(_:args:)` method, the platform-gated `makeProcess`,
/// the `ServerContext.sshTransportFactory` injection point, and the
/// HermesLogService refactor that drives remote tailing through
/// `streamLines` instead of a raw `Process` + `Pipe`.
///
/// **`.serialized` is mandatory.** Several tests set the static
/// `ServerContext.sshTransportFactory` + restore in `defer`. Running
/// them in parallel (swift-testing's default) makes the factory a
/// race hazard — one test's scripted transport gets read by the
/// other, producing confusing "wrong log line" failures.
@Suite(.serialized) struct M3TransportTests {

    // MARK: - streamLines: LocalTransport

    @Test func localStreamLinesYieldsOneLinePerNewline() async throws {
        // `echo -e` is not portable between BSD and GNU `echo`, so we
        // use `/bin/sh -c 'printf ...'` which is deterministic on both.
        // LocalTransport's streamLines should yield three lines when
        // the subprocess emits "a\nb\nc\n".
        let transport = LocalTransport()
        let stream = transport.streamLines(
            executable: "/bin/sh",
            args: ["-c", "printf 'a\\nb\\nc\\n'"]
        )
        var collected: [String] = []
        for try await line in stream {
            collected.append(line)
        }
        #expect(collected == ["a", "b", "c"])
    }

    @Test func localStreamLinesFinishesOnEOFWithoutTrailingNewline() async throws {
        // If the subprocess emits "a\nb" (no trailing newline), we
        // yield "a" and DROP "b" — the stream framer treats partial
        // trailing content as unterminated. This is the documented
        // behaviour and matches what the HermesLogService tail path
        // sees over SSH.
        let transport = LocalTransport()
        let stream = transport.streamLines(
            executable: "/bin/sh",
            args: ["-c", "printf 'a\\nb'"]
        )
        var collected: [String] = []
        for try await line in stream {
            collected.append(line)
        }
        #expect(collected == ["a"])
    }

    @Test func localStreamLinesSurfacesNonZeroExit() async throws {
        let transport = LocalTransport()
        let stream = transport.streamLines(
            executable: "/bin/sh",
            args: ["-c", "printf 'a\\n'; exit 3"]
        )
        var collected: [String] = []
        var thrown: Error?
        do {
            for try await line in stream {
                collected.append(line)
            }
        } catch {
            thrown = error
        }
        #expect(collected == ["a"])
        guard let err = thrown as? TransportError else {
            Issue.record("expected TransportError, got \(String(describing: thrown))")
            return
        }
        if case .commandFailed(let exit, _) = err {
            #expect(exit == 3)
        } else {
            Issue.record("expected .commandFailed, got \(err)")
        }
    }

    // MARK: - sshTransportFactory injection

    @Test func sshTransportFactoryOverridesDefault() {
        // Set up a mock factory that returns a `LocalTransport` regardless
        // of the ServerKind — easy way to prove the injection point
        // routes to our override.
        final class CountingBox: @unchecked Sendable {
            var count = 0
            func bump() { count += 1 }
        }
        let box = CountingBox()
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }

        ServerContext.sshTransportFactory = { id, _, _ in
            box.bump()
            return LocalTransport(contextID: id)
        }

        let ctx = ServerContext(
            id: UUID(),
            displayName: "test",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let transport = ctx.makeTransport()
        #expect(transport is LocalTransport)
        #expect(box.count == 1)
    }

    @Test func sshTransportFactoryNilFallsBackToSSHTransport() {
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = nil

        let ctx = ServerContext(
            id: UUID(),
            displayName: "test",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let transport = ctx.makeTransport()
        #expect(transport is SSHTransport)
    }

    @Test func sshTransportFactoryIgnoredForLocalContext() {
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        // Even if set, the factory is ONLY consulted for `.ssh` kinds —
        // `.local` always gets a `LocalTransport` directly.
        ServerContext.sshTransportFactory = { _, _, _ in
            Issue.record("factory called for local context")
            return LocalTransport()
        }

        let transport = ServerContext.local.makeTransport()
        #expect(transport is LocalTransport)
    }

    // MARK: - HermesLogService remote tail refactor

    /// Minimal `ServerTransport` test double: `isRemote == true`, all
    /// file I/O throws, `streamLines` returns a scripted sequence of
    /// lines. Exists to verify HermesLogService's remote-tail path
    /// pumps scripted output into the ring buffer without a real SSH
    /// subprocess.
    final class ScriptedTransport: ServerTransport, @unchecked Sendable {
        public let contextID: ServerID = UUID()
        public let isRemote: Bool = true
        private let lines: [String]

        init(lines: [String]) { self.lines = lines }

        func readFile(_ path: String) throws -> Data { throw TransportError.other(message: "N/A") }
        func writeFile(_ path: String, data: Data) throws { throw TransportError.other(message: "N/A") }
        func fileExists(_ path: String) -> Bool { true }
        func stat(_ path: String) -> FileStat? { FileStat(size: 0, mtime: Date(), isDirectory: false) }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {}
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
            // For readLastLines' one-shot tail — return all scripted lines joined.
            let content = lines.joined(separator: "\n") + "\n"
            return ProcessResult(exitCode: 0, stdout: Data(content.utf8), stderr: Data())
        }
        #if !os(iOS)
        func makeProcess(executable: String, args: [String]) -> Process {
            // Required by protocol on non-iOS; not exercised in tests below.
            Process()
        }
        #endif
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                }
            }
        }
        func snapshotSQLite(remotePath: String) throws -> URL { URL(fileURLWithPath: remotePath) }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
            AsyncStream { $0.finish() }
        }
    }

    // Note: We can't easily inject the ScriptedTransport into
    // HermesLogService directly (it takes a `ServerContext` and constructs
    // its transport internally via `context.makeTransport()`). Instead we
    // wire the scripted transport through the factory injection point.
    @Test func hermesLogServiceRemoteTailPumpsThroughStreamLines() async throws {
        let scripted = ScriptedTransport(lines: [
            "2026-04-22 12:00:00,001 INFO hermes.agent: starting",
            "2026-04-22 12:00:01,002 WARNING hermes.gateway: low disk",
            "2026-04-22 12:00:02,003 ERROR hermes.agent: boom",
        ])

        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = { _, _, _ in scripted }

        let ctx = ServerContext(
            id: UUID(),
            displayName: "t",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let service = HermesLogService(context: ctx)
        await service.openLog(path: "/fake/agent.log")
        defer { Task { await service.closeLog() } }

        // Give the pump task a moment to drain the scripted stream.
        try await Task.sleep(nanoseconds: 50_000_000)

        let entries = await service.readNewLines()
        #expect(entries.count == 3)
        #expect(entries[0].level == .info)
        #expect(entries[1].level == .warning)
        #expect(entries[2].level == .error)
        #expect(entries[2].message == "boom")
    }

    @Test func hermesLogServiceReadLastLinesUsesOneShotTail() async {
        let scripted = ScriptedTransport(lines: ["x", "y", "z"])
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = { _, _, _ in scripted }

        let ctx = ServerContext(
            id: UUID(),
            displayName: "t",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let service = HermesLogService(context: ctx)
        // Doesn't need openLog first for the one-shot, but currentPath
        // has to be set — openLog does both.
        await service.openLog(path: "/fake/agent.log")
        defer { Task { await service.closeLog() } }

        let entries = await service.readLastLines(count: 100)
        #expect(entries.count == 3)
        #expect(entries[0].message == "x")
        #expect(entries[2].message == "z")
    }
}
