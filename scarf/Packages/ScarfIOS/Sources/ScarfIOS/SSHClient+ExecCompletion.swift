// Gated on `canImport(Citadel)` like every Citadel-touching file —
// Linux CI can't resolve Citadel; iOS + macOS compile it normally.
#if canImport(Citadel)

import Citadel
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

extension SSHClient {
    /// `withExec` whose final `channel.close()` tolerates a channel the
    /// remote already closed.
    ///
    /// **Why this exists.** Citadel's `withExec` (TTY.swift:456) runs the
    /// closure, then `try await channel.close()` unconditionally — on the
    /// success path AND in its catch. But the inbound stream only ends when
    /// `ExecCommandHandler.handlerRemoved` fires, i.e. once the child
    /// channel is already closed. NIOSSH fails a close on a closed child
    /// channel with `ChannelError.alreadyClosed` (`SSHChildChannel.swift:332`),
    /// which Foundation bridges as the opaque "NIOCore.ChannelError error 6".
    /// So every exec whose command finished before the closure returned —
    /// which is every normal one — threw AFTER its output was collected, and
    /// a non-zero exit's `CommandFailed` was replaced by the same close error.
    /// The dashboard's 6 ms `sqlite3` preflight hit it on every load; chat
    /// only survived because its channel stays open for the session.
    ///
    /// **What it keeps.** Everything P48 wanted from `withExec`: the channel
    /// is still closed when the closure throws (a timeout, a cancellation),
    /// because Citadel still runs its close in that path. This wrapper only
    /// decides which error the caller sees: the closure's own error always
    /// wins, and an `alreadyClosed` from the trailing close is dropped
    /// because a closed channel is exactly the state we wanted.
    func withExecTolerantClose(
        _ command: String,
        environment: [SSHChannelRequestEvent.EnvironmentRequest] = [],
        perform: (_ inbound: TTYOutput, _ outbound: TTYStdinWriter) async throws -> Void
    ) async throws {
        let performError = ExecClosureError()
        do {
            try await withExec(command, environment: environment) { inbound, outbound in
                do {
                    try await perform(inbound, outbound)
                } catch {
                    performError.store(error)
                    throw error
                }
            }
        } catch {
            if let original = performError.value {
                throw original
            }
            if Self.isAlreadyClosed(error) {
                return
            }
            throw error
        }
    }

    /// True for the "close on an already-closed channel" outcome only. Any
    /// other `ChannelError` (or error type) is a real failure and propagates.
    static func isAlreadyClosed(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError, case .alreadyClosed = channelError {
            return true
        }
        return false
    }
}

/// Carries the closure's own error across `withExec`'s catch, which would
/// otherwise replace it with the close error. Plain class + lock: the value
/// is written once from inside the closure and read once after.
final class ExecClosureError: @unchecked Sendable {
    private let lock = NIOLock()
    private var stored: Error?
    func store(_ error: Error) { lock.withLock { stored = error } }
    var value: Error? { lock.withLock { stored } }
}

#endif // canImport(Citadel)
