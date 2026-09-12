import Foundation
import os

// `Process` does not exist in the iOS SDK. Every Scarf spawn is a Mac-side
// operation; the iOS half of ScarfCore compiles without this file rather
// than carrying a stub nothing can call.
#if !os(iOS)

/// Bounded waits for `Process`, shared by the Mac app target and ScarfCore.
///
/// **This lives in ScarfCore, not the app target.** It was written in the app
/// (round-3 P33, hoisted out of `HealthViewModel.dashboardListenerPID`), but
/// ScarfCore has spawns of its own — `unzip`/`zip` in `RemoteRestoreService`
/// and `RemoteBackupService`, the sole C10 exposure the round-4 audit found —
/// and a package cannot import its client. A second copy down here would be
/// two implementations of the one rule the charter states once, so the single
/// definition moved DOWN and the app target reaches it through
/// `import ScarfCore` like every other shared primitive (round-4 P43,
/// decision 15).
extension Process {
    /// Wait for this process to exit, giving up after `timeout` seconds.
    ///
    /// Charter C10: "every subprocess has a timeout." `waitUntilExit()` alone
    /// waits forever, which is only safe when the child is guaranteed to be
    /// short — and nothing is: `lsof` blocks in the kernel on a stuck NFS or
    /// FUSE mount, and any spawn can be stopped by a debugger or a full pipe.
    /// On a main-actor call path that is a frozen window.
    ///
    /// Polls rather than using a `terminationHandler` semaphore so it stays
    /// usable from plain synchronous code (the transport layer's own timeout
    /// loop has the same shape).
    ///
    /// **Every wait in here is bounded, including the overrun path.** The first
    /// version of this helper finished with `terminate(); waitUntilExit()` — a
    /// bare, unbounded wait, which re-introduced exactly the hang the helper
    /// exists to remove. A child that installs `SIGTERM` to ignore, or that is
    /// wedged in an uninterruptible kernel sleep (the stuck-mount case above),
    /// never reaps, so the overrun arm was only bounded for a child that would
    /// have been easy anyway. Escalation is now SIGTERM → bounded poll →
    /// SIGKILL → bounded poll, and the call returns either way.
    ///
    /// - Returns: `true` if the process exited on its own within the budget.
    ///   `false` after an overrun. On an overrun it has been sent SIGTERM and,
    ///   if that did not take, SIGKILL — so the caller is never BLOCKED by a
    ///   runaway child. Note this is not a promise that the child is gone: a
    ///   process stuck in an uninterruptible wait cannot be killed by anyone,
    ///   and `isRunning` may still be true when this returns `false`.
    @discardableResult
    public func waitUntilExit(timeout: TimeInterval, pollInterval: TimeInterval = 0.05) -> Bool {
        /// Poll for at most `budget` seconds. `true` when the child went away.
        func poll(_ budget: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(budget)
            while isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
            }
            return !isRunning
        }

        if poll(timeout) { return true }

