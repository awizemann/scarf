import Testing
import Foundation
@testable import ScarfCore

/// Round-5 P52 — ``OffPool``, the house helper for blocking work.
///
/// `Task.detached` gets work off the MAIN actor and leaves it on the
/// cooperative pool, which is one thread per core and cannot grow. Blocking
/// work there (an SSH `readFile`, a `swift_once` waiting on two `zsh` probes
/// at 5 s + 3 s) parks a thread every other task is competing for. P48 wrote
/// the rule down; P51 then reached for `Task.detached` three more times, so
/// the shape that actually works — `withCheckedContinuation` +
/// `Thread.detachNewThread`, which `Process.waitUntilExitAsync` already was —
/// is now one named helper with its own tests.
@Suite("OffPool runs blocking work on its own thread (P52)")
struct OffPoolP52Tests {

    @Test("the work runs on a thread that is neither the caller's nor main")
    func runsOffTheCallersThread() async {
        // Compared by mach thread port, not `Thread` identity: `Thread` is
        // not `Sendable`, and the port is what distinguishes a fresh thread.
        let caller = pthread_mach_thread_np(pthread_self())
        let result = await OffPool.run { () -> (value: Int, thread: UInt32, isMain: Bool) in
            (41 + 1, pthread_mach_thread_np(pthread_self()), Thread.isMainThread)
        }
        #expect(result.value == 42)
        #expect(result.thread != caller)
        #expect(!result.isMain)
    }

    /// The property the cooperative pool cannot give: N blocking calls at
    /// once make N threads, so none of them waits on another.
    ///
    /// Proved by RENDEZVOUS, not by the clock. Each of 32 concurrent calls
    /// announces its arrival and then blocks until every one of them has
    /// arrived — which can only happen if all 32 are running at once. A
    /// fixed-width pool (one thread per core) cannot get past its own width,
    /// so a regression fails on the arrival wait instead of on a stopwatch.
    /// P48's lesson against timing bets: the first draft of this test
    /// compared elapsed time against a fraction of the serial total, and it
    /// went red in the full parallel `swift test` run purely from machine
    /// load, which is exactly the flake that teaches people to ignore a suite.
    @Test("N blocking calls do not queue behind one another")
    func blockingCallsDoNotSerialise() async {
        let count = 32
        // A CEILING, not a budget. `allArrived` failed 2 of 6 full parallel
        // runs on P58b's reviewer's machine at 10 s: 32 threads all reaching
        // their rendezvous is a load bet when the rest of the suite is also
        // spawning. Under the REGRESSION the 32nd call never arrives at all,
        // so the ceiling is only ever paid in full when the suite is red —
        // same reasoning as `StreamingSpawnPipeReaderP58Tests`' park test.
        let bound: DispatchTimeInterval = .seconds(60)
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        async let workers: Void = withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    await OffPool.run {
                        arrived.signal()
                        // Bounded so a regression FAILS rather than hangs the
                        // host; only ever reached on the failure path.
                        _ = release.wait(timeout: .now() + bound)
                    }
                }
            }
            await group.waitForAll()
        }

        // The collection itself blocks, so it goes through the helper too —
        // `DispatchSemaphore.wait` is unavailable from an async context, for
        // the very reason this whole suite is about.
        let allArrived = await OffPool.run { () -> Bool in
            for _ in 0..<count where arrived.wait(timeout: .now() + bound) == .timedOut {
                return false
            }
            return true
        }
        for _ in 0..<count { release.signal() }
        await workers

        #expect(allArrived, """
            Not all \(count) blocking calls were running at once — they are \
            sharing a fixed-width pool instead of getting a thread each.
            """)
    }

    /// A `Thread` cannot be cancelled, so the documented contract is that the
    /// RESULT is dropped, never the work. Pinned because a caller reading
    /// "off-main" as "cancellable" would write a cleanup that never runs.
    @Test("cancelling the caller does not cancel the work")
    func cancellationDropsTheResultNotTheWork() async {
        let ran = Ran()
        let task = Task {
            _ = await OffPool.run { ran.mark() }
            return Task.isCancelled
        }
        task.cancel()
        let sawCancellation = await task.value
        #expect(sawCancellation)
        #expect(ran.value)
    }

    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func mark() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
