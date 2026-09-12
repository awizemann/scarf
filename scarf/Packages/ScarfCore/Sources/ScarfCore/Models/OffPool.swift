import Foundation

/// The house way to run BLOCKING work from an `async` context.
///
/// Charter C10's second half. `Task.detached { … }` gets the work off the
/// MAIN actor, which is what the P22/P43c/P48 sweeps were asking for — but a
/// detached task still runs on the Swift concurrency COOPERATIVE POOL, which
/// holds one thread per core and cannot grow. Work that blocks its thread
/// (a `Thread.sleep` poll loop, an SSH round-trip, a `swift_once` waiting on
/// two `zsh` probes at 5 s + 3 s) parks one of those threads for its whole
/// duration, and enough of them at once starves every other task in the
/// process — including the ones the main actor is awaiting.
///
/// So blocking work gets a thread of its OWN. This is the same shape
/// ``Foundation/Process/waitUntilExitAsync(timeout:pollInterval:)`` already
/// is — `withCheckedContinuation` + `Thread.detachNewThread` — hoisted so the
/// non-`Process` call sites (round-5 P51 created three, and two more were
/// already there) stop spelling it `Task.detached`. `Thread.detachNewThread`
/// is also the opt-out the P22 main-actor sweep already recognises.
///
/// **Cancellation:** a `Thread` cannot be cancelled, so `work` always runs to
/// completion and the AWAIT is what a cancelled caller abandons — the result
/// is dropped, never the work. That is exactly the behaviour the
/// `Task.detached { … }.value` sites had (a detached task inherits no
/// cancellation either, and `Task.value` on a non-throwing task cannot throw
/// one), so callers keep their existing `guard !Task.isCancelled` after the
/// hop. Do not hand this long-running or repeating work: one call is one
/// thread, so it is for bounded, blocking, one-shot work.
public enum OffPool {

    /// Run `work` on a dedicated thread and resume the caller with its value.
    public static func run<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: work())
            }
        }
    }
}
