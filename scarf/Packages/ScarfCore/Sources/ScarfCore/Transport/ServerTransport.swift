import Foundation

/// Unified I/O surface shared by local and remote Hermes installations.
///
/// **Design rationale.** The services that read Hermes state (`~/.hermes/…`)
/// and spawn the `hermes` CLI all boil down to a handful of primitives:
/// read/write/list files, stat file attributes, run a process to completion,
/// spawn a long-running stdio process for streaming, take a consistent DB
/// snapshot, observe file changes. `ServerTransport` exposes exactly those
/// primitives so the same service code works against either a local
/// filesystem or a remote host reached over SSH.
///
/// The primitives are deliberately **synchronous where possible** (file I/O,
/// process `run` + wait) so services don't need to become `async` end-to-end.
/// Streaming stdio (log tail, ACP JSON-RPC) goes through the
/// `streamLines(...)` async-stream variant so `Foundation.Process` never
/// appears in the public protocol — that's iOS-unavailable and would break
/// the ScarfCore compile for the iOS app target.
public protocol ServerTransport: Sendable {
    /// Identifies the context this transport serves. Used for cache
    /// namespacing (e.g. per-server SQLite snapshot directories).
    nonisolated var contextID: ServerID { get }

    /// `true` if this transport talks to a remote host over SSH.
    nonisolated var isRemote: Bool { get }

    // MARK: - Files

    nonisolated func readFile(_ path: String) throws -> Data
    /// Atomic write: the file at `path` is either the previous contents or
    /// the new contents, never a partial write. Preserves `0600` mode for
    /// paths that match `.env` conventions so secrets stay owner-only.
    nonisolated func writeFile(_ path: String, data: Data) throws
    nonisolated func fileExists(_ path: String) -> Bool
    nonisolated func stat(_ path: String) -> FileStat?
    /// Stat MANY paths, ideally in one transport round-trip.
    ///
    /// The point of this existing at all is the remote case: `stat` is one
    /// SSH round-trip, so a caller that wants to know whether any of a
    /// dozen files changed paid a dozen. Every change-detection fast path
    /// in the app (the cockpit's per-facet short-circuit, the widget
    /// re-read guards) asks that question, so it gets one call. Paths that
    /// do not exist are simply ABSENT from the result — the same
    /// information `stat` returning nil carries.
    nonisolated func statAll(_ paths: [String]) -> [String: FileStat]
    nonisolated func listDirectory(_ path: String) throws -> [String]
    /// Create directories including intermediates. No-op if already present.
    nonisolated func createDirectory(_ path: String) throws
    /// Delete a file. No-op if absent.
    nonisolated func removeFile(_ path: String) throws

    // MARK: - Processes

    /// Run a process to completion and capture its stdout/stderr. For remote
    /// transports this actually invokes `ssh host -- executable args…` under
    /// the hood; for local it spawns `executable` directly.
    nonisolated func runProcess(
        executable: String,
        args: [String],
        stdin: Data?,
        timeout: TimeInterval?
    ) throws -> ProcessResult

    /// Return a `Process` configured for the target — already pointed at the
    /// right executable with the right arguments, but **not yet started**.
    /// Callers attach their own `Pipe`s and call `run()`. Used by the Mac
    /// app's ACPClient+Mac factory and (historically) by HermesLogService's
    /// streaming tail.
    ///
    /// **Platform-gated.** `Foundation.Process` is macOS/Linux-only — it is
    /// NOT available on iOS. The iOS app uses `streamLines(...)` for any
    /// streaming-stdio need; `makeProcess` exists solely for the Mac /
    /// Linux-CI code paths that already depended on it.
    #if !os(iOS)
    nonisolated func makeProcess(executable: String, args: [String]) -> Process

