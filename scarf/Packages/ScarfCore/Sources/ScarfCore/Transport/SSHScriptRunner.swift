import Foundation
import os

/// Runs multi-line shell scripts on a server (local or SSH) without
/// going through `ServerTransport.runProcess`.
///
/// **Why this exists.** `SSHTransport.runProcess` quotes every argument
/// via `remotePathArg` (it rewrites `~/` → `$HOME/`), which is correct
/// for path arguments but mangles a multi-line script containing
/// `"$VAR"` references, nested quotes, and control structures. The
/// remote receives a scrambled string and the script silently
/// produces no useful output.
///
/// `RemoteDiagnosticsViewModel` originally documented this and worked
/// around it locally. Issue #44 surfaced the same bug for the
/// connection-status pill (multi-line probe script through
/// `runProcess` → tier 2 always reads as failed even when the file
/// is readable, while diagnostics — which used the workaround —
/// reports 14/14 passing). This helper centralises the workaround so
/// any future caller running a script gets it for free.
///
/// **Approach.** We invoke `/usr/bin/ssh ... -- /bin/sh -s` directly
/// and pipe the script via stdin, so the script travels as a single
/// opaque byte stream that the remote shell parses unchanged. Local
/// contexts skip ssh and just pipe to `/bin/sh -s` — same shape so
/// callers can treat both uniformly.
public enum SSHScriptRunner {

    /// Thread-safe boolean flag used to bridge parent-task cancellation
    /// into the detached `Task` body that owns the ssh subprocess.
    /// `Task.detached { ... }` does NOT inherit cancellation from the
    /// awaiting parent; without this flag, cancelling a chat-load /
    /// hydration / activity-fetch Task only throws `CancellationError`
    /// at the chat layer while the ssh subprocess keeps running until
    /// its 30s timeout fires — pinning a remote sqlite query (and a
    /// ControlMaster session slot) for the full deadline. v2.8 fix
    /// observed in 2026-05-05 dogfooding: rapid chat-switching left a
    /// chain of stale 30s ssh subprocesses behind, blocking the
    /// dashboard's queryBatch and producing a "spinning" load.
    private final class CancelFlag: @unchecked Sendable {
        // os_unfair_lock (via OSAllocatedUnfairLock) per the project's lock
        // convention — cheaper than NSLock for this once-per-run flag. (t-aud15)
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { lock.withLock { $0 } }
        func cancel() { lock.withLock { $0 = true } }
    }

    /// Lock-protected `Data` accumulator used by the stdout/stderr
    /// readability handlers below. Two of these per script run, one per
    /// stream. `@unchecked Sendable` because mutation goes through the
    /// `NSLock` — Swift can't see that.
    ///
    /// Why this exists (issue #77): the previous implementation read
    /// stdout/stderr via `readToEnd()` *after* the subprocess exited.
    /// On macOS pipes default to a 16–64 KB kernel buffer; once
    /// `sqlite3 -json` writes more than that, the SSH client back-
    /// pressures over the wire, the remote sqlite3 blocks, the script
    /// never finishes, the 30 s timeout fires, and the caller sees
    /// "Script timed out" + an empty result set. v2.7's
    /// `sessionListSnapshot(limit: 500)` crossed that threshold for
    /// any user with ~150+ sessions. Draining concurrently with
    /// `readabilityHandler` removes the back-pressure.
    private final class LockedData: @unchecked Sendable {
        // os_unfair_lock (via OSAllocatedUnfairLock) per the project's lock
        // convention. (t-aud15)
        private let lock = OSAllocatedUnfairLock(initialState: Data())
        func append(_ chunk: Data) { lock.withLock { $0.append(chunk) } }
        func snapshot() -> Data { lock.withLock { $0 } }
    }

    public enum Outcome: Sendable {
        /// Couldn't even reach the remote (process spawn failed,
        /// timeout before any output, network refused). Carries the
        /// human-readable reason.
        case connectFailure(String)
        /// Script ran to completion (or until timeout cut it short
        /// after producing partial output). Exit code, stdout, stderr
        /// are reported as captured.
        case completed(stdout: String, stderr: String, exitCode: Int32)
    }

    /// Run `script` against the given context. Times out after
    /// `timeout` seconds, killing the subprocess if it overruns.
    ///
    /// **Platforms.** Real implementation is macOS-only — relies on
    /// `Foundation.Process` which iOS doesn't ship. iOS callers
    /// (ScarfGo) use Citadel-backed SSH transports for their own
    /// flows; they never reach this entry point. To keep ScarfCore
    /// cross-platform we return a connect failure on non-macOS so
    /// the file compiles everywhere.
    public static func run(script: String, context: ServerContext, timeout: TimeInterval = 30) async -> Outcome {
        await ScarfMon.measureAsync(.transport, "ssh.run") {
            // Bridge parent cancellation into the detached subprocess
            // task. Without this, killing a chat-hydration Task on a
            // session switch only unwinds Swift state — the ssh
            // subprocess keeps holding a remote sqlite query + a
            // ControlMaster session for the full 30s timeout. v2.8.
            let cancelFlag = CancelFlag()
            return await withTaskCancellationHandler(
                operation: {
                    #if os(macOS)
                    switch context.kind {
                    case .local:
                        return await runLocally(script: script, timeout: timeout, cancelFlag: cancelFlag)
                    case .ssh(let config):
                        return await runOverSSH(script: script, config: config, timeout: timeout, cancelFlag: cancelFlag)
                    }
                    #else
                    return .connectFailure("SSHScriptRunner is only available on macOS")
                    #endif
                },
                onCancel: {
                    cancelFlag.cancel()
                    ScarfMon.event(.transport, "ssh.cancelled", count: 1)
                }
            )
        }
    }

