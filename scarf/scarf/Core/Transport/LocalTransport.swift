import Foundation
import os

/// `ServerTransport` over the local filesystem. Thin wrapper around
/// `FileManager`, `Process`, and `DispatchSourceFileSystemObject` — the APIs
/// services were already using before Phase 2.
struct LocalTransport: ServerTransport {
    private static let logger = Logger(subsystem: "com.scarf", category: "LocalTransport")

    let contextID: ServerID
    let isRemote: Bool = false

    init(contextID: ServerID = ServerContext.local.id) {
        self.contextID = contextID
    }

    // MARK: - Files

    func readFile(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    func writeFile(_ path: String, data: Data) throws {
        let tmp = path + ".scarf.tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            // Preserve `0600` for dotfiles holding secrets (.env, .auth, ...).
            // The existing files already use 0600 via HermesEnvService; we
            // mirror that here so a brand-new file created via this write
            // also starts with safe permissions.
            if Self.shouldEnforcePrivateMode(for: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
            }
            // Atomic swap onto the final path.
            let destURL = URL(fileURLWithPath: path)
            let tmpURL = URL(fileURLWithPath: tmp)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tmpURL)
            } else {
                // Ensure parent exists.
                let parent = (path as NSString).deletingLastPathComponent
                if !parent.isEmpty, !FileManager.default.fileExists(atPath: parent) {
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                }
                try FileManager.default.moveItem(at: tmpURL, to: destURL)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func stat(_ path: String) -> FileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return FileStat(size: size, mtime: mtime, isDirectory: isDir)
    }

    func listDirectory(_ path: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    func createDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    func removeFile(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    // MARK: - Processes

    func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
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
    }

    func makeProcess(executable: String, args: [String]) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        return proc
    }

    // MARK: - SQLite

    func snapshotSQLite(remotePath: String) throws -> URL {
        // Local case: no copy needed. Services open the path directly.
        URL(fileURLWithPath: remotePath)
    }

    // MARK: - Watching

    func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream { continuation in
            var sources: [DispatchSourceFileSystemObject] = []
            for path in paths {
                let fd = Darwin.open(path, O_EVTONLY)
                guard fd >= 0 else { continue }
                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend, .rename],
                    queue: .global()
                )
                src.setEventHandler { continuation.yield(.anyChanged) }
                src.setCancelHandler { Darwin.close(fd) }
                src.resume()
                sources.append(src)
            }
            continuation.onTermination = { _ in
                for s in sources { s.cancel() }
            }
        }
    }

    // MARK: - Helpers

    /// Heuristic: files that conventionally hold secrets should be created
    /// with restrictive permissions so a future `scp` or editor doesn't end
    /// up exposing them.
    private static func shouldEnforcePrivateMode(for path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".env" || name == "auth.json" || name.hasSuffix("-tokens.json")
    }
}
