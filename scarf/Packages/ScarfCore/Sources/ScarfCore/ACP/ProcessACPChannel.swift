// iOS can't spawn subprocesses (no `Process`, sandboxed away from fork/exec).
// Everything below only makes sense on platforms that can — macOS and Linux.
// iOS gets its ACP transport from a future `SSHExecACPChannel` (Citadel)
// landing in M4.
#if !os(iOS)

import Foundation

/// `ACPChannel` backed by a `Foundation.Process` spawning `hermes acp`
/// (local) or `ssh -T host -- hermes acp` (remote, via
/// `SSHTransport.makeProcess`). Owns the process lifecycle, stdin/stdout
/// pipes, and a small ring-buffered stderr capture for diagnostics.
///
/// The per-call `send(_:)` path uses raw POSIX `write(2)` instead of
/// `FileHandle.write` — `FileHandle.write` crashes the whole app on
/// EPIPE (broken pipe) rather than throwing, so the original ACPClient
/// installed a `SIGPIPE` handler and a POSIX-write helper. That logic
/// moves here intact.
public actor ProcessACPChannel: ACPChannel {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    /// Cached raw file descriptor for the stdin write end. Captured on
    /// init because `Process.standardInput` gets nilled after `close()`.
    private let stdinFd: Int32

    private let incomingContinuation: AsyncThrowingStream<String, Error>.Continuation
    /// Retain the stream — callers get it lazily; we stash it here so the
    /// continuation doesn't outlive its producer.
    public nonisolated let incoming: AsyncThrowingStream<String, Error>
    private let stderrContinuation: AsyncThrowingStream<String, Error>.Continuation
    public nonisolated let stderr: AsyncThrowingStream<String, Error>

    private var isClosed = false
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    /// The subprocess's PID as a human-readable string.
    public var diagnosticID: String? {
        "pid=\(process.processIdentifier)"
    }

    /// Spawn `executable` with `args`, wiring its stdin/stdout/stderr into
    /// this channel. `env` is passed verbatim to the subprocess (callers
    /// are responsible for running it through whatever enrichment they
    /// need — this layer doesn't know about `SSH_AUTH_SOCK` or PATH).
    ///
    /// For remote contexts, the Mac caller passes a pre-configured
    /// `Process` via `init(process:)` below — `SSHTransport.makeProcess`
    /// already set up the ssh argv.
    public init(
        executable: String,
        args: [String],
        env: [String: String]
    ) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.environment = env
        try await Self.launch(process: proc, self_: nil)
        try Self.ignoreSIGPIPE_once()

        self.process = proc
        self.stdinPipe  = proc.standardInput  as! Pipe
        self.stdoutPipe = proc.standardOutput as! Pipe
        self.stderrPipe = proc.standardError  as! Pipe
        self.stdinFd = stdinPipe.fileHandleForWriting.fileDescriptor

        let (inStream, inContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.incoming = inStream
        self.incomingContinuation = inContinuation

        let (errStream, errContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.stderr = errStream
        self.stderrContinuation = errContinuation

        await startReaders()
    }

    /// Secondary entry point for callers that have a pre-configured
    /// `Process` (typically from `SSHTransport.makeProcess`). The process
    /// must NOT already be running — this initializer calls `run()`.
    public init(process: Process) async throws {
        try await Self.launch(process: process, self_: nil)
        try Self.ignoreSIGPIPE_once()

        self.process = process
        self.stdinPipe  = process.standardInput  as! Pipe
        self.stdoutPipe = process.standardOutput as! Pipe
        self.stderrPipe = process.standardError  as! Pipe
        self.stdinFd = stdinPipe.fileHandleForWriting.fileDescriptor

        let (inStream, inContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.incoming = inStream
        self.incomingContinuation = inContinuation

        let (errStream, errContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.stderr = errStream
        self.stderrContinuation = errContinuation

        await startReaders()
    }

    /// Wire fresh stdin/stdout/stderr pipes (overwriting any the caller
    /// set) and start the subprocess. `self_` is unused today — the
    /// placeholder keeps the signature ready for a future hook that
    /// captures termination in `proc.terminationHandler` and routes it
    /// into the channel's actor state.
    private static func launch(process: Process, self_: Any?) async throws {
        process.standardInput  = Pipe()
        process.standardOutput = Pipe()
        process.standardError  = Pipe()
        do {
            try process.run()
        } catch {
            throw ACPChannelError.launchFailed(error.localizedDescription)
        }
    }

    /// Ignore SIGPIPE once per process so a broken-pipe write returns
    /// `EPIPE` (which we surface as `.writeEndClosed`) instead of
    /// delivering SIGPIPE and tearing the app down. Idempotent; the
    /// kernel is fine with repeated `SIG_IGN` installs.
    nonisolated private static func ignoreSIGPIPE_once() throws {
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Send

    public func send(_ line: String) async throws {
        guard !isClosed else { throw ACPChannelError.writeEndClosed }
        guard var data = line.data(using: .utf8) else {
            throw ACPChannelError.invalidEncoding
        }
        data.append(0x0A) // '\n'
        let fd = stdinFd
        // POSIX write, looping on partial writes and surfacing EPIPE as
        // `.writeEndClosed`. Crucial: `FileHandle.write(_:)` crashes the
        // app on EPIPE rather than throwing; the original ACPClient used
        // this same `Darwin.write` (or `Glibc.write` on Linux) technique.
        let ok = Self.safeWrite(fd: fd, data: data)
        if !ok {
            throw ACPChannelError.writeEndClosed
        }
    }

    nonisolated private static func safeWrite(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            var written = 0
            let total = buf.count
            while written < total {
                #if canImport(Darwin)
                let result = Darwin.write(fd, base.advanced(by: written), total - written)
                #elseif canImport(Glibc)
                let result = Glibc.write(fd, base.advanced(by: written), total - written)
                #else
                return false
                #endif
                if result <= 0 { return false }
                written += result
            }
            return true
        }
    }

    // MARK: - Close

    public func close() async {
        guard !isClosed else { return }
        isClosed = true

        // Close stdin so the child sees EOF and can flush. readerTask
        // will see the pipe close and finish naturally.
        stdinPipe.fileHandleForWriting.closeFile()

        if process.isRunning {
            // SIGINT for graceful Python shutdown — raises KeyboardInterrupt
            // cleanly instead of aborting in the middle of a JSON write.
            process.interrupt()
            // Watchdog: force-kill if still running after 2s. A stuck
            // child shouldn't keep the app's close() hanging.
            let watchdog = process
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if watchdog.isRunning { watchdog.terminate() }
            }
        }

        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()

        readerTask?.cancel()
        stderrTask?.cancel()
        incomingContinuation.finish()
        stderrContinuation.finish()
    }

    // MARK: - Reader loops

    private func startReaders() {
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        let inCont = incomingContinuation
        let errCont = stderrContinuation

        readerTask = Task.detached {
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = outHandle.availableData
                if chunk.isEmpty { break } // EOF
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex..<nl])
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    guard !lineData.isEmpty else { continue }
                    if let text = String(data: lineData, encoding: .utf8) {
                        inCont.yield(text)
                    } else {
                        inCont.finish(throwing: ACPChannelError.invalidEncoding)
                        return
                    }
                }
            }
            inCont.finish()
        }

        stderrTask = Task.detached {
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = errHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex..<nl])
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    guard !lineData.isEmpty else { continue }
                    if let text = String(data: lineData, encoding: .utf8) {
                        errCont.yield(text)
                    }
                    // Non-UTF-8 stderr lines are dropped silently;
                    // we're not going to crash the channel over a
                    // weird byte in a log line.
                }
            }
            errCont.finish()
        }
    }
}

#endif // !os(iOS)
