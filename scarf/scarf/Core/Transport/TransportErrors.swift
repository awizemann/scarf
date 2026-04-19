import Foundation

/// Typed errors surfaced by `ServerTransport` implementations. The UI
/// distinguishes these so user-visible messages can be specific
/// ("authentication failed" vs. "command failed") without having to grep
/// stderr strings.
enum TransportError: LocalizedError {
    /// `ssh`/`scp` could not reach the host or hit a protocol-level issue
    /// (name resolution, connection refused, route error).
    case hostUnreachable(host: String, stderr: String)
    /// Remote rejected our credentials. Typically means no ssh-agent key is
    /// loaded, or the loaded keys don't match any `authorized_keys` entry.
    case authenticationFailed(host: String, stderr: String)
    /// Remote `~/.ssh/known_hosts` fingerprint no longer matches. Blocking —
    /// we never auto-accept on mismatch.
    case hostKeyMismatch(host: String, stderr: String)
    /// The command ran on the remote but exited non-zero.
    case commandFailed(exitCode: Int32, stderr: String)
    /// Local filesystem operation failed (read/write/stat) with the OS error
    /// message attached.
    case fileIO(path: String, underlying: String)
    /// Timed out waiting for a process to finish. `partialStdout` carries
    /// whatever output was captured before the timer fired.
    case timeout(seconds: TimeInterval, partialStdout: Data)
    /// Something we didn't plan for. Fall-through bucket with enough context
    /// for a bug report.
    case other(message: String)

    var errorDescription: String? {
        switch self {
        case .hostUnreachable(let host, _):
            return "Can't reach \(host). Check the hostname, network, and SSH config."
        case .authenticationFailed(let host, _):
            return "SSH authentication to \(host) failed. Ensure your key is loaded in ssh-agent."
        case .hostKeyMismatch(let host, _):
            return "Host key for \(host) has changed. Inspect ~/.ssh/known_hosts before continuing."
        case .commandFailed(let code, let stderr):
            // Trim stderr to a single line for the summary; full text is in
            // the associated value for disclosure views.
            let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? ""
            return "Remote command exited \(code). \(firstLine)"
        case .fileIO(let path, let msg):
            return "File I/O failed at \(path): \(msg)"
        case .timeout(let secs, _):
            return "Command timed out after \(Int(secs))s."
        case .other(let msg):
            return msg
        }
    }

    /// Full stderr (if any) for display in a disclosure view. Empty string
    /// when there's no additional detail worth showing.
    var diagnosticStderr: String {
        switch self {
        case .hostUnreachable(_, let s),
             .authenticationFailed(_, let s),
             .hostKeyMismatch(_, let s),
             .commandFailed(_, let s):
            return s
        default:
            return ""
        }
    }

    /// Heuristic classifier: convert the ssh/scp stderr of a failed command
    /// into a specific `TransportError`. Used by `SSHTransport` after a
    /// non-zero exit. Defaults to `.commandFailed` when no known marker
    /// matches.
    static func classifySSHFailure(host: String, exitCode: Int32, stderr: String) -> TransportError {
        let s = stderr.lowercased()
        if s.contains("permission denied") || s.contains("authentication failed")
            || s.contains("publickey") && s.contains("denied") {
            return .authenticationFailed(host: host, stderr: stderr)
        }
        if s.contains("host key verification failed")
            || s.contains("remote host identification has changed") {
            return .hostKeyMismatch(host: host, stderr: stderr)
        }
        if s.contains("no route to host") || s.contains("connection refused")
            || s.contains("connection timed out") || s.contains("could not resolve hostname")
            || s.contains("connection closed by") && s.contains("port 22") {
            return .hostUnreachable(host: host, stderr: stderr)
        }
        return .commandFailed(exitCode: exitCode, stderr: stderr)
    }
}
