import Foundation
#if canImport(os)
import os
#endif

/// `ServerTransport` that reaches a remote Hermes installation through the
/// system `ssh`, `scp`, and `sftp` binaries.
///
/// Why system ssh (not a native library): the user's `~/.ssh/config`,
/// ssh-agent, 1Password/Secretive agents, ProxyJump, and ControlMaster
/// multiplexing all work for free. OpenSSH also owns crypto — a smaller
/// audit surface than dragging libssh2 along.
///
/// **ControlMaster matters.** Without it, every remote primitive (stat, cat,
/// cp) authenticates from scratch — 500ms-2s per call. With ControlMaster
/// `auto` + `ControlPersist 600`, the first call authenticates, subsequent
/// calls reuse the same TCP/crypto session at ~5ms each. We point the
/// control socket at `~/Library/Caches/scarf/ssh/%C` so multiple Scarf
/// windows pointed at the same host share one session cleanly.
public struct SSHTransport: ServerTransport {
    #if canImport(os)
    nonisolated private static let logger = Logger(subsystem: "com.scarf", category: "SSHTransport")
    #endif

    public let contextID: ServerID
    public let isRemote: Bool = true

    public let config: SSHConfig
    public let displayName: String

    public nonisolated init(contextID: ServerID, config: SSHConfig, displayName: String) {
        self.contextID = contextID
        self.config = config
        self.displayName = displayName
    }

    // MARK: - ssh/scp binary discovery

    nonisolated private var sshBinary: String { "/usr/bin/ssh" }
    nonisolated private var scpBinary: String { "/usr/bin/scp" }

    /// The fully-qualified `user@host` spec (or just `host` if no user set).
    nonisolated private var hostSpec: String {
        if let user = config.user, !user.isEmpty { return "\(user)@\(config.host)" }
        return config.host
    }

    /// Absolute path to this server's ControlMaster socket directory. One
    /// socket per server, lives under the app's Caches so macOS can sweep it.
    nonisolated private var controlDir: String { Self.controlDirPath() }

    /// Circuit-breaker key for this endpoint (gh#138). All gate accounting
    /// for this transport — and for `SSHScriptRunner` against the same
    /// config — uses this key.
    nonisolated var gateKey: String { SSHConnectionGate.key(host: config.host, port: config.port) }

    /// Per-server snapshot cache directory (for SQLite `.backup` drops).
    nonisolated private var snapshotDir: String { Self.snapshotDirPath(for: contextID) }

    /// Shared control-master socket directory (one dir, sockets within it are
    /// per-host via OpenSSH's `%C` token). Exposed as a static so
    /// cleanup paths (`ServerRegistry.removeServer`, app-launch sweep) can
    /// compute it without instantiating a transport.
    ///
    /// Uses a short path under /tmp to stay within the 104-byte macOS
    /// Unix domain socket limit. The Caches path
    /// (~/Library/Caches/scarf/ssh/%C) can exceed this limit when the
    /// username is long, causing ssh to exit 255.
    public nonisolated static func controlDirPath() -> String {
        return "/tmp/scarf-ssh-\(getuid())"
    }

