#if os(macOS)
import Foundation

/// Runs a real process for tests that exercise generated shell/Python.
/// Output goes to temp FILES, not pipes: tests spawn processes in parallel,
/// and a sibling child that inherits a pipe's write end would hold the
/// reader's EOF hostage. The run is bounded by a timeout (charter C10
/// applies to tests too).
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
        timeout: TimeInterval = 30
    ) throws -> Output {
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
        defer {
            try? outHandle.close()
            try? errHandle.close()
            try? inHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = inHandle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TimedOut()
        }
        return Output(stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                      stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "",
                      status: process.terminationStatus)
    }
}
#endif
