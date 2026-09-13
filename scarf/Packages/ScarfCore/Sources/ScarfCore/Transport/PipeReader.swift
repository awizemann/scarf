// iOS can't spawn subprocesses, so nothing here has an iOS meaning.
#if !os(iOS)

import Foundation

/// Event-driven, non-blocking reader for one pipe read end.
///
/// **Why this exists at all.** The shape it replaces is
/// `Task.detached { while true { handle.availableData } }`, which parks a
/// cooperative-pool thread inside a blocking `read(2)` for the whole life of
/// the stream. The pool is one thread per core and cannot grow, so a handful
/// of live streams starves every other task in the process — including the
/// ones the main actor is awaiting. That is charter C10, and it is the
/// confirmed contributor to the 2026-07-13 "Loading session…" wedge that the
/// ACP channel was moved off in the first place. A `DispatchSourceRead` parks
/// ZERO threads between readability events, and EOF (all write ends closed)
/// is delivered immediately instead of whenever a blocked read happens to
/// return.
///
/// This was `ProcessACPChannel`'s private `PipeLineReader`. Round-6 P58
/// (decision 10) hoisted it here so the four streaming spawns
/// (`LocalTransport`/`SSHTransport` × `streamLines`/`streamRawBytes`) could
/// use it rather than grow a second copy — round-5 P48's lesson that "a
/// defect fixed in one primitive does not reach a second copy of that
/// primitive, and a second copy is invisible precisely because it has a
/// different name."
///
/// **Threading.** The event handler and the cancel handler both run on the
/// private serial `queue`, so the mutable state needs no lock. libdispatch
/// guarantees the cancel handler runs strictly after any in-flight event
/// handler, and the fd is closed ONLY in the cancel handler — a read can
/// therefore never race a closed (or recycled) descriptor. **The reader owns
/// the read end**: callers must not close the handle themselves.
///
/// **Backpressure: none** — identical to the loop implementation. Events
/// drain the pipe as fast as the child writes; memory is bounded by the
/// consumer keeping up. Acceptable for the shapes that use it: ACP's small
/// JSON-RPC frames, and log tails whose consumer is a SwiftUI list.
///
/// `@unchecked Sendable`: all mutable state lives in `Sink`, which is
/// confined to the serial `queue`.
final class PipeReader: @unchecked Sendable {

    /// How bytes are framed before they reach the sink.
    enum Framing: Sendable {
        /// Yield every read verbatim as `Data`. No framing, no decoding.
        case rawChunks
        /// Split on `\n` (0x0A); the terminator is not included.
        ///
        /// - `failOnInvalidUTF8`: a frame that is not valid UTF-8 ends the
        ///   stream with `.invalidUTF8` (ACP stdout, where a frame that
        ///   cannot be decoded cannot be parsed either) rather than being
        ///   dropped silently (ACP stderr, log tails).
        /// - `deliverPartialAtEOF`: emit a trailing UNTERMINATED line when
        ///   the pipe reaches EOF. False for ACP, where a partial frame is
        ///   an unparseable half-JSON object; true for the streaming
        ///   transports, where the child's last line legitimately may not
        ///   end in a newline and dropping it loses user-visible output.
        /// - `skipEmpty`: drop a zero-length frame (a blank line) instead of
        ///   yielding `""`. **The two line semantics differ and neither is
        ///   the default**: ACP skips, because an empty JSON-RPC frame is
        ///   nothing and a reader that yields `""` makes the decoder parse
        ///   it; the streaming transports do NOT, because their consumer is
        ///   `HermesLogService`'s Logs pane and a blank line is a separator
        ///   the user wrote and expects to see. P58 hoisted this primitive
        ///   out of ACP and carried ACP's skip with it, silently deleting
        ///   every blank line from the Logs pane — hence the explicit
        ///   parameter (round-6 lesson 10: a parameter that IS the fix gets
        ///   no default).
        case lines(failOnInvalidUTF8: Bool, deliverPartialAtEOF: Bool, skipEmpty: Bool)
    }

    /// Why the reader stopped.
    enum FinishReason: Sendable {
        /// EOF, a read error, or `cancel()`. The normal end.
        case eof
        /// A frame failed UTF-8 decoding under `failOnInvalidUTF8: true`.
        case invalidUTF8
    }

