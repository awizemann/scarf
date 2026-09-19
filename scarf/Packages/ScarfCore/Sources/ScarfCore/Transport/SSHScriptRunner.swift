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

    #if !os(iOS)
    /// Feeds the script to the child's stdin without ever blocking the run.
    ///
    /// `/bin/sh -s` reads its script as it executes, so it stops reading
    /// while a command runs. A plain blocking `write` of a script bigger than
    /// the pipe buffer (16–64 KB) whose early command stalls would park the
    /// run before it reaches its own timeout loop — the P43b tarball-push bug
    /// (charter C10). So the write end is `O_NONBLOCK` + `F_SETNOSIGPIPE`,
    /// `pump()` writes what the pipe takes NOW, and the run loop calls it on
    /// every tick, where the timeout and cancellation checks already live.
    /// Only ever touched from the one detached task that owns the run.
    final class ScriptFeeder {
        private let handle: FileHandle
        private let data: Data
        private var offset = 0
        private(set) var isDone = false

        /// The `errno` of a write that lost bytes of the script, if one
        /// happened. Anything other than EPIPE here means the child is still
        /// there and would otherwise run the TRUNCATED prefix as if it were
        /// the whole script — a `cd /tmp && rm -rf "$d"` cut mid-line is its
        /// own command. The run reports it as a connect failure instead of
        /// handing the caller that run's output. EPIPE is exempt: the reader
        /// is gone, so nothing runs and the child's own exit reports.
        private(set) var failure: Int32?

        init(handle: FileHandle, script: String) {
            self.handle = handle
            self.data = Data(script.utf8)
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            // A child that exits before reading everything is EPIPE, not a
            // SIGPIPE that would take Scarf down.
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }

        /// Writes as much as the pipe accepts without blocking. Closes the
        /// write end (the child's EOF) once every byte is in, or once the
        /// reader is gone.
        func pump() {
            guard !isDone else { return }
            let fd = handle.fileDescriptor
            while offset < data.count {
                let n = data.withUnsafeBytes { buf in
                    Darwin.write(fd, buf.baseAddress! + offset, data.count - offset)
                }
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { return }
                // EPIPE: nobody is reading, nothing ran. Anything else lost
                // bytes with the child still alive — record it so the run
                // fails loudly rather than reporting the truncated script's
                // output as the script's own.
                if n < 0 && errno != EPIPE { failure = errno }
                break
            }
            finish()
        }

        func finish() {
            guard !isDone else { return }
            isDone = true
            try? handle.close()
        }
    }
    #endif

    /// Lock-protected `Data` accumulator used by the stdout/stderr
    /// readability handlers below. Two of these per script run, one per
    /// stream. `@unchecked Sendable` because mutation goes through the
    /// `NSLock` — Swift can't see that.
    ///
    /// Why this exists (issue #77): the previous implementation read
    /// stdout/stderr via `readToEnd()` *after* the subprocess exited.
    /// **The pipe-buffer back-story.** On macOS pipes default to a 16–64 KB
    /// kernel buffer; once `sqlite3 -json` writes more than that, the SSH
    /// client back-pressures over the wire, the remote sqlite3 blocks, the
    /// script never finishes, the 30 s timeout fires, and the caller sees
    /// "Script timed out" + an empty result set. v2.7's
    /// `sessionListSnapshot(limit: 500)` crossed that threshold for any user
    /// with ~150+ sessions. Both arms below drain concurrently with the run,
    /// through `Process.startDraining` — the app's one drain primitive — which
    /// replaced a hand-rolled `readabilityHandler` pair whose snapshot was
    /// taken at EXIT rather than at EOF (round-5 P48).

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

    #if !os(iOS)
    /// The outcome for a script that could not be fed to the shell in full.
    /// Never `.completed`: the child saw a prefix, so whatever it printed
    /// answers a different script than the caller asked for.
    static func feedFailure(errno code: Int32) -> Outcome {
        .connectFailure("failed to feed the script: \(String(cString: strerror(code)))")
    }
    #endif

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
                    #if !os(iOS)
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

    #if !os(iOS)
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

            // Without a drain running for the whole spawn a >64 KB script
            // output wedges the pipe + ssh + remote sqlite3 chain and the
            // only visible symptom is a timeout (issue #77). The drain is
            // installed BEFORE the stdin write below, which is the P43b rule:
            // the reader must be in place before the parent's LAST write to
            // the child, not merely before its first read.
            // One drain, EOF-exact and bounded: `Process.startDraining`
            // installs a reader per pipe at spawn and `collect(grace:)` waits
            // for the LAST EOF, not merely for the process to go.
            //
            // The readabilityHandler pair this replaces judged too early. It
            // nilled both handlers the moment `isRunning` went false and
            // snapshotted whatever had landed — but exit is not EOF: a chunk
            // still on the pipe's queue was silently dropped, and the line a
            // failing script prints immediately before exiting is exactly the
            // one at risk. That is the P40 OAuthFlowController class of bug,
            // third site (round-5 P48).
            let drain = Process.startDraining(pipes: [stdoutPipe, stderrPipe])

            do {
                try proc.run()
            } catch {
                try? stdinPipe.fileHandleForReading.close()
                try? stdinPipe.fileHandleForWriting.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                _ = drain.collect()
                return .connectFailure("Failed to launch ssh: \(error.localizedDescription)")
            }
            // Parent's copies of the ends the child owns, so EOF lands.
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            let feeder = ScriptFeeder(handle: stdinPipe.fileHandleForWriting, script: script)
            defer { feeder.finish() }
            feeder.pump()

            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                feeder.pump()
                // A short write with the child still alive left it holding a
                // truncated script; kill it rather than let the shell run the
                // prefix and report its output as the script's result.
                if let code = feeder.failure {
                    proc.terminate()
                    _ = await proc.waitDrainingAsync(timeout: 0, drain: drain)
                    return feedFailure(errno: code)
                }
                // Honor BOTH the detached-task's own cancellation flag
                // (set by the parent's `withTaskCancellationHandler`)
                // and the legacy `Task.isCancelled` check in case the
                // detached body gets cancelled directly. The flag is
                // the load-bearing path; Task.isCancelled is harmless
                // belt-and-suspenders.
                if cancelFlag.isCancelled || Task.isCancelled {
                    // Bounded escalation, and the drain owns the read ends —
                    // closing them here would raise while a reader is still
                    // blocked on one.
                    _ = await proc.waitDrainingAsync(timeout: 0, drain: drain)
                    return .connectFailure("Script cancelled")
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                _ = await proc.waitDrainingAsync(timeout: 0, drain: drain)
                return .connectFailure("Script timed out after \(Int(timeout))s")
            }
            // Wait for the LAST EOF, not merely for the process to go.
            // `waitDrainingAsync` with a spent budget: the child has already
            // gone, so this is the drain collection alone — but on a dedicated
            // thread, because `collect(grace:)` still blocks for up to its
            // grace and this closure runs on the cooperative pool.
            let collected = await proc.waitDrainingAsync(timeout: 0, drain: drain).data
            let out = collected.first ?? Data()
            let err = collected.count > 1 ? collected[1] : Data()
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
            // The script travels on stdin, never in argv: argv is readable in
            // `ps` by every user on the Mac for as long as the script runs,
            // and scripts carry things like Live Voice's SDP offer (ICE
            // credentials) and the text sent to TTS. Same shape as the SSH
            // path's `-- /bin/sh -s`.
            proc.arguments = ["-s"]

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            // Same pipe-buffer fix as runOverSSH. Local scripts can also
            // blow past the 16–64 KB pipe buffer (e.g. local `sqlite3 -json`
            // over a fat result set) and would wedge in exactly the same way.
            // One drain, EOF-exact and bounded: `Process.startDraining`
            // installs a reader per pipe at spawn and `collect(grace:)` waits
            // for the LAST EOF, not merely for the process to go.
            //
            // The readabilityHandler pair this replaces judged too early. It
            // nilled both handlers the moment `isRunning` went false and
            // snapshotted whatever had landed — but exit is not EOF: a chunk
            // still on the pipe's queue was silently dropped, and the line a
            // failing script prints immediately before exiting is exactly the
            // one at risk. That is the P40 OAuthFlowController class of bug,
            // third site (round-5 P48).
            //
            // The drain is installed BEFORE the stdin feed below (the P43b
            // rule: the reader must be in place before the parent's LAST write
            // to the child, not merely before its first read).
            let drain = Process.startDraining(pipes: [stdoutPipe, stderrPipe])

            do {
                try proc.run()
            } catch {
                try? stdinPipe.fileHandleForReading.close()
                try? stdinPipe.fileHandleForWriting.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                _ = drain.collect()
                return .connectFailure("Failed to launch /bin/sh: \(error.localizedDescription)")
            }
            // Parent's copies of the ends the child owns, so EOF lands.
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            let feeder = ScriptFeeder(handle: stdinPipe.fileHandleForWriting, script: script)
            defer { feeder.finish() }
            feeder.pump()

            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                feeder.pump()
                // A short write with the child still alive left it holding a
                // truncated script; kill it rather than let the shell run the
                // prefix and report its output as the script's result.
                if let code = feeder.failure {
                    proc.terminate()
                    _ = await proc.waitDrainingAsync(timeout: 0, drain: drain)
                    return feedFailure(errno: code)
                }
                if cancelFlag.isCancelled || Task.isCancelled {
                    // Bounded escalation, and the drain owns the read ends —
                    // closing them here would raise while a reader is still
                    // blocked on one.
                    _ = await proc.waitDrainingAsync(timeout: 0, drain: drain)
                    return .connectFailure("Script cancelled")
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                _ = await proc.waitDrainingAsync(timeout: 0, drain: drain)
                return .connectFailure("Script timed out after \(Int(timeout))s")
            }
            // `waitDrainingAsync` with a spent budget: the child has already
            // gone, so this is the drain collection alone — but on a dedicated
            // thread, because `collect(grace:)` still blocks for up to its
            // grace and this closure runs on the cooperative pool.
            let collected = await proc.waitDrainingAsync(timeout: 0, drain: drain).data
            let out = collected.first ?? Data()
            let err = collected.count > 1 ? collected[1] : Data()
            return .completed(
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? "",
                exitCode: proc.terminationStatus
            )
        }.value
    }
    #endif // !os(iOS)
}
