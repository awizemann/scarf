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
        let box = OSAllocatedUnfairLock(initialState: [Int: Data]())
        let group = DispatchGroup()
        for (index, pipe) in pipes.enumerated() {
            let reader = pipe.fileHandleForReading
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = reader.readDataToEndOfFile()
                try? reader.close()
                box.withLock { $0[index] = data }
                group.leave()
            }
        }
        let exited = waitUntilExit(timeout: timeout)
        // Bounded, like every other wait here: EOF arrives when the last
        // write end closes, which is at exit — but a fd inherited by a
        // grandchild would otherwise hold the read open forever.
        _ = group.wait(timeout: .now() + drainGrace)
        let collected = box.withLock { $0 }
        return (exited, (0..<pipes.count).map { collected[$0] ?? Data() })
    }

    /// How long to wait for a drained pipe to reach EOF after the child has
    /// gone. See ``waitDraining(timeout:pipes:drainGrace:)``.
    ///
    /// `public` only because it is `waitDraining`'s default argument, and a
    /// default argument on public API cannot name a narrower symbol.
    public static let drainGrace: TimeInterval = 1
}

#endif
