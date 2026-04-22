import Foundation
import ScarfCore

/// Bypasses `SSHTransport`'s normal terse-error path so the Add Server sheet
/// can show the user a full diagnostic on failure: the exact ssh command we
/// invoked, the verbose `ssh -v` handshake trace, and any remote shell
/// output. This is the difference between "Remote command exited 255" with
/// no further info, and "ssh said 'Permission denied (publickey)' on line N
/// of the trace, here's the command we ran, here's what was in your env".
struct TestConnectionProbe {
    let config: SSHConfig

    func run() async -> AddServerViewModel.TestResult {
        let host = config.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            return .failure(message: "Host is empty", stderr: "", command: "")
        }

        // Same options SSHTransport uses, plus -v for verbose ssh trace.
        // We deliberately skip ControlMaster here so the probe is a fresh
        // connection — a stale control socket from a previous failed run
        // shouldn't mask current state.
        var sshArgs: [String] = [
            "-v",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR"  // Errors only on stderr; -v puts handshake on stderr separately
        ]
        if let port = config.port { sshArgs += ["-p", String(port)] }
        if let id = config.identityFile, !id.isEmpty {
            sshArgs += ["-i", id]
        }
        let hostSpec: String
        if let user = config.user, !user.isEmpty { hostSpec = "\(user)@\(host)" }
        else { hostSpec = host }
        sshArgs.append(hostSpec)
        sshArgs.append("--")

        // Remote probe script. Tries three strategies in order:
        //   1. `command -v hermes` against the bare non-interactive PATH —
        //      works if the user put their install location in ~/.zshenv.
        //   2. Source common login rc files (.zprofile, .bash_profile,
        //      .profile) and re-probe — picks up PATH set in login shells.
        //   3. Probe the well-known install candidates directly. Mirrors
        //      `HermesPathSet.hermesBinaryCandidates` so behavior matches
        //      Scarf's local resolution.
        // The matched absolute path is stored as `hermesBinaryHint` on the
        // SSHConfig so subsequent CLI/ACP invocations don't have to re-probe.
        // If the user already typed a remoteHome override, use it; otherwise
        // default to $HOME/.hermes. Either way, the script also probes a
        // short list of well-known alternates when the primary path doesn't
        // have state.db — systemd/docker/VPS installs tend to live at
        // /var/lib/hermes/.hermes or /home/hermes/.hermes, and SSHing in as
        // a different user than the Hermes daemon is the leading cause of
        // "connection green, data empty" bug reports (issue #19).
        let primary: String
        if let override = config.remoteHome, !override.isEmpty {
            if override.hasPrefix("~/") {
                primary = "$HOME/\(override.dropFirst(2))"
            } else if override == "~" {
                primary = "$HOME"
            } else {
                primary = override
            }
        } else {
            primary = "$HOME/.hermes"
        }

