import Foundation

#if !os(iOS)
/// The child process behind an `AsyncThrowingStream`, so the stream's
/// `onTermination` can reach it.
///
/// Round-5 decision 6. The four streaming spawns — `streamLines` and
/// `streamRawBytes` on each Mac transport — installed no `onTermination` at
/// all, so a consumer that stopped iterating (a log tail whose pane closed, a
/// backup the user cancelled, a `Task` cancelled anywhere upstream) left the
/// child running with nobody reading its stdout: it filled the 64 KB pipe
/// buffer, blocked in `write()`, and stayed there. The producer task was
/// parked in `availableData` on the same pipe, so it never noticed either.
/// A remote one of those is an `ssh` holding a ControlMaster channel open.
///
/// The box exists because `onTermination` is installed BEFORE `run()` has
/// returned — the consumer can cancel during the spawn — so the cancel and
/// the adoption race. Whichever arrives second does the reaping.
///
/// Reaping is `waitUntilExit(timeout: 0)`: the deadline is already gone by
/// definition (the consumer is no longer listening), so this is SIGTERM →
/// bounded poll → pid-guarded SIGKILL → bounded poll with no initial wait. It
/// runs on a THREAD and not `Task.detached`, because the primitive is a
/// `Thread.sleep` poll loop and `Task.detached` is the same cooperative pool
/// the caller is on (round-4 P43c).
final class StreamingChild: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    /// The stdout reader, once the spawn has one. Cancelling it closes the
    /// read end and delivers EOF, which is what lets the producer task stop
    /// waiting and reap — without it, a consumer that walks away leaves the
    /// task parked on `PipeEOFSignal.wait()` until the child happens to die.
    private var reader: PipeReader?
    private var settled = false

    /// The spawn succeeded. Hand the child over, or reap it immediately if
    /// the consumer already gave up while `run()` was in flight.
    func adopt(_ process: Process) {
        lock.lock()
        let alreadySettled = settled
        if !alreadySettled { proc = process }
        lock.unlock()
        if alreadySettled { Self.reap(process) }
    }

    /// The stdout reader is live. Same race as `adopt`: a consumer that gave
    /// up while the spawn was in flight has already settled us, so the reader
    /// is cancelled here instead of being stored.
    func adoptReader(_ pipeReader: PipeReader) {
        lock.lock()
        let alreadySettled = settled
        if !alreadySettled { reader = pipeReader }
        lock.unlock()
        if alreadySettled { pipeReader.cancel() }
    }

    /// The consumer is gone. Stop the child.
    func cancel() {
        lock.lock()
        settled = true
        let process = proc
        let pipeReader = reader
        proc = nil
        reader = nil
        lock.unlock()
        pipeReader?.cancel()
        if let process { Self.reap(process) }
    }

    /// The producer ran to completion; the child reaped itself.
    func finish() {
        lock.lock()
        settled = true
        proc = nil
        // The producer is past EOF, so the reader has already cancelled
        // itself; drop our reference so the fd's owner goes away with it.
        reader = nil
        lock.unlock()
    }

    private static func reap(_ process: Process) {
        guard process.isRunning else { return }
        Thread.detachNewThread {
            _ = process.waitUntilExit(timeout: 0)
        }
    }

    /// How long a streaming spawn waits for its child to reap after stdout
    /// has reached EOF.
    ///
    /// Short on purpose: EOF means the child has already closed its end, so a
    /// healthy one is a few milliseconds from exiting. This is the ceiling
    /// for the unhealthy case — an `ssh` whose ControlMaster teardown wedges,
    /// or a grandchild still holding the fd — where the old bare
    /// `waitUntilExit()` simply never returned.
    static let reapCeiling: TimeInterval = 10
}
#endif
