import Foundation
import os

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
struct SSHTransport: ServerTransport {
    nonisolated private static let logger = Logger(subsystem: "com.scarf", category: "SSHTransport")

    let contextID: ServerID
    let isRemote: Bool = true

    let config: SSHConfig
    let displayName: String

    nonisolated init(contextID: ServerID, config: SSHConfig, displayName: String) {
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

    /// Per-server snapshot cache directory (for SQLite `.backup` drops).
    nonisolated private var snapshotDir: String { Self.snapshotDirPath(for: contextID) }

    /// Shared control-master socket directory (one dir, sockets within it are
    /// per-host via OpenSSH's `%C` token). Exposed as a static so
    /// cleanup paths (`ServerRegistry.removeServer`, app-launch sweep) can
    /// compute it without instantiating a transport.
    nonisolated static func controlDirPath() -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Caches"
        return base + "/scarf/ssh"
    }

    /// Snapshot cache directory for a given server. Stable per-ID so repeated
    /// connections to the same server share the cache, and so cleanup can
    /// find it from the ID alone.
    nonisolated static func snapshotDirPath(for contextID: ServerID) -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Caches"
        return base + "/scarf/snapshots/\(contextID.uuidString)"
    }

    /// Root of the snapshot cache (all servers). Used by the app-launch sweep
    /// that prunes dirs whose UUID no longer appears in the registry.
    nonisolated static func snapshotRootPath() -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Caches"
        return base + "/scarf/snapshots"
    }

    /// Remove the snapshot directory for a server (no-op if absent). Called
    /// on `removeServer` and on app-launch for orphaned dirs.
    static func pruneSnapshotCache(for contextID: ServerID) {
        let dir = snapshotDirPath(for: contextID)
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Walk the snapshot root and delete any directory whose UUID isn't in
    /// `keep`. Called once at app launch so snapshots from servers the user
    /// removed while the app was closed don't linger.
    static func sweepOrphanSnapshots(keeping keep: Set<ServerID>) {
        let root = snapshotRootPath()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in entries {
            if let id = ServerID(uuidString: name), keep.contains(id) { continue }
            try? FileManager.default.removeItem(atPath: root + "/" + name)
        }
    }

    /// Ask OpenSSH to shut down this host's ControlMaster socket, so the TCP
    /// session isn't held open after the user removes this server. If no
    /// master is currently running, `ssh -O exit` exits non-zero — we ignore
    /// the exit code because the desired end state (no master) is reached
    /// either way.
    func closeControlMaster() {
        ensureControlDir()
        let args = sshArgs(extra: ["-O", "exit", hostSpec])
        _ = try? runLocal(executable: sshBinary, args: args, stdin: nil, timeout: 10)
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

    /// Ensure the ControlMaster socket directory exists. Called before every
    /// ssh invocation. Cheap — `createDirectory(withIntermediateDirectories: true)`
    /// is a no-op when present.
    nonisolated private func ensureControlDir() {
        try? FileManager.default.createDirectory(atPath: controlDir, withIntermediateDirectories: true)
        // 0700 so socket files aren't visible to other users on the Mac.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDir)
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
        var p = path
        if p.hasPrefix("~/") {
            p = "$HOME/" + p.dropFirst(2)
        } else if p == "~" {
            p = "$HOME"
        }
        let escaped = p
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
        args.append(hostSpec)
        args.append("sh")
        args.append("-c")
        args.append(Self.shellQuote(command))
        return try runLocal(executable: sshBinary, args: args, stdin: nil, timeout: timeout)
    }

    // MARK: - Files

    func readFile(_ path: String) throws -> Data {
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

    func writeFile(_ path: String, data: Data) throws {
        // Atomic pattern:
        //   1. scp to `<path>.scarf.tmp` on the remote
        //   2. ssh `mv <tmp> <path>` — atomic on POSIX within the same FS
        // Hermes never sees a partial write.
        let tmp = path + ".scarf.tmp"

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
        scpArgs.append("\(hostSpec):\(tmp)")

        let scpResult = try runLocal(executable: scpBinary, args: scpArgs, stdin: nil, timeout: 60)
        if scpResult.exitCode != 0 {
            throw TransportError.classifySSHFailure(host: config.host, exitCode: scpResult.exitCode, stderr: scpResult.stderrString)
        }

        // Now atomic mv on the remote. Note: scp/sftp DOES expand `~` (it
        // goes through the SSH file transfer protocol, not a remote shell),
        // so the upload landed at the resolved $HOME path. The mv is a
        // shell command and needs the $HOME-rewritten path to find it.
        let mvResult = try runRemoteShell("mv \(Self.remotePathArg(tmp)) \(Self.remotePathArg(path))")
        if mvResult.exitCode != 0 {
            // Best-effort cleanup of the orphan tmp.
            _ = try? runRemoteShell("rm -f \(Self.remotePathArg(tmp))")
            throw TransportError.classifySSHFailure(host: config.host, exitCode: mvResult.exitCode, stderr: mvResult.stderrString)
        }
    }

    func fileExists(_ path: String) -> Bool {
        guard let result = try? runRemoteShell("test -e \(Self.remotePathArg(path))") else {
            return false
        }
        return result.exitCode == 0
    }

    func stat(_ path: String) -> FileStat? {
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

    func listDirectory(_ path: String) throws -> [String] {
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

    func createDirectory(_ path: String) throws {
        let result = try runRemoteShell("mkdir -p \(Self.remotePathArg(path))")
        if result.exitCode != 0 {
            throw TransportError.classifySSHFailure(host: config.host, exitCode: result.exitCode, stderr: result.stderrString)
        }
    }

    func removeFile(_ path: String) throws {
        let result = try runRemoteShell("rm -f \(Self.remotePathArg(path))")
        if result.exitCode != 0 {
            throw TransportError.classifySSHFailure(host: config.host, exitCode: result.exitCode, stderr: result.stderrString)
        }
    }

    // MARK: - Processes

    func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
        // Wrap in `sh -c '<exe> <arg> <arg>'` with `~/`-rewritten paths so
        // home-relative args expand on the remote. The executable might be
        // `~/.local/bin/hermes` or just `hermes`; either survives.
        let cmd = ([executable] + args).map { Self.remotePathArg($0) }.joined(separator: " ")
        var sshArgv = sshArgs()
        sshArgv.append(hostSpec)
        sshArgv.append("sh")
        sshArgv.append("-c")
        sshArgv.append(Self.shellQuote(cmd))
        return try runLocal(executable: sshBinary, args: sshArgv, stdin: stdin, timeout: timeout)
    }

    func makeProcess(executable: String, args: [String]) -> Process {
        ensureControlDir()
        // `-T` disables pty allocation — critical for binary-clean stdin/stdout
        // (ACP JSON-RPC, log tail bytes). Same sh -c wrapping as runProcess
        // so home-relative paths in `executable`/`args` actually expand.
        let cmd = ([executable] + args).map { Self.remotePathArg($0) }.joined(separator: " ")
        var sshArgv = sshArgs()
        sshArgv.insert("-T", at: 0)
        sshArgv.append(hostSpec)
        sshArgv.append("sh")
        sshArgv.append("-c")
        sshArgv.append(Self.shellQuote(cmd))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sshBinary)
        proc.arguments = sshArgv
        proc.environment = Self.sshSubprocessEnvironment()
        return proc
    }

    /// Environment for an ssh/scp subprocess: process env merged with
    /// SSH_AUTH_SOCK / SSH_AGENT_PID harvested from the user's login shell.
    /// Without this, GUI-launched Scarf can't reach 1Password / Secretive /
    /// `ssh-add`'d keys that the user's terminal sees fine.
    nonisolated private static func sshSubprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let shellEnv = HermesFileService.enrichedEnvironment()
        for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
            if env[key] == nil, let value = shellEnv[key], !value.isEmpty {
                env[key] = value
            }
        }
        return env
    }

    // MARK: - SQLite snapshot

    func snapshotSQLite(remotePath: String) throws -> URL {
        try? FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)
        let localPath = snapshotDir + "/state.db"
        // `.backup` is WAL-safe: sqlite takes a consistent snapshot without
        // blocking writers. A plain `cp` of a WAL-mode DB could corrupt.
        let remoteTmp = "/tmp/scarf-snapshot-\(UUID().uuidString).db"
        // sqlite3's `.backup` is a dot-command, not a CLI arg. The whole
        // dot-command must be one shell argument (double-quoted) so sqlite3
        // receives it as a single command; the backup path inside it is
        // single-quoted so sqlite3 parses it correctly. The DB path is a
        // separate shell argument and goes through `remotePathArg`
        // (double-quoted, $HOME-aware) so `~/.hermes/state.db` actually
        // resolves on the remote.
        //
        // The second sqlite3 invocation flips the snapshot out of WAL mode
        // so the scp'd file is self-contained: `.backup` preserves the
        // source's journal_mode in the destination header, so without this
        // step the client would need the `-wal`/`-shm` sidecars too, and
        // every read would fail with "unable to open database file".
        //
        // Final shell command on the remote:
        //   sqlite3 "$HOME/.hermes/state.db" ".backup '/tmp/scarf-snapshot-XYZ.db'" \
        //     && sqlite3 '/tmp/scarf-snapshot-XYZ.db' "PRAGMA journal_mode=DELETE;"
        let backupScript = #"sqlite3 \#(Self.remotePathArg(remotePath)) ".backup '\#(remoteTmp)'" && sqlite3 '\#(remoteTmp)' "PRAGMA journal_mode=DELETE;" > /dev/null"#
        let backup = try runRemoteShell(backupScript)
        if backup.exitCode != 0 {
            throw TransportError.classifySSHFailure(host: config.host, exitCode: backup.exitCode, stderr: backup.stderrString)
        }
        // scp the backup down. scp/sftp expands `~` natively (it goes
        // through the SSH file-transfer protocol, not a remote shell), so
        // remoteTmp's `/tmp/...` absolute path round-trips as-is.
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
        scpArgs.append("\(hostSpec):\(remoteTmp)")
        scpArgs.append(localPath)
        let pull = try runLocal(executable: scpBinary, args: scpArgs, stdin: nil, timeout: 120)
        // Regardless of pull outcome, try to clean up the remote tmp.
        _ = try? runRemoteShell("rm -f \(Self.remotePathArg(remoteTmp))")
        if pull.exitCode != 0 {
            throw TransportError.classifySSHFailure(host: config.host, exitCode: pull.exitCode, stderr: pull.stderrString)
        }
        return URL(fileURLWithPath: localPath)
    }

    // MARK: - Watching

    func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        // Polling: call `stat -c %Y` on all paths every 3s and yield a single
        // `.anyChanged` when any mtime changed vs. the prior tick. ControlMaster
        // makes each stat ~5ms so the cost is bounded.
        AsyncStream { continuation in
            let task = Task.detached { [self] in
                var lastSignature: String = ""
                while !Task.isCancelled {
                    // Build one shell command that stats all paths in one
                    // ssh round-trip. Missing paths print "0" which still
                    // participates correctly in change detection. Paths
                    // get the `~`→`$HOME` rewrite via remotePathArg.
                    let argList = paths.map { Self.remotePathArg($0) }.joined(separator: " ")
                    let cmd = "for p in \(argList); do stat -c %Y \"$p\" 2>/dev/null || stat -f %m \"$p\" 2>/dev/null || echo 0; done"
                    do {
                        let result = try runRemoteShell(cmd, timeout: 30)
                        let signature = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !signature.isEmpty && signature != lastSignature {
                            if !lastSignature.isEmpty {
                                continuation.yield(.anyChanged)
                            }
                            lastSignature = signature
                        }
                    } catch {
                        // Transient failure (connection drop) — skip this tick.
                        Self.logger.debug("watchPaths poll failed: \(String(describing: error))")
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
    nonisolated private func runLocal(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
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
        do {
            try proc.run()
        } catch {
            throw TransportError.other(message: "Failed to launch \(executable): \(error.localizedDescription)")
        }
        if let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                proc.terminate()
                let partial = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                throw TransportError.timeout(seconds: timeout, partialStdout: partial)
            }
        } else {
            proc.waitUntilExit()
        }
        let out = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
        return ProcessResult(exitCode: proc.terminationStatus, stdout: out, stderr: err)
    }
}