        // Overrun. Ask politely, then insist — each with its own bounded
        // window, never a bare `waitUntilExit()`. The grace windows are short
        // and fixed: the caller's budget is already spent, and this path runs
        // only when the child has already outstayed it.
        terminate()
        if poll(Self.signalGrace) { return false }
        // Guard the pid: `kill(0, …)` signals the WHOLE process group, which
        // includes Scarf itself. `isRunning` being true means it launched, so
        // this should never be 0 — which is exactly why it is worth asserting
        // rather than trusting.
        if processIdentifier > 0 {
            kill(processIdentifier, SIGKILL)
            _ = poll(Self.signalGrace)
        }
        return false
    }

    /// How long to wait for a signal to take effect before escalating (or
    /// giving up). Small on purpose — the caller's own budget is already gone.
    private static let signalGrace: TimeInterval = 2

    /// The `async` twin of ``waitUntilExit(timeout:pollInterval:)``.
    ///
    /// Same rule as ``waitDrainingAsync(timeout:drain:drainGrace:)``: the
    /// synchronous form is a `Thread.sleep` poll loop, so an `async` caller
    /// parks a COOPERATIVE-POOL thread — one per core, unable to grow — for
    /// the whole budget. That is true of the ESCALATION arm too, which is
    /// where this twin earns its keep: `waitUntilExit(timeout: 0)` is the
    /// house spelling for "the deadline is gone, stop this child now", and
    /// even that can sleep through two `signalGrace` windows before it
    /// returns. Round-5 P48 added it after the widened `ProcessAsyncWait`
    /// sweep found eleven such calls sitting directly in `Task` closures.
    public func waitUntilExitAsync(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(
                    returning: self.waitUntilExit(
                        timeout: timeout, pollInterval: pollInterval))
            }
        }
    }

    /// Wait for a piped child within `timeout`, draining its pipes
    /// CONCURRENTLY with the wait, and hand back what they held.
    ///
    /// Charter C10 has two halves at a piped spawn and the ad-hoc call sites
    /// kept getting one of them:
    ///
    /// 1. **The wait must be bounded.** `waitUntilExit()` alone waits forever.
    /// 2. **The drain must not come AFTER the wait.** `run` → `waitUntilExit`
    ///    → `readToEnd` is the classic pipe deadlock: a child that fills the
    ///    64 KB pipe buffer blocks in `write()` while the parent waits for an
    ///    exit that can no longer come — so the "bounded" wait in (1) is the
    ///    only thing that saves it, and it saves it by killing a child that
    ///    was working fine. Reading after an overrun's SIGTERM/SIGKILL also
    ///    collects only what a killed writer happened to flush.
    ///
    /// `unzip`/`zip` are the real exposure: a corrupt or adversarial archive
    /// makes them print a warning per entry, and a big enough one fills the
    /// buffer. This is `HealthViewModel.dashboardListenerPID`'s shape, hoisted
    /// so the three remaining ad-hoc spawns share it instead of each growing a
    /// third of it (round-3 P33).
    ///
    /// **This owns the READ ends' lifetime.** Each reading handle is closed
    /// by the reader that drained it, immediately after its own
    /// `readDataToEndOfFile` returned — never by the caller. Closing a
    /// `FileHandle` while another thread is blocked reading it is a raised
    /// `NSFileHandleOperationException`, and on the drain-overrun path (a
    /// grandchild inherited the fd and holds the pipe open) that is exactly
    /// what a caller-side `close()` after this returns would do. The caller's
    /// own `closePipes()` keeps the WRITE ends, which nobody else touches.
    ///
    /// - Returns: `exited` is false after an overrun (the child has been
    ///   SIGTERMed and then SIGKILLed); the drained data is whatever arrived
    ///   either way.
    public func waitDraining(
        timeout: TimeInterval,
        pipes: [Pipe],
        drainGrace: TimeInterval = Process.drainGrace
    ) -> (exited: Bool, data: [Data]) {
        waitDraining(
            timeout: timeout,
            drain: Process.startDraining(pipes: pipes),
            drainGrace: drainGrace
        )
    }

    /// Install the readers NOW and hand back the token to collect them with.
    ///
    /// ``waitDraining(timeout:pipes:)`` starts the readers and waits in one
    /// call, which is right whenever the parent has nothing left to do. It is
    /// WRONG whenever the parent still has to feed the child: a caller that
    /// pumps a file into the child's stdin and only then calls the combined
    /// form has no reader installed for the whole pump, so a child that fills
    /// its 64 KB stderr buffer stops reading stdin, the parent blocks forever
    /// inside `write()`, and the bounded wait that would have rescued it is
    /// never reached at all (round-4 P43b, `RemoteRestoreService.pushTarball`).
    ///
    /// Split the two halves in that case: `startDraining` immediately after a
    /// successful `run()`, then ``waitDraining(timeout:drain:drainGrace:)``
    /// once the pump is done. Read-end ownership is unchanged — the drain owns
    /// them and closes each one itself.
    public static func startDraining(pipes: [Pipe]) -> ProcessPipeDrain {
        ProcessPipeDrain(pipes: pipes)
    }

    /// Wait for this process within `timeout`, then collect a drain that was
    /// started earlier by ``startDraining(pipes:)``.
    public func waitDraining(
        timeout: TimeInterval,
        drain: ProcessPipeDrain,
        drainGrace: TimeInterval = Process.drainGrace
    ) -> (exited: Bool, data: [Data]) {
        let exited = waitUntilExit(timeout: timeout)
        // Bounded, like every other wait here: EOF arrives when the last
        // write end closes, which is at exit — but a fd inherited by a
        // grandchild would otherwise hold the read open forever.
        return (exited, drain.collect(grace: drainGrace))
    }

    /// The `async` twin of ``waitDraining(timeout:drain:drainGrace:)``.
    ///
    /// **Never call the synchronous form from an `async` function.** It is a
    /// `Thread.sleep` poll loop, so an `async` caller parks a COOPERATIVE-POOL
    /// thread for as long as the budget runs — up to
    /// `RemoteRestoreService.remoteExtractTimeout` (300 s) at the tarball push.
    /// That pool has one thread per core and no way to grow: a handful of
    /// those and every other task in the process stops, including the ones the
    /// UI is suspended on. The forward progress rule Swift states for actors
    /// is the same rule here.
    ///
    /// So the reap moves onto a thread that is allowed to block and the caller
    /// suspends on a continuation instead. Same move as
    /// `SpotifyAuthFlow.reapDetached`, which made it for the main actor's sake;
    /// round-4 P43c generalises it, and `ProcessAsyncWaitP43cTests` fails if an
    /// `async func` in ScarfCore reaches for the synchronous spelling again.
    public func waitDrainingAsync(
        timeout: TimeInterval,
        drain: ProcessPipeDrain,
        drainGrace: TimeInterval = Process.drainGrace
    ) async -> (exited: Bool, data: [Data]) {
        await withCheckedContinuation { continuation in
            // A DEDICATED thread, not `Task.detached` and not a GCD global
            // queue. `Task.detached` runs on the same cooperative pool the
            // caller is on, so it would move the block one hop and change
            // nothing; a global queue is a pool too, capped per QoS, and
            // parking one of its threads for up to five minutes is precisely
            // the misuse that starves everything else queued behind it. A
            // thread is the cheap, correct primitive for a wait that is
            // BOUNDED and mostly asleep — see `ProcessPipeDrain` for the same
            // reasoning about its readers (round-4 P43c).
            Thread.detachNewThread {
                continuation.resume(
                    returning: self.waitDraining(
                        timeout: timeout, drain: drain, drainGrace: drainGrace))
            }
        }
    }

    /// The `async` twin of ``waitDraining(timeout:pipes:drainGrace:)``.
    ///
    /// The readers are installed synchronously, BEFORE the first suspension —
    /// `startDraining` runs while this call's arguments are evaluated — so the
    /// drain is in place from the same instant it would be in the synchronous
    /// form.
    public func waitDrainingAsync(
        timeout: TimeInterval,
        pipes: [Pipe],
        drainGrace: TimeInterval = Process.drainGrace
    ) async -> (exited: Bool, data: [Data]) {
        await waitDrainingAsync(
            timeout: timeout,
            drain: Process.startDraining(pipes: pipes),
            drainGrace: drainGrace
        )
    }

    /// How long to wait for a drained pipe to reach EOF after the child has
    /// gone. See ``waitDraining(timeout:pipes:drainGrace:)``.
    ///
    /// `public` only because it is `waitDraining`'s default argument, and a
    /// default argument on public API cannot name a narrower symbol.
    public static let drainGrace: TimeInterval = 1
}