    enum Event: Sendable {
        case line(String)
        case chunk(Data)
        /// Delivered EXACTLY once, after any partial-line flush.
        case finished(FinishReason)
    }

    /// Every piece of mutable state, plus the sink itself. Held strongly by
    /// BOTH dispatch handlers, so `.finished` is still delivered once if the
    /// `PipeReader` itself has already been released. Queue-confined.
    private final class Sink: @unchecked Sendable {
        let framing: Framing
        let emit: @Sendable (Event) -> Void
        var buffer = Data()
        var done = false

        init(framing: Framing, emit: @escaping @Sendable (Event) -> Void) {
            self.framing = framing
            self.emit = emit
        }

        /// Feed one read's worth of bytes. Returns false when the reader
        /// must stop (a decode failure under `failOnInvalidUTF8`).
        func deliver(_ data: Data) -> Bool {
            if done { return false }
            switch framing {
            case .rawChunks:
                emit(.chunk(data))
                return true
            case .lines(let failOnInvalidUTF8, _, let skipEmpty):
                buffer.append(data)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex..<nl])
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    if lineData.isEmpty {
                        // A blank line: nothing to decode either way, so the
                        // only question is whether the sink wants to see it.
                        if !skipEmpty { emit(.line("")) }
                        continue
                    }
                    if let text = String(data: lineData, encoding: .utf8) {
                        emit(.line(text))
                    } else if failOnInvalidUTF8 {
                        finish(.invalidUTF8)
                        return false
                    }
                    // else: a weird byte in a log line is not worth ending
                    // the stream over (unchanged from the loop reader).
                }
                return true
            }
        }

        /// Deliver `.finished` once, flushing a trailing partial line first
        /// where the framing asks for it.
        func finish(_ reason: FinishReason) {
            if done { return }
            done = true
            // An EMPTY buffer at EOF is not a partial line — it means the
            // last line ended in `\n` and was already emitted (blank lines
            // included, under `skipEmpty: false`). Only a genuinely
            // unterminated tail is flushed here.
            if reason == .eof,
               case .lines(_, let deliverPartialAtEOF, _) = framing,
               deliverPartialAtEOF, !buffer.isEmpty,
               let text = String(data: buffer, encoding: .utf8) {
                emit(.line(text))
            }
            buffer = Data()
            emit(.finished(reason))
        }
    }

    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    /// Retained so the fd stays valid until the cancel handler closes it;
    /// the handle holds no reference back, so there is no retain cycle.
    private let handle: FileHandle
    private let fd: Int32
    private let sink: Sink

    init(
        handle: FileHandle,
        label: String,
        framing: Framing,
        sink emit: @escaping @Sendable (Event) -> Void
    ) {
        self.handle = handle
        let sink = Sink(framing: framing, emit: emit)
        self.sink = sink
        let queue = DispatchQueue(label: label)
        self.queue = queue
        let fd = handle.fileDescriptor
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source

        // `[weak self]` — the source retains its handlers and we retain the
        // source; a strong `self` capture would cycle
        // reader → source → handler → reader. `sink` is captured strongly on
        // purpose (see its doc).
        source.setEventHandler { [weak self, sink] in
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
                // Retriable results are NOT stream-enders: EINTR (a signal
                // landed mid-read) and EAGAIN (spurious wake, or
                // `cancelAfterDrainingPipe` flipped the fd to O_NONBLOCK
                // while a final readability event was already enqueued)
                // leave the pipe alive — return and let the level-triggered
                // source fire again. Treating them as EOF finished the
                // stream early, which upstream reads as "connection died".
                if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
                // 0 → EOF; any other error → the pipe is done.
                sink.finish(.eof)
                self?.source.cancel()
                return
            }
            if !sink.deliver(Data(chunk[0..<n])) {
                self?.source.cancel()
            }
        }

        source.setCancelHandler { [handle, sink] in
            // The ONLY place the fd is closed — runs after any in-flight
            // event handler. The close comes FIRST so that a consumer which
            // acts on `.finished` (a test probing the descriptor, a caller
            // closing the other end) cannot observe a still-open fd; `finish`
            // is idempotent, so this is safe after an EOF-driven finish too.
            try? handle.close()
            sink.finish(.eof)
        }

        source.resume()
    }

    /// Stop reading: closes the fd and delivers `.finished` via the cancel
    /// handler (asynchronously, on the reader queue). Idempotent.
    func cancel() {
        source.cancel()
    }

    /// Drain whatever is already sitting in the pipe, then stop. Used by the
    /// process termination handler: the child is dead, so everything it
    /// wrote is in the pipe RIGHT NOW — but EOF may never arrive (a
    /// grandchild like ssh's ControlMaster can inherit the write end and
    /// keep it open), so we must not wait for it either. A non-blocking read
    /// loop on the reader queue picks up the final output (the old
    /// blocked-`availableData` reader usually won this race by being parked
    /// in the kernel already; a dispatch-source block under load can lose
    /// it, observed as dropped final lines in the channel test suite), then
    /// the source is cancelled as before.
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
                // EINTR: a signal interrupted the read — the pipe may still
                // hold final output, so retry rather than drop it.
                if n < 0 && errno == EINTR { continue }
                // 0 = EOF, -1 = EAGAIN (pipe empty) or error — done either
                // way; the child can't write anything more.
                guard n > 0 else { break }
                if !sink.deliver(Data(chunk[0..<n])) { break }
            }
            source.cancel()
        }
    }

    deinit {
        // A resumed, uncancelled source must be cancelled before its last
        // reference goes away; idempotent if close()/EOF already did it.
        source.cancel()
    }
}

