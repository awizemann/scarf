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

    /// Whether the child is still alive. Test seam for the close watchdog's
    /// escalation — the process itself stays private.
    var childIsRunning: Bool { process.isRunning }

    /// How long ``close()``'s watchdog waits between escalations — SIGINT,
    /// then SIGTERM, then SIGKILL. Two seconds each: long enough for a
    /// healthy `hermes acp` to flush and exit on the interrupt, short enough
    /// that a wedged one is bounded rather than permanent.
    static let closeGrace: TimeInterval = 2

    private var isClosed = false
    private let stdoutReader: PipeReader
    private let stderrReader: PipeReader

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

        self.stdoutReader = PipeReader.acpLines(
            handle: stdoutPipe.fileHandleForReading,
            label: "com.scarf.acp.stdout",
            continuation: inContinuation,
            failOnInvalidUTF8: true
        )
        self.stderrReader = PipeReader.acpLines(
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

        self.stdoutReader = PipeReader.acpLines(
            handle: stdoutPipe.fileHandleForReading,
            label: "com.scarf.acp.stdout",
            continuation: inContinuation,
            failOnInvalidUTF8: true
        )
        self.stderrReader = PipeReader.acpLines(
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
            // Watchdog: insist if still running after the grace. A stuck
            // child shouldn't keep the app's close() hanging.
            //
            // Round-6 P58: this escalated SIGINT → SIGTERM and stopped there,
            // so a child that traps or ignores both — a Python whose
            // `KeyboardInterrupt` handler is itself wedged, an `ssh` blocked
            // in an uninterruptible read on a half-open connection — survived
            // the watchdog entirely, and the "force-kill" the comment
            // promised never happened. Same escalation the rest of the app
            // uses (`Process.waitUntilExit(timeout:)`, `HermesProxyService
            // .stop()`): ask, wait a bounded grace, then SIGKILL, pid-guarded
            // because `kill(0, …)` signals the whole process group — Scarf
            // included. `isRunning` means it launched, so a non-positive pid
            // should be impossible, which is why it is asserted rather than
            // trusted (round-5 P48b's proxy Stop shape).
            //
            // P58b: the SIGTERM step is `kill(pid, SIGTERM)`, not
            // `terminate()`. `guard watchdog.isRunning` is a CHECK, not a
            // hold — the child can be reaped in the gap between the guard and
            // the call, and `Process.terminate()` on a reaped process raises
            // an ObjC exception, which in Swift is an untrappable crash.
            // `kill(2)` on a stale pid cannot trap: it returns ESRCH, or at
            // worst signals a recycled pid. **The residual window is pid
            // recycling** — between the guard and the `kill` the kernel could
            // hand this number to an unrelated process, and neither this
            // shape nor `terminate()` can close that without a pidfd; it is
            // accepted here because the gap is one statement wide and the two
            // signals are the ones a wedged child had two `closeGrace`
            // windows to answer.
            let watchdog = process
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(Self.closeGrace * 1_000_000_000))
                guard watchdog.isRunning else { return }
                let pid = watchdog.processIdentifier
                guard pid > 0 else { return }
                kill(pid, SIGTERM)
                try? await Task.sleep(nanoseconds: UInt64(Self.closeGrace * 1_000_000_000))
                guard watchdog.isRunning else { return }
                kill(pid, SIGKILL)
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

#endif // !os(iOS)
