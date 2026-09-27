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
            case .configYAMLReadable:     return "config.yaml readable (optional)"
            case .configYAMLContents:     return "config.yaml content (optional)"
            case .stateDBReadable:        return "state.db readable"
            case .sqlite3Installed:       return "sqlite3 binary installed on remote"
            case .sqlite3CanOpenStateDB:  return "sqlite3 can open state.db"
            case .hermesBinaryNonLogin:   return "hermes binary on non-login PATH"
            case .hermesBinaryLogin:      return "hermes binary on login shell's PATH"
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
                // Reached only when the file EXISTS but is unreadable —
                // a real permission issue. The "file absent" case emits
                // SKIP (Hermes v0.11+ creates config.yaml lazily, only
                // when the user changes a setting from defaults).
                return "`config.yaml` exists on the remote but the SSH user can't read it. Either (a) run Hermes as the SSH user, (b) `chmod a+r ~/.hermes/config.yaml`, or (c) configure Scarf to SSH as the Hermes user. If `config.yaml` is missing entirely, that's fine — Hermes only creates it when you change a setting from the defaults."
            case .stateDBReadable:
                return "Scarf can't read `state.db` — Sessions, Activity, Dashboard stats all depend on this. Either (a) run Hermes as the SSH user, (b) `chmod a+r ~/.hermes/state.db`, or (c) configure Scarf to SSH as the Hermes user."
            case .sqlite3Installed:
                return "Scarf pulls a snapshot of state.db via `sqlite3 .backup`, so sqlite3 must be installed on the remote AND visible to non-interactive SSH sessions. The probe uses your login shell's PATH and falls back to `/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, and `/opt/local/bin` — if it's still not found, either install via your package manager (`sudo apt install sqlite3` / `sudo yum install sqlite` / `apk add sqlite`) or symlink the existing binary into a location the probe checks (e.g. `sudo ln -s /your/path/sqlite3 /usr/local/bin/sqlite3`)."
            case .sqlite3CanOpenStateDB:
                return "sqlite3 exists but can't open state.db. Could be a permission issue, a corrupt DB, or a version skew."
            case .hermesBinaryNonLogin:
                return "Scarf's runtime calls use non-login SSH shells (no .bashrc), with `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.hermes/bin` added to PATH. When this server has a saved Hermes binary, that is what this check looks for. If `hermes` lives somewhere else and only appears via the login path, runtime CLI calls will fail. Move your PATH export from `.bashrc` to `.zshenv` or `.profile`, or set the Hermes binary in Manage Servers → this server → Edit."
            case .hermesBinaryLogin:
                return "hermes couldn't be located on your login shell's PATH or in the standard install directories. If this server has a saved Hermes binary, check that it still exists; otherwise set the Hermes binary in Manage Servers → this server → Edit."
            case .pgrepAvailable:
                return "pgrep not found on remote. Dashboard can't determine whether Hermes is running. Install procps: `apt install procps` (most distros have it by default)."
            }
        }
    }

    /// Tri-state probe outcome. `.skipped` covers checks that didn't
    /// run because they aren't applicable (e.g. config.yaml absence on
    /// a fresh Hermes v0.11+ install — the file is created lazily, so
    /// missing is normal). UI renders skipped probes with a grey info
    /// icon and excludes them from "X/Y failing" tallies.
    enum ProbeStatus: Sendable, Equatable {
        case pass
        case fail
        case skipped
    }

    struct Probe: Identifiable, Sendable {
        let id: ProbeID
        let status: ProbeStatus
        let detail: String

        /// Back-compat for callers (Copy Full Report, view counters)
        /// that still think in pass/fail. Skipped probes report `true`
        /// so they don't count as failures.
        var passed: Bool { status != .fail }
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

        let binaryHint: String?
        let binaryHintIsPath: Bool
        if case .ssh(let cfg) = context.kind {
            binaryHint = cfg.hermesBinaryHint
            binaryHintIsPath = cfg.hermesBinaryHintIsPath == true
        } else {
            binaryHint = nil
            binaryHintIsPath = false
        }
        let script = Self.buildScript(
            hermesHome: context.paths.home,
            binaryHint: binaryHint, binaryHintIsPath: binaryHintIsPath)
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
                Probe(id: .connectivity, status: .fail, detail: msg)
            ] + ProbeID.allCases
                .filter { $0 != .connectivity }
                .map { Probe(id: $0, status: .fail, detail: "(skipped — SSH didn't connect)") }
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

    /// Quick summary string. Skipped probes (e.g. config.yaml absent
    /// on a fresh Hermes v0.11+ install) are excluded from the
    /// denominator so the user sees "12/12 passing" instead of a
    /// misleading "12/14 passing." When any probe is skipped we
    /// append a parenthetical so it's still visible at a glance.
    var summary: String {
        guard !probes.isEmpty else { return "Not yet run." }
        let total = probes.filter { $0.status != .skipped }.count
        var s = "\(passingCount)/\(total) checks passing"
        if skippedCount > 0 {
            s += " (\(skippedCount) optional skipped)"
        }
        return s
    }

    var passingCount: Int {
        probes.filter { $0.status == .pass }.count
    }

    var skippedCount: Int {
        probes.filter { $0.status == .skipped }.count
    }

    var failingCount: Int {
        probes.filter { $0.status == .fail }.count
    }

    /// True iff every applicable probe passed — skipped probes don't
    /// block the green-banner state because they're informational.
    var allPassed: Bool {
        !probes.isEmpty && failingCount == 0
    }

    // MARK: - Script + parsing

    /// Build the remote shell script. Uses a pipe-delimited protocol so the
    /// Swift side can parse without regex surprises. Status is `PASS` or
    /// `FAIL`; detail is a single line (can be blank). `__END__` at the
    /// bottom lets us detect truncation.
    ///
    /// `binaryHint` is the server's saved Hermes binary (T6-F4). When set,
    /// the two hermes checks look for it, the way the runtime runs it: a
    /// path Test Connection found (`binaryHintIsPath`) is one word, and a
    /// typed command line (`docker compose exec hermes hermes`) is checked
    /// by its first word. Without one they look for `hermes`, as before.
    nonisolated static func buildScript(
        hermesHome: String, binaryHint: String? = nil, binaryHintIsPath: Bool = false
    ) -> String {
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
        // Escaped for a double-quoted sh string, as TestConnectionProbe does.
        let hint = (binaryHint ?? "").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")

        return #"""
        H=\#(expanded)
        HINT="\#(hint)"
        HINT_IS_PATH=\#(binaryHintIsPath ? "1" : "0")
        emit() { printf '%s|%s|%s\n' "$1" "$2" "$3"; }
        # The word the runtime runs: the saved Hermes binary (its first
        # word for a typed command line, all of it for a probed path),
        # else plain `hermes`.
        hermes_word() {
            if [ -z "$HINT" ]; then printf '%s' hermes; return; fi
            if [ "$HINT_IS_PATH" = 1 ]; then w="$HINT"; else w=$(printf '%s\n' "$HINT" | awk '{print $1}'); fi
            case "$w" in
                "~") w="$HOME" ;;
                "~/"*) w="$HOME/${w#??}" ;;
            esac
            printf '%s' "$w"
        }
        hermes_what() {
            if [ -n "$HINT" ]; then printf 'saved Hermes binary "%s"' "$HINT"; else printf '%s' hermes; fi
        }

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

        # config.yaml is OPTIONAL on Hermes v0.11+ — the file is created
        # lazily when the user changes a setting from defaults. So a
        # working fresh install is expected to have no config.yaml.
        # The probe distinguishes:
        #   PASS — file exists and is readable
        #   SKIP — file is absent (informational, not a failure)
        #   FAIL — file exists but the SSH user can't read it (real perm issue)
        if [ -r "$H/config.yaml" ]; then
            emit configYAMLReadable PASS ""
        else
            if [ -e "$H/config.yaml" ]; then
                emit configYAMLReadable FAIL "exists but not readable by $user"
            else
                emit configYAMLReadable SKIP "not present (Hermes creates it on first config change)"
            fi
        fi

        if [ -e "$H/config.yaml" ]; then
            if head -c 1 "$H/config.yaml" > /dev/null 2>&1; then
                size=$(wc -c < "$H/config.yaml" 2>/dev/null | tr -d ' ')
                emit configYAMLContents PASS "${size} bytes"
            else
                emit configYAMLContents FAIL "cannot read file contents"
            fi
        else
            emit configYAMLContents SKIP "not present (no content to read)"
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

        # Non-login PATH probe for `hermes` runs BEFORE sourcing rc files,
        # with the same install dirs Scarf's SSH transport appends to every
        # remote command (`HermesConfigReader.pathFallback`, S15-F1) — so it
        # answers "will Scarf's runtime calls find hermes?", and a stock
        # `~/.local/bin` install passes.
        hw=$(hermes_word)
        hpath=$(PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin"; command -v "$hw" 2>/dev/null)
        if [ -n "$hpath" ]; then
            emit hermesBinaryNonLogin PASS "$hpath"
        else
            emit hermesBinaryNonLogin FAIL "$(hermes_what) not on non-login PATH ($PATH)"
        fi

        # Borrow the login shell's PATH (the same line TestConnectionProbe
        # uses) so the checks below see the user's full login PATH:
        # sqlite3 / hermes-login detection happens AFTER this so installs
        # in Homebrew / `/usr/local/bin` / pipx / etc. are findable on hosts
        # where the non-login SSH session inherits a stripped PATH (issue
        # #19). The rc files are NOT sourced into this sh any more: under
        # dash one zsh-only line in them ended the whole script, and every
        # check after it showed as FAILED (T6-F2).
        \#(TestConnectionProbe.loginPathBorrow)

        # Login-PATH `hermes` probe, with the install candidates as a
        # fallback when no Hermes binary is saved.
        hpath2=$(command -v "$hw" 2>/dev/null)
        if [ -z "$hpath2" ] && [ -z "$HINT" ]; then
            for cand in "$HOME/.local/bin/hermes" "/opt/homebrew/bin/hermes" "/usr/local/bin/hermes" "$HOME/.hermes/bin/hermes"; do
                if [ -x "$cand" ]; then hpath2="$cand"; break; fi
            done
        fi
        if [ -n "$hpath2" ]; then
            emit hermesBinaryLogin PASS "$hpath2"
        else
            emit hermesBinaryLogin FAIL "$(hermes_what) not found on the login shell's PATH"
        fi

        # sqlite3 detection — also after sourcing rc files, with a
        # standard-location fallback that mirrors the hermes probe
        # above. Pre-fix this was a bare `command -v sqlite3` in the
        # non-login shell, which produced false negatives on Homebrew
        # / `/usr/local/bin` installs (issue #19 layer 3).
        sqbin=$(command -v sqlite3 2>/dev/null)
        if [ -z "$sqbin" ]; then
            for cand in "/usr/bin/sqlite3" "/usr/local/bin/sqlite3" "/opt/homebrew/bin/sqlite3" "/opt/local/bin/sqlite3"; do
                if [ -x "$cand" ]; then sqbin="$cand"; break; fi
            done
        fi
        if [ -n "$sqbin" ]; then
            emit sqlite3Installed PASS "$sqbin"
        else
            emit sqlite3Installed FAIL "not found on PATH or in standard locations"
        fi

        # Use the resolved sqlite3 path explicitly so the open-state.db
        # probe doesn't re-fail-by-PATH when the binary is at e.g.
        # /opt/homebrew/bin. Falls back to bare `sqlite3` so the FAIL
        # detail line (with the underlying error) is still informative
        # if no candidate was found.
        sqcmd="${sqbin:-sqlite3}"
        if "$sqcmd" "$H/state.db" 'SELECT 1' > /dev/null 2>&1; then
            emit sqlite3CanOpenStateDB PASS ""
        else
            err=$("$sqcmd" "$H/state.db" 'SELECT 1' 2>&1 | head -1)
            emit sqlite3CanOpenStateDB FAIL "$err"
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
            let statusRaw = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let detail = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard let probe = ProbeID(rawValue: key) else { continue }
            let status: ProbeStatus
            switch statusRaw {
            case "PASS": status = .pass
            case "SKIP": status = .skipped
            default:     status = .fail
            }
            results[probe] = Probe(
                id: probe,
                status: status,
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
            results[id] ?? Probe(id: id, status: .fail, detail: fallbackDetail)
        }
    }
}
