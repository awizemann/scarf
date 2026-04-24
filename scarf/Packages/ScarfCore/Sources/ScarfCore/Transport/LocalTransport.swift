import Foundation
#if canImport(os)
import os
#endif

/// `ServerTransport` over the local filesystem. Thin wrapper around
/// `FileManager`, `Process`, and `DispatchSourceFileSystemObject` — the APIs
/// services were already using before Phase 2.
///
/// **Platform note.** All Hermes code paths that actually construct a
/// `LocalTransport` run on macOS (iOS uses `SSHTransport` exclusively). The
/// `#if canImport(Darwin)` guards below exist only so ScarfCore still
/// compiles on Linux for `swift test` CI — on Linux, file-watching is a
/// no-op stream and the subprocess spawn still works via Foundation's
/// `Process`.
public struct LocalTransport: ServerTransport {
    #if canImport(os)
    nonisolated private static let logger = Logger(subsystem: "com.scarf", category: "LocalTransport")
    #endif

    public let contextID: ServerID
    public let isRemote: Bool = false

    public nonisolated init(contextID: ServerID = ServerContext.local.id) {
        self.contextID = contextID
    }

    // MARK: - Files

    public func readFile(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    public func writeFile(_ path: String, data: Data) throws {
        do {
            // Ensure the parent dir exists — callers sometimes pass a
            // path whose parent hasn't been mkdir'd yet (e.g.,
            // `~/.hermes/memories/MEMORY.md` on a Hermes install that
            // never wrote memories before).
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            // Atomic write: Data.write(options: .atomic) drops a temp
            // file alongside the destination and rename(2)s it into
            // place. Cross-platform (macOS + iOS + Linux CI for tests).
            //
            // Earlier this method used `FileManager.replaceItemAt`,
            // which is Apple-only — Linux swift-corelibs would fail.
            // Data.write-atomic works everywhere with identical
            // semantics.
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            // Preserve 0600 for files that conventionally hold secrets.
            // The existing files use 0600 via HermesEnvService; apply
            // the same to brand-new files so we never demote
            // permissions on a rewrite.
            if Self.shouldEnforcePrivateMode(for: path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func stat(_ path: String) -> FileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return FileStat(size: size, mtime: mtime, isDirectory: isDir)
    }

    public func listDirectory(_ path: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    public func createDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    public func removeFile(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    // MARK: - Processes

    public func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
        #if os(iOS)
        // iOS can't spawn processes. Callers on iOS use `CitadelServerTransport`
        // (from the ScarfIOS package) instead; reaching here is a wiring bug.
        throw TransportError.other(message: "LocalTransport.runProcess is unavailable on iOS")
        #else
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if stdin != nil { proc.standardInput = stdinPipe }
        do {
            try proc.run()
        } catch {
            throw TransportError.other(message: "Failed to launch \(executable): \(error.localizedDescription)")
        }
        if let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        // Timeout handling: poll every 100ms up to timeout, kill on overrun.
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                proc.terminate()
                let partial = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                throw TransportError.timeout(seconds: timeout, partialStdout: partial)
            }
        } else {
            proc.waitUntilExit()
        }
        let out = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
        return ProcessResult(exitCode: proc.terminationStatus, stdout: out, stderr: err)
        #endif
    }

    #if !os(iOS)
    public func makeProcess(executable: String, args: [String]) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        return proc
    }
    #endif

    public func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        #if os(iOS)
        // LocalTransport doesn't run on iOS at runtime — the iOS app
        // talks only to remote hosts via `CitadelServerTransport` — but
        // we still need this method to satisfy the `ServerTransport`
        // protocol for the compile. Return an immediately-finished
        // stream so any accidental iOS caller gets a no-op.
        return AsyncThrowingStream { $0.finish() }
        #else
        return AsyncThrowingStream { continuation in
            Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let handle = outPipe.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = Data(buffer[buffer.startIndex..<nl])
                        buffer = Data(buffer[buffer.index(after: nl)...])
                        if let text = String(data: lineData, encoding: .utf8) {
                            continuation.yield(text)
                        }
                    }
                }
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let stderr = (try? errPipe.fileHandleForReading.readToEnd())
                        .flatMap { String(data: $0 ?? Data(), encoding: .utf8) } ?? ""
                    continuation.finish(throwing: TransportError.commandFailed(
                        exitCode: proc.terminationStatus, stderr: stderr
                    ))
                } else {
                    continuation.finish()
                }
            }
        }
        #endif
    }

    // MARK: - SQLite

    public func snapshotSQLite(remotePath: String) throws -> URL {
        // Local case: no copy needed. Services open the path directly.
        URL(fileURLWithPath: remotePath)
    }

    // MARK: - Watching

    #if canImport(Darwin)
    public func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream { continuation in
            // Build the source list immutably, then hand a value-typed copy
            // to onTermination. Swift 6's concurrent-capture rule rejects a
            // `var sources` shared between the outer builder and the inner
            // termination closure.
            let sources: [DispatchSourceFileSystemObject] = paths.compactMap { path in
                let fd = Darwin.open(path, O_EVTONLY)
                guard fd >= 0 else { return nil }
                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend, .rename],
                    queue: .global()
                )
                src.setEventHandler { continuation.yield(.anyChanged) }
                src.setCancelHandler { Darwin.close(fd) }
                src.resume()
                return src
            }
            continuation.onTermination = { _ in
                for s in sources { s.cancel() }
            }
        }
    }
    #else
    /// Linux stub: no FSEvents, no inotify wiring for now. Returns an empty
    /// stream so callers that `for await _ in transport.watchPaths(...)`
    /// simply never tick. Real Linux deployment would switch this to an
    /// inotify implementation, but Linux is a CI-only target for us, not a
    /// runtime target — the stub suffices.
    public func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
    #endif

    // MARK: - Helpers

    /// Heuristic: files that conventionally hold secrets should be created
    /// with restrictive permissions so a future `scp` or editor doesn't end
    /// up exposing them.
    private static func shouldEnforcePrivateMode(for path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".env" || name == "auth.json" || name.hasSuffix("-tokens.json")
    }
}
