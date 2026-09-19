#if os(macOS)
import Foundation

/// Runs a real process for tests that exercise generated shell/Python.
/// Output goes to temp FILES, not pipes: tests spawn processes in parallel,
/// and a sibling child that inherits a pipe's write end would hold the
/// reader's EOF hostage. The run is bounded by a timeout (charter C10
/// applies to tests too).
///
/// `run` is `async` and SUSPENDS while the child runs: the termination
/// handler resumes it, and the timeout is a dispatch timer. Nothing parks a
/// cooperative-pool thread. The first version waited on a
/// `DispatchSemaphore` inside synchronous tests, so every child — a Hermes
/// ACP import took 11 s+ under full-suite load — held one of the pool's
/// ten threads for its whole life, and the ACP suites' 2 s `waitFor`s
/// starved behind them. `ShellTestRunnerPoolTests` pins this.
enum ShellTestRunner {
    struct Output {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    struct TimedOut: Error {}

    static func run(
        _ executable: String = "/bin/sh",
        arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 120
    ) async throws -> Output {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("scarf-shell-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("stdout"), errURL = dir.appendingPathComponent("stderr")
        let inURL = dir.appendingPathComponent("stdin")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        fm.createFile(atPath: inURL.path, contents: stdin ?? Data())

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        let inHandle = try FileHandle(forReadingFrom: inURL)
        // The child holds its own copies once spawned, so ours close right
        // after `run()`: a long child then costs this process no descriptors,
        // and the fd-counting leak tests running beside it see no noise.
        var handlesOpen = true
        func closeHandles() {
            guard handlesOpen else { return }
            handlesOpen = false
            try? outHandle.close()
            try? errHandle.close()
            try? inHandle.close()
        }
        defer { closeHandles() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = inHandle

        let timedOut = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let settle = Settle(continuation)
            process.terminationHandler = { _ in _ = settle.resume(false) }
            do {
                try process.run()
            } catch {
                settle.fail(error)
                return
            }
            closeHandles()
            // Whichever of exit and deadline comes first settles; the loser
            // is a no-op, so a late timer never signals a finished child.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if settle.resume(true) { process.terminate() }
            }
        }
        if timedOut { throw TimedOut() }
        return Output(stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                      stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "",
                      status: process.terminationStatus)
    }

    /// Resumes the continuation exactly once: the exit and the timer race.
    private final class Settle: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Error>?

        init(_ continuation: CheckedContinuation<Bool, Error>) { self.continuation = continuation }

        /// Returns whether THIS call settled it.
        func resume(_ timedOut: Bool) -> Bool {
            guard let c = take() else { return false }
            c.resume(returning: timedOut)
            return true
        }

        func fail(_ error: Error) { take()?.resume(throwing: error) }

        private func take() -> CheckedContinuation<Bool, Error>? {
            lock.lock(); defer { lock.unlock() }
            let c = continuation
            continuation = nil
            return c
        }
    }
}
#endif
