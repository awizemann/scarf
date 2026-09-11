import Foundation

/// The reader side's hand-off buffer for a streamed `Process`: text
/// accumulates here in READ order on the pipe's own queue, and the main actor
/// drains it whenever one of its hops lands.
///
/// ## Why this exists rather than appending straight to the view model
///
/// `Pipe.fileHandleForReading.readabilityHandler` fires on Foundation's own
/// queue, so each read has to hop to the main actor to mutate observable
/// state — and each hop is an INDEPENDENT `Task { @MainActor }`. Those hops
/// are not ordered relative to one another, so a controller that appends
/// inside the hop can apply chunk 2 before chunk 1, and can judge the run
/// before the chunk carrying the verdict has been applied at all. Sequencing
/// the text where it is PRODUCED rather than where it is applied is what
/// makes the unordered hops harmless.
///
/// `markEOF` is the other half: EOF is a property of the reader, not of the
/// process, and a verdict taken at `terminationHandler` time is taken before
/// the pipe has reported it. `drain()` hands both back together so the
/// consumer can hold the verdict until EOF and the exit status are BOTH in.
///
/// **One per run.** A single instance reset per run re-opens the race: the
/// reader's `append`/`markEOF` carry no generation check (they run on the
/// pipe's queue), so a retired run's reader writes into — and can `markEOF` —
/// the replacement run's buffer. With a fresh inbox per run a stale reader
/// writes into a buffer nothing will ever drain.
public final class ProcessOutputInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var eof = false

    public init() {}

    public func append(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock(); pending += text; lock.unlock()
    }

    public func markEOF() {
        lock.lock(); eof = true; lock.unlock()
    }

    /// Everything buffered since the last drain, plus whether the reader has
    /// reported EOF.
    public func drain() -> (text: String, sawEOF: Bool) {
        lock.lock()
        defer { pending = ""; lock.unlock() }
        return (pending, eof)
    }
}