    /// Snapshot cache directory for a given server. Stable per-ID so repeated
    /// connections to the same server share the cache, and so cleanup can
    /// find it from the ID alone.
    public nonisolated static func snapshotDirPath(for contextID: ServerID) -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Caches"
        return base + "/scarf/snapshots/\(contextID.uuidString)"
    }

    /// Root of the snapshot cache (all servers). Used by the app-launch sweep
    /// that prunes dirs whose UUID no longer appears in the registry.
    public nonisolated static func snapshotRootPath() -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Caches"
        return base + "/scarf/snapshots"
    }

    /// Remove the snapshot directory for a server (no-op if absent). Called
    /// on `removeServer` and on app-launch for orphaned dirs.
    public static func pruneSnapshotCache(for contextID: ServerID) {
        let dir = snapshotDirPath(for: contextID)
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Walk the snapshot root and delete any directory whose UUID isn't in
    /// `keep`. Called once at app launch so snapshots from servers the user
    /// removed while the app was closed don't linger.
    public static func sweepOrphanSnapshots(keeping keep: Set<ServerID>) {
        let root = snapshotRootPath()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in entries {
            if let id = ServerID(uuidString: name), keep.contains(id) { continue }
            try? FileManager.default.removeItem(atPath: root + "/" + name)
        }
    }

    /// Remove ControlMaster socket files older than `staleAfter` seconds.
    ///
    /// Socket basenames are %C hashes (not ServerIDs), so we can't keep "still
    /// registered" sockets the way `sweepOrphanSnapshots` does. But
    /// `ControlPersist` is 600s — anything older than 30 minutes is guaranteed
    /// to be a dead orphan from a crashed master, an unclean app exit, or a
    /// server removed while another Scarf instance was holding the dir.
    /// Wiping these on launch keeps `/tmp/scarf-ssh-<uid>/` from accumulating
    /// indefinitely until reboot, while leaving any concurrent Scarf
    /// instance's live sockets (always <600s old) untouched.
    public static func sweepStaleControlSockets(staleAfter: TimeInterval = 1800) {
        let root = controlDirPath()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        let cutoff = Date().addingTimeInterval(-staleAfter)
        for name in entries {
            let path = root + "/" + name
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            if mtime < cutoff {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Ask OpenSSH to shut down this host's ControlMaster socket, so the TCP
    /// session isn't held open after the user removes this server. If no
    /// master is currently running, `ssh -O exit` exits non-zero — we ignore
    /// the exit code because the desired end state (no master) is reached
    /// either way.
    public func closeControlMaster() {
        ensureControlDir()
        let args = sshArgs(extra: ["-O", "exit", hostSpec])
        _ = try? runLocal(executable: sshBinary, args: args, stdin: nil, timeout: 10, gate: .none)
    }

    /// Recover from a ControlMaster whose TCP session died while its master
    /// lingers holding the socket — the post-sleep/network-change state
    /// behind gh#123. `ControlMaster=auto` routes every subsequent ssh
    /// through the corpse, where it hangs for its full timeout, so a
    /// "worked yesterday" remote reads as permanently stuck; until now the
    /// only path that issued `-O exit` was removing the server.
    ///
    /// Two steps so healthy masters are spared: `-O check` asks whether a
    /// master owns the socket at all (local round-trip, no TCP), and only
    /// when one does, a trivial muxed remote command probes the session
    /// behind it. A hang or non-zero exit → `-O exit`, so the next caller
    /// handshakes fresh instead of joining the corpse.
    ///
    /// The return value exists so the caller can report *what happened* (see
    /// the wake sweep in the macOS app, which turns it into one
    /// `reconnect_attempted`/`reconnect_succeeded` pair per wake) without
    /// re-probing.
    public enum ControlMasterRecovery: Sendable, Equatable {
        /// No master owned the socket — nothing to recover, and no evidence
        /// either way about the host.
        case noMaster
        /// A master was there and the session behind it answered.
        case alive
        /// A master was there, the session behind it was dead, and we tore
        /// the socket down so the next caller handshakes fresh.
        case recovered
    }

    @discardableResult
    public func recoverControlMasterIfDead(probeTimeout: TimeInterval = 10) -> ControlMasterRecovery {
        ensureControlDir()
        let check = try? runLocal(
            executable: sshBinary,
            args: sshArgs(extra: ["-O", "check", hostSpec]),
            stdin: nil,
            timeout: 5,
            gate: .none
        )
        guard let check, check.exitCode == 0 else { return .noMaster }

        let probe = try? runLocal(
            executable: sshBinary,
            args: sshArgs(extra: [hostSpec, "true"]),
            stdin: nil,
            timeout: probeTimeout
        )
        if (probe?.exitCode ?? 1) != 0 {
            closeControlMaster()
            return .recovered
        }
        return .alive
    }

    /// Common ssh options used by every invocation. Keep every `-o` flag
    /// here so we never drift between calls.
    ///
    /// - `ControlMaster=auto` + `ControlPersist=600` gives us free connection
    ///   pooling for the bursty stat/cat/cp traffic the services produce.
    /// - `StrictHostKeyChecking=accept-new` writes new hosts to
    ///   `known_hosts` silently the first time but blocks on key mismatch —
    ///   the UX surfaced by `TransportError.hostKeyMismatch`.
    /// - `ServerAliveInterval=30` makes dropped connections surface as a
    ///   process exit rather than a hang.
    /// - `LogLevel=QUIET` suppresses the login banner so ACP's line-delimited
    ///   JSON stays binary-clean.
    nonisolated private func sshArgs(extra: [String] = []) -> [String] {
        var args: [String] = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDir)/%C",
            "-o", "ControlPersist=600",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=QUIET",
            "-o", "BatchMode=yes"  // Never prompt for passphrases; ssh-agent only.
        ]
        if let port = config.port { args += ["-p", String(port)] }
        if let id = config.identityFile, !id.isEmpty {
            args += ["-i", id]
        }
        args += extra
        return args
    }

    /// Ensure the ControlMaster socket directory exists, is a real directory
    /// (not a symlink), is owned by us, and has mode 0700. Called before every
    /// ssh invocation.
    ///
    /// Defensive against `/tmp` pre-creation: any local user can create
    /// `/tmp/scarf-ssh-<uid>` before Scarf launches. Plain `mkdir -p` plus
    /// `setAttributes` would silently accept a hostile dir (since the chmod
    /// fails when we don't own it, and the Foundation API swallows that). So
    /// we use POSIX `mkdir` (atomic, sets perms at create time, doesn't
    /// follow symlinks) and `lstat` to verify ownership when the entry
    /// already exists.
    nonisolated private func ensureControlDir() {
        #if canImport(Darwin)
        let path = controlDir

        let mkResult = path.withCString { mkdir($0, 0o700) }
        if mkResult == 0 { return }

        let mkErr = errno
        if mkErr != EEXIST {
            Self.logger.error("Failed to create ControlDir \(path, privacy: .public): errno=\(mkErr)")
            return
        }

        var st = Darwin.stat()
        let lstatResult = path.withCString { lstat($0, &st) }
        guard lstatResult == 0 else {
            Self.logger.error("Could not lstat existing ControlDir \(path, privacy: .public): errno=\(errno)")
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            Self.logger.error("ControlDir \(path, privacy: .public) exists but is not a directory (possibly a symlink) — refusing to use")
            return
        }
        guard st.st_uid == getuid() else {
            Self.logger.error("ControlDir \(path, privacy: .public) owned by uid \(st.st_uid), expected \(getuid()) — refusing to use")
            return
        }
        if (st.st_mode & 0o777) != 0o700 {
            Self.logger.warning("ControlDir \(path, privacy: .public) had mode \(String(st.st_mode & 0o777, radix: 8), privacy: .public), repairing to 700")
            _ = path.withCString { chmod($0, 0o700) }
        }
        #else
        // Linux (CI-only) stub: SSH isn't exercised at runtime on Linux, so
        // we don't need a real ControlMaster setup. A best-effort mkdir is
        // enough for any tests that poke at `controlDir`.
        try? FileManager.default.createDirectory(atPath: controlDir, withIntermediateDirectories: true)
        #endif
    }

    /// Shell-quote a single argument for remote execution. The remote shell
    /// receives our argv joined with spaces, so anything containing
    /// whitespace/metacharacters must be quoted to survive that flattening.
    nonisolated private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        // Safe subset: alphanumerics + a few shell-inert characters.
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        // Wrap in single quotes; close/reopen around any embedded single quote.
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Format a path for inclusion in a remote `sh -c` command. **Critical**
    /// for any path containing `~/`: bash/zsh do NOT expand `~` inside
    /// quotes (single OR double), so a single-quoted `'~/.hermes/foo'` is
    /// passed to commands as the literal seven-character string
    /// `~/.hermes/foo` and lookups fail. We rewrite the leading `~/` to
    /// `$HOME/` (which DOES expand inside double quotes) and emit the path
    /// double-quoted so embedded spaces / metacharacters are still safe.
    ///
    /// Why not single-quote: that would make `$HOME` literal too. We
    /// specifically need partial-expansion semantics, which is what double
    /// quotes give us.
    nonisolated private static func remotePathArg(_ path: String) -> String {
        // Neutralize shell-active metacharacters in the (user-influenced) path
        // FIRST — inside the double quotes below, an injected `$(…)`, backtick,
        // or `$VAR` would otherwise expand / run as command substitution on the
        // remote. Mirrors `HermesProfileScope.shellQuoteHome`.
        var p = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        // THEN apply the `~/`→`$HOME/` rewrite, inserting an intentionally-live
        // `$HOME` AFTER escaping so it still expands inside the double quotes
        // (the whole reason we double-quote rather than single-quote).
        if p.hasPrefix("~/") {
            p = "$HOME/" + p.dropFirst(2)
        } else if p == "~" {
            p = "$HOME"
        }
        return "\"\(p)\""
    }

    /// Quote the path half of an `scp` `host:path` argument.
    ///
    /// `scp`'s remote spec is expanded by a shell on the far side, so an
    /// unquoted path containing a space (`~/My Projects/…`) is split into
    /// two arguments and the transfer either fails or lands somewhere
    /// unintended. A leading `~/` is deliberately left OUTSIDE the quotes:
    /// tilde expansion doesn't happen inside them, and every remote path
    /// Scarf writes is home-relative.
    nonisolated static func scpRemoteSpec(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return "~/" + shellQuote(String(path.dropFirst(2)))
        }
        return shellQuote(path)
    }

    /// Run a remote shell command. Wraps in `sh -c '<command>'` and uses
    /// the standard ssh-after-host placement (no `--` separator — that
    /// would be sent to the remote shell as a literal first token, which
    /// most shells reject as "command not found"). The `command` is
    /// single-quoted via `shellQuote` so ssh's argv-join-by-space doesn't
    /// split it across multiple shell tokens on the remote side.
    @discardableResult
    nonisolated private func runRemoteShell(_ command: String, timeout: TimeInterval? = 60) throws -> ProcessResult {
        var args = sshArgs()
        // `-T` disables pty allocation, exactly as `makeProcess` /
        // `streamLines` / `streamRawBytes` already do. Without it a user's
        // `RequestTTY yes` in `~/.ssh/config` — or an interactive-shell
        // banner from a chatty `~/.zshenv` — gets interleaved into stdout,
        // which for `readFile` means `cat` bytes come back with junk
        // prepended: the registry then decodes as damage and is quarantined
        // on a file that was never corrupt.
        args.insert("-T", at: 0)
        args.append(hostSpec)
        args.append("sh")
        args.append("-c")
        args.append(Self.shellQuote(command))
        return try runLocal(executable: sshBinary, args: args, stdin: nil, timeout: timeout)
    }

    // MARK: - Files

    public func readFile(_ path: String) throws -> Data {
        // `cat` is the simplest portable "give me file bytes" command; we
        // don't need scp's progress machinery for typical config/memory
        // files (<1 MB each).
        let result = try runRemoteShell("cat \(Self.remotePathArg(path))")
        if result.exitCode != 0 {
            let errText = result.stderrString
            // Missing file looks like exit 1 + "No such file" — surface as a
            // typed fileIO error so callers that treat missing == "empty"
            // behave the same as they do locally.
            if errText.contains("No such file") {
                throw TransportError.fileIO(path: path, underlying: "No such file or directory")
            }
            throw TransportError.classifySSHFailure(host: config.host, exitCode: result.exitCode, stderr: errText)
        }
        return result.stdout
    }

    public func writeFile(_ path: String, data: Data) throws {
        // Atomic pattern:
        //   1. scp to `<path>.scarf-<nonce>.tmp` on the remote
        //   2. ssh `mv <tmp> <path>` — atomic on POSIX within the same FS
        // Hermes never sees a partial write.
        //
        // The staging name carries a per-write nonce. A constant
        // `<path>.scarf.tmp` made the PUBLISH atomic but the STAGING shared:
        // two writers (the app and the MCP helper, or two windows on one
        // host) uploading concurrently interleave their bytes in the one
        // temp file, and whichever `mv` runs second publishes the other
        // writer's partial content — an atomic rename of corrupt bytes,
        // which no refusal guard upstream can see.
        let tmp = path + ".scarf-\(UUID().uuidString.prefix(8)).tmp"

        // scp from a local temp file (scp reads from disk, not stdin).
        let localTmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scarf-scp-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: localTmpURL)
        } catch {
            throw TransportError.fileIO(path: path, underlying: "local temp write: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: localTmpURL) }

        ensureControlDir()
        var scpArgs: [String] = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDir)/%C",
            "-o", "ControlPersist=600",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=QUIET",
            "-o", "BatchMode=yes"
        ]
        if let port = config.port { scpArgs += ["-P", String(port)] }
        if let id = config.identityFile, !id.isEmpty { scpArgs += ["-i", id] }
        scpArgs.append(localTmpURL.path)
        scpArgs.append("\(hostSpec):\(Self.scpRemoteSpec(tmp))")

        var scpResult = try runLocal(executable: scpBinary, args: scpArgs, stdin: nil, timeout: 60, gate: .admitOnly)
        if scpResult.exitCode != 0 {
            // Parity with `LocalTransport`, which mkdir -p's the parent
            // before writing: a caller handing us a path whose directory
            // was never created (a profile's first `.env`, a project's
            // first `.scarf/`) fails here with "No such file or directory"
            // where the same call succeeds locally. Retry ONCE behind a
            // `mkdir -p`, so the happy path still costs exactly one scp.
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != path {
                _ = try? runRemoteShell("mkdir -p \(Self.remotePathArg(parent))")
                scpResult = try runLocal(executable: scpBinary, args: scpArgs, stdin: nil, timeout: 60, gate: .admitOnly)
            }
            if scpResult.exitCode != 0 {
                throw TransportError.classifySSHFailure(host: config.host, exitCode: scpResult.exitCode, stderr: scpResult.stderrString)
            }
        }

        // Now atomic mv on the remote. Note: scp/sftp DOES expand `~` (it
        // goes through the SSH file transfer protocol, not a remote shell),
        // so the upload landed at the resolved $HOME path. The mv is a
        // shell command and needs the $HOME-rewritten path to find it.
        // Tighten permissions on the TMP file, in the same command as the
        // mv and BEFORE it: `scp` creates the upload with the remote umask
        // (commonly 0644), so a `chmod` after the rename would leave the
        // real path world-readable for a window. Chmod-then-mv means the
        // file is never observable at its final path in a loose mode.
        // Mirrors LocalTransport, via the shared basename list — the local
        // side has enforced 0600 on these since day one and the remote side
        // silently did not.
        //
        // When the destination already exists and is NOT a private-mode
        // file, its mode is carried over to the staged copy first: `scp`
        // creates the upload with the remote umask, so a plain rename
        // would silently re-permission a file the user (or Hermes) had
        // deliberately tightened or loosened. Mode preservation is
        // best-effort (`;`, not `&&`) — a `stat` that doesn't understand
        // either flavour must not block the write; the `mv` is last, so
        // its exit code is still what we check.
        let dst = Self.remotePathArg(path)
        let src = Self.remotePathArg(tmp)
        var command = "m=$(stat -c %a \(dst) 2>/dev/null || stat -f %Lp \(dst) 2>/dev/null || echo); "
            + "if [ -n \"$m\" ]; then chmod \"$m\" \(src) 2>/dev/null; fi; "
        if TransportPrivateMode.shouldEnforce(for: path) {
            command += "chmod 600 \(src) && "
        }
        command += "mv \(src) \(dst)"
        let mvResult = try runRemoteShell(command)
        if mvResult.exitCode != 0 {
            // Best-effort cleanup of the orphan tmp.
            _ = try? runRemoteShell("rm -f \(Self.remotePathArg(tmp))")
            throw TransportError.classifySSHFailure(host: config.host, exitCode: mvResult.exitCode, stderr: mvResult.stderrString)
        }
    }

    public func fileExists(_ path: String) -> Bool {
        guard let result = try? runRemoteShell("test -e \(Self.remotePathArg(path))") else {
            return false
        }
        return result.exitCode == 0
    }

    public func stat(_ path: String) -> FileStat? {
        // macOS and Linux `stat` differ in flags. `stat -f` is macOS's BSD
        // form; `stat -c` is GNU/Linux. We try the GNU form first (typical
        // remote target) and fall back to BSD. The format strings use
        // double quotes — safe inside our outer single-quoted sh -c.
        let linux = try? runRemoteShell(#"stat -c "%s %Y %F" \#(Self.remotePathArg(path))"#)
        if let result = linux, result.exitCode == 0 {
            return Self.parseStatOutput(result.stdoutString)
        }
        let bsd = try? runRemoteShell(#"stat -f "%z %m %HT" \#(Self.remotePathArg(path))"#)
        if let result = bsd, result.exitCode == 0 {
            return Self.parseStatOutput(result.stdoutString)
        }
        return nil
    }

    /// One round-trip for every path, instead of one round-trip per path.
    ///
    /// Each reply line is SELF-IDENTIFYING: the shell prints
    /// `<marker><index> ` immediately before the stat output for that
    /// path, so a line is matched back to its input by the index it
    /// carries rather than by its position in the stream.
    ///
    /// Positional zipping is what this replaces, and it was not a
    /// tidiness problem. One stray stdout line — a remote `.profile` that
    /// echoes, a shell notice — shifted every signature by one, and the
    /// wrong answer was STABLE: the cockpit's short-circuit compared two
    /// equally-wrong signatures forever and never reloaded again until
    /// the app restarted. A path containing a newline did the same thing
    /// deliberately (DI M6); such paths are now REFUSED outright, since
    /// nothing in Hermes legitimately has one and no framing survives it.
    ///
    /// Returns `nil` — not a partial map — whenever the reply cannot be
    /// accounted for path-by-path. See the protocol doc: an untrustworthy
    /// answer must be legible as untrustworthy.
    public func statAll(_ paths: [String]) -> [String: FileStat]? {
        guard !paths.isEmpty else { return [:] }
        let unique = Array(Set(paths))
        // A newline in a path cannot be framed back out of a line-oriented
        // reply, so it is refused rather than misattributed.
        guard !unique.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            // SAID OUT LOUD, because the consequence is a surface that
            // stops live-updating: every caller treats nil as "keep what
            // you have", so a path that permanently fails this guard
            // permanently disables its caller's tick refresh (a manual
            // refresh still works). Nothing in Hermes legitimately has a
            // newline in a path, so this is a diagnostic, not a warning
            // the user is expected to see.
            #if canImport(os)
            Self.logger.error("statAll refused: a watched path contains a newline")
            #endif
            return nil
        }
        let argList = unique.map { Self.remotePathArg($0) }.joined(separator: " ")
        // GNU first, BSD fallback, placeholder last — the same ladder
        // `stat(_:)` climbs, just once per path inside one shell. `i` is
        // the echo that makes the reply self-describing.
        let marker = Self.statAllMarker
        let cmd = """
            i=0; for p in \(argList); do i=$((i+1)); \
            printf '%s%s ' '\(marker)' "$i"; \
            stat -c "%s %Y %F" "$p" 2>/dev/null \
            || stat -f "%z %m %HT" "$p" 2>/dev/null \
            || echo "- - -"; done
            """
        guard let result = try? runRemoteShell(cmd), result.exitCode == 0 else { return nil }
        return Self.parseStatAllReply(result.stdoutString, paths: unique)
    }

    /// Reply parsing, split out so the framing can be tested without a
    /// host. Returns `nil` for any reply it cannot account for
    /// path-by-path — see `statAll`.
    static func parseStatAllReply(_ stdout: String, paths: [String]) -> [String: FileStat]? {
        let marker = Self.statAllMarker
        var out: [String: FileStat] = [:]
        var seen = Set<Int>()
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Unmarked output is somebody else's (a profile banner, a
            // warning). Ignored rather than counted — it is precisely the
            // thing that used to shift the mapping.
            guard line.hasPrefix(marker) else { continue }
            let body = line.dropFirst(marker.count)
            guard let space = body.firstIndex(of: " "),
                  let index = Int(body[body.startIndex..<space]),
                  index >= 1, index <= paths.count,
                  seen.insert(index).inserted
            else {
                // A duplicate or out-of-range index means the framing is
                // not what we think it is; refuse the whole reply.
                return nil
            }
            let path = paths[index - 1]
            let statText = body[body.index(after: space)...].trimmingCharacters(in: .whitespaces)
            // The placeholder must NOT parse: `parseStatOutput` would read
            // "- - -" as a zero-byte file at the epoch, turning "absent"
            // into "present and empty" — which is exactly the
            // absent-vs-unreadable confusion the registry work spent a
            // phase removing.
            guard statText != "- - -" else { continue }
            if let info = Self.parseStatOutput(statText) { out[path] = info }
        }
        // Every path must have been answered for. A short reply is a
        // truncated / sick round-trip, and the paths missing from it are
        // NOT "absent files".
        guard seen.count == paths.count else { return nil }
        return out
    }

    /// Prefix that tags each `statAll` reply line with its input index.
    /// An ASCII unit separator keeps it out of any plausible stat output
    /// or shell banner.
    static let statAllMarker = "\u{1F}s"

    private static func parseStatOutput(_ s: String) -> FileStat? {
        // Expected: "<bytes> <unix-epoch-secs> <type>" where <type> is either
        // a GNU word ("regular file", "directory") or a BSD word ("Regular
        // File", "Directory"). Only the first word of <type> matters for
        // isDirectory.
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let size = Int64(parts[0]) ?? 0
        let mtimeSecs = TimeInterval(parts[1]) ?? 0
        let typeStr = parts.count == 3 ? parts[2].lowercased() : ""
        let isDir = typeStr.contains("directory")
        return FileStat(size: size, mtime: Date(timeIntervalSince1970: mtimeSecs), isDirectory: isDir)
    }

    public func listDirectory(_ path: String) throws -> [String] {
        // `ls -A` lists all entries (incl. dotfiles) except `.`/`..`, one per
        // line. Sort order matches local FileManager.contentsOfDirectory.
        let result = try runRemoteShell("ls -A \(Self.remotePathArg(path))")
        if result.exitCode != 0 {
            if result.stderrString.contains("No such file") {
                throw TransportError.fileIO(path: path, underlying: "No such file or directory")
            }
            throw TransportError.classifySSHFailure(host: config.host, exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public func createDirectory(_ path: String) throws {
        let result = try runRemoteShell("mkdir -p \(Self.remotePathArg(path))")
        if result.exitCode != 0 {
            throw TransportError.classifySSHFailure(host: config.host, exitCode: result.exitCode, stderr: result.stderrString)
        }
    }

    public func removeFile(_ path: String) throws {
        let result = try runRemoteShell("rm -f \(Self.remotePathArg(path))")
        if result.exitCode != 0 {
            throw TransportError.classifySSHFailure(host: config.host, exitCode: result.exitCode, stderr: result.stderrString)
        }
    }

    // MARK: - Processes

    /// Compose the remote command shared by `runProcess`, `makeProcess`,
    /// and `streamLines`: an optional `cd <cwd>;` prefix, the profile
    /// `HERMES_HOME=` scope, then the `~`-rewritten executable + args.
    ///
    /// The `HERMES_HOME=` assignment scopes the invocation to the selected
    /// profile when `config.remoteHome` points at one (#126, the Mac
    /// counterpart of `CitadelServerTransport`'s #120 injection). Set
    /// unconditionally (not just when the executable is hermes) because it
    /// is `""` for a default/root home — legacy `active_profile` resolution
    /// and pre-profile hosts are untouched — and harmless for non-hermes
    /// executables, which ignore it. Without it, every CLI-backed action
    /// (chat, cron run, config set, …) would resolve the server's
    /// `active_profile` while the window's file reads show the viewing
    /// profile — a silent cross-profile split.
    func composedRemoteCommand(executable: String, args: [String], cwd: String? = nil) -> String {
        let hermesHome = HermesProfileScope.hermesHomeShellAssignment(
            forHome: config.remoteHome ?? HermesPathSet.defaultRemoteHome)
        // `~/`-rewritten paths so home-relative args expand on the remote.
        // The executable might be `~/.local/bin/hermes` or just `hermes`;
        // either survives.
        var cmd = hermesHome + ([executable] + args).map { Self.remotePathArg($0) }.joined(separator: " ")
        // Run FROM the project dir so Hermes loads its AGENTS.md (Hermes
        // reads project context files from the process cwd, not the ACP
        // session cwd). `;` (not `&&`) is deliberate: a stale/missing dir
        // degrades to the login dir rather than failing the session;
        // `remotePathArg` rewrites `~/`→`$HOME/` and double-quotes so
        // spaces/metacharacters survive.
        if let cwd, !cwd.isEmpty {
            cmd = "cd \(Self.remotePathArg(cwd)); " + cmd
        }
        return cmd
    }

    public func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
        // Wrap in `sh -c '<exe> <arg> <arg>'`.
        let cmd = composedRemoteCommand(executable: executable, args: args)
        var sshArgv = sshArgs()
        sshArgv.append(hostSpec)
        sshArgv.append("sh")
        sshArgv.append("-c")
        sshArgv.append(Self.shellQuote(cmd))
        return try runLocal(executable: sshBinary, args: sshArgv, stdin: stdin, timeout: timeout)
    }

    #if !os(iOS)
    public func makeProcess(executable: String, args: [String]) -> Process {
        makeProcess(executable: executable, args: args, cwd: nil)
    }

    public func makeProcess(executable: String, args: [String], cwd: String?) -> Process {
        ensureControlDir()
        // `-T` disables pty allocation — critical for binary-clean stdin/stdout
        // (ACP JSON-RPC, log tail bytes). `bash -lc` (login shell) sources the
        // user's profile so PATH picks up pipx's `~/.local/bin`, Homebrew on
        // Linux, asdf shims, and conda envs. Plain `sh -c` is non-login, so
        // pipx-installed `hermes` isn't on PATH unless `hermesBinaryHint` was
        // set explicitly — exactly the failure that surfaces as a
        // "command not found" / opaque init timeout against fresh droplets.
        let cmd = composedRemoteCommand(executable: executable, args: args, cwd: cwd)
        var sshArgv = sshArgs()
        sshArgv.insert("-T", at: 0)
        sshArgv.append(hostSpec)
        sshArgv.append("bash")
        sshArgv.append("-lc")
        sshArgv.append(Self.shellQuote(cmd))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sshBinary)
        proc.arguments = sshArgv
        proc.environment = Self.sshSubprocessEnvironment()
        return proc
    }
    #endif

    public func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        #if os(iOS)
        // SSHTransport is not a runtime choice on iOS — the iOS app
        // uses `CitadelServerTransport` instead. This conformance
        // exists so ScarfCore compiles for iOS; actual streaming SSH
        // exec on iOS is Citadel's job.
        return AsyncThrowingStream { $0.finish() }
        #else
        return AsyncThrowingStream { continuation in
            Task.detached { [self] in
                if case .blocked(let retryAt) = SSHConnectionGate.shared.admit(gateKey) {
                    continuation.finish(throwing: TransportError.circuitOpen(host: config.host, retryAt: retryAt))
                    return
                }
                ensureControlDir()
                // `bash -lc` (login shell) so PATH picks up profile-only
                // entries like pipx's `~/.local/bin` — same rationale as
                // `makeProcess` above. Streaming consumers (log tails)
                // don't tolerate a missing-binary failure any better than
                // ACP does.
                let cmd = composedRemoteCommand(executable: executable, args: args)
                var sshArgv = sshArgs()
                sshArgv.insert("-T", at: 0)
                sshArgv.append(hostSpec)
                sshArgv.append("bash")
                sshArgv.append("-lc")
                sshArgv.append(Self.shellQuote(cmd))
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: sshBinary)
                proc.arguments = sshArgv
                proc.environment = Self.sshSubprocessEnvironment()
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                // Parent's copy of the writing ends — close ours so EOF
                // reaches the reader after the child exits.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                let handle = outPipe.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = Data(buffer[buffer.startIndex..<nl])
                        buffer = Data(buffer[buffer.index(after: nl)...])
                        if let text = String(data: lineData, encoding: .utf8) {
                            continuation.yield(text)
                        }
                    }
                }
                proc.waitUntilExit()
                let stderrTail: String
                if proc.terminationStatus != 0 {
                    stderrTail = (try? errPipe.fileHandleForReading.readToEnd())
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                } else {
                    stderrTail = ""
                }
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                if proc.terminationStatus == 255 {
                    SSHConnectionGate.shared.recordFailure(gateKey)
                } else {
                    SSHConnectionGate.shared.recordSuccess(gateKey)
                }
                if proc.terminationStatus != 0 {
                    continuation.finish(throwing: TransportError.classifySSHFailure(
                        host: config.host, exitCode: proc.terminationStatus, stderr: stderrTail
                    ))
                } else {
                    continuation.finish()
                }
            }
        }
        #endif
    }

    public func streamRawBytes(executable: String, args: [String]) -> AsyncThrowingStream<Data, Error> {
        #if os(iOS)
        return AsyncThrowingStream { $0.finish() }
        #else
        return AsyncThrowingStream { continuation in
            Task.detached { [self] in
                if case .blocked(let retryAt) = SSHConnectionGate.shared.admit(gateKey) {
                    continuation.finish(throwing: TransportError.circuitOpen(host: config.host, retryAt: retryAt))
                    return
                }
                ensureControlDir()
                // Same `bash -lc` wrapping as `streamLines` so PATH picks
                // up profile-only entries (pipx, asdf, conda). The
                // difference here is we yield raw `Data` chunks — no
                // newline framing, no UTF-8 decoding. Required for
                // backup tarballs.
                let cmd = ([executable] + args).map { Self.remotePathArg($0) }.joined(separator: " ")
                var sshArgv = sshArgs()
                sshArgv.insert("-T", at: 0)
                sshArgv.append(hostSpec)
                sshArgv.append("bash")
                sshArgv.append("-lc")
                sshArgv.append(Self.shellQuote(cmd))
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: sshBinary)
                proc.arguments = sshArgv
                proc.environment = Self.sshSubprocessEnvironment()
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                let handle = outPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    continuation.yield(chunk)
                }
                proc.waitUntilExit()
                let stderrTail: String
                if proc.terminationStatus != 0 {
                    stderrTail = (try? errPipe.fileHandleForReading.readToEnd())
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                } else {
                    stderrTail = ""
                }
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                if proc.terminationStatus == 255 {
                    SSHConnectionGate.shared.recordFailure(gateKey)
                } else {
                    SSHConnectionGate.shared.recordSuccess(gateKey)
                }
                if proc.terminationStatus != 0 {
                    continuation.finish(throwing: TransportError.classifySSHFailure(
                        host: config.host, exitCode: proc.terminationStatus, stderr: stderrTail
                    ))
                } else {
                    continuation.finish()
                }
            }
        }
        #endif
    }

    /// Injection point for ssh/scp subprocess environment enrichment.
    ///
    /// On the Mac app, this is wired at startup to
    /// `HermesFileService.enrichedEnvironment()` — the full two-attempt
    /// login-shell probe (`zsh -l -i` with prompt defangs, fallback to
    /// `zsh -l`) that harvests SSH_AUTH_SOCK + SSH_AGENT_PID from
    /// 1Password / Secretive / `.zshrc`-exported agents. Without this
    /// harvesting, a GUI-launched Scarf can't reach ssh-agent sockets
    /// that the user's Terminal sees fine — auth fails with "Permission
    /// denied" / exit 255.
    ///
    /// On iOS the agent comes from Citadel (M4+), not from a login shell
    /// probe — leave this `nil` and iOS falls back to
    /// `ProcessInfo.processInfo.environment` alone.
    ///
    /// Set once at app launch (startup is single-threaded). Tests may
    /// inject a stub.
    nonisolated(unsafe) public static var environmentEnricher: (@Sendable () -> [String: String])?

    /// Environment for an ssh/scp subprocess: process env merged with
    /// anything the configured `environmentEnricher` produces. The enricher
    /// only wins for keys the process env doesn't already have, so an
    /// explicit `SSH_AUTH_SOCK=…` in the Xcode scheme / launchd plist
    /// survives.
    nonisolated private static func sshSubprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let enricher = Self.environmentEnricher else { return env }
        let extra = enricher()
        for (key, value) in extra where env[key] == nil && !value.isEmpty {
            env[key] = value
        }
        return env
    }

    // MARK: - Script streaming

    /// Pipe `script` to `/bin/sh -s` over the ControlMaster-shared SSH
    /// channel. Used by `RemoteSQLiteBackend` to invoke `sqlite3 -json`
    /// per query without the per-arg quoting that `runProcess` would
    /// apply. Delegates to `SSHScriptRunner` which already implements
    /// the ssh-stdin-pipe pattern correctly.
    public func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        let context = ServerContext(id: contextID, displayName: displayName, kind: .ssh(config))
        let outcome = await SSHScriptRunner.run(script: script, context: context, timeout: timeout)
        switch outcome {
        case .connectFailure(let reason):
            throw TransportError.other(message: reason)
        case .completed(let stdout, let stderr, let exitCode):
            return ProcessResult(
                exitCode: exitCode,
                stdout: Data(stdout.utf8),
                stderr: Data(stderr.utf8)
            )
        }
    }

    // MARK: - Watching

    public func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        watchPaths(paths, baseline: nil)
    }

    public func watchPaths(
        _ paths: [String], baseline: WatchBaselineStore?
    ) -> AsyncStream<WatchEvent> {
        // Polling: stat all paths every 3s and yield a single `.anyChanged`
        // when any of them changed vs. the prior tick. ControlMaster makes
        // each stat ~5ms so the cost is bounded.
        //
        // The signature is `mtime:size` PER PATH, held in the caller's
        // `baseline` when one is supplied. Two things follow that a single
        // joined mtime string could not do: a same-second write that
        // changed the file's length is still a delta, and a restart of this
        // stream (the watcher's project set changed) resumes from what the
        // previous stream knew instead of silently re-baselining and
        // swallowing whatever landed in the gap.
        AsyncStream { continuation in
            let task = Task.detached { [self] in
                let memory = baseline ?? WatchBaselineStore()
                while !Task.isCancelled {
                    // Build one shell command that stats all paths in one
                    // ssh round-trip. Missing paths print "0 0" which still
                    // participates correctly in change detection (a file
                    // appearing or vanishing is a change). Paths get the
                    // `~`→`$HOME` rewrite via remotePathArg.
                    let argList = paths.map { Self.remotePathArg($0) }.joined(separator: " ")
                    let cmd = "for p in \(argList); do stat -c \"%Y:%s\" \"$p\" 2>/dev/null || stat -f \"%m:%z\" \"$p\" 2>/dev/null || echo 0:0; done"
                    do {
                        let result = try runRemoteShell(cmd, timeout: 30)
                        let lines = result.stdoutString
                            .split(separator: "\n", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        // A short or empty reply is a sick transport, not a
                        // set of vanished files: applying it per-path would
                        // forget baselines and then report a spurious change
                        // when the host came back.
                        //
                        // A reply that doesn't line up is still USABLE as a
                        // whole-blob signature, and falling back to one is
                        // what keeps a host whose `stat` we can't read
                        // line-by-line from having no watcher at all — the
                        // pre-existing behaviour, kept as the floor.
                        if lines.count == paths.count {
                            var fresh: [String: String] = [:]
                            for (index, path) in paths.enumerated() { fresh[path] = lines[index] }
                            if memory.apply(fresh) {
                                continuation.yield(.anyChanged)
                            }
                        } else if !lines.isEmpty {
                            // MISALIGNED, NOT AUTHORITATIVE. The blob is
                            // still worth keeping — it is what lets a host
                            // whose `stat` we can't read line-by-line have a
                            // watcher at all — but it must be recorded
                            // ALONGSIDE the per-path baselines, never
                            // instead of them. `apply` replaces the whole
                            // map, so a single misaligned reply used to
                            // forget every per-path signature; the next
                            // aligned reply then re-baselined silently and
                            // swallowed every change that landed in the gap
                            // (DI H6).
                            if memory.merge(["\u{0}blob": lines.joined(separator: "\n")]) {
                                continuation.yield(.anyChanged)
                            }
                        }
                        // An empty reply falls through to the sleep: it is a
                        // sick transport, and `continue`-ing past the sleep
                        // turned that into a tight SSH loop (DI H7).
                    } catch {
                        // Transient failure (connection drop) — skip this tick.
                        #if canImport(os)
                        Self.logger.debug("watchPaths poll failed: \(String(describing: error))")
                        #endif
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private helpers

    /// Spawn a local process (ssh/scp/etc.) and collect its result. Mirrors
    /// `LocalTransport.runProcess` — duplicated rather than shared because
    /// SSH-specific code paths live on this type and we want all Process
    /// lifecycle in one place per transport.
    /// How an invocation participates in the per-host circuit breaker
    /// (gh#138).
    enum GatePolicy {
        /// Blocked while the gate is open; exit code feeds the gate.
        case full
        /// Blocked while the gate is open, but the exit code is NOT fed
        /// back. For `scp`, whose exit codes don't distinguish connection
        /// failure (it exits 1, where ssh exits 255) — a dead connection
        /// must not be scored as a success.
        case admitOnly
        /// Exempt entirely. Only for local-only ControlMaster ops
        /// (`-O check` / `-O exit`) — those never dial the remote, so they
        /// must neither be blocked nor poison the gate with their
        /// non-zero "no master running" exits.
        case none
    }

    nonisolated private func runLocal(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?, gate: GatePolicy = .full) throws -> ProcessResult {
        #if os(iOS)
        // iOS uses `CitadelServerTransport` instead of spawning ssh/scp
        // binaries. Reaching here from iOS is a wiring bug.
        throw TransportError.other(message: "SSHTransport.runLocal is unavailable on iOS")
        #else
        if gate != .none, case .blocked(let retryAt) = SSHConnectionGate.shared.admit(gateKey) {
            // Fail fast WITHOUT spawning ssh: with a ProxyCommand like
            // cloudflared, merely attempting the dial has side effects
            // (browser OAuth tabs) — the whole point of the breaker.
            throw TransportError.circuitOpen(host: config.host, retryAt: retryAt)
        }
        ensureControlDir()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        // Inherit the user's shell environment so ssh can reach the
        // ssh-agent socket. GUI-launched apps don't see SSH_AUTH_SOCK by
        // default — without this, terminal ssh works (because the user's
        // shell exports it) but Scarf-launched ssh fails auth with exit 255.
        proc.environment = Self.sshSubprocessEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if stdin != nil { proc.standardInput = stdinPipe }
        let pipeCapture = ProcessPipeDrainer.start(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
        do {
            try proc.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            if stdin != nil {
                try? stdinPipe.fileHandleForReading.close()
            }
            _ = pipeCapture.wait()
            throw TransportError.other(message: "Failed to launch \(executable): \(error.localizedDescription)")
        }
        // Parent's copy of the inherited ends — close so EOF lands when
        // the child exits and we don't leak fds.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if stdin != nil {
            try? stdinPipe.fileHandleForReading.close()
        }
        if let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        if let timeout {
            // Kernel-wait via DispatchGroup + terminationHandler instead
            // of a 100ms Thread.sleep spin loop. The old loop burned a
            // cooperative-pool thread for the full timeout duration AND
            // had 100ms granularity on the deadline; this version blocks
            // once on a semaphore that the OS wakes when the process
            // terminates (or when the timeout fires). Net effect: under
            // concurrent SSH load (sidebar reload + chat finalize +
            // watcher poll all firing together) we don't accumulate
            // multiple spin-blocked threads, which was the mechanism
            // behind the 7-second `loadRecentSessions` outliers
            // observed in remote-context perf captures.
            let waitGroup = DispatchGroup()
            waitGroup.enter()
            proc.terminationHandler = { _ in waitGroup.leave() }
            let outcome = waitGroup.wait(timeout: .now() + timeout)
            proc.terminationHandler = nil
            if outcome == .timedOut {
                proc.terminate()
                // Brief block until the kill actually lands so we can
                // collect partial stdout. terminate() is async; without
                // this wait the readToEnd below could race the close.
                proc.waitUntilExit()
                let captured = pipeCapture.wait()
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                // A timeout is connection-level for gate purposes: the
                // reported cloudflared scenario is precisely ssh blocking
                // on its ProxyCommand's OAuth dance until our timer fires.
                if gate == .full { SSHConnectionGate.shared.recordFailure(gateKey) }
                throw TransportError.timeout(seconds: timeout, partialStdout: captured.stdout)
            }
        } else {
            proc.waitUntilExit()
        }
        let captured = pipeCapture.wait()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
        if gate == .full {
            // Exit 255 is ssh's own failure code (dial/auth/proxy); any
            // other exit means the remote actually ran our command, which
            // proves the connection is alive — even if the command failed.
            if proc.terminationStatus == 255 {
                SSHConnectionGate.shared.recordFailure(gateKey)
            } else {
                SSHConnectionGate.shared.recordSuccess(gateKey)
            }
        }
        return ProcessResult(exitCode: proc.terminationStatus, stdout: captured.stdout, stderr: captured.stderr)
        #endif
    }
}
