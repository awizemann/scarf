import Foundation
import ScarfCore
import os

/// Runs a fixed check-list against a remote server and reports per-probe
/// pass/fail. Exists because `TestConnectionProbe` only verifies ssh
/// connectivity + hermes binary presence, and `ConnectionStatusViewModel`
/// only pings `/bin/sh -c true`. When users file "connection green but
/// everything empty" bug reports (issue #19), this is the diagnostic surface
/// that tells them (and us) exactly which read fails and why.
///
/// One shell invocation runs every check on the remote and emits a
/// line-delimited `KEY|STATUS|DETAIL` protocol that the view model parses.
/// Cheaper than one SSH round-trip per probe and gives a consistent shell
/// environment across all probes.
@Observable
@MainActor
final class RemoteDiagnosticsViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "RemoteDiagnostics")

    let context: ServerContext

    /// Probes in display order. The order matters: connectivity first, then
    /// environment checks, then Hermes data-path checks. A failure early in
    /// the list usually explains every subsequent failure.
    enum ProbeID: String, CaseIterable, Identifiable {
        case connectivity
        case remoteUser
        case remoteHome
        case hermesHomeConfigured
        case hermesDirExists
        case hermesDirReadable
        case configYAMLReadable
        case configYAMLContents
        case stateDBReadable
        case sqlite3Installed
        case sqlite3CanOpenStateDB
        case hermesBinaryNonLogin
        case hermesBinaryLogin
        case pgrepAvailable

        var id: String { rawValue }

        /// Human-readable title rendered in the diagnostics sheet.
        var title: String {
            switch self {
            case .connectivity:           return "SSH connectivity"
            case .remoteUser:             return "Remote user identity"
            case .remoteHome:             return "Remote $HOME"
            case .hermesHomeConfigured:   return "Hermes home directory"
            case .hermesDirExists:        return "Hermes directory exists"
            case .hermesDirReadable:      return "Hermes directory readable"
            case .configYAMLReadable:     return "config.yaml readable"
            case .configYAMLContents:     return "config.yaml actually readable (content)"
            case .stateDBReadable:        return "state.db readable"
            case .sqlite3Installed:       return "sqlite3 binary installed on remote"
            case .sqlite3CanOpenStateDB:  return "sqlite3 can open state.db"
            case .hermesBinaryNonLogin:   return "hermes binary on non-login PATH"
            case .hermesBinaryLogin:      return "hermes binary on login PATH (via rc files)"
            case .pgrepAvailable:         return "pgrep available (for 'is Hermes running')"
            }
        }

        /// When the check fails, show this hint alongside the stderr.
        var failureHint: String? {
            switch self {
            case .connectivity:
                return "SSH itself can't complete. Before re-testing in Scarf, confirm `ssh <host>` works in Terminal."
            case .remoteUser, .remoteHome:
                return nil
            case .hermesHomeConfigured:
                return nil
            case .hermesDirExists:
                return "Scarf is looking at the default `~/.hermes`. If Hermes is installed elsewhere (e.g. `/var/lib/hermes/.hermes` for systemd installs), set the Hermes home directory in Manage Servers → this server → Edit."
            case .hermesDirReadable:
                return "The SSH user can see `~/.hermes` but can't list it. Check permissions: `ls -ld ~/.hermes` on the remote — the SSH user needs at least `r-x`."
            case .configYAMLReadable, .configYAMLContents:
                return "Scarf can't read `config.yaml`. This usually means the SSH user is different from the user Hermes runs as. Either (a) run Hermes as the SSH user, (b) `chmod a+r ~/.hermes/config.yaml`, or (c) configure Scarf to SSH as the Hermes user."
            case .stateDBReadable:
                return "Scarf can't read `state.db` — Sessions, Activity, Dashboard stats all depend on this. Same fix pattern as config.yaml."
            case .sqlite3Installed:
                return "Scarf pulls a snapshot of state.db via `sqlite3 .backup`, so sqlite3 must be installed on the remote. Install: `sudo apt install sqlite3` (Ubuntu/Debian), `sudo yum install sqlite` (RHEL/Fedora), `apk add sqlite` (Alpine)."
            case .sqlite3CanOpenStateDB:
                return "sqlite3 exists but can't open state.db. Could be a permission issue, a corrupt DB, or a version skew."
            case .hermesBinaryNonLogin:
                return "Scarf's runtime calls use non-login SSH shells (no .bashrc). If `hermes` only appears here via the login path, runtime CLI calls will fail. Move your PATH export from `.bashrc` to `.zshenv` or `.profile`."
            case .hermesBinaryLogin:
                return "hermes couldn't be located even after sourcing login rc files. Install path is non-standard — set the hermes binary path manually in Manage Servers."
            case .pgrepAvailable:
                return "pgrep not found on remote. Dashboard can't determine whether Hermes is running. Install procps: `apt install procps` (most distros have it by default)."
            }
        }
    }

    struct Probe: Identifiable, Sendable {
        let id: ProbeID
        let passed: Bool
        let detail: String
    }

    private(set) var probes: [Probe] = []
    private(set) var isRunning: Bool = false
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Raw stdout/stderr from the most recent run, preserved so the UI can
    /// surface them in a disclosure panel when things look wrong. This is
    /// how we debug cases where the script ran but no probes were parsed
    /// (e.g. transport-quoting bugs, dash-vs-bash incompatibilities).
    private(set) var rawStdout: String = ""
    private(set) var rawStderr: String = ""
    private(set) var rawExitCode: Int32 = 0

    init(context: ServerContext) {
        self.context = context
    }

    /// Kick off the full check list. Safe to call again to re-run.
    func run() async {
        if isRunning { return }
        isRunning = true
        probes = []
        startedAt = Date()
        finishedAt = nil

        let script = Self.buildScript(hermesHome: context.paths.home)
        // Use the shared SSHScriptRunner so this view model and the
        // ConnectionStatusViewModel pill always agree on what the
        // remote sees (issue #44 — the prior local copies of the
        // workaround drifted from each other).
        let captured = await SSHScriptRunner.run(script: script, context: context, timeout: 30)

        switch captured {
        case .connectFailure(let msg):
            rawStdout = ""
            rawStderr = msg
            rawExitCode = -1
            probes = [
                Probe(id: .connectivity, passed: false, detail: msg)
            ] + ProbeID.allCases
                .filter { $0 != .connectivity }
                .map { Probe(id: $0, passed: false, detail: "(skipped — SSH didn't connect)") }
        case .completed(let stdout, let stderr, let exitCode):
            rawStdout = stdout
            rawStderr = stderr
            rawExitCode = exitCode
            probes = Self.parse(stdout: stdout, stderr: stderr, exitCode: exitCode)
        }

        finishedAt = Date()
        isRunning = false
        Self.logger.info("Diagnostics for \(self.context.displayName, privacy: .public) finished — \(self.passingCount)/\(self.probes.count) passing")
    }

    /// Quick summary string, e.g. "9/14 passing". Used in the header.
    var summary: String {
        guard !probes.isEmpty else { return "Not yet run." }
        return "\(passingCount)/\(probes.count) checks passing"
    }

    var passingCount: Int {
        probes.filter { $0.passed }.count
    }

    var allPassed: Bool {
        !probes.isEmpty && passingCount == probes.count
    }

    // MARK: - Script + parsing

    /// Build the remote shell script. Uses a pipe-delimited protocol so the
    /// Swift side can parse without regex surprises. Status is `PASS` or
    /// `FAIL`; detail is a single line (can be blank). `__END__` at the
    /// bottom lets us detect truncation.
    private static func buildScript(hermesHome: String) -> String {
        // Shell-quote the home path — user may have typed `~/.hermes` which
        // we want the remote shell to expand, so we substitute `~/` with
        // `$HOME/` like `SSHTransport.remotePathArg` does.
        let expanded: String
        if hermesHome.hasPrefix("~/") {
            expanded = "\"$HOME/\(hermesHome.dropFirst(2))\""
        } else if hermesHome == "~" {
            expanded = "\"$HOME\""
        } else {
            // Absolute path — still quote in case of spaces.
            expanded = "\"\(hermesHome.replacingOccurrences(of: "\"", with: "\\\""))\""
        }

        return #"""
        H=\#(expanded)
        emit() { printf '%s|%s|%s\n' "$1" "$2" "$3"; }

        emit connectivity PASS "(running in this shell)"

        user=$(id -un 2>/dev/null || echo unknown)
        emit remoteUser PASS "$user"

        emit remoteHome PASS "$HOME"

        emit hermesHomeConfigured PASS "$H"

        if [ -d "$H" ]; then
            emit hermesDirExists PASS "$H"
        else
            emit hermesDirExists FAIL "not a directory: $H"
        fi

        if [ -r "$H" ] && [ -x "$H" ]; then
            emit hermesDirReadable PASS ""
        else
            emit hermesDirReadable FAIL "cannot read/enter $H (check perms on the dir)"
        fi

        if [ -r "$H/config.yaml" ]; then
            emit configYAMLReadable PASS ""
        else
            if [ -e "$H/config.yaml" ]; then
                emit configYAMLReadable FAIL "exists but not readable by $user"
            else
                emit configYAMLReadable FAIL "file does not exist"
            fi
        fi

        if head -c 1 "$H/config.yaml" > /dev/null 2>&1; then
            size=$(wc -c < "$H/config.yaml" 2>/dev/null | tr -d ' ')
            emit configYAMLContents PASS "${size} bytes"
        else
            emit configYAMLContents FAIL "cannot read file contents"
        fi

        if [ -r "$H/state.db" ]; then
            size=$(wc -c < "$H/state.db" 2>/dev/null | tr -d ' ')
            emit stateDBReadable PASS "${size} bytes"
        else
            if [ -e "$H/state.db" ]; then
                emit stateDBReadable FAIL "exists but not readable by $user"
            else
                emit stateDBReadable FAIL "file does not exist"
            fi
        fi

        if command -v sqlite3 > /dev/null 2>&1; then
            sq=$(command -v sqlite3)
            emit sqlite3Installed PASS "$sq"
        else
            emit sqlite3Installed FAIL "sqlite3 not on PATH"
        fi

        if sqlite3 "$H/state.db" 'SELECT 1' > /dev/null 2>&1; then
            emit sqlite3CanOpenStateDB PASS ""
        else
            err=$(sqlite3 "$H/state.db" 'SELECT 1' 2>&1 | head -1)
            emit sqlite3CanOpenStateDB FAIL "$err"
        fi

        # Non-login PATH: just ask the current shell.
        hpath=$(command -v hermes 2>/dev/null)
        if [ -n "$hpath" ]; then
            emit hermesBinaryNonLogin PASS "$hpath"
        else
            emit hermesBinaryNonLogin FAIL "not on non-login PATH ($PATH)"
        fi

        # Login PATH: source rc files (mirroring TestConnectionProbe) and re-probe.
        for rc in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.profile"; do
            [ -f "$rc" ] && . "$rc" 2>/dev/null
        done
        hpath2=$(command -v hermes 2>/dev/null)
        if [ -z "$hpath2" ]; then
            for cand in "$HOME/.local/bin/hermes" "/opt/homebrew/bin/hermes" "/usr/local/bin/hermes" "$HOME/.hermes/bin/hermes"; do
                if [ -x "$cand" ]; then hpath2="$cand"; break; fi
            done
        fi
        if [ -n "$hpath2" ]; then
            emit hermesBinaryLogin PASS "$hpath2"
        else
            emit hermesBinaryLogin FAIL "not found after sourcing rc files"
        fi

        if command -v pgrep > /dev/null 2>&1; then
            emit pgrepAvailable PASS "$(command -v pgrep)"
        else
            emit pgrepAvailable FAIL "pgrep not on PATH"
        fi

        printf '__END__\n'
        """#
    }

    private static func parse(stdout: String, stderr: String, exitCode: Int32) -> [Probe] {
        var results: [ProbeID: Probe] = [:]
        for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let status = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let detail = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard let probe = ProbeID(rawValue: key) else { continue }
            results[probe] = Probe(
                id: probe,
                passed: status == "PASS",
                detail: detail
            )
        }

        // If the script didn't complete, fill in the missing probes so the UI
        // still shows every expected row (rather than silently skipping).
        let terminated = stdout.contains("__END__")
        let fallbackDetail: String
        if terminated {
            fallbackDetail = "(no output)"
        } else if exitCode != 0 {
            fallbackDetail = "(script exited \(exitCode) before this check — stderr: \(stderr.prefix(200)))"
        } else {
            fallbackDetail = "(no output from script)"
        }

        return ProbeID.allCases.map { id in
            results[id] ?? Probe(id: id, passed: false, detail: fallbackDetail)
        }
    }
}
