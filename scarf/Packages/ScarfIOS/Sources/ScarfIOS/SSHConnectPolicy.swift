// Gated on `canImport(Citadel)` like every Citadel-touching file —
// Linux CI can't resolve Citadel; iOS + macOS compile it normally.
#if canImport(Citadel)

import Foundation
import Citadel
import NIOCore
#if canImport(os)
import os
#endif

/// Shared connect policy for every `SSHClient.connect` funnel — the
/// pooled transport's `ConnectionHolder` and the ACP chat channel.
///
/// **Why retries exist.** Citadel hard-codes a 10-second SSH *login*
/// timeout (`ClientHandshakeHandler(loginTimeout: .seconds(10))`), and
/// the clock starts when the channel is initialized — i.e. it must
/// cover TCP connect + key exchange + auth. A cold Tailscale path on
/// cellular (CGNAT usually forces the first packets through a DERP
/// relay while NAT traversal warms up) routinely blows through that
/// window, surfacing as `NIOCore.ChannelError error 0` — which is
/// `connectTimeout`, NOT `connectPending`: Swift numbers bridged enum
/// error codes by ABI tag, payload cases first, and `connectTimeout`
/// is `ChannelError`'s first payload case. The same host connects in
/// well under a second on Wi-Fi/LAN, which is why users report the
/// failure as cellular-only. By the second attempt the tunnel is warm
/// and the handshake almost always fits, so a short in-place retry
/// converts a hard error into a slow first connect.
enum SSHConnectPolicy {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "SSHConnectPolicy")
    #endif

    /// Total attempts when the failure is the SSH login/connect timeout.
    static let maxAttempts = 3
    /// Pause between attempts. Short — the failed attempt itself already
    /// gave the tunnel 10+ seconds to warm up.
    static let retryDelayNanoseconds: UInt64 = 1_500_000_000

    /// Run `open`, retrying up to `maxAttempts` times when the failure
    /// is a connect/login timeout. Every other error propagates
    /// immediately — retrying a rejected key or an unreachable host
    /// just burns time (and can trip sshd's per-source penalties).
    /// Generic so tests can exercise the retry contract without a live
    /// `SSHClient`.
    static func connect<T: Sendable>(
        retryDelayNanoseconds: UInt64 = SSHConnectPolicy.retryDelayNanoseconds,
        _ open: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await open()
            } catch {
                guard isTimeout(error), attempt < maxAttempts else { throw error }
                #if canImport(os)
                logger.info("SSH connect attempt \(attempt) timed out; retrying (\(attempt + 1)/\(Self.maxAttempts))")
                #endif
                attempt += 1
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
    }

    /// True for the two timeout shapes a connect can produce: NIO's
    /// TCP connect timeout and Citadel's hard-coded 10s login timeout
    /// (both surface as `ChannelError.connectTimeout`).
    static func isTimeout(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError,
           case .connectTimeout = channelError {
            return true
        }
        return false
    }

    /// Human-readable text for a final connect failure, replacing the
    /// opaque bridged forms ("NIOCore.ChannelError error 0",
    /// "Citadel.SSHClientError error 4") users have been pasting into
    /// bug reports.
    static func describeConnectFailure(_ error: Error, host: String) -> String {
        if isTimeout(error) {
            return "SSH login to \(host) timed out after \(maxAttempts) attempts. "
                + "Slow or relayed routes (for example Tailscale over cellular before a direct "
                + "connection is established) can exceed the 10-second SSH login window. "
                + "Check that the host is awake and reachable, then retry — a warm route usually succeeds."
        }
        if let clientError = error as? SSHClientError,
           case .allAuthenticationOptionsFailed = clientError {
            return "\(host) rejected this device's SSH key. "
                + "Make sure this server entry's public key is in ~/.ssh/authorized_keys on the host "
                + "(Servers → this server shows the key), or re-run onboarding for this server."
        }
        return error.localizedDescription
    }
}

#endif // canImport(Citadel)
