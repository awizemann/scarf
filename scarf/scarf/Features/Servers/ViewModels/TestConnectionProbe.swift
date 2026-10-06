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

    /// How long the probe gives `ssh` before giving up. A named budget so the
    /// deadline and the message the user reads can never drift apart — they
    /// were two independent literals, `20` and the string "Timed out after
    /// 20s" (round-5 P48).
    // `nonisolated`: read inside the detached probe closure; the app target
    // defaults declarations to `@MainActor`, and Release treats the cross-actor
    // read as an error.
    nonisolated static let probeTimeout: TimeInterval = 20

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
        Analytics.record(.connectAttempted(transport: .ssh, source: .testProbe))
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

        let script = Self.probeScript(config: config)
        // The script goes to `/bin/sh -s` on stdin, never as an ssh argv
        // word. ssh joins its argv into ONE string for the remote login
        // shell, so `/bin/sh -c <script>` ran only the script's first line
        // (`HERMES_HINT=…`) in that child sh, and every later line in the
        // login shell with the hint gone: a manual "Hermes binary" override
        // was never tested (S15-F3). `SSHScriptRunner` avoids the same trap
        // the same way.
        sshArgs.append("/bin/sh")
        sshArgs.append("-s")
        let scriptData = Data(script.utf8)

        // Build the displayable command string: what the user can paste
        // into Terminal to reproduce the probe, script included as a
        // heredoc on the same stdin.
        let displayCommand = "/usr/bin/ssh " + sshArgs.map { Self.shellDisplayQuote($0) }.joined(separator: " ")
            + " <<'SCARF_PROBE'\n" + script + "\nSCARF_PROBE"

        // The login-shell env probe, hoisted OUT of the detached closure.
        // Everything else in that closure suspends rather than blocks (the
        // `Task.sleep` poll and `waitDrainingAsync` below, both deliberate),
        // but `enrichedEnvironment()` reads a `static let` whose `swift_once`
        // initialiser is two `zsh` probes at 5 s + 3 s
        // (`HermesFileService.swift`, `runShellProbe(script:`) — it BLOCKS,
        // and a detached task is off the MAIN actor but still on the
        // cooperative pool, one thread per core and unable to grow. So the
        // one blocking call gets a thread of its own and the closure stays
        // the suspending thing it was written to be (charter C10, round-5
        // P53). One read, before the spawn, so it is also one probe instead
        // of one per attempt.
        let shellEnv = await OffPool.run { HermesFileService.enrichedEnvironment() }

        let probe = await Task.detached { () -> (Int32, String, String) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = sshArgs
            // Inherit shell-derived SSH_AUTH_SOCK so ssh can reach the agent.
            // Without this, GUI-launched Scarf can't see the user's
            // ssh-add'd keys (terminal works because shell sets the var).
            var env = ProcessInfo.processInfo.environment
            for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
                if env[key] == nil, let value = shellEnv[key], !value.isEmpty {
                    env[key] = value
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
                // Nothing spawned and no drain is running, so these are the
                // explicit release. (`Pipe.deinit` closes them anyway —
                // measured; the release is stated rather than implied.)
                try? stdinPipe.fileHandleForReading.close()
                try? stdinPipe.fileHandleForWriting.close()
                try? stdoutPipe.fileHandleForReading.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForWriting.close()
                return (-1, "", "Failed to launch /usr/bin/ssh: \(error.localizedDescription)")
            }
            // Hand over the script and close stdin so the remote sh sees EOF.
            // The script is a couple of KB, far under the smallest pipe
            // buffer (16 KB), so this write returns at once even before ssh
            // reads it; SIGPIPE is off so a dead ssh can't take Scarf down.
            try? stdinPipe.fileHandleForReading.close()
            let stdinFD = stdinPipe.fileHandleForWriting.fileDescriptor
            _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
            try? stdinPipe.fileHandleForWriting.write(contentsOf: scriptData)
            try? stdinPipe.fileHandleForWriting.close()
            // Drain BOTH pipes for the whole run, never with a `readToEnd()`
            // after the wait. This probe runs `ssh -vvv`, so a stderr trace
            // past the 64 KB pipe buffer is the EXPECTED case and not the
            // corner: undrained, ssh blocked in `write()`, the poll below ran
            // its full twenty seconds, and a connection that was working
            // reported "Timed out after 20s" — the probe manufacturing the
            // failure it exists to diagnose (round-5 P48, t-10eb7c17 item 4).
            let drain = Process.startDraining(pipes: [stdoutPipe, stderrPipe])
            // Bound the probe so a hung connection doesn't lock the UI. The
            // poll SUSPENDS rather than blocking — this closure is `async`,
            // and `Process.waitDraining` is a `Thread.sleep` loop that would
            // park a cooperative-pool thread for the whole budget (P43c).
            let deadline = Date().addingTimeInterval(Self.probeTimeout)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                // Bounded escalation, not a bare `terminate()`: a wedged
                // ProxyCommand ignores it, and the trace collected so far is
                // the whole value of this arm.
                let partial = await proc.waitDrainingAsync(timeout: 0, drain: drain).data
                let trace = String(
                    data: partial.count > 1 ? partial[1] : Data(), encoding: .utf8) ?? ""
                return (-1, "", "Timed out after \(Int(Self.probeTimeout))s.\n\nssh trace so far:\n" + trace)
            }
            let collected = await proc.waitDrainingAsync(timeout: 0, drain: drain).data
            return (
                proc.terminationStatus,
                String(data: collected.first ?? Data(), encoding: .utf8) ?? "",
                String(data: collected.count > 1 ? collected[1] : Data(), encoding: .utf8) ?? ""
            )
        }.value

        let (exitCode, stdout, stderr) = probe

        // Diagnostic envelope: always include the ssh command + the
        // SSH_AUTH_SOCK presence at the top of the stderr blob so the
        // user immediately sees whether agent inheritance worked.
        // `shellEnv`, not a second `enrichedEnvironment()` call: the value is
        // memoised, but reading it HERE on the main actor is only free
        // because the hoisted read above happened to populate the
        // `swift_once` first — an ordering dependency nobody wrote down, and
        // one that breaks the moment this line moves above it (round-6 P58).
        let agentEnv = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            ?? shellEnv["SSH_AUTH_SOCK"]
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
                durationBucket: .init(since: attemptStart),
                source: .testProbe
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
            errorKind: Self.analyticsErrorKind(host: host, exitCode: exitCode, stderr: stderr),
            source: .testProbe
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

    /// Two script lines that put the user's LOGIN shell's PATH in front of
    /// this sh's, without sourcing any rc file into sh. Shared with Remote
    /// Diagnostics, which used to source the rc files and died under dash
    /// (T6-F2).
    nonisolated static let loginPathBorrow = #"""
    lp=$("${SHELL:-/bin/sh}" -lc 'printf "__SCARF_PATH__%s" "$PATH"' </dev/null 2>/dev/null | sed -n 's/.*__SCARF_PATH__//p' | tail -n 1)
    [ -n "$lp" ] && PATH="$lp:$PATH"
    """#

    /// The remote probe script for `config`, fed to `/bin/sh -s` on stdin.
    /// Split out so tests can run it against a local shell.
    nonisolated static func probeScript(config: SSHConfig) -> String {
        // Remote probe script. Tries three strategies in order:
        //   1. A manual hint, if the user typed one.
        //   2. `command -v hermes` against the login shell's PATH, borrowed
        //      from `$SHELL -lc` (the rc files are not sourced into sh).
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
        // Advanced override) the probe trusts it verbatim: a
        // `docker compose exec` wrapper won't survive a PATH lookup, so
        // the auto-detect would always fail for those setups. A
        // single-word hint is checked with `command -v` (on the login
        // shell's PATH, see the script); anything else is reported as
        // typed, since Hermes is invoked as `<hint> …` downstream.
        let hintEnv: String
        if let hint = config.hermesBinaryHint, !hint.isEmpty {
            // Escape everything a double-quoted sh string would still
            // expand, so a hint like `sh -c 'exec hermes "$@"' hermes`
            // reaches the probe as typed.
            let escaped = hint
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            hintEnv = "HERMES_HINT=\"\(escaped)\"\n"
        } else {
            hintEnv = "HERMES_HINT=\"\"\n"
        }

        let script = #"""
        \#(hintEnv)
        # Borrow the PATH of the user's own login shell, so an install
        # its profile puts on PATH (asdf, pipx, Homebrew) is found. The
        # rc files are NOT sourced into this sh: under dash (Ubuntu's
        # /bin/sh) one line of zsh syntax in them (`plugins=(git)`) ends
        # the whole probe, and an rc command that reads stdin would eat
        # the rest of this script. The marker skips anything a profile
        # prints before the PATH.
        \#(loginPathBorrow)
        hpath=""
        if [ -n "$HERMES_HINT" ]; then
            # Resolve the first token of the hint via `command -v` so
            # `hermes` (a function) → that function's display path,
            # `/abs/path` → itself, etc. Failing that, surface the
            # hint verbatim — downstream callers run it through a
            # shell which may resolve it even when this probe can't.
            # A multi-word hint (`docker compose exec hermes hermes`) is a
            # command line, not a path: report it as typed, since the
            # first word alone (`/usr/bin/docker`) is not the binary.
            first=$(printf '%s\n' "$HERMES_HINT" | awk '{print $1}')
            resolved=$(command -v "$first" 2>/dev/null)
            if [ -n "$resolved" ] && [ "$first" = "$HERMES_HINT" ]; then
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
        return script
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