    /// As `makeProcess(executable:args:)` but spawns the process with its
    /// working directory set to `cwd` (when non-nil + present). Used for
    /// project-scoped `hermes acp` chats: Hermes reads a project's context
    /// files (AGENTS.md / CLAUDE.md / .cursorrules) from the PROCESS cwd, so
    /// the spawn dir — not the ACP `session/new` cwd — is what loads them.
    /// A default impl (below) ignores `cwd`, so transports that don't need
    /// it require no change.
    nonisolated func makeProcess(executable: String, args: [String], cwd: String?) -> Process
    #endif

    /// Platform-neutral streaming exec. Runs `executable args…` on the target
    /// and yields one stdout line per `AsyncThrowingStream` element (newline
    /// framing, stripped). The stream finishes on EOF / clean exit and errors
    /// with `TransportError.commandFailed` on non-zero exit.
    ///
    /// Callers must iterate the stream to consume bytes — the underlying
    /// subprocess / SSH channel is started lazily on first iteration and
    /// torn down when the iterator is dropped.
    ///
    /// Replaces the stdout-pipe dance that `makeProcess` required; services
    /// like `HermesLogService` migrated here in M3.
    nonisolated func streamLines(
        executable: String,
        args: [String]
    ) -> AsyncThrowingStream<String, Error>

    /// Binary-safe streaming exec. Same shape as `streamLines` but yields
    /// arbitrary `Data` chunks of stdout instead of newline-delimited
    /// strings. Required by the backup feature: `tar -czf -` produces
    /// gzipped tar bytes that must NOT be decoded as UTF-8 / split on
    /// `\n` — `streamLines` would silently corrupt the archive.
    ///
    /// Stream finishes on EOF / clean exit; errors with
    /// `TransportError.commandFailed` on non-zero exit (carrying the
    /// captured stderr tail). Chunk sizes are whatever the underlying
    /// pipe returns from `availableData`, typically 4–64 KB on macOS.
    nonisolated func streamRawBytes(
        executable: String,
        args: [String]
    ) -> AsyncThrowingStream<Data, Error>

    /// Pipe a multi-line shell script through `/bin/sh -s` on the
    /// target and return its captured output. The script travels as a
    /// single opaque byte stream — no per-line shell interpolation,
    /// no per-arg quoting — so `"$VAR"` references, here-docs, and
    /// nested quotes survive untouched.
    ///
    /// Replaces the old `snapshotSQLite` + scp pipeline. Used by
    /// `RemoteSQLiteBackend` to invoke `sqlite3 -readonly -json` over
    /// SSH per query (or per batch). Local transport runs the script
    /// in-process via `/bin/sh -c`. SSH transport delegates to
    /// `SSHScriptRunner` (ControlMaster-shared channel). Citadel
    /// transport (iOS) base64-encodes the script + decodes remotely
    /// to skirt Citadel's missing-stdin support.
    ///
    /// Throws on transport failures (host unreachable, ssh exit 255,
    /// timeout). Returns `ProcessResult` with the script's exit code
    /// + stdout + stderr on completion — non-zero exit is NOT a
    /// throw; callers inspect `exitCode` and decide.
    nonisolated func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult

    // MARK: - Watching

    /// Observe changes to a set of paths and yield events when any of them
    /// change. Local: FSEvents. Remote: polls `stat` mtime every 3s.
    nonisolated func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent>

    /// `watchPaths`, but with the caller's own per-path signature memory.
    ///
    /// A polling watcher has to baseline before it can report a delta, so
    /// the FIRST poll after a (re)start is silent by construction — and a
    /// change that lands inside that window is swallowed forever. That is
    /// only tolerable while restarts are rare; when the caller restarts the
    /// poller because its watch set changed, the baseline belongs to the
    /// CALLER, not to the stream. Pass a store and a restart resumes from
    /// what the previous stream already knew: paths it has seen keep their
    /// signature (so a change during the gap is reported), paths it has not
    /// are seeded silently (so an added path is not a spurious delta).
    nonisolated func watchPaths(
        _ paths: [String], baseline: WatchBaselineStore?
    ) -> AsyncStream<WatchEvent>
}

