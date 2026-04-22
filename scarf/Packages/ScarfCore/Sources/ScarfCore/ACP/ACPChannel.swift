import Foundation

/// The bidirectional line-oriented transport that `ACPClient` speaks
/// JSON-RPC over. Abstracts away whether the other end is a local
/// `hermes acp` subprocess (macOS) or a remote SSH exec channel (iOS via
/// Citadel in M4+). ACPClient never touches `Process`, `Pipe`, file
/// descriptors, or SSH sessions directly — it just sends and receives
/// newline-delimited JSON lines over one of these.
///
/// **Line framing.** Senders pass a JSON object serialized to a single
/// line (no embedded `\n`). The channel appends the terminator itself.
/// The receiver yields one complete JSON line per `incoming` element;
/// partial lines are buffered internally until a newline arrives.
///
/// **Lifecycle.** A channel is "already live" when you hold a reference —
/// the constructor (or channel-factory call) spawns the subprocess / opens
/// the SSH exec channel. `close()` tears down and causes `incoming` /
/// `stderr` to finish. After `close()`, `send(_:)` throws.
///
/// **Errors.** Transport errors (broken pipe, SSH disconnect, process
/// died) surface as an error-terminated `incoming` stream — consumers
/// should be prepared for that, not just for clean `.finished` stream
/// termination. `send(_:)` also throws on these.
public protocol ACPChannel: Sendable {
    /// Append `\n` and write atomically. Thread-safe (the actor boundary
    /// is on the implementation side, not the protocol).
    func send(_ line: String) async throws

    /// One complete JSON-RPC line per element, without the trailing
    /// newline. Yields in arrival order. Finishes (clean or error) when
    /// the underlying transport closes.
    var incoming: AsyncThrowingStream<String, Error> { get }

    /// Diagnostic stderr. For `ProcessACPChannel` this is the spawned
    /// process's stderr, line-buffered. For future SSH-exec channels
    /// where stderr folds into events, this is an empty stream.
    /// Lines are yielded without the trailing newline.
    var stderr: AsyncThrowingStream<String, Error> { get }

    /// Request graceful shutdown. Closes stdin first (so the remote side
    /// sees EOF and can flush), then waits briefly for the subprocess /
    /// exec channel to exit, then force-terminates. Idempotent — calling
    /// `close()` on an already-closed channel is a no-op.
    func close() async

    /// Short identifier for logs. Process channels return the child PID;
    /// SSH exec channels return the SSH channel id or `nil` when not
    /// applicable.
    var diagnosticID: String? { get async }
}

/// Errors raised by `ACPChannel` implementations when the underlying
/// transport breaks. JSON-RPC errors (the remote returning an `error`
/// field) are not in this enum — they ride as valid `incoming` lines and
/// are ACPClient's problem to decode.
public enum ACPChannelError: Error, LocalizedError {
    /// The underlying subprocess or SSH exec channel exited. `exitCode`
    /// is the subprocess exit status (or a synthetic value for SSH).
    case closed(exitCode: Int32)
    /// `send(_:)` was called on a channel whose write end is already
    /// closed. Typically means a previous `close()` call or a pipe
    /// broken by a remote termination.
    case writeEndClosed
    /// Bytes sent or received couldn't be encoded/decoded as UTF-8.
    /// Hermes emits only UTF-8; hitting this usually means a framing
    /// bug or random binary junk on the channel.
    case invalidEncoding
    /// Failed to launch the subprocess or open the SSH exec channel.
    case launchFailed(String)
    /// Catch-all for everything else with a context string.
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .closed(let code): return "ACP channel closed (exit \(code))"
        case .writeEndClosed:   return "ACP channel write end is closed"
        case .invalidEncoding:  return "ACP channel carried non-UTF-8 bytes"
        case .launchFailed(let msg): return "Failed to launch ACP channel: \(msg)"
        case .other(let msg): return msg
        }
    }
}
