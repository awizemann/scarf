#if !os(iOS)
import Testing
import Foundation
@testable import ScarfCore

/// Round-6 decision 11 — `ServerTransport` has an `async` seam.
///
/// `runProcess(executable:args:stdin:timeout:)` BLOCKS its caller's thread,
/// and every caller is `async`. On iOS each one wrapped it in a
/// `Task.detached`, so the WAIT ran on the cooperative pool (one thread per
/// core, unable to grow) while the exec it waited for ran on that same pool
/// — the caller competing with the thing it was waiting for (charter C10).
///
/// `CitadelServerTransport` overrides the seam with its own `async` exec, so
/// the iOS path has no blocking bridge at all. The default implementation
/// tested here is the smaller claim for the two Mac transports: the wait
/// gets a thread of its OWN (`OffPool`, never `Task.detached`). Converting
/// their internals end-to-end is `t-02f830f4`.
@Suite("The async runProcess seam (P58)")
struct AsyncRunProcessSeamP58Tests {

    @Test("the default seam runs the blocking call off the caller's thread")
    func defaultSeamLeavesTheCallersThread() async throws {
        let caller = pthread_mach_thread_np(pthread_self())
        let transport = ThreadRecordingTransport()
        _ = try await transport.asyncRunProcess(
            executable: "/bin/echo", args: ["hi"], stdin: nil, timeout: 5)
        let ran = try #require(transport.observedThread)
        #expect(ran != caller, """
            The default `asyncRunProcess` ran the blocking `runProcess` on the \
            caller's own thread — it is not hopping at all.
            """)
        #expect(transport.observedMain == false)
    }

    @Test("a throwing transport still throws through the seam")
    func errorsPropagate() async {
        let transport = ThreadRecordingTransport(failing: true)
        await #expect(throws: TransportError.self) {
            _ = try await transport.asyncRunProcess(
                executable: "/bin/echo", args: [], stdin: nil, timeout: 5)
        }
    }

    /// The real transports must not silently inherit a bridge that is itself
    /// a `Task.detached`: that would put the wait back on the pool while
    /// every call site believed it had left.
    @Test("the seam's default is `OffPool`, not `Task.detached`")
    func theDefaultUsesOffPool() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // …/ScarfCoreTests
                .deletingLastPathComponent()   // …/Tests
                .deletingLastPathComponent()   // …/ScarfCore
                .appendingPathComponent("Sources/ScarfCore/Transport/ServerTransport.swift"),
            encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.contains("nonisolated func asyncRunProcess(") && !$0.hasPrefix("//") }
                .flatMap { idx -> Int? in
                    // The DEFAULT is the second declaration (the first is the
                    // protocol requirement, which has no body).
                    lines[(idx + 1)...].firstIndex { $0.contains("nonisolated func asyncRunProcess(") }
                },
            "`asyncRunProcess` has no default implementation any more")
        let body = lines[start..<min(start + 20, lines.count)].joined(separator: "\n")
        #expect(body.contains("OffPool.run"))
        #expect(!body.contains("Task.detached"))
    }

    /// Records where `runProcess` actually ran. Only the process verbs are
    /// real; the file verbs are unused here and refuse rather than lie.
    private final class ThreadRecordingTransport: ServerTransport, @unchecked Sendable {
        private let failing: Bool
        private let lock = NSLock()
        private var thread: UInt32?
        private var main: Bool?

        init(failing: Bool = false) { self.failing = failing }

        var observedThread: UInt32? { lock.lock(); defer { lock.unlock() }; return thread }
        var observedMain: Bool? { lock.lock(); defer { lock.unlock() }; return main }

        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.lock()
            thread = pthread_mach_thread_np(pthread_self())
            main = Thread.isMainThread
            lock.unlock()
            if failing { throw TransportError.other(message: "nope") }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }

        func readFile(_ path: String) throws -> Data { throw unsupported }
        func unguardedWriteFile(_ path: String, data: Data) throws { throw unsupported }
        func fileExists(_ path: String) -> Bool { false }
        func stat(_ path: String) -> FileStat? { nil }
        func listDirectory(_ path: String) throws -> [String] { throw unsupported }
        func createDirectory(_ path: String) throws { throw unsupported }
        func removeFile(_ path: String) throws { throw unsupported }
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process { Process() }
        func streamRawBytes(executable: String, args: [String]) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        var isRemote: Bool { false }
        let contextID: ServerID = UUID()
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
            AsyncStream { $0.finish() }
        }
        func statAll(_ paths: [String]) -> [String: FileStat]? { nil }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            throw unsupported
        }

        private var unsupported: TransportError {
            .other(message: "ThreadRecordingTransport covers the process verbs only")
        }
    }
}
#endif
