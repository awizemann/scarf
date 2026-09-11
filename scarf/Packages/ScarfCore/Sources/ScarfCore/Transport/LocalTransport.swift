import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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

    // MARK: - Environment enrichment

    /// Injection point for local-subprocess environment enrichment.
    /// Mirrors `SSHTransport.environmentEnricher` — the Mac app wires
    /// this at launch to `HermesFileService.enrichedEnvironment()`,
    /// which probes the user's login shell for PATH + credential env
    /// vars. Without it, GUI-launched Scarf hands subprocesses a
    /// stripped `/usr/bin:/bin:/usr/sbin:/sbin` PATH and child
    /// `hermes` invocations from inside spawned workers fail with
    /// `executable not found on PATH`.
    ///
    /// Set once at app launch (startup is single-threaded). Tests may
    /// inject a stub. iOS leaves this `nil` because LocalTransport
    /// doesn't run subprocesses there.
    nonisolated(unsafe) public static var environmentEnricher: (@Sendable () -> [String: String])?

    /// The `COLUMNS` handed to the Hermes subprocesses Scarf JUDGES BY OUTPUT,
    /// so `rich` does not wrap a line Scarf matches on. Wide enough that no
    /// marker line Hermes prints comes close, narrow enough to stay a
    /// plausible terminal.
    ///
    /// ## Exactly which spawns carry it
    ///
    /// - ``runProcess(executable:args:stdin:timeout:cwd:)`` locally, via
    ///   ``subprocessEnvironment(forExecutable:)`` — that is the one-shot CLI
    ///   path every ``HermesCLIVerdict`` call site runs through.
    /// - every remote command, via the prefix
    ///   ``SSHTransport/composedRemoteCommand(executable:args:cwd:)`` builds —
    ///   an ssh client's own environment does not cross to the remote shell.
    ///   That prefix is on the shared composer, so the remote ACP spawn gets
    ///   it too; harmless, and not something ACP reads.
    ///
    /// It is deliberately NOT on the LOCAL streaming spawns —
    /// ``streamLines(executable:args:)``, ``streamRawBytes(executable:args:)``
    /// and ``makeProcess(executable:args:cwd:)`` (the ACP spawn). Those
    /// inherit the app's environment rather than building one, and routing
    /// them through ``subprocessEnvironment(forExecutable:)`` for `COLUMNS`
    /// alone would also move PATH (which the enricher always overrides) and
    /// every other key the shell-harvested enricher supplies onto the ACP
    /// session — a real behaviour change for one setting nothing on those
    /// paths reads. Nothing streamed is judged by a `rich`-printed marker:
    /// `streamLines` tails log files (`HermesLogService`), `streamRawBytes`
    /// moves raw bytes (`cat`, `RemoteBackupService`), and ACP is
    /// newline-framed JSON-RPC.
    public static let wideColumns = "400"

    /// Build the environment dict for a single subprocess. Process
    /// env wins for keys it has; the enricher fills gaps + always
    /// owns PATH (which is the whole point of running it). The
    /// executable's parent directory is appended as a final fallback
    /// so `runProcess` works even before the enricher has been wired
    /// (during very early startup, in tests, etc.).
    nonisolated static func subprocessEnvironment(forExecutable executable: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let enricher = Self.environmentEnricher {
            let extra = enricher()
            for (key, value) in extra where !value.isEmpty {
                if key == "PATH" {
                    // Enricher always wins for PATH — that's the
                    // whole reason the enricher exists. The GUI
                    // process PATH is the broken thing we're
                    // replacing.
                    env[key] = value
                } else if (env[key] ?? "").isEmpty {
                    // For other keys (credential env, locale, etc.)
                    // an explicit non-empty value in the GUI
                    // environment wins; an empty or absent value
                    // gets filled by the shell-harvested copy.
                    env[key] = value
                }
            }
        }
        // `rich` wraps `console.print` at 80 columns when stdout is not a TTY
        // (`Console.width` falls back to `COLUMNS`, then to 80), and a pipe is
        // never a TTY. Scarf judges Hermes runs by matching whole printed
        // lines, so an 80-column wrap can split a marker in half: the live
        // case is `✓ Plugin <name> updated.` (`hermes_cli/plugins_cmd.py:828`
        // @ v2026.9.7), matched as a column-0 `Plugin ` prefix AND an
        // `updated.` tail, which a long plugin name pushes onto two lines.
        // A wide `COLUMNS` keeps Hermes's own lines intact. An explicit
        // value in the environment is left alone — the user (or a test) meant
        // it.
        if (env["COLUMNS"] ?? "").isEmpty { env["COLUMNS"] = Self.wideColumns }

        // Always make sure the executable's own directory is on PATH —
        // covers the case where the enricher hasn't been wired (tests,
        // pre-launch helpers) but a child process still tries to spawn
        // its sibling tools by bare name.
        let dir = (executable as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            let currentPATH = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let parts = currentPATH.split(separator: ":").map(String.init)
            if !parts.contains(dir) {
                env["PATH"] = "\(dir):\(currentPATH)"
            }
        }
        return env
    }

    // MARK: - Files

    public func readFile(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            // Normalize "it isn't there" to the same phrase `SSHTransport`
            // produces, so `TransportError.isNoSuchFile` means one thing on
            // both transports (GW-F6 / audit DI L1). Everything else keeps
            // its own message.
            if (error as NSError).code == NSFileReadNoSuchFileError,
               (error as NSError).domain == NSCocoaErrorDomain {
                throw TransportError.fileIO(path: path, underlying: "No such file or directory")
            }
            throw TransportError.fileIO(path: path, underlying: error.localizedDescription)
        }
    }

    public func unguardedWriteFile(_ path: String, data: Data) throws {
        do {
            // Ensure the parent dir exists — callers sometimes pass a
            // path whose parent hasn't been mkdir'd yet (e.g.,
            // `~/.hermes/memories/MEMORY.md` on a Hermes install that
            // never wrote memories before).
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            // Atomic write: stage the bytes in a temp file IN THE SAME
            // DIRECTORY, put the final mode on the temp, and only then
            // `rename(2)` it into place. Cross-platform (macOS + iOS +
            // Linux CI for tests) — `rename` is POSIX, and it replaces
            // the destination entry rather than following a symlink
            // planted there, which is the property the guarded writers'
            // `.bak`/`.corrupt-` copies rely on.
            //
            // WHY NOT `Data.write(options: .atomic)` ANY MORE (GW-F5 /
            // SEC F2). That call also renames a temp into place, but it
            // creates the temp with the process umask (0644 typically),
            // so the chmod could only happen AFTER the file was already
            // published: a brand-new `.env`, `.env.bak` or `auth.json`
            // was observable at its real path in a loose mode for the
            // length of that window, and the `try?` around the chmod
            // meant a failure left it there forever. `SSHTransport`
            // (chmod-then-mv in one remote command) and
            // `CitadelServerTransport` both fixed this the other way
            // round; this is the local side of the same rule, so all
            // three transports now decide the mode BEFORE the bytes are
            // reachable at their real name.
            //
            // Earlier this method used `FileManager.replaceItemAt`,
            // which is Apple-only — Linux swift-corelibs would fail.
            let dir = parent.isEmpty ? "." : parent
            let staging = dir + "/.scarf-write-" + UUID().uuidString + ".tmp"
            defer { try? FileManager.default.removeItem(atPath: staging) }
            try data.write(to: URL(fileURLWithPath: staging))
            if TransportPrivateMode.shouldEnforce(for: path) {
                // Files that conventionally hold secrets are owner-only
                // from the instant they exist under their real name.
                // NOT `try?`: a mode we could not set is a failed write,
                // not a quiet downgrade.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: staging
                )
            } else if let existing = try? FileManager.default.attributesOfItem(atPath: path),
                      let mode = existing[.posixPermissions] as? NSNumber {
                // Existing-file mode semantics, preserved (audit I2): a
                // rewrite must not re-permission a file the user or
                // Hermes deliberately tightened or loosened. Best effort
                // — an unreadable mode is not a reason to fail the write.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: mode], ofItemAtPath: staging
                )
            }
            guard rename(staging, path) == 0 else {
                throw TransportError.fileIO(
                    path: path,
                    underlying: "publish failed: \(String(cString: strerror(errno)))"
                )
            }
        } catch let error as TransportError {
            throw error
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
        // Hand subprocesses an environment that includes the user's
        // login-shell PATH. Without this, `hermes` (pipx-installed at
        // `~/.local/bin/hermes`) ends up running with macOS's GUI
        // launch-services PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), and
        // when Hermes itself shells out to spawn a worker (e.g. the
        // kanban dispatcher invoking `hermes` by name from a Python
        // subprocess), it returns "executable not found on PATH" and
        // the run records `outcome=spawn_failed`. Mirrors the SSH
        // transport's environmentEnricher hook and is wired by
        // `scarfApp.swift` at launch.
        proc.environment = Self.subprocessEnvironment(forExecutable: executable)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if stdin != nil { proc.standardInput = stdinPipe }
        let pipeCapture = ProcessPipeDrainer.start(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
        do {
            try proc.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            if stdin != nil {
                try? stdinPipe.fileHandleForReading.close()
            }
            _ = pipeCapture.wait()
            throw TransportError.other(message: "Failed to launch \(executable): \(error.localizedDescription)")
        }
        // Parent has its own copy of every pipe end after fork. The child
        // inherits and uses the writing ends of stdout/stderr and the
        // reading end of stdin; the parent must close its own copies of
        // those so EOF reaches the parent's reader once the child exits
        // (otherwise the kernel keeps each fd open as long as any process
        // holds a reference, and we leak fds).
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if stdin != nil {
            try? stdinPipe.fileHandleForReading.close()
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
                proc.waitUntilExit()
                let captured = pipeCapture.wait()
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                throw TransportError.timeout(seconds: timeout, partialStdout: captured.stdout)
            }
        } else {
            proc.waitUntilExit()
        }
        let captured = pipeCapture.wait()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
        return ProcessResult(exitCode: proc.terminationStatus, stdout: captured.stdout, stderr: captured.stderr)
        #endif
    }

    #if !os(iOS)
    public func makeProcess(executable: String, args: [String]) -> Process {
        makeProcess(executable: executable, args: args, cwd: nil)
    }

    public func makeProcess(executable: String, args: [String], cwd: String?) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        // Spawn FROM the project dir so Hermes loads its AGENTS.md (Hermes
        // reads project context files from the process cwd). Guard on an
        // existing DIRECTORY so a stale/missing/non-dir path degrades to the
        // default cwd instead of making `run()` throw and killing the session.
        var isDir: ObjCBool = false
        if let cwd, !cwd.isEmpty,
           FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        return proc
    }
    #endif

    public func streamRawBytes(executable: String, args: [String]) -> AsyncThrowingStream<Data, Error> {
        #if os(iOS)
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
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                let handle = outPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    continuation.yield(chunk)
                }
                proc.waitUntilExit()
                let stderrTail: String
                if proc.terminationStatus != 0 {
                    stderrTail = (try? errPipe.fileHandleForReading.readToEnd())
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                } else {
                    stderrTail = ""
                }
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                if proc.terminationStatus != 0 {
                    continuation.finish(throwing: TransportError.commandFailed(
                        exitCode: proc.terminationStatus, stderr: stderrTail
                    ))
                } else {
                    continuation.finish()
                }
            }
        }
        #endif
    }

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
                // Parent's copy of the writing ends — the child has its
                // own; close ours so EOF reaches the reader after exit.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
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
                let stderrTail: String
                if proc.terminationStatus != 0 {
                    stderrTail = (try? errPipe.fileHandleForReading.readToEnd())
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                } else {
                    stderrTail = ""
                }
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                if proc.terminationStatus != 0 {
                    continuation.finish(throwing: TransportError.commandFailed(
                        exitCode: proc.terminationStatus, stderr: stderrTail
                    ))
                } else {
                    continuation.finish()
                }
            }
        }
        #endif
    }

    // MARK: - Script streaming

    /// Run `script` through `/bin/sh -c` locally. Local data path
    /// doesn't actually call this in production (the data service
    /// hands `LocalSQLiteBackend` the libsqlite3-direct path) — kept
    /// for protocol parity and for tooling that wants a uniform
    /// "run a script" entry on either context kind.
    public func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        #if os(iOS)
        throw TransportError.other(message: "LocalTransport.streamScript is unavailable on iOS")
        #else
        let outcome = await SSHScriptRunner.run(
            script: script,
            context: ServerContext(id: contextID, displayName: "Local", kind: .local),
            timeout: timeout
        )
        switch outcome {
        case .connectFailure(let reason):
            throw TransportError.other(message: reason)
        case .completed(let stdout, let stderr, let exitCode):
            return ProcessResult(
                exitCode: exitCode,
                stdout: Data(stdout.utf8),
                stderr: Data(stderr.utf8)
            )
        }
        #endif
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

}
