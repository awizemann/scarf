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

    // MARK: - ServerTransport: SQLite snapshot

    public func snapshotSQLite(remotePath: String) throws -> URL {
        try runSync { try await self.asyncSnapshotSQLite(remotePath: remotePath) }
    }

    // MARK: - ServerTransport: watching

    public func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        // Polling-based, identical in shape to `SSHTransport`'s remote-
        // watch fallback: stat each path, yield `.anyChanged` when any
        // mtime shifts. 3s tick keeps bandwidth low.
        AsyncStream { continuation in
            let task = Task.detached { [weak self] in
                var lastSignature = ""
                while !Task.isCancelled {
                    guard let self else { break }
                    let current = await self.buildWatchSignature(for: paths)
                    if !current.isEmpty, current != lastSignature {
                        if !lastSignature.isEmpty {
                            continuation.yield(.anyChanged)
                        }
                        lastSignature = current
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildWatchSignature(for paths: [String]) async -> String {
        var parts: [String] = []
        for path in paths {
            if let stat = try? await asyncStat(path) {
                parts.append("\(path):\(Int(stat.mtime.timeIntervalSince1970)):\(stat.size)")
            } else {
                parts.append("\(path):0:0")
            }
        }
        return parts.joined(separator: ",")
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

    private func asyncWriteFile(_ path: String, data: Data) async throws {
        let sftp = try await connectionHolder.sftp()
        let resolved = try await resolveSFTPPath(path)
        let byteBuffer = ByteBuffer(bytes: data)
        try await sftp.withFile(
            filePath: resolved,
            flags: [.write, .create, .truncate]
        ) { file in
            try await file.write(byteBuffer, at: 0)
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
        let cmd = Self.shellJoin([executable] + args)
        // Citadel's executeCommand accumulates stdout into a ByteBuffer.
        // stderr isn't separately exposed — we fold it into the output
        // via `2>&1` so error paths still give callers something to
        // show. Exit code is similarly not directly exposed; on non-
        // zero exit Citadel throws, so we map that to a commandFailed
        // error with the captured output as stderr.
        do {
            let buffer = try await client.executeCommand(cmd + " 2>&1")
            var buf = buffer
            let str = buf.readString(length: buf.readableBytes) ?? ""
            return ProcessResult(
                exitCode: 0,
                stdout: Data(str.utf8),
                stderr: Data()
            )
        } catch {
            return ProcessResult(
                exitCode: 1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8)
            )
        }
    }

    private func asyncSnapshotSQLite(remotePath: String) async throws -> URL {
        // Same flow as SSHTransport: run `sqlite3 .backup` on the remote
        // (WAL-safe), flip out of WAL mode on the snapshot, then SFTP
        // the backup file down to the local cache.
        try? FileManager.default.createDirectory(at: snapshotBaseDir, withIntermediateDirectories: true)
        let localURL = snapshotBaseDir.appendingPathComponent("state.db")
        let client = try await connectionHolder.ssh()
        let remoteTmp = "/tmp/scarf-snapshot-\(UUID().uuidString).db"
        // Double-quote paths; $HOME expansion happens inside double quotes.
        let rewritten = Self.rewriteHomeRelative(remotePath)
        let backupScript = #"sqlite3 "\#(rewritten)" ".backup '\#(remoteTmp)'" && sqlite3 '\#(remoteTmp)' "PRAGMA journal_mode=DELETE;" > /dev/null"#
        _ = try await client.executeCommand(backupScript + " 2>&1")

        // SFTP-download the remote tmp into our local snapshot cache.
        let sftp = try await connectionHolder.sftp()
        let data: Data = try await sftp.withFile(filePath: remoteTmp, flags: [.read]) { file in
            let buf = try await file.readAll()
            return Data(buffer: buf)
        }
        try data.write(to: localURL, options: .atomic)

        // Best-effort cleanup of the remote tmp.
        _ = try? await client.executeCommand("rm -f '\(remoteTmp)'")

        return localURL
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
        let client = try await openSSH()
        sshClient = client
        return client
    }

    func sftp() async throws -> SFTPClient {
        if let existing = sftpClient {
            return existing
        }
        let client = try await ssh()
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
        guard let parts = Ed25519KeyGenerator.decodeRawEd25519PEM(key.privateKeyPEM) else {
            throw TransportError.other(message: "Stored private key is not in the expected Scarf Ed25519 PEM format")
        }
        guard let ck = try? Curve25519.Signing.PrivateKey(rawRepresentation: parts.privateKey) else {
            throw TransportError.other(message: "Stored private key is malformed")
        }
        let username = config.user ?? "root"
        let auth: SSHAuthenticationMethod = .ed25519(username: username, privateKey: ck)
        var settings = SSHClientSettings(
            host: config.host,
            authenticationMethod: { auth },
            hostKeyValidator: .acceptAnything()
        )
        if let port = config.port {
            settings.port = port
        }
        return try await SSHClient.connect(to: settings)
    }
}

#endif // canImport(Citadel)
