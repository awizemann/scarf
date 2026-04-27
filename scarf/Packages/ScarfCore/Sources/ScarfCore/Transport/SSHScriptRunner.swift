import Foundation

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
        #if os(macOS)
        switch context.kind {
        case .local:
            return await runLocally(script: script, timeout: timeout)
        case .ssh(let config):
            return await runOverSSH(script: script, config: config, timeout: timeout)
        }
        #else
        return .connectFailure("SSHScriptRunner is only available on macOS")
        #endif
    }

    // MARK: - SSH path

    #if os(macOS)
    private static func runOverSSH(script: String, config: SSHConfig, timeout: TimeInterval) async -> Outcome {
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

            do {
                try proc.run()
            } catch {
                return .connectFailure("Failed to launch ssh: \(error.localizedDescription)")
            }

            if let data = script.data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                proc.terminate()
                return .connectFailure("Script timed out after \(Int(timeout))s")
            }
            let out = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
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

    private static func runLocally(script: String, timeout: TimeInterval) async -> Outcome {
        return await Task.detached { () -> Outcome in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            do {
                try proc.run()
            } catch {
                return .connectFailure("Failed to launch /bin/sh: \(error.localizedDescription)")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                proc.terminate()
                return .connectFailure("Script timed out after \(Int(timeout))s")
            }
            let out = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
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
