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
    private let stdoutReader: PipeLineReader
    private let stderrReader: PipeLineReader

    /// Read by `ACPClient` to fill in `processTerminated(exitCode:…)`
    /// so the error names the actual exit code rather than reporting a
    /// bare timeout. Sourced directly from `Process` — `Process` is
    /// thread-safe for this read and reflects the actual reap state,
    /// so we sidestep the race between the OS-side `terminationHandler`
    /// callback and the EOF-driven disconnect cleanup that would
    /// otherwise need an atomic to coordinate.
    public var lastExitCode: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

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
        try await Self.launch(process: proc)
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

        self.stdoutReader = PipeLineReader(
            handle: stdoutPipe.fileHandleForReading,
            label: "com.scarf.acp.stdout",
            continuation: inContinuation,
            failOnInvalidUTF8: true
        )
        self.stderrReader = PipeLineReader(
            handle: stderrPipe.fileHandleForReading,
            label: "com.scarf.acp.stderr",
            continuation: errContinuation,
            failOnInvalidUTF8: false
        )
        installTerminationHandler()
    }

    /// Secondary entry point for callers that have a pre-configured
    /// `Process` (typically from `SSHTransport.makeProcess`). The process
    /// must NOT already be running — this initializer calls `run()`.
    public init(process: Process) async throws {
        try await Self.launch(process: process)
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

        self.stdoutReader = PipeLineReader(
            handle: stdoutPipe.fileHandleForReading,
            label: "com.scarf.acp.stdout",
            continuation: inContinuation,
            failOnInvalidUTF8: true
        )
        self.stderrReader = PipeLineReader(
            handle: stderrPipe.fileHandleForReading,
            label: "com.scarf.acp.stderr",
            continuation: errContinuation,
            failOnInvalidUTF8: false
        )
        installTerminationHandler()
    }

    /// Wire fresh stdin/stdout/stderr pipes (overwriting any the caller
    /// set) and start the subprocess.
    private static func launch(process: Process) async throws {
        process.standardInput  = Pipe()
        process.standardOutput = Pipe()
        process.standardError  = Pipe()
        do {
            try process.run()
        } catch {
            throw ACPChannelError.launchFailed(error.localizedDescription)
        }
    }

    /// Install a `terminationHandler` that tears down the stdout reader
    /// the moment the OS reaps the child. Without this, a grandchild
    /// that inherited the pipe's write end (ssh ControlMaster is the
    /// classic case) keeps the pipe open past the child's exit and EOF
    /// never arrives — visible to the user as a 30s ACP `initialize`
    /// timeout where a fast SSH-side failure (Connection refused,
    /// exit 127) should surface in under a second.
    ///
    /// The pre-2026-07 implementation closed the read `FileHandle`
    /// directly from this callback to unblock the `availableData`
    /// reader thread. The dispatch-source reader must not have its fd
    /// closed out from under it (read-after-close race), so we tear it
    /// down via `cancelAfterDrainingPipe()` instead: a non-blocking
    /// final drain (the child's last writes are already in the pipe;
    /// dropping them was a live race even pre-rework) followed by a
    /// cancel whose handler closes the fd on the reader's own queue,
    /// strictly after any in-flight read. The exit code itself is read
    /// on demand from `Process.terminationStatus` (see `lastExitCode`),
    /// so this callback doesn't need to touch actor state.
    private func installTerminationHandler() {
        let reader = stdoutReader
        process.terminationHandler = { _ in
            reader.cancelAfterDrainingPipe()
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

        // Close stdin so the child sees EOF and can flush. The stdout
        // reader will see the pipe close and finish naturally.
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
        // Our copies of the child-side write ends — closing them lets
        // the pipes EOF once the child is gone.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // Cancel the readers. Each reader's cancel handler closes its
        // read fd and finishes its stream from the reader's own serial
        // queue — strictly after any in-flight readability event — so
        // no read ever races a closed descriptor.
        stdoutReader.cancel()
        stderrReader.cancel()

        // Belt-and-braces immediate finish (matches the pre-2026-07
        // behavior of finishing synchronously inside close()); finishing
        // an already-finished stream is a no-op.
        incomingContinuation.finish()
        stderrContinuation.finish()
    }
}

// MARK: - Pipe line reader

/// Event-driven, non-blocking line reader for one pipe read end,
/// bridging readability events into an `AsyncThrowingStream` of
/// newline-delimited frames.
///
/// **Why not `Task.detached { availableData }`?** The previous
/// implementation parked a cooperative-pool thread inside a blocking
/// `read(2)` for the channel's entire lifetime — two threads per live
/// channel (stdout + stderr). The pool is sized at one thread per core;
/// a handful of live/wedged channels (leaked by start-failure paths)
/// starves it and stalls unrelated Swift-concurrency work — a confirmed
/// contributor to the S3 self-locking "Loading session…" wedge
/// (2026-07-13 diagnosis). A `DispatchSourceRead` parks zero threads
/// between events, and EOF (all write ends closed) is delivered
/// immediately instead of whenever a blocked read happens to return.
///
/// **Threading.** The event handler and cancel handler both run on the
/// private serial `queue`, so `buffer` needs no lock. libdispatch
/// guarantees the cancel handler runs strictly after any in-flight
/// event handler, and the fd is closed ONLY in the cancel handler — a
/// read can therefore never race a closed (or recycled) descriptor.
///
/// **Semantics preserved from the loop implementation:**
/// - frames split on `\n` (0x0A); the terminator is not included;
/// - empty lines are skipped;
/// - a trailing unterminated partial line at EOF is dropped;
/// - EOF (or a read error) finishes the stream cleanly;
/// - invalid UTF-8: stdout finishes the stream with
///   `ACPChannelError.invalidEncoding` and stops reading; stderr drops
///   the offending line silently and keeps going.
///
/// **Backpressure: none** — identical to the previous implementation.
/// Readability events drain the pipe as fast as the child writes and
/// buffer complete lines into the unbounded `AsyncThrowingStream`;
/// memory is bounded by the consumer keeping up. Acceptable here
/// because the only producer is `hermes acp`, whose frames are small
/// JSON-RPC lines consumed promptly by `ACPClient`'s read loop.
///
/// `@unchecked Sendable`: all mutable state (`buffer`) is confined to
/// the serial `queue`.
final class PipeLineReader: @unchecked Sendable {
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    /// Retained so the fd stays valid until the cancel handler closes
    /// it; the handle itself holds no reference back to this reader,
    /// so there is no retain cycle.
    private let handle: FileHandle
    private let fd: Int32
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let failOnInvalidUTF8: Bool
    /// Partial-line accumulation. Touched only on `queue`.
    private var buffer = Data()