/// The readers `Process.startDraining(pipes:)` installed, and the handle the
/// caller collects them with.
///
/// One per spawn: the readers are running from the moment this is created, so
/// an instance cannot be reused across runs. ``collect(grace:)`` is idempotent
/// — the second call returns the same data without waiting again.
public final class ProcessPipeDrain: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock(initialState: [Int: Data]())
    private let group = DispatchGroup()
    private let count: Int
    /// The latch, and the gate that makes it one. Held ACROSS the wait, not
    /// merely across the read and the write of `collected`: the two-lock-scope
    /// version was a check-then-set, so two callers could both find it empty,
    /// both wait, and each return whatever had arrived by its own deadline —
    /// two different answers to a call documented as idempotent, with the
    /// second one overwriting the first's latch. An `NSLock` rather than
    /// `OSAllocatedUnfairLock` precisely because it IS held across a blocking
    /// wait, which is not what an unfair lock is for (round-4 P43c).
    private let gate = NSLock()
    private var collected: [Data]?

    fileprivate init(pipes: [Pipe]) {
        count = pipes.count
        for (index, pipe) in pipes.enumerated() {
            let reader = pipe.fileHandleForReading
            group.enter()
            // **A thread per reader, not a global-queue block.**
            // `readDataToEndOfFile` blocks until the child closes its end,
            // which is unbounded from this side, and GCD's global queues are
            // a fixed-width pool: a process with several piped spawns in
            // flight — `swift test` is exactly that — can park every thread
            // of the `.utility` queue in a read and leave the NEXT spawn's
            // drain unscheduled, so the child it was meant to unblock fills
            // its 64 KB stderr buffer and wedges. That is the deadlock this
            // whole file exists to prevent, re-entered through the back door
            // (round-4 P43c). A blocking read belongs on its own thread.
            Thread.detachNewThread { [box, group] in
                let data = reader.readDataToEndOfFile()
                // The drain owns the READ ends: each reader closes the handle
                // it drained, immediately after its own read returned. A
                // caller-side close while this thread is still blocked in the
                // read raises.
                try? reader.close()
                box.withLock { $0[index] = data }
                group.leave()
            }
        }
    }

    /// Everything the readers have produced, waiting at most `grace` for the
    /// last EOF. One slot per pipe, in the order they were passed.
    public func collect(grace: TimeInterval = Process.drainGrace) -> [Data] {
        gate.lock()
        defer { gate.unlock() }
        if let collected { return collected }
        _ = group.wait(timeout: .now() + grace)
        let snapshot = box.withLock { $0 }
        let data = (0..<count).map { snapshot[$0] ?? Data() }
        collected = data
        return data
    }
}

#endif
