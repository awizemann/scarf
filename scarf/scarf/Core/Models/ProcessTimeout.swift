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
    /// - Returns: `true` if the process exited on its own within the budget.
    ///   `false` after an overrun, in which case it has been sent SIGTERM and
    ///   reaped — the caller never leaves a runaway child behind.
    @discardableResult
    func waitUntilExit(timeout: TimeInterval, pollInterval: TimeInterval = 0.05) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        guard isRunning else { return true }
        terminate()
        waitUntilExit()
        return false
    }
}
