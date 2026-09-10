import Foundation

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
    func waitUntilExit(timeout: TimeInterval, pollInterval: TimeInterval = 0.05) -> Bool {
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
}
