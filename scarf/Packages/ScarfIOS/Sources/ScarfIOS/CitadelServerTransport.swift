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
/// Citadel is `async` everywhere. The `runSync(deadline:_:)` helper uses a
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

    // MARK: - Bridge ceilings

    /// How much longer than the caller's own timeout the synchronous bridge
    /// waits before giving up on the detached task (see ``runSync``). Long
    /// enough that a run finishing exactly on its budget is never pre-empted
    /// by the backstop, short enough that a wedged connection is a bounded
    /// stall rather than a permanent one.
    nonisolated static let syncGrace: TimeInterval = 10

    /// The ceiling for the SFTP operations, which carry no caller budget —
    /// `ServerTransport`'s file verbs take no `timeout` (unlike
    /// `runProcess`, whose one became non-optional in round-5 P48). A remote
    /// `readFile` of a Hermes JSON file is a sub-second round trip; sixty
    /// seconds is "the connection is gone", not "the file is big".
    nonisolated static let sftpCeiling: TimeInterval = 60

    // MARK: - ServerTransport: files

    public func readFile(_ path: String) throws -> Data {
        try runSync(deadline: Self.sftpCeiling) { try await self.asyncReadFile(path) }
    }

    public func unguardedWriteFile(_ path: String, data: Data) throws {
        try runSync(deadline: Self.sftpCeiling) { try await self.asyncWriteFile(path, data: data) }
    }

    public func fileExists(_ path: String) -> Bool {
        (try? runSync(deadline: Self.sftpCeiling) { try await self.asyncFileExists(path) }) ?? false
    }

    public func stat(_ path: String) -> FileStat? {
        try? runSync(deadline: Self.sftpCeiling) { try await self.asyncStat(path) }
    }

    public func listDirectory(_ path: String) throws -> [String] {
        try runSync(deadline: Self.sftpCeiling) { try await self.asyncListDirectory(path) }
    }

    public func createDirectory(_ path: String) throws {
        try runSync(deadline: Self.sftpCeiling) { try await self.asyncCreateDirectory(path) }
    }

    public func removeFile(_ path: String) throws {
        try runSync(deadline: Self.sftpCeiling) { try await self.asyncRemoveFile(path) }
    }

    // MARK: - ServerTransport: processes

    /// **This is not dead code, and P58's write-up said it was.** Decision 11
    /// gave the iOS bridge an `async` seam and the note recorded that `runSync`
    /// "survives only for the SFTP file verbs" — measured at P58b, the
    /// SYNCHRONOUS `runProcess` still has a live iOS caller:
    /// `ServerContext.UserHomeCache.probe` (`ServerContext.swift:343`), which
    /// is unguarded ScarfCore compiled for iOS and reaches this type through
    /// `ServerContext.sshTransportFactory`. Converting it to `asyncRunProcess`
    /// belongs to `t-02f830f4` with the rest of the end-to-end conversion;
    /// until then `runSync` has eight callers, not seven.
    ///
    /// **`stdin` is a straight pass-through to `runExec`'s write arm**
    /// (the same `Self.writeStdin` mechanism `_streamScriptImpl` uses), not a
    /// separate code path — `execArms` already runs the write concurrently
    /// with the drain, so there is nothing process-specific left to wire.
    public func runProcess(
        executable: String,
        args: [String],
        stdin: Data?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        // The async op owns `timeout`; the bridge's ceiling only has to
        // outlive it (see `runSync`).
        return try runSync(deadline: timeout + Self.syncGrace) {
            try await self.asyncRunProcess(executable: executable, args: args, stdin: stdin, timeout: timeout)
        }
    }

    /// The `async` seam (round-6 decision 11) — no bridge at all.
    ///
    /// ``ServerTransport``'s default implementation wraps the SYNCHRONOUS
    /// `runProcess` in an `OffPool.run`, which for this transport would be
    /// two hops around work that is already `async`: `runSync` blocks a
    /// thread on a semaphore while `asyncRunProcess` runs on the cooperative
    /// pool, so a caller on a pool thread competes with the work it waits
    /// for. Overriding here deletes both. `runSync` stays for the SFTP file
    /// verbs, whose `ServerTransport` signatures are synchronous.
    ///
    /// The partial-stdout-on-timeout contract is unchanged and is now the
    /// only one in play: `asyncRunProcess`'s drain and budget arms share one
    /// ``PartialStdout`` accumulator (round-6 P53), where the bridge could
    /// only ever report `Data()`.
    public func asyncRunProcess(
        executable: String,
        args: [String],
        stdin: Data?,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await asyncRunProcessImpl(
            executable: executable, args: args, stdin: stdin, timeout: timeout)
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

    /// Run `script` on the remote by writing it to the exec channel's STDIN.
    ///
    /// The command line is only
    ///
    ///     PATH=… head -c <byte count> | /bin/sh
    ///
    /// and the script bytes follow on stdin. Nothing of the script is in any
    /// remote process's argv, so nothing in it (a Live Voice SDP offer with
    /// its ICE credentials, the text of a message being spoken) is visible
    /// in the host's `ps` while it runs. This replaced
    /// `printf '%s' '<base64 script>' | base64 -d | /bin/sh`, which put the
    /// whole script in the login shell's argv for the script's lifetime.
    ///
    /// **Why `head -c`, not `sh -s`.** Citadel 0.12's `TTYStdinWriter` can
    /// write but cannot send EOF (it has only `write` and `changeSize`,
    /// `Citadel/TTY/Client/TTY.swift:75-94`), so a shell reading the channel
    /// directly would wait for more script forever. `head -c N` reads exactly
    /// the script, exits, and so hands `/bin/sh` the EOF the channel can't.
    /// Commands in the script share `sh`'s stdin — the script pipe — exactly
    /// as they did with the old base64 pipe, so a command that reads stdin
    /// would eat the rest of the script; every caller feeds its input by
    /// heredoc instead. `head -c` is in GNU coreutils, BSD/macOS and BusyBox;
    /// where it were missing, `sh` would see an empty script and exit 0 —
    /// the same failure shape as a missing `base64` before.
    ///
    /// **A host whose login rc files themselves read stdin will eat script
    /// bytes and the call will time out.** `head -c N | /bin/sh` guarantees
    /// only that the *script* isn't interrupted mid-read by another reader on
    /// the same pipe — `/bin/sh` here may still source `.bashrc`/`.zshrc`/
    /// `.profile` before it gets to `head`'s output, and if one of those rc
    /// files has an interactive-only `read` (a "press enter to continue"
    /// prompt, an MOTD gate, etc.) that `read` consumes bytes from the same
    /// stdin the script is riding in on. The fix is on the remote host:
    /// guard any such line with `[[ $- == *i* ]]` (true only for an
    /// interactive shell) so it never runs against this non-interactive
    /// exec. See the wiki Troubleshooting page for the user-facing symptom
    /// and remedy.
    public func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        try await ScarfMon.measureAsync(.transport, "ssh.streamScript") {
            try await _streamScriptImpl(script, timeout: timeout)
        }
    }

    private func _streamScriptImpl(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        let scriptBytes = Data(script.utf8)
        let cmd = Self.streamScriptCommand(byteCount: scriptBytes.count)
        return try await runScript(cmd, stdin: scriptBytes, timeout: timeout)
    }

    /// The exec command for a script of `byteCount` bytes sent on stdin.
    /// Same PATH guard `asyncRunProcess` uses, so `head` and `sh` resolve on
    /// hosts with a stripped exec PATH.
    nonisolated static func streamScriptCommand(byteCount: Int) -> String {
        "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" "
            + "head -c \(byteCount) | /bin/sh"
    }

    private func runScript(_ cmd: String, stdin: Data? = nil, timeout: TimeInterval) async throws -> ProcessResult {
        do {
            return try await runExec(cmd, stdin: stdin, timeout: timeout, midStream: .typedError)
        } catch let start as ExecStartFailure {
            throw TransportError.other(
                message: "Failed to start exec stream: \(start.underlying.localizedDescription)")
        }
    }

    // MARK: - The one remote-exec drain

    /// What a mid-stream transport failure means to the caller.
    enum MidStreamFailure {
        /// Keep the partial output and report exit `-1`, so the caller can
        /// tell a broken channel from a clean non-zero remote exit
        /// (`asyncRunProcess`).
        case exitMinusOne
        /// Throw a typed `TransportError.other`, so `RemoteSQLiteBackend`
        /// routes it to `.transport` rather than misreading it as a sqlite
        /// crash (`runScript`).
        case typedError
    }

    /// The exec never started — the caller decides what that looks like.
    private struct ExecStartFailure: Error { let underlying: any Error }

    /// Citadel's `TTYOutput` is not `Sendable`; exactly one task ever reads it.
    private struct UncheckedBox<T>: @unchecked Sendable { let value: T }

    /// Run `cmd` on the remote, collect stdout/stderr regardless of exit code,
    /// and give up after `timeout` — **closing the SSH channel when it does**.
    ///
    /// Both remote execs used `executeCommandStream`, which hands back only
    /// the `AsyncThrowingStream` and DISCARDS the `Channel`
    /// `_executeCommandStream` created for it (Citadel
    /// `Sources/Citadel/TTY/Client/TTY.swift:269-339`). That stream has no
    /// `onTermination`, so cancelling the task that reads it stops the READER
    /// and nothing else: the remote command kept running and its channel
    /// stayed open until the command finished on its own, one orphan per
    /// timed-out call, on a phone whose whole reason for the timeout is that
    /// the remote has stopped answering (round-5 P48b).
    ///
    /// `withExec` is the public API that OWNS the channel — it closes it when
    /// the closure returns and when the closure throws — so the timeout is
    /// thrown from inside the closure rather than raced outside it. Same call
    /// Citadel's own docs use, and the one `SSHExecACPChannel` already drives.
    private func runExec(
        _ cmd: String,
        stdin: Data? = nil,
        timeout: TimeInterval,
        midStream: MidStreamFailure
    ) async throws -> ProcessResult {
        let client = try await connectionHolder.ssh()
        var started = false
        var collected: ProcessResult?
        do {
            try await client.withExecTolerantClose(cmd) { inbound, outbound in
                started = true
                let boxed = UncheckedBox(value: inbound)
                let writer = UncheckedBox(value: outbound)
                // The bytes the drain has accumulated SO FAR, readable from
                // the timeout arm. Without it the two arms each built a
                // different error: the drain's `CancellationError` catch
                // raised `.timeout(partialStdout: stdout)` with everything it
                // had read, and the budget arm — the one that actually wins a
                // timeout, since `group.next()` returns the FIRST arm and the
                // drain's throw is then discarded by `cancelAll()` — raised
                // `.timeout(partialStdout: Data())`. Every iOS timeout
                // therefore reported empty output, while `SSHTransport`'s
                // timeout arm hands back `drain.collect()` (round-5 P53).
                let partial = PartialStdout()
                let writeArm: (@Sendable () async throws -> Void)?
                if let stdin, !stdin.isEmpty {
                    writeArm = {
                        try await Self.writeStdin(stdin) { chunk in
                            try await writer.value.write(ByteBuffer(bytes: chunk))
                        }
                    }
                } else {
                    writeArm = nil
                }
                collected = try await Self.execArms(
                    writeStdin: writeArm,
                    drain: { try await Self.drain(boxed, timeout: timeout, midStream: midStream, partial: partial) },
                    timeout: timeout
                )
                if collected == nil {
                    // The budget went first. THROWING is what closes the
                    // channel: `withExec` closes it on the way out either way,
                    // and returning normally here would hand the caller a
                    // success it does not have. The partial stdout is the
                    // whole value of this arm — a `hermes` run that printed
                    // half a JSON payload before the connection wedged is
                    // diagnosable, an empty `Data()` is not.
                    throw TransportError.timeout(
                        seconds: timeout, partialStdout: partial.bytes())
                }
            }
        } catch {
            if !started { throw ExecStartFailure(underlying: error) }
            throw error
        }
        guard let collected else {
            throw TransportError.other(message: "SSH exec produced no result")
        }
        return collected
    }

    /// Run the exec's three concurrent parts: the stdin write, the drain of
    /// the remote's output, and the timeout budget. Returns the drained
    /// result, or `nil` when the budget won.
    ///
    /// The write runs in a task of its OWN, outside the group, for two
    /// reasons. It used to sit at the head of the drain's task, so no output
    /// was read until it finished — a remote that answers while still being
    /// fed, or a stdin larger than the SSH channel window (which only opens
    /// as the remote reads), stalls that way round. And because NIO's
    /// `writeAndFlush` ignores cancellation, awaiting the write inside the
    /// group let a parked write hold `withThrowingTaskGroup` open long past
    /// `timeout` — charter C10 wants a timeout that can actually fire. The
    /// write task is cancelled on the way out either way.
    ///
    /// A failed write usually means the remote already exited (a login shell
    /// that rejected the command): its exit status and stderr are the real
    /// diagnosis, so the write error is reported only when the drain came
    /// back with nothing at all.
    static func execArms(
        writeStdin: (@Sendable () async throws -> Void)?,
        drain: @escaping @Sendable () async throws -> ProcessResult,
        timeout: TimeInterval
    ) async throws -> ProcessResult? {
        let writeFailure = WriteFailure()
        let writeTask: Task<Void, Never>? = writeStdin.map { write in
            Task { do { try await write() } catch { writeFailure.record(error) } }
        }
        defer { writeTask?.cancel() }
        return try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask {
                let result = try await drain()
                if let failure = writeFailure.error, result.exitCode == 0,
                   result.stdout.isEmpty, result.stderr.isEmpty {
                    throw TransportError.other(
                        message: "Failed to send the script over SSH: \(failure.localizedDescription)")
                }
                return result
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw TransportError.other(message: "SSH exec produced no result")
            }
            group.cancelAll()
            return first
        }
    }

    /// How much stdin goes out per `writeAndFlush`. Small enough that a
    /// remote which stopped reading parks only one chunk.
    static let stdinChunkBytes = 16 * 1024

    /// Write `data` to the exec channel in chunks, checking for cancellation
    /// between them: `writeAndFlush` itself ignores cancellation, so one big
    /// write on a full channel window is un-interruptible for as long as the
    /// remote refuses to read. Chunking bounds that to one chunk.
    static func writeStdin(
        _ data: Data,
        chunkSize: Int = stdinChunkBytes,
        write: (Data) async throws -> Void
    ) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            let end = data.index(offset, offsetBy: min(chunkSize, data.distance(from: offset, to: data.endIndex)))
            try await write(data[offset..<end])
            offset = end
        }
    }

    /// Read the exec stream to EOF. Cancellation (the timeout arm cancelling
    /// the group) surfaces as a typed timeout carrying whatever had arrived.
    private static func drain(
        _ boxed: UncheckedBox<TTYOutput>,
        timeout: TimeInterval,
        midStream: MidStreamFailure,
        partial: PartialStdout
    ) async throws -> ProcessResult {
        try await absorb(boxed.value, timeout: timeout, midStream: midStream, partial: partial)
    }

    /// The loop itself, over ANY sequence of exec chunks.
    ///
    /// Split out from ``drain(_:timeout:midStream:partial:)`` — whose only
    /// job is now unwrapping the non-`Sendable` `TTYOutput` — so the mirror
    /// into `partial` can be proved by RUNNING it. P53's test asserted the
    /// mirror by grepping this file for `partial.append(bytes)`, which says
    /// nothing about which arm the call sits in or whether the timeout arm
    /// can see the bytes (round-6 P53b).
    static func absorb<S: AsyncSequence>(
        _ chunks: S,
        timeout: TimeInterval,
        midStream: MidStreamFailure,
        partial: PartialStdout
    ) async throws -> ProcessResult where S.Element == ExecCommandOutput {
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32 = 0
        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                switch chunk {
                case .stdout(var buf):
                    // Read RAW bytes, never decode per chunk. Citadel hands
                    // back one `ExecCommandOutput` per SSH data packet, and a
                    // multi-byte UTF-8 character routinely lands split across
                    // two of them — decoding each packet on its own (the old
                    // `readString(length:)`) turns the split character into
                    // two U+FFFD replacement characters, silently, since
                    // `ByteBuffer.readString` never throws on invalid UTF-8.
                    // `ProcessResult.stdout`/`stderr` are `Data`, not `String`
                    // — there is no decode step this needs to wait for, only
                    // one to stop doing early. Any caller that wants text
                    // decodes the fully-accumulated `Data` once, at the end.
                    if let bytes = buf.readBytes(length: buf.readableBytes) {
                        let data = Data(bytes)
                        stdout.append(data)
                        // Mirrored into the shared accumulator as it arrives,
                        // so the sibling timeout arm can report it.
                        partial.append(data)
                    }
                case .stderr(var buf):
                    if let bytes = buf.readBytes(length: buf.readableBytes) {
                        stderr.append(Data(bytes))
                    }
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            // A genuine remote non-zero exit — surfaced as a ProcessResult so
            // the caller's exit-code handling fires (mapped to
            // BackendError.sqlite by RemoteSQLiteBackend).
            exitCode = Int32(failed.exitCode)
        } catch is CancellationError {
            throw TransportError.timeout(seconds: timeout, partialStdout: stdout)
        } catch {
            switch midStream {
            case .exitMinusOne:
                stderr.append(Data(error.localizedDescription.utf8))
                exitCode = -1
            case .typedError:
                throw TransportError.other(
                    message: "SSH stream failed: \(error.localizedDescription)")
            }
        }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
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

        try await SFTPRenamePublisher.publish(
            stagedPath: tmp,
            reportPath: path,
            rename: { try await sftp.rename(at: tmp, to: resolved) },
            destinationExists: { (try? await sftp.getAttributes(at: resolved)) != nil },
            removeDestination: { try await sftp.remove(at: resolved) },
            removeStaged: { try? await sftp.remove(at: tmp) }
        )
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

    private func asyncRunProcessImpl(
        executable: String,
        args: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
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
        // `COLUMNS` rides the same assignment prefix as `PATH` and
        // `HERMES_HOME` (P54, round-6). Citadel's raw exec channel is not a
        // TTY and forwards none of the client's environment, so the remote
        // `rich` takes its 80-column non-TTY default
        // (`Console.width` → `COLUMNS` → 80) and wraps any line longer than
        // that. Scarf judges Hermes runs by matching whole printed lines, so
        // a wrap can split a marker in half — the shipped case P40b found is
        // `✓ Plugin <name> updated.` (`hermes_cli/plugins_cmd.py:828` @
        // `v2026.9.7`), matched as a column-0 prefix AND an `updated.` tail.
        //
        // The Mac's two transports have carried a wide `COLUMNS` since P40b
        // (``ScarfCore/LocalTransport/subprocessEnvironment(forExecutable:)``
        // and `SSHTransport.composedRemoteCommand`). This is the THIRD spawn
        // family and it was the one without — every judged `runProcess` the
        // iOS runtime makes comes through here. The value is read from
        // `LocalTransport.wideColumns` rather than written out, so the three
        // families cannot drift to three different widths.
        //
        // The remaining exec family, `_streamScriptImpl`, deliberately does
        // NOT carry it: it pipes a `/bin/sh` script (sqlite3, the bots
        // scan), none of whose output is verdict-matched, and the Mac twin
        // (`SSHTransport.streamScript` → `SSHScriptRunner`) does not carry it
        // either. Parity is the point in both directions.
        let cmd = "COLUMNS=\(LocalTransport.wideColumns) "
            + "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" "
            + hermesHome
            + Self.shellJoin([executable] + args)
        // Citadel's `executeCommand` discards captured output when the
        // remote exits non-zero (it throws `CommandFailed` and the
        // accumulated ByteBuffer is lost). That breaks legitimate cases
        // like `hermes skills browse` printing a full table and *then*
        // exiting non-zero — callers see nothing and report "Browse
        // failed". `runExec` drives the stream directly so we collect
        // stdout + stderr regardless of exit code, and surface the real exit
        // status.
        //
        // `timeout` was accepted and then IGNORED here until round-5 P48 —
        // every arm simply drained the stream to its end, so a remote that
        // stopped producing hung the iOS caller with no ceiling at all. C10
        // says every subprocess has a timeout and a remote exec is one. P48b
        // moved both execs onto `withExec` so the ceiling also CLOSES the
        // channel instead of abandoning it; see `runExec`.
        do {
            return try await runExec(cmd, stdin: stdin, timeout: timeout, midStream: .exitMinusOne)
        } catch let start as ExecStartFailure {
            return ProcessResult(
                exitCode: -1,
                stdout: Data(),
                stderr: Data(start.underlying.localizedDescription.utf8)
            )
        }
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
    ///
    /// **The wait is BOUNDED (charter C10, round-5 P53).** It was a bare
    /// `semaphore.wait()`, which is the one shape C10 has no answer for: the
    /// work runs on a `Task.detached` — a COOPERATIVE-POOL task, one thread
    /// per core and unable to grow — while the caller's thread blocks on the
    /// semaphore. If the caller is itself on a pool thread, the two are
    /// competing for the same fixed set, and if Citadel never resumes (a
    /// half-open TCP connection with no keepalive, the iOS analogue of the
    /// wedged `ProxyCommand` `SSHTransport.runLocal` bounds) nothing on
    /// either side ever times out. Every macOS spawn has a ceiling; this is
    /// the iOS one.
    ///
    /// The deadline is the CALLER's budget plus ``syncGrace``: the async op
    /// owns the timeout (`asyncRunProcess` races the drain against
    /// `timeout`), so this ceiling only has to outlive it far enough not to
    /// pre-empt a legitimate slow-but-succeeding run — it is a backstop for
    /// an op that never returns at all, not a second timeout.
    ///
    /// **The seam, stated plainly:** the right fix is for `runProcess` to be
    /// `async` so there is no blocking bridge at all — `t-02f830f4`. Until
    /// then the bridge exists and is bounded, and on expiry the result is
    /// ABANDONED, not cancelled: the detached task keeps running and writes
    /// into a `ResultBox` nobody reads. That is the same contract
    /// ``ScarfCore/OffPool`` documents ("the result is dropped, never the
    /// work"), written down here because a caller that reads a timeout as
    /// "the remote command stopped" would be wrong.
    ///
    /// **And its own expiry throws `partialStdout: Data()` on purpose**
    /// (P60). `PartialStdout` exists so the INNER budget — the one
    /// `asyncRunProcess` races the drain against — can report the bytes the
    /// drain had accumulated, and that arm is the one a real slow command
    /// hits. This arm is the backstop BEHIND it: reaching it means the async
    /// op blew past its own timeout plus ``syncGrace`` and never returned at
    /// all, so the detached task still owns its drain and there is no
    /// accumulator to read from here. Empty is the honest answer, not a
    /// missing hand-off to `PartialStdout`.
    nonisolated private func runSync<T: Sendable>(
        deadline: TimeInterval,
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
        if semaphore.wait(timeout: .now() + deadline) == .timedOut {
            throw TransportError.timeout(seconds: deadline, partialStdout: Data())
        }
        return try resultBox.get()
    }
}

/// The stdin write task's error, read by the drain arm that runs alongside
/// it (``CitadelServerTransport/execArms(writeStdin:drain:timeout:)``).
final class WriteFailure: @unchecked Sendable {
    private var stored: (any Error)?
    private let lock = NSLock()

    func record(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        stored = error
    }

    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// The stdout bytes an exec drain has read so far, shared with its sibling
/// timeout arm.
///
/// `SSHTransport.runLocal`'s timeout arm reports `drain.collect()` — whatever
/// the concurrent drain had accumulated when the budget ran out. The iOS
/// exec had no equivalent, so its timeout reported `Data()` while the drain
/// task held the bytes and was then cancelled. One lock, append-only, read
/// once.
final class PartialStdout: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(bytes)
    }

    func bytes() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
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

/// The PUBLISH half of an atomic SFTP write: stage under a nonce name,
/// then rename into place. Factored out of `CitadelServerTransport` so its
/// policy is testable without a live SFTP server (`TransportError.fileIO`
/// and the closures are the whole surface).
///
/// **The rule it encodes (P8 DI-H1).** SFTP v3's `SSH_FXP_RENAME` is not
/// POSIX rename — OpenSSH's sftp-server FAILS when the destination exists,
/// so a fallback that displaces the destination is required. But a failed
/// rename is not PROOF that the destination is what failed it: SFTP hands
/// back one undifferentiated status, and a dropped cellular link produces
/// the same one. The previous fallback deleted the destination on ANY
/// rename error, so a blip deleted the user's file and then failed the
/// retry too. Two proofs are taken before the destination is touched:
/// the plain rename is retried once (a transient blip clears), and only
/// then is the destination probed for existence. Without both, the
/// destination is left exactly as it was and the staged bytes — the only
/// copy of the new content — are named in the thrown error, never removed.
enum SFTPRenamePublisher {
    static func publish(
        stagedPath: String,
        reportPath: String,
        rename: () async throws -> Void,
        destinationExists: () async -> Bool,
        removeDestination: () async throws -> Void,
        removeStaged: () async -> Void
    ) async throws {
        do {
            try await rename()
            return
        } catch {
            // 1. A transient failure clears on a retry, and a retry costs
            //    one round-trip against destroying a file.
            if (try? await rename()) != nil { return }

            // 2. Only a destination that is actually there justifies
            //    removing it.
            guard await destinationExists() else {
                throw TransportError.fileIO(
                    path: reportPath,
                    underlying: "write staged at \(stagedPath) but could not be renamed into place "
                        + "(the destination was left untouched): \(error.localizedDescription)"
                )
            }

            do {
                try await removeDestination()
            } catch {
                // The destination is still intact, so the staging copy is
                // redundant — clear it rather than leave one behind per
                // failed write.
                await removeStaged()
                throw error
            }

            do {
                try await rename()
            } catch {
                // The destination is gone and the staged file is now the
                // ONLY copy of these bytes. Deleting it here would be the
                // same data loss this path exists to prevent, so it stays —
                // named in the error so a human can move it back.
                throw TransportError.fileIO(
                    path: reportPath,
                    underlying: "write staged at \(stagedPath) but could not be renamed into place: \(error.localizedDescription)"
                )
            }
        }
    }
}

#endif // canImport(Citadel)