    init(
        handle: FileHandle,
        label: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        failOnInvalidUTF8: Bool
    ) {
        self.handle = handle
        self.continuation = continuation
        self.failOnInvalidUTF8 = failOnInvalidUTF8
        let queue = DispatchQueue(label: label)
        self.queue = queue
        let fd = handle.fileDescriptor
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source

        // `[weak self]` — the source retains its handlers and we retain
        // the source; a strong `self` capture would cycle
        // reader → source → handler → reader.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = chunk.withUnsafeMutableBytes { buf -> Int in
                #if canImport(Darwin)
                Darwin.read(fd, buf.baseAddress, buf.count)
                #elseif canImport(Glibc)
                Glibc.read(fd, buf.baseAddress, buf.count)
                #else
                -1
                #endif
            }
            guard n > 0 else {
                // Retriable results are NOT stream-enders: EINTR (a
                // signal landed mid-read) and EAGAIN (spurious wake,
                // or `cancelAfterDrainingPipe` flipped the fd to
                // O_NONBLOCK while a final readability event was
                // already enqueued) leave the pipe alive — return and
                // let the level-triggered source fire again. Treating
                // them as EOF finished the stream early, which upstream
                // reads as "connection died".
                if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
                // 0 → EOF; any other error → the pipe is done: finish
                // cleanly (matching the loop reader's EOF path) and
                // cancel so the fd gets closed.
                continuation.finish()
                self.source.cancel()
                return
            }
            self.buffer.append(contentsOf: chunk[0..<n])
            self.drainLines(continuation: continuation, failOnInvalidUTF8: failOnInvalidUTF8)
        }

        source.setCancelHandler { [handle] in
            // The ONLY place the fd is closed — runs after any
            // in-flight event handler. Finishing twice is a no-op, so
            // this is safe after an EOF-driven finish too.
            continuation.finish()
            try? handle.close()
        }

        source.resume()
    }

    /// Stop reading: closes the fd and finishes the stream via the
    /// cancel handler (asynchronously, on the reader queue). Idempotent.
    func cancel() {
        source.cancel()
    }

    /// Drain whatever is already sitting in the pipe, then stop. Used
    /// by the process termination handler: the child is dead, so
    /// everything it wrote is in the pipe RIGHT NOW — but EOF may never
    /// arrive (a grandchild like ssh's ControlMaster can inherit the
    /// write end and keep it open), so we must not wait for it either.
    /// A non-blocking read loop on the reader queue picks up the final
    /// output (the old blocked-`availableData` reader usually won this
    /// race by being parked in the kernel already; a dispatch-source
    /// block under load can lose it, observed as dropped final lines in
    /// the channel test suite), then the source is cancelled as before.
    func cancelAfterDrainingPipe() {
        queue.async { [self] in
            if source.isCancelled { return }
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            while true {
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = chunk.withUnsafeMutableBytes { buf -> Int in
                    #if canImport(Darwin)
                    Darwin.read(fd, buf.baseAddress, buf.count)
                    #elseif canImport(Glibc)
                    Glibc.read(fd, buf.baseAddress, buf.count)
                    #else
                    -1
                    #endif
                }
                // EINTR: a signal interrupted the read — the pipe may
                // still hold final output, so retry rather than drop it.
                if n < 0 && errno == EINTR { continue }
                // 0 = EOF, -1 = EAGAIN (pipe empty) or error — done
                // either way; the child can't write anything more.
                guard n > 0 else { break }
                buffer.append(contentsOf: chunk[0..<n])
                drainLines(continuation: continuation, failOnInvalidUTF8: failOnInvalidUTF8)
            }
            source.cancel()
        }
    }

    deinit {
        // A resumed, uncancelled source must be cancelled before its
        // last reference goes away; idempotent if close()/EOF already
        // cancelled it.
        source.cancel()
    }

    /// Split complete `\n`-terminated frames out of `buffer` and yield
    /// them. Runs on `queue` only.
    private func drainLines(
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        failOnInvalidUTF8: Bool
    ) {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[buffer.startIndex..<nl])
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard !lineData.isEmpty else { continue }
            if let text = String(data: lineData, encoding: .utf8) {
                continuation.yield(text)
            } else if failOnInvalidUTF8 {
                continuation.finish(throwing: ACPChannelError.invalidEncoding)
                source.cancel()
                return
            }
            // else: non-UTF-8 stderr lines are dropped silently — we're
            // not going to crash the channel over a weird byte in a log
            // line (unchanged from the loop reader).
        }
    }
}

#endif // !os(iOS)
