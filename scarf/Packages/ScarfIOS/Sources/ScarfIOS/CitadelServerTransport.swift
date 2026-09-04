// Gated on `canImport(Citadel)` so Linux CI (which can't resolve
// Citadel transitively from ScarfIOS anyway) skips the file. iOS +
// macOS compile it normally.
#if canImport(Citadel)

import Foundation
import NIOCore
import NIOPosix
import Citadel
import CryptoKit
import ScarfCore
#if canImport(os)
import os
#endif

/// `ServerTransport` conformance backed by Citadel's SSH + SFTP client.
///
/// Used by the iOS app as the `.ssh` transport implementation (wired via
/// `ServerContext.sshTransportFactory` at app launch). Every file I/O
/// primitive routes through SFTP; every process invocation routes
/// through `SSHClient.executeCommand`; SQLite snapshot pulls run
/// `sqlite3 .backup` remotely then SFTP-download the backup file.
///
/// **Single long-lived connection per transport instance.** Citadel's
/// `SSHClient.connect(...)` handshake is ~500ms on a warm network; we
/// don't want to pay that per file read. The first call that needs the
/// connection opens it; subsequent calls reuse. On error, the next call
/// re-opens.
///
/// **Blocking bridge to async.** `ServerTransport` protocol methods are
/// synchronous, by design — services don't become `async` end-to-end.
/// Citadel is `async` everywhere. The `runSync(_:)` helper uses a
/// `DispatchSemaphore` to block the caller thread until the async
/// operation finishes. This matches how the macOS `SSHTransport` blocks
/// on its `/usr/bin/ssh` subprocess; semantically identical.
///
/// **M3 scope.** `streamLines(...)` currently returns an empty stream —
/// iOS log tailing comes in a later phase. `watchPaths(...)` polls
/// `stat` every 3s as a remote heartbeat, same as macOS SSHTransport's
/// remote-watch fallback. Everything else (readFile, writeFile,
/// listDirectory, runProcess, snapshotSQLite) has a full Citadel-
/// backed implementation.
///
/// `@unchecked Sendable`: all stored properties are immutable `let`s
/// (contextID, isRemote, config, displayName, the `@Sendable` keyProvider)
/// and the only mutable state lives behind the `ConnectionHolder` actor,
/// so the type is safe to share across actor boundaries. (t-aud15)
public final class CitadelServerTransport: ServerTransport, @unchecked Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "CitadelServerTransport")
    #endif

    public let contextID: ServerID
    public let isRemote: Bool = true

    public let config: SSHConfig
    public let displayName: String

    /// Async-safe provider for the SSH private key bundle. iOS wires
    /// this to read from the Keychain; tests inject a fixed bundle.
    public typealias KeyProvider = @Sendable () async throws -> SSHKeyBundle
    private let keyProvider: KeyProvider

    /// Shared directory under which cached SQLite snapshots land. On
    /// iOS this maps to `<Caches>/scarf/snapshots/<server-id>/`.
    /// Stable per-server cache directory. Was used by the snapshot
    /// pipeline pre-v2.7; kept for the cache-cleanup migration that
    /// purges old snapshot files at first launch on the new build.
    private let snapshotBaseDir: URL

    /// Actor-serialized access to the one shared `SSHClient`. Opens
    /// lazily on first use, reconnects on error.
    private let connectionHolder: ConnectionHolder

    public init(
        contextID: ServerID,
        config: SSHConfig,
        displayName: String,
        keyProvider: @escaping KeyProvider
    ) {
        self.contextID = contextID
        self.config = config
        self.displayName = displayName
        self.keyProvider = keyProvider
        self.snapshotBaseDir = Self.snapshotDirURL(for: contextID)
        self.connectionHolder = ConnectionHolder(
            contextID: contextID,
            config: config,
            keyProvider: keyProvider
        )
    }

    deinit {
        // Fire-and-forget close. Swift deinit doesn't allow awaiting;
        // Citadel's close is async so we push it onto a detached task
        // and let it run to completion when the app is still alive.
        let holder = connectionHolder
        Task.detached { await holder.closeIfOpen() }
    }

    /// Explicit shutdown hook — call before releasing the transport
    /// to guarantee the SSH connection is closed before the app
    /// suspends. Idempotent.
    public func close() async {
        await connectionHolder.closeIfOpen()
    }

    // MARK: - ServerTransport: files

    public func readFile(_ path: String) throws -> Data {
        try runSync { try await self.asyncReadFile(path) }
    }

    public func writeFile(_ path: String, data: Data) throws {
        try runSync { try await self.asyncWriteFile(path, data: data) }
    }

    public func fileExists(_ path: String) -> Bool {
        (try? runSync { try await self.asyncFileExists(path) }) ?? false
    }

    public func stat(_ path: String) -> FileStat? {
        try? runSync { try await self.asyncStat(path) }
    }

    public func listDirectory(_ path: String) throws -> [String] {
        try runSync { try await self.asyncListDirectory(path) }
    }

    public func createDirectory(_ path: String) throws {
        try runSync { try await self.asyncCreateDirectory(path) }
    }

    public func removeFile(_ path: String) throws {
        try runSync { try await self.asyncRemoveFile(path) }
    }

    // MARK: - ServerTransport: processes

    public func runProcess(
        executable: String,
        args: [String],
        stdin: Data?,
        timeout: TimeInterval?
    ) throws -> ProcessResult {
        if stdin != nil {
            // Citadel's `executeCommand` doesn't accept stdin. None of
            // the iOS runtime paths exercise this today (the one call
            // in `ServerContext.UserHomeCache.probe` passes `nil`), so
            // fail loudly rather than silently drop.
            throw TransportError.other(message: "CitadelServerTransport.runProcess does not support stdin yet")
        }
        return try runSync {
            try await self.asyncRunProcess(executable: executable, args: args, timeout: timeout)
        }
    }

    public func streamLines(
        executable: String,
        args: [String]
    ) -> AsyncThrowingStream<String, Error> {
        // M3 stub. iOS log tailing (HermesLogService streaming tail)
        // comes in a later phase — for now the Dashboard path doesn't
        // need streaming exec. A future revision should use Citadel's
        // raw exec channel to pipe stdout line-by-line without
        // buffering the whole command output.
        AsyncThrowingStream { $0.finish() }
    }

    #if !os(iOS)
    /// macOS/Linux-only `ServerTransport` requirement. `CitadelServerTransport`
    /// is an iOS-runtime type (the Mac app uses `SSHTransport`); this stub
    /// exists solely so the package still *compiles* as a macOS target — the
    /// indexer and `swift test` build the iOS sources against the macOS SDK.
    /// It is never reached on macOS at runtime, so it traps rather than
    /// fabricate a bogus local `Process` for an SSH transport. (Mirrors
    /// `LocalTransport.runProcess`'s iOS-unavailable trap.)
    public func makeProcess(executable: String, args: [String]) -> Process {
        fatalError("CitadelServerTransport.makeProcess is unavailable — this is an iOS-only transport")
    }
    #endif

    // MARK: - ServerTransport: script streaming

    /// Pipe `script` to `/bin/sh -s` over Citadel's exec channel.
    ///
    /// **Why base64.** Citadel's `executeCommandStream` doesn't expose
    /// stdin in the version we're on, so we can't just open `sh -s` and
    /// write the script. Instead we encode the script as base64, decode
    /// it on the remote inline, and pipe the result into `sh`:
    ///
    ///     printf '%s' '<b64>' | base64 -d | /bin/sh
    ///
    /// `base64 -d` is universally available on Linux/macOS. The base64
    /// blob travels as a single shell-safe argv token, so multi-line
    /// scripts with `"$VAR"` references and nested quotes survive
    /// untouched — same correctness guarantee as `SSHScriptRunner`'s
    /// stdin-pipe approach.
    public func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        try await ScarfMon.measureAsync(.transport, "ssh.streamScript") {
            try await _streamScriptImpl(script, timeout: timeout)
        }
    }

    private func _streamScriptImpl(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        let scriptBytes = Data(script.utf8)
        let b64 = scriptBytes.base64EncodedString()
        // Prepend the same PATH guard that `asyncRunProcess` uses so
        // base64 + sh resolve on hosts where they live in non-default
        // prefixes. Most distros have base64 in /usr/bin but
        // homebrew-installed coreutils in /opt/homebrew/bin would
        // otherwise be invisible from a stripped-PATH exec channel.
        let cmd = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" "
            + "printf '%s' '\(b64)' | base64 -d | /bin/sh"
        return try await runScript(cmd, timeout: timeout)
    }

    private func runScript(_ cmd: String, timeout: TimeInterval) async throws -> ProcessResult {
        let client = try await connectionHolder.ssh()
        let stream: AsyncThrowingStream<ExecCommandOutput, Error>
        do {
            stream = try await client.executeCommandStream(cmd)
        } catch {
            throw TransportError.other(message: "Failed to start exec stream: \(error.localizedDescription)")
        }
        // Drain in a child task and race against a sleep so a wedged remote
        // sqlite3 (or a mid-stream Citadel transport failure) can't hang the
        // caller indefinitely. Mirrors the busy-wait deadline that
        // SSHScriptRunner enforces on Mac.
        return try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask {
                var stdout = Data()
                var stderr = Data()
                var exitCode: Int32 = 0
                do {
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        switch chunk {
                        case .stdout(var buf):
                            if let s = buf.readString(length: buf.readableBytes) {
                                stdout.append(Data(s.utf8))
                            }
                        case .stderr(var buf):
                            if let s = buf.readString(length: buf.readableBytes) {
                                stderr.append(Data(s.utf8))
                            }
                        }
                    }
                } catch let failed as SSHClient.CommandFailed {
                    // Genuine remote non-zero exit — surface as
                    // ProcessResult so the caller's existing exit-code
                    // handling fires (mapped to BackendError.sqlite by
                    // RemoteSQLiteBackend).
                    exitCode = Int32(failed.exitCode)
                } catch is CancellationError {
                    throw TransportError.timeout(seconds: timeout, partialStdout: stdout)
                } catch {
                    // Transport-level failure (host unreachable, channel
                    // dropped, ControlMaster died, NIO read error). Throw
                    // as a typed TransportError so RemoteSQLiteBackend
                    // routes it to BackendError.transport rather than
                    // misclassifying as a sqlite crash via a fake -1 exit.
                    throw TransportError.other(
                        message: "SSH stream failed: \(error.localizedDescription)"
                    )
                }
                return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw TransportError.other(message: "SSH stream produced no result")
            }
            group.cancelAll()
            if let result = first {
                return result
            }
            // Timeout fired first — drain task gets cancelled by the
            // group cancel above; surface as a typed timeout.
            throw TransportError.timeout(seconds: timeout, partialStdout: Data())
        }
    }

    // MARK: - ServerTransport: watching

    public func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        // Polling-based, identical in shape to `SSHTransport`'s remote-
        // watch fallback: stat each path, yield `.anyChanged` when any
        // mtime shifts. 3s tick keeps bandwidth low.
        //
        // ScarfMon — A1 instrumentation:
        // - `ios.fileWatcher.tick` (interval) — full poll cycle latency,
        //   includes the SSH stat round-trips. Pre-fix this is what an
        //   "out of sync" user is feeling: anything > 1500 ms means
        //   the channel is congested or the host is slow.
        // - `ios.fileWatcher.delta` (event) — fires only when the
        //   signature actually changed. Low ratio (delta count / tick
        //   count) means we're polling more aggressively than the
        //   change rate warrants — opens the door to dropping the 3s
        //   cadence on LAN.
        // - `ios.fileWatcher.paths` (event with bytes=count) — number
        //   of paths watched per cycle, helps explain a slow tick when
        //   the project list grows.
        watchPaths(paths, baseline: nil)
    }

    public func watchPaths(
        _ paths: [String], baseline: WatchBaselineStore?
    ) -> AsyncStream<WatchEvent> {
        AsyncStream { continuation in
            let task = Task.detached { [weak self] in
                // Per-path signatures in the CALLER's store when it supplied
                // one, so restarting this stream (the watcher's project set
                // changed) doesn't silently re-baseline and swallow whatever
                // landed during the gap. See `WatchBaselineStore`.
                let memory = baseline ?? WatchBaselineStore()
                while !Task.isCancelled {
                    guard let self else { break }
                    ScarfMon.event(.transport, "ios.fileWatcher.paths", count: 1, bytes: paths.count)
                    let current = await ScarfMon.measureAsync(.transport, "ios.fileWatcher.tick") {
                        await self.buildWatchSignature(for: paths)
                    }
                    if !current.isEmpty, memory.apply(current) {
                        ScarfMon.event(.transport, "ios.fileWatcher.delta", count: 1)
                        continuation.yield(.anyChanged)
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildWatchSignature(for paths: [String]) async -> [String: String] {
        var parts: [String: String] = [:]
        for path in paths {
            if let stat = try? await asyncStat(path) {
                parts[path] = "\(Int(stat.mtime.timeIntervalSince1970)):\(stat.size)"
            } else {
                parts[path] = "0:0"
            }
        }
        return parts
    }

    // MARK: - Static helpers

    /// The app-level snapshots root, same shape as the macOS transport.
    nonisolated public static func snapshotDirURL(for id: ServerID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return caches
            .appendingPathComponent("scarf", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Async primitives (package-private, testable through subclassing)

    /// Rewrite a leading `~/` or bare `~` to the probed absolute
    /// `$HOME`. SFTP (per RFC 4254 / SFTP protocol) does NOT expand
    /// tildes — a path like `~/.hermes/memories/MEMORY.md` is treated
    /// as a relative path with a literal `~` directory name, so every
    /// SFTP op silently fails to locate the file. Normalize here before
    /// handing paths to Citadel's SFTP client.
    private func resolveSFTPPath(_ path: String) async throws -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = try await connectionHolder.resolveHome()
        if path == "~" { return home }
        return home + "/" + path.dropFirst(2)
    }

    private func asyncReadFile(_ path: String) async throws -> Data {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        return try await sftp.withFile(filePath: resolved, flags: [.read]) { file in
            let buf = try await file.readAll()
            return Data(buffer: buf)
        }
    }

    /// Atomic write: stage into a sibling temp file, then rename over the
    /// destination. Matches the contract `ServerTransport.writeFile`
    /// states and the other two transports already honour (`LocalTransport`
    /// writes `.atomic`, `SSHTransport` scps to a temp and `mv`s).
    ///
    /// The previous implementation opened the DESTINATION with `.truncate`
    /// and wrote chunks into it: on a phone, where the link drops for a
    /// lift-out-of-coverage as routinely as it stays up, that zeroed
    /// `AGENTS.md` / the session map / `cron/jobs.json` and left whatever
    /// chunks had landed. Nothing upstream can recover from that — the
    /// salvage/quarantine guards only ever see the file AFTER it was
    /// destroyed.
    ///
    /// Two details worth keeping:
    /// - The temp name carries a nonce, so two writers never share staging.
    /// - SFTP v3 `SSH_FXP_RENAME` is not POSIX rename: OpenSSH's
    ///   `sftp-server` FAILS when the destination exists. So a failed
    ///   rename falls back to remove-then-rename. That window is a few
    ///   milliseconds wide and, unlike truncate-first, the complete new
    ///   bytes already exist on the far side the whole time.
    private func asyncWriteFile(_ path: String, data: Data) async throws {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        let tmp = resolved + ".scarf-\(UUID().uuidString.prefix(8)).tmp"
        let byteBuffer = ByteBuffer(bytes: data)

        // `attributes` is applied at CREATE time, so a private-mode file is
        // never observable in a loose mode — the same chmod-before-publish
        // ordering `SSHTransport` uses. Citadel enforced no mode at all
        // before this, which left remote `.env` / `auth.json` written from
        // the phone world-readable where the Mac wrote them 0600.
        var attributes = SFTPFileAttributes()
        if TransportPrivateMode.shouldEnforce(for: path) {
            attributes.permissions = 0o600
        }

        do {
            try await sftp.withFile(
                filePath: tmp,
                flags: [.write, .create, .truncate],
                attributes: attributes
            ) { file in
                try await file.write(byteBuffer, at: 0)
            }
        } catch {
            try? await sftp.remove(at: tmp)
            throw error
        }

        // Belt to the create-time braces: some servers ignore the
        // attributes on OPEN. Applied to the STAGED path, so the file is
        // never observable at its real path in a loose mode — the same
        // chmod-before-publish ordering `SSHTransport` uses. Best effort:
        // a server that refuses `setstat` must not fail the write.
        if attributes.permissions != nil {
            try? await sftp.setAttributes(at: tmp, to: attributes)
        }

        do {
            try await sftp.rename(at: tmp, to: resolved)
        } catch {
            do {
                try await sftp.remove(at: resolved)
            } catch {
                // The destination is still intact, so the staging copy is
                // redundant — clear it rather than leave one behind per
                // failed write.
                try? await sftp.remove(at: tmp)
                throw error
            }
            do {
                try await sftp.rename(at: tmp, to: resolved)
            } catch {
                // The destination is gone and `tmp` is now the ONLY copy of
                // these bytes. Deleting it here would be the same data loss
                // this method exists to prevent, so it stays — named in the
                // error so a human can move it back.
                throw TransportError.fileIO(
                    path: path,
                    underlying: "write staged at \(tmp) but could not be renamed into place: \(error.localizedDescription)"
                )
            }
        }
    }

    private func asyncFileExists(_ path: String) async throws -> Bool {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        do {
            _ = try await sftp.getAttributes(at: resolved)
            return true
        } catch {
            return false
        }
    }

    private func asyncStat(_ path: String) async throws -> FileStat? {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        do {
            let attrs = try await sftp.getAttributes(at: resolved)
            let size = attrs.size.map { Int64($0) } ?? 0
            let mtime = attrs.accessModificationTime?.modificationTime ?? Date(timeIntervalSince1970: 0)
            // SFTPFileAttributes doesn't expose a "type" field directly;
            // infer "directory" from the permissions bits (S_IFDIR=0o40000).
            let isDir: Bool = {
                guard let perms = attrs.permissions else { return false }
                return (perms & 0o170000) == 0o040000
            }()
            return FileStat(size: size, mtime: mtime, isDirectory: isDir)
        } catch {
            return nil
        }
    }

    private func asyncListDirectory(_ path: String) async throws -> [String] {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        let listing = try await sftp.listDirectory(atPath: resolved)
        // Flatten all components across the response batches, strip the
        // conventional "." / ".." entries to match
        // `FileManager.contentsOfDirectory` behaviour.
        let names = listing.flatMap { $0.components }.map(\.filename)
        return names.filter { $0 != "." && $0 != ".." }
    }

    private func asyncCreateDirectory(_ path: String) async throws {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        // `createDirectory` at Citadel layer fails if the dir exists;
        // we want mkdir -p semantics so we walk the path and create
        // each component. Absolute paths only — the iOS app never
        // passes a relative path.
        let components = resolved.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var cursor = resolved.hasPrefix("/") ? "" : ""
        for component in components {
            cursor += "/" + component
            do {
                try await sftp.createDirectory(atPath: cursor)
            } catch {
                // Ignore "already exists" errors — mkdir -p semantics.
                // Citadel surfaces these as `SFTPError`; we can't cleanly
                // narrow to the SSH_FX_FAILURE subtype so we swallow any
                // error that specifically means "exists" by re-checking
                // via stat.
                let exists = (try? await asyncFileExists(cursor)) ?? false
                if !exists { throw error }
            }
        }
    }

    private func asyncRemoveFile(_ path: String) async throws {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        // Parallel to LocalTransport: no-op if the file doesn't exist.
        let exists = try await asyncFileExists(resolved)
        if !exists { return }
        try await sftp.remove(at: resolved)
    }

    private func asyncRunProcess(
        executable: String,
        args: [String],
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        let client = try await connectionHolder.ssh()
        // Citadel's raw exec channel doesn't source the user's shell rc
        // files, so non-interactive SSH sessions land with a stripped
        // PATH (typically just `/usr/bin:/bin`). pipx installs `hermes`
        // at `~/.local/bin/hermes`, and many of hermes's sub-tools
        // (git/curl/python) live in homebrew prefixes that the remote
        // sshd would otherwise add via login-shell init. Mac's OpenSSH
        // sshd handles this transparently; Citadel does not. We extend
        // PATH inline so bare `hermes` resolves AND any subprocess it
        // spawns can still find its tools.
        // Scope the selected profile's HERMES_HOME (#120, Design B) as a
        // process-env assignment. Set unconditionally (not just when the
        // executable is hermes) because several callers run hermes INSIDE a
        // `/bin/sh -c "… hermes …"` script — the env propagates to the
        // child hermes there too. It's empty for a default/root home, so
        // legacy active_profile behavior is preserved and pre-profile hosts
        // are unaffected; and it's harmless for the lone non-hermes caller
        // (`echo $HOME`), which ignores it. Mirrors the file layer, which
        // scopes via this same `config.remoteHome`.
        let hermesHome = HermesProfileScope.hermesHomeShellAssignment(
            forHome: config.remoteHome ?? HermesPathSet.defaultRemoteHome)
        let cmd = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" "
            + hermesHome
            + Self.shellJoin([executable] + args)
        // Citadel's `executeCommand` discards captured output when the
        // remote exits non-zero (it throws `CommandFailed` and the
        // accumulated ByteBuffer is lost). That breaks legitimate cases
        // like `hermes skills browse` printing a full table and *then*
        // exiting non-zero — callers see nothing and report "Browse
        // failed". Drive `executeCommandStream` directly so we can
        // collect stdout + stderr regardless of exit code, and surface
        // the real exit status.
        let stream: AsyncThrowingStream<ExecCommandOutput, Error>
        do {
            stream = try await client.executeCommandStream(cmd)
        } catch {
            return ProcessResult(
                exitCode: -1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8)
            )
        }
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32 = 0
        do {
            for try await chunk in stream {
                switch chunk {
                case .stdout(var buf):
                    if let s = buf.readString(length: buf.readableBytes) {
                        stdout.append(Data(s.utf8))
                    }
                case .stderr(var buf):
                    if let s = buf.readString(length: buf.readableBytes) {
                        stderr.append(Data(s.utf8))
                    }
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            exitCode = Int32(failed.exitCode)
        } catch {
            // Network / channel-level failure mid-stream — preserve any
            // partial output and report -1 so callers can distinguish
            // from a clean non-zero remote exit.
            stderr.append(Data(error.localizedDescription.utf8))
            exitCode = -1
        }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    // MARK: - Shell helpers

    /// Minimal shell-argument joiner. Handles spaces + quotes; sufficient
    /// for the commands we actually pass (`echo`, `stat`, `tail`, `sqlite3`).
    nonisolated static func shellJoin(_ argv: [String]) -> String {
        argv.map { arg in
            if arg.isEmpty { return "''" }
            let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_$")
            if arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// Rewrite a leading `~/` to `$HOME/` so remote double-quoted strings
    /// expand the path correctly. Matches SSHTransport's `remotePathArg`.
    nonisolated static func rewriteHomeRelative(_ path: String) -> String {
        if path.hasPrefix("~/") { return "$HOME/" + path.dropFirst(2) }
        if path == "~" { return "$HOME" }
        return path
    }

    // MARK: - Sync bridge

    /// Block the caller thread until the given async throwing operation
    /// finishes. Uses a `DispatchSemaphore` because `ServerTransport`'s
    /// protocol is synchronous (by design — services don't want to be
    /// async end-to-end). The macOS `SSHTransport` solves the same
    /// problem by spawning a subprocess and `Thread.sleep`-polling for
    /// termination; this is the Swift-concurrency equivalent.
    ///
    /// **Do not call from a MainActor context for long-running ops.**
    /// SwiftUI views should push through a ViewModel on a detached
    /// task. Transport users in this codebase already do this (every
    /// service touches disk in a `Task.detached` or on a nonisolated
    /// actor method).
    nonisolated private func runSync<T: Sendable>(
        _ op: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox<T>()
        Task.detached {
            do {
                let value = try await op()
                resultBox.set(.success(value))
            } catch {
                resultBox.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try resultBox.get()
    }
}

/// Tiny boxed result so the `runSync` continuation can store the async
/// result and hand it back to the blocking caller. `@unchecked Sendable`
/// because Swift can't prove the single-writer / single-reader pattern
/// is safe — we enforce it by the semaphore order-of-operations.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private var value: Result<T, Error>?
    private let lock = NSLock()

    func set(_ result: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = result
    }

    func get() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let value else {
            throw TransportError.other(message: "runSync completed without setting a result")
        }
        return try value.get()
    }
}

/// Owns the one long-lived `SSHClient` + `SFTPClient` pair for a
/// transport. Serializes open / reconnect so concurrent calls don't
/// race on the initial handshake.
private actor ConnectionHolder {
    private let contextID: ServerID
    private let config: SSHConfig
    private let keyProvider: CitadelServerTransport.KeyProvider

    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?
    /// In-flight connect / SFTP-open tasks so a CONCURRENT cold-start burst
    /// coalesces onto ONE handshake instead of each caller racing through the
    /// `nil` check during the `await` and opening its own connection (actor
    /// reentrancy). This is the other half of the gh#112 churn fix: pooling
    /// reuses one transport across ops; this makes that transport open one
    /// connection when Settings fires parallel reads at once.
    private var connectTask: Task<SSHClient, Error>?
    private var sftpTask: Task<SFTPClient, Error>?
    /// Resolved absolute `$HOME` on the remote host. Probed once per
    /// connection via `echo $HOME` over SSH exec, then memoized. Used
    /// to rewrite `~/…` SFTP paths (SFTP does NOT expand tildes — it
    /// treats them as literal characters, so `~/.hermes/…` reads fail
    /// unless we rewrite to the absolute path client-side).
    private var resolvedHome: String?

    init(
        contextID: ServerID,
        config: SSHConfig,
        keyProvider: @escaping CitadelServerTransport.KeyProvider
    ) {
        self.contextID = contextID
        self.config = config
        self.keyProvider = keyProvider
    }

    /// Probe + cache the remote user's home directory. Returns the
    /// absolute path (e.g. `/Users/alan`). Falls back to the original
    /// tilde-form on probe failure so callers get a best-effort path
    /// rather than a hard error; those callers will surface the real
    /// failure via the subsequent SFTP op.
    func resolveHome() async throws -> String {
        if let cached = resolvedHome { return cached }
        let client = try await ssh()
        let buffer = try await client.executeCommand("echo $HOME")
        let raw = buffer.getString(at: 0, length: buffer.readableBytes) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = trimmed.isEmpty ? "~" : trimmed
        resolvedHome = home
        return home
    }

    func ssh() async throws -> SSHClient {
        if let existing = sshClient, existing.isConnected {
            return existing
        }
        // Coalesce: a concurrent caller is already opening — join its task.
        if let inFlight = connectTask {
            return try await inFlight.value
        }
        // Create + publish the task with NO `await` between the nil-check above
        // and this assignment, so any caller entering during the open sees
        // `connectTask` and joins instead of starting its own handshake.
        let task = Task<SSHClient, Error> { [self] in try await self.openAndCache() }
        connectTask = task
        defer { connectTask = nil }
        return try await task.value
    }

    /// Drop a stale SFTP client bound to a now-dead connection, open a fresh
    /// SSH connection, and cache it. Runs inside the coalesced `connectTask`.
    private func openAndCache() async throws -> SSHClient {
        // Replacing the SSHClient invalidates any cached SFTPClient that was
        // bound to the previous (now-dead) connection. Drop it here so the
        // next sftp() call re-opens against the new client; without this,
        // every SFTP-backed call after a reconnect throws "channel closed"
        // until the app is restarted.
        if let oldSftp = sftpClient {
            try? await oldSftp.close()
            sftpClient = nil
        }
        let client = try await openSSH()
        sshClient = client
        return client
    }

    func sftp() async throws -> SFTPClient {
        // Pulling SSH first ensures a stale-after-reconnect cached
        // sftpClient is cleared in `ssh()` before we read it here.
        let client = try await ssh()
        if let existing = sftpClient {
            return existing
        }
        // Same coalescing as `ssh()` — concurrent first-SFTP callers share one
        // `openSFTP()` channel rather than each opening their own.
        if let inFlight = sftpTask {
            return try await inFlight.value
        }
        let task = Task<SFTPClient, Error> { [self] in try await self.openSFTPAndCache(client) }
        sftpTask = task
        defer { sftpTask = nil }
        return try await task.value
    }

    private func openSFTPAndCache(_ client: SSHClient) async throws -> SFTPClient {
        let sftp = try await client.openSFTP()
        sftpClient = sftp
        return sftp
    }

    func closeIfOpen() async {
        if let sftp = sftpClient {
            try? await sftp.close()
            sftpClient = nil
        }
        if let client = sshClient {
            try? await client.close()
            sshClient = nil
        }
    }

    private func openSSH() async throws -> SSHClient {
        let key = try await keyProvider()
        let ck: Curve25519.Signing.PrivateKey
        do {
            ck = try SSHPrivateKeyDecoding.curve25519PrivateKey(fromPEM: key.privateKeyPEM)
        } catch {
            throw TransportError.other(message: String(describing: error))
        }
        let username = config.user ?? "root"
        let host = config.host
        let port = config.port
        do {
            return try await SSHConnectPolicy.connect {
                // Fresh SSHAuthenticationMethod per attempt — Citadel's
                // auth delegate consumes its offer list on use, so a
                // reused instance would fail the retry with
                // `allAuthenticationOptionsFailed` instead of re-offering
                // the key.
                let auth: SSHAuthenticationMethod = .ed25519(username: username, privateKey: ck)
                var settings = SSHClientSettings(
                    host: host,
                    authenticationMethod: { auth },
                    hostKeyValidator: .acceptAnything()
                )
                if let port {
                    settings.port = port
                }
                return try await SSHClient.connect(to: settings)
            }
        } catch {
            throw TransportError.other(
                message: SSHConnectPolicy.describeConnectFailure(error, host: config.host)
            )
        }
    }
}

#endif // canImport(Citadel)