/// Per-path signature memory shared between a watcher and the polling
/// streams it starts. Mutable across stream restarts on purpose — it is
/// the thing that must OUTLIVE them.
///
/// The signature is `mtime-seconds:size`, not mtime alone. One-second
/// mtime granularity is the resolution `stat` reports over SSH, so two
/// writes inside the same second are one signature; pairing size with it
/// catches the overwhelmingly common case of that pair (a file that grew
/// or shrank) at zero extra cost. It is not a hash and does not pretend
/// to be one — a same-second, same-size rewrite is still invisible until
/// the next poll that differs.
public final class WatchBaselineStore: @unchecked Sendable {
    private let lock = NSLock()
    private var signatures: [String: String] = [:]

    public init() {}

    /// Fold a fresh poll into the baseline.
    ///
    /// - Returns: `true` when a path we ALREADY had a signature for now has
    ///   a different one. A path seen for the first time is recorded and
    ///   reported as no change; paths absent from `fresh` are forgotten so
    ///   a shrinking watch set can't keep answering for paths nobody
    ///   watches.
    @discardableResult
    public func apply(_ fresh: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for (path, signature) in fresh {
            if let known = signatures[path], known != signature { changed = true }
        }
        signatures = fresh
        return changed
    }

    /// Test seam: the signature currently held for `path`, if any.
    public func signature(for path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return signatures[path]
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        signatures.removeAll()
    }
}

public extension ServerTransport {
    /// Default: one `stat` per path. Correct everywhere and cheap on a
    /// local filesystem; `SSHTransport` overrides it with a single shell
    /// command so the remote case is one round-trip instead of N.
    nonisolated func statAll(_ paths: [String]) -> [String: FileStat] {
        var result: [String: FileStat] = [:]
        for path in paths where result[path] == nil {
            if let info = stat(path) { result[path] = info }
        }
        return result
    }

    /// Default: ignore the baseline and use the stream's own. Correct for
    /// the local FSEvents transport (which has no baseline — it is
    /// event-driven, not polled) and for test fakes.
    nonisolated func watchPaths(
        _ paths: [String], baseline: WatchBaselineStore?
    ) -> AsyncStream<WatchEvent> {
        watchPaths(paths)
    }
}

public extension ServerTransport {
    /// Default: backup-class binary streaming isn't implemented for
    /// every transport (notably the iOS `CitadelServerTransport`,
    /// which doesn't expose a raw stdout pipe). Concrete Mac
    /// transports override this. The fallback yields a stream that
    /// throws on first iteration so callers fail fast rather than
    /// hanging silently.
    nonisolated func streamRawBytes(
        executable: String,
        args: [String]
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: TransportError.other(
                message: "streamRawBytes is not supported on this transport"
            ))
        }
    }

    #if !os(iOS)
    /// Default: ignore `cwd` and fall back to the 2-arg spawn. Concrete
    /// transports that can honor a working directory (Local, SSH) override
    /// this; test fakes + iOS inherit the no-op.
    nonisolated func makeProcess(executable: String, args: [String], cwd: String?) -> Process {
        makeProcess(executable: executable, args: args)
    }
    #endif
}

/// Stat-style file metadata. `nil` (return value) means the file does not
/// exist or couldn't be queried.
public struct FileStat: Sendable, Hashable {
    public let size: Int64
    public let mtime: Date
    public let isDirectory: Bool

    public init(
        size: Int64,
        mtime: Date,
        isDirectory: Bool
    ) {
        self.size = size
        self.mtime = mtime
        self.isDirectory = isDirectory
    }
}

/// Result of a one-shot process invocation.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data


    public init(
        exitCode: Int32,
        stdout: Data,
        stderr: Data
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
    public nonisolated var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
    public nonisolated var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}

public enum WatchEvent: Sendable {
    /// Any path in the watched set changed; implementations may coalesce
    /// rapid changes into one event. Consumers should treat this as "refresh
    /// whatever you were displaying" rather than expecting fine-grained
    /// per-path signals.
    case anyChanged
}