    // MARK: - SSH path

    #if os(macOS)
    private static func runOverSSH(script: String, config: SSHConfig, timeout: TimeInterval, cancelFlag: CancelFlag) async -> Outcome {
        // Per-host circuit breaker (gh#138): fail fast without spawning
        // ssh while the gate is open, and feed connection-level outcomes
        // back so this path counts alongside SSHTransport's.
        let gateKey = SSHConnectionGate.key(host: config.host, port: config.port)
        if case .blocked(let retryAt) = SSHConnectionGate.shared.admit(gateKey) {
            let secs = max(0, Int(retryAt.timeIntervalSinceNow))
            return .connectFailure("Connection to \(config.host) is paused after repeated failures. Retrying in \(secs)s.")
        }
        let outcome = await runOverSSHUngated(script: script, config: config, timeout: timeout, cancelFlag: cancelFlag)
        switch outcome {
        case .completed(_, _, let exitCode):
            if exitCode == 255 {
                SSHConnectionGate.shared.recordFailure(gateKey)
            } else {
                SSHConnectionGate.shared.recordSuccess(gateKey)
            }
        case .connectFailure(let reason):
            // Timeouts count (an OAuth-blocked ProxyCommand looks exactly
            // like this); local launch errors and cancellation don't.
            if reason.hasPrefix("Script timed out") {
                SSHConnectionGate.shared.recordFailure(gateKey)
            }
        }
        return outcome
    }

    private static func runOverSSHUngated(script: String, config: SSHConfig, timeout: TimeInterval, cancelFlag: CancelFlag) async -> Outcome {
        var sshArgv: [String] = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(SSHTransport.controlDirPath())/%C",
            "-o", "ControlPersist=600",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=QUIET",
            "-o", "BatchMode=yes",
            "-T",  // no pty — keep stdin/stdout a clean byte stream
        ]
        if let port = config.port { sshArgv += ["-p", String(port)] }
        if let id = config.identityFile, !id.isEmpty {
            sshArgv += ["-i", id]
        }
        let hostSpec: String
        if let user = config.user, !user.isEmpty { hostSpec = "\(user)@\(config.host)" }
        else { hostSpec = config.host }
        sshArgv.append(hostSpec)
        sshArgv.append("--")
        sshArgv.append("/bin/sh")
        sshArgv.append("-s")  // read script from stdin

        return await Task.detached { () -> Outcome in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = sshArgv

            // Inherit shell-derived SSH_AUTH_SOCK so ssh-agent reaches.
            // Same path SSHTransport uses internally — see
            // `environmentEnricher` set at app boot.
            var env = ProcessInfo.processInfo.environment
            if let enricher = SSHTransport.environmentEnricher {
                let shellEnv = enricher()
                for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
                    if env[key] == nil, let v = shellEnv[key], !v.isEmpty {
                        env[key] = v
                    }
                }
            }
            proc.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            // Drain stdout/stderr concurrently with the running process —
            // see the LockedData docstring above for the issue-#77
            // back-story. Without these handlers a >64 KB script output
            // wedges the pipe + ssh + remote sqlite3 chain and the only
            // visible symptom is a timeout.
            let outBuf = LockedData()
            let errBuf = LockedData()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outBuf.append(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errBuf.append(chunk)
                }
            }

            do {
                try proc.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                return .connectFailure("Failed to launch ssh: \(error.localizedDescription)")
            }

            if let data = script.data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                // Honor BOTH the detached-task's own cancellation flag
                // (set by the parent's `withTaskCancellationHandler`)
                // and the legacy `Task.isCancelled` check in case the
                // detached body gets cancelled directly. The flag is
                // the load-bearing path; Task.isCancelled is harmless
                // belt-and-suspenders.
                if cancelFlag.isCancelled || Task.isCancelled {
                    proc.terminate()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    return .connectFailure("Script cancelled")
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                proc.terminate()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Pipe fds leak otherwise — closing on the timeout branch
                // matches the success-path discipline (see CLAUDE.md
                // "Always close both fileHandleForReading and
                // fileHandleForWriting on Pipe objects").
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                return .connectFailure("Script timed out after \(Int(timeout))s")
            }
            // Detach the readabilityHandlers and capture whatever the
            // accumulator has. The handler may have already seen EOF
            // (`chunk.isEmpty`) and self-cleared, but assigning nil is
            // idempotent and guards against a late tick from the queue.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let out = outBuf.snapshot()
            let err = errBuf.snapshot()
            // Best-effort fd close — Pipe leaks fd's otherwise.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            return .completed(
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? "",
                exitCode: proc.terminationStatus
            )
        }.value
    }

    // MARK: - Local path

    private static func runLocally(script: String, timeout: TimeInterval, cancelFlag: CancelFlag) async -> Outcome {
        return await Task.detached { () -> Outcome in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            // Drain concurrently — same pipe-buffer fix as runOverSSH.
            // Local scripts can also blow past the 16–64 KB pipe buffer
            // (e.g. local `sqlite3 -json` over a fat result set) and
            // would wedge in exactly the same way.
            let outBuf = LockedData()
            let errBuf = LockedData()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outBuf.append(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errBuf.append(chunk)
                }
            }

            do {
                try proc.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                return .connectFailure("Failed to launch /bin/sh: \(error.localizedDescription)")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                if cancelFlag.isCancelled || Task.isCancelled {
                    proc.terminate()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    return .connectFailure("Script cancelled")
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                proc.terminate()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                return .connectFailure("Script timed out after \(Int(timeout))s")
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let out = outBuf.snapshot()
            let err = errBuf.snapshot()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            return .completed(
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? "",
                exitCode: proc.terminationStatus
            )
        }.value
    }
    #endif // os(macOS)
}