// MARK: - ACP convenience

extension PipeReader {
    /// The `ProcessACPChannel` shape: newline frames into an
    /// `AsyncThrowingStream<String, Error>`, no trailing partial line (a
    /// half-written JSON-RPC frame is not a frame), empty frames skipped (an
    /// empty JSON-RPC frame is nothing), and an invalid-UTF8 frame ends the
    /// stdout stream with `ACPChannelError.invalidEncoding`. **This is the
    /// only caller that skips empties** — the streaming transports yield
    /// `""` for a blank log line.
    static func acpLines(
        handle: FileHandle,
        label: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        failOnInvalidUTF8: Bool
    ) -> PipeReader {
        PipeReader(
            handle: handle,
            label: label,
            framing: .lines(
                failOnInvalidUTF8: failOnInvalidUTF8,
                deliverPartialAtEOF: false,
                // An empty JSON-RPC frame is nothing; ACP has always skipped
                // blank lines and this factory is the ONLY place that does.
                skipEmpty: true
            )
        ) { event in
            switch event {
            case .line(let text):
                continuation.yield(text)
            case .chunk:
                break // unreachable under `.lines`
            case .finished(let reason):
                switch reason {
                case .eof:
                    continuation.finish()
                case .invalidUTF8:
                    continuation.finish(throwing: ACPChannelError.invalidEncoding)
                }
            }
        }
    }
}

// MARK: - Awaiting the reader's end

/// A one-shot "the reader is done" latch that an `async` caller can await.
///
/// `PipeReader` reports EOF on its own serial queue, but the streaming
/// transports must not finish their continuation there: the verdict (exit
/// code, stderr) is only known after the child is reaped. So they await this,
/// reap, and finish with the real outcome.
///
/// Signalling before anyone waits is the normal case (a child that exits
/// while the spawning task is still between statements), so `signal()` latches
/// and a later `wait()` returns immediately. Signalling twice is a no-op —
/// `PipeReader` promises `.finished` exactly once, but the cancel path can
/// reach this from two directions and a double resume of a continuation traps.
///
/// **ONE waiter. This latch is not a broadcast** (P60, stated rather than
/// changed). `waiter` is a single slot, so a second concurrent `wait()`
/// OVERWRITES the first continuation and that first caller is never resumed —
/// it hangs until its own task is cancelled. Every call site today is
/// one-await-per-signal: each streaming spawn constructs its own signal and
/// awaits it from the single task that owns the spawn, which is why a single
/// slot is the honest shape rather than a latent bug. If a second waiter is
/// ever needed, hold an ARRAY of continuations and resume all of them in
/// `signal()` — do not simply add the call and hope the timing works out.
final class PipeEOFSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

#endif // !os(iOS)
