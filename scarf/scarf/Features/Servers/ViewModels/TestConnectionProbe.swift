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
            // Not a connect attempt — no ssh is spawned, and the user hasn't
            // finished filling the form. Nothing to report.
            return .failure(message: "Host is empty", stderr: "", command: "")
        }
        // This is the app's one user-initiated, user-visible SSH connect:
        // "Test Connection" in Add/Edit Server. The background pollers and
        // internal retries deliberately do *not* emit connect_* — they'd
        // outnumber real attempts by orders of magnitude, and the facts they
        // carry are covered by circuit_breaker_* and connection_degraded.
        let attemptStart = Date()
        Analytics.record(.connectAttempted(transport: .ssh))
        // The user explicitly asked to try this host — their intent
        // overrides any open circuit breaker (gh#138), and background
        // traffic should resume immediately if the connection is back.
        SSHConnectionGate.shared.reset(SSHConnectionGate.key(host: host, port: config.port))

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

        // When the user supplied a manual `hermesBinaryHint` (gh#105
        // Advanced override) the probe trusts it verbatim: a wrapper
        // function defined in `~/.zshrc` or a `docker compose exec`
        // alias won't survive a non-interactive /bin/sh PATH lookup,
        // so the auto-detect would always fail for those setups.
        // Source the common login rc files first so a function the
        // user defined there has a chance to load; then check the
        // first word against `command -v` (handles bare paths AND
        // shell functions). Fall back to reporting the raw hint even
        // if the lookup doesn't resolve — Hermes is invoked via
        // `/bin/sh -c "<hint> …"` downstream, where a `~/.zshrc`-
        // sourced shell may resolve the same string the probe
        // couldn't reach (we can't replicate the runtime shell here).
        let hintEnv: String
        if let hint = config.hermesBinaryHint, !hint.isEmpty {
            let escaped = hint
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            hintEnv = "HERMES_HINT=\"\(escaped)\"\n"
        } else {
            hintEnv = "HERMES_HINT=\"\"\n"
        }

        let script = #"""
        \#(hintEnv)
        # Always source login rc files first so functions/aliases the
        # user defined in their interactive shell at least have a
        # chance to be visible in the lookups below.
        for rc in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
            [ -f "$rc" ] && . "$rc" 2>/dev/null
        done
        hpath=""
        if [ -n "$HERMES_HINT" ]; then
            # Resolve the first token of the hint via `command -v` so
            # `hermes` (a function) → that function's display path,
            # `/abs/path` → itself, etc. Failing that, surface the
            # hint verbatim — downstream callers run it through a
            # shell which may resolve it even when this probe can't.
            first=$(printf '%s\n' "$HERMES_HINT" | awk '{print $1}')
            resolved=$(command -v "$first" 2>/dev/null)
            if [ -n "$resolved" ]; then
                hpath="$resolved"
            else
                hpath="$HERMES_HINT"
            fi
        fi
        if [ -z "$hpath" ]; then
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
            // The *connection* is what connect_succeeded is about (its props
            // are transport + duration, nothing about Hermes), and exit 0
            // means ssh authenticated and ran our script. The "hermes binary
            // not found" branch below is a healthy connection to a host
            // without a usable Hermes — a Hermes-compatibility fact, not a
            // transport one — so it is not reported as a connect failure.
            Analytics.record(.connectSucceeded(
                transport: .ssh,
                durationBucket: .init(since: attemptStart)
            ))
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

        Analytics.record(.connectFailed(
            transport: .ssh,
            errorKind: Self.analyticsErrorKind(host: host, exitCode: exitCode, stderr: stderr)
        ))

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

    /// Bounded `error_kind` token for a failed probe.
    ///
    /// Routes through `TransportError` so this classification and the one the
    /// rest of the transport layer uses can never drift apart, then takes the
    /// case-derived token — no stderr, host, or message text ever leaves this
    /// function. The two `exitCode == -1` cases are ours, not ssh's: the
    /// detached probe above synthesizes that code (with a prefix it wrote
    /// itself) for a 20s deadline and for a `Process` that wouldn't launch.
    static func analyticsErrorKind(host: String, exitCode: Int32, stderr: String) -> UsageEvent.TransportErrorKind {
        let error: TransportError
        if exitCode == -1 {
            error = stderr.hasPrefix("Timed out after")
                ? .timeout(seconds: 20, partialStdout: Data())
                : .other(message: "")
        } else {
            let classified = TransportError.classifySSHFailure(host: host, exitCode: exitCode, stderr: stderr)
            // `classifySSHFailure` falls through to `.commandFailed`, which
            // would be a lie for exit 255: ssh's own "something went wrong
            // before/instead of the remote command" code means no remote
            // command ever ran. Unrecognized 255s belong in the `other`
            // bucket, which is exactly what that bucket is for.
            if case .commandFailed = classified, exitCode == 255 {
                error = .other(message: "")
            } else {
                error = classified
            }
        }
        return UsageEvent.TransportErrorKind(error)
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
