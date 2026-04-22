// Gated on `canImport(Citadel)` so Linux CI skips the file.
#if canImport(Citadel)

import Foundation
import NIOCore
import Citadel
import ScarfCore

/// `ACPChannel` backed by a Citadel SSH exec session. iOS counterpart
/// to Mac's `ProcessACPChannel` — same protocol, different transport.
///
/// Citadel exposes an 8-bit-safe bidirectional exec channel via
/// `SSHClient.withExec(_:perform:)`. We drive it with a detached Task
/// that (a) calls `withExec` and handles its closure-scoped lifecycle,
/// (b) captures the `TTYStdinWriter` so our `send(_:)` can write
/// JSON-RPC lines, and (c) pumps stdout/stderr through line-framers
/// into the `incoming` / `stderr` `AsyncThrowingStream`s that
/// `ACPClient` consumes.
///
/// **Lifecycle**. Constructor is async; it spawns the exec task and
/// returns once the writer is available for the first `send(_:)`.
/// `close()` cancels the exec task — Citadel's `withExec` then closes
/// the SSH channel, which cleanly finishes the streams. If the iOS
/// side closed the `SSHClient` too (ownsClient), that happens after.
///
/// **Line framing**. Bytes arrive from Citadel in arbitrary-sized
/// `ByteBuffer` chunks — stdout/stderr may be split mid-line. We
/// buffer partial lines internally and only yield whole JSON-RPC
/// lines (newline-stripped) through `incoming` / `stderr`.
public actor SSHExecACPChannel: ACPChannel {
    private let client: SSHClient
    private let ownsClient: Bool

    public nonisolated let incoming: AsyncThrowingStream<String, Error>
    public nonisolated let stderr: AsyncThrowingStream<String, Error>
    private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
    private let stderrCont: AsyncThrowingStream<String, Error>.Continuation

    /// Populated once the exec session's `withExec` closure fires.
    /// `send(_:)` awaits this (first send may block ~handshake-time,
    /// subsequent sends are instant).
    private var writer: TTYStdinWriter?
    /// Continuations waiting on the writer.
    private var writerWaiters: [CheckedContinuation<TTYStdinWriter, Error>] = []
    private var isClosed = false

    /// Detached Task that drives `withExec`. Kept so we can cancel
    /// on `close()`.
    private var execTask: Task<Void, Never>?

    /// Partial-line buffers for the line framer.
    private var stdoutBuf = Data()
    private var stderrBuf = Data()

    public nonisolated var diagnosticID: String? { "citadel-exec" }

    /// Start the exec. `command` is typically the remote path to
    /// `hermes acp` (optionally with a leading `cd …; ` if cwd matters).
    /// `ownsClient` tells us whether to close the underlying `SSHClient`
    /// on `close()` — true when we opened a dedicated client for this
    /// channel; false when the client is shared with other features
    /// (file I/O transport, etc.).
    public init(
        client: SSHClient,
        command: String,
        ownsClient: Bool = false
    ) async throws {
        self.client = client
        self.ownsClient = ownsClient

        let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
        self.incoming = inStream
        self.incomingCont = inCont
        let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
        self.stderr = errStream
        self.stderrCont = errCont

        await startExecTask(client: client, command: command)
        // Wait for the exec session to hand us its stdin writer. If
        // anything fails before that, the exec task will surface the
        // error via the waiters queue.
        _ = try await waitForWriter()
    }

    private func startExecTask(client: SSHClient, command: String) {
        let inCont = incomingCont
        let errCont = stderrCont
        execTask = Task { [weak self] in
            do {
                try await client.withExec(command) { inbound, outbound in
                    await self?.writerBecameAvailable(outbound)
                    for try await event in inbound {
                        if Task.isCancelled { break }
                        switch event {
                        case .stdout(let buf):
                            await self?.ingest(buf, isStderr: false)
                        case .stderr(let buf):
                            await self?.ingest(buf, isStderr: true)
                        }
                    }
                }
                inCont.finish()
                errCont.finish()
                await self?.markClosed()
            } catch is CancellationError {
                inCont.finish()
                errCont.finish()
                await self?.markClosed()
            } catch {
                // Includes `SSHClient.CommandFailed(exitCode:)` when
                // the remote `hermes acp` exits non-zero. ACPClient
                // maps that to `.processTerminated` via its read-loop
                // error handler.
                await self?.failWriterWaiters(with: error)
                inCont.finish(throwing: error)
                errCont.finish(throwing: error)
                await self?.markClosed()
            }
        }
    }

    // MARK: - ACPChannel

    public func send(_ line: String) async throws {
        if isClosed { throw ACPChannelError.writeEndClosed }
        let w = try await waitForWriter()
        var buf = ByteBufferAllocator().buffer(capacity: line.utf8.count + 1)
        buf.writeString(line)
        buf.writeInteger(UInt8(ascii: "\n"))
        try await w.write(buf)
    }

    public func close() async {
        if isClosed { return }
        isClosed = true
        execTask?.cancel()
        execTask = nil

        // Fail any pending waiters so a racing `send(_:)` doesn't hang.
        failWriterWaiters(with: ACPChannelError.writeEndClosed)

        // Drain the line buffers once more so any final byte boundary
        // produces a valid line (e.g. if the remote process exits
        // after writing "…}\n"). Citadel's stream termination already
        // does this via yielding the trailing bytes before .exit(),
        // so this is belt-and-suspenders.
        if !stdoutBuf.isEmpty {
            if let text = String(data: stdoutBuf, encoding: .utf8), !text.isEmpty {
                incomingCont.yield(text)
            }
            stdoutBuf.removeAll()
        }
        incomingCont.finish()
        stderrCont.finish()

        if ownsClient {
            try? await client.close()
        }
    }

    // MARK: - Internal

    private func writerBecameAvailable(_ w: TTYStdinWriter) {
        writer = w
        let waiters = writerWaiters
        writerWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: w)
        }
    }

    private func failWriterWaiters(with error: Error) {
        let waiters = writerWaiters
        writerWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func markClosed() {
        isClosed = true
    }

    private func waitForWriter() async throws -> TTYStdinWriter {
        if let w = writer { return w }
        return try await withCheckedThrowingContinuation { cont in
            writerWaiters.append(cont)
        }
    }

    /// Called per stdout/stderr chunk from Citadel. Line-frame + yield.
    private func ingest(_ buffer: ByteBuffer, isStderr: Bool) {
        var buf = buffer
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        if isStderr {
            stderrBuf.append(contentsOf: bytes)
            while let nl = stderrBuf.firstIndex(of: 0x0A) {
                let line = Data(stderrBuf[stderrBuf.startIndex..<nl])
                stderrBuf = Data(stderrBuf[stderrBuf.index(after: nl)...])
                guard !line.isEmpty else { continue }
                if let text = String(data: line, encoding: .utf8) {
                    stderrCont.yield(text)
                }
            }
        } else {
            stdoutBuf.append(contentsOf: bytes)
            while let nl = stdoutBuf.firstIndex(of: 0x0A) {
                let line = Data(stdoutBuf[stdoutBuf.startIndex..<nl])
                stdoutBuf = Data(stdoutBuf[stdoutBuf.index(after: nl)...])
                guard !line.isEmpty else { continue }
                if let text = String(data: line, encoding: .utf8) {
                    incomingCont.yield(text)
                }
            }
        }
    }
}

#endif // canImport(Citadel)