        let script = #"""
        hpath=$(command -v hermes 2>/dev/null)
        if [ -z "$hpath" ]; then
            for rc in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.profile"; do
                [ -f "$rc" ] && . "$rc" 2>/dev/null
            done
            hpath=$(command -v hermes 2>/dev/null)
        fi
        if [ -z "$hpath" ]; then
            for cand in "$HOME/.local/bin/hermes" "/opt/homebrew/bin/hermes" "/usr/local/bin/hermes" "$HOME/.hermes/bin/hermes"; do
                if [ -x "$cand" ]; then hpath="$cand"; break; fi
            done
        fi
        echo "HERMES:$hpath"
        PRIMARY="\#(primary)"
        if [ -r "$PRIMARY/state.db" ]; then
            echo "DB:ok"
            echo "HOME_USED:$PRIMARY"
        else
            echo "DB:missing"
            # Probe well-known alternates. Emit the first one that has a
            # readable state.db so the UI can offer a one-click fill.
            for alt in "/var/lib/hermes/.hermes" "/opt/hermes/.hermes" "/home/hermes/.hermes" "/root/.hermes"; do
                if [ -r "$alt/state.db" ]; then
                    echo "SUGGEST:$alt"
                    break
                fi
            done
        fi
        """#
        sshArgs.append("/bin/sh")
        sshArgs.append("-c")
        sshArgs.append(script)

        // Build the displayable command string. Show exactly what `ssh ...`
        // would look like in the user's terminal (with single-quoting for
        // the script). Doesn't have to be byte-equivalent to what
        // `Process` invokes — just a faithful reproduction the user can
        // paste into Terminal to compare.
        let displayCommand = "/usr/bin/ssh " + sshArgs.map { Self.shellDisplayQuote($0) }.joined(separator: " ")

        let probe = await Task.detached { () -> (Int32, String, String) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = sshArgs
            // Inherit shell-derived SSH_AUTH_SOCK so ssh can reach the agent.
            // Without this, GUI-launched Scarf can't see the user's
            // ssh-add'd keys (terminal works because shell sets the var).
            var env = ProcessInfo.processInfo.environment
            let shellEnv = HermesFileService.enrichedEnvironment()
            for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
                if env[key] == nil, let value = shellEnv[key], !value.isEmpty {
                    env[key] = value
                }
            }
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            do {
                try proc.run()
            } catch {
                return (-1, "", "Failed to launch /usr/bin/ssh: \(error.localizedDescription)")
            }
            // Bound the probe so a hung connection doesn't lock the UI.
            let deadline = Date().addingTimeInterval(20)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                proc.terminate()
                let partial = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                return (-1, "", "Timed out after 20s.\n\nssh trace so far:\n" + (String(data: partial, encoding: .utf8) ?? ""))
            }
            let out = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            return (
                proc.terminationStatus,
                String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? ""
            )
        }.value

        let (exitCode, stdout, stderr) = probe

        // Diagnostic envelope: always include the ssh command + the
        // SSH_AUTH_SOCK presence at the top of the stderr blob so the
        // user immediately sees whether agent inheritance worked.
        let agentEnv = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            ?? HermesFileService.enrichedEnvironment()["SSH_AUTH_SOCK"]
            ?? "(not set)"
        let envSummary = "SSH_AUTH_SOCK = \(agentEnv)\n\n"

        if exitCode == 0 {
            let lines = stdout.split(separator: "\n").map(String.init)
            let hermesPath = lines.first(where: { $0.hasPrefix("HERMES:") })?
                .dropFirst("HERMES:".count).trimmingCharacters(in: .whitespaces) ?? ""
            let dbFound = lines.contains(where: { $0 == "DB:ok" })
            let suggestedHome = lines.first(where: { $0.hasPrefix("SUGGEST:") })
                .map { String($0.dropFirst("SUGGEST:".count)).trimmingCharacters(in: .whitespaces) }
            if hermesPath.isEmpty {
                return .failure(
                    message: "hermes binary not found in remote $PATH",
                    stderr: envSummary + "Add hermes to the remote PATH (e.g. ~/.zshenv).\n\nRemote stdout:\n\(stdout)",
                    command: displayCommand
                )
            }
            return .success(hermesPath: String(hermesPath), dbFound: dbFound, suggestedRemoteHome: suggestedHome)
        }

        // Classify common failures by scanning the stderr trace.
        let lower = stderr.lowercased()
        let summary: String
        if lower.contains("permission denied") {
            summary = "Permission denied — check that your key is loaded in ssh-agent (run `ssh-add -l` in Terminal) and that the remote accepts it."
        } else if lower.contains("host key verification failed") {
            summary = "Host key mismatch — run `ssh-keygen -R \(host)` in Terminal, then retry."
        } else if lower.contains("connection refused") || lower.contains("no route to host") {
            summary = "Can't reach the host — check the IP/network/firewall."
        } else if lower.contains("could not resolve hostname") {
            summary = "Hostname did not resolve."
        } else if exitCode == 255 {
            summary = "ssh failed (exit 255). See the trace below."
        } else {
            summary = "Remote command exited \(exitCode)."
        }

        return .failure(
            message: summary,
            stderr: envSummary + (stderr.isEmpty ? "(ssh produced no stderr — this usually means the process itself failed to start, the executable couldn't be located, or stdin/stdout was closed unexpectedly.)" : stderr),
            command: displayCommand
        )
    }

    /// Quote an argument for display in a copy-pasteable ssh command. Always
    /// wraps in single quotes if it contains anything beyond a basic safe set
    /// — visually noisier than minimal quoting but unambiguous.
    private static func shellDisplayQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
