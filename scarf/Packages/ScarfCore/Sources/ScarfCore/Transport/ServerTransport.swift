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

    // MARK: - SQLite

    /// Return a local filesystem URL pointing at a fresh, consistent copy of
    /// the SQLite database at `remotePath`. For local transports this is
    /// just the remote path unchanged. For SSH transports this performs
    /// `sqlite3 .backup` on the remote side and scp's the backup into
    /// `~/Library/Caches/scarf/<serverID>/state.db`, returning that URL.
    nonisolated func snapshotSQLite(remotePath: String) throws -> URL

    // MARK: - Watching

    /// Observe changes to a set of paths and yield events when any of them
    /// change. Local: FSEvents. Remote: polls `stat` mtime every 3s.
    nonisolated func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent>
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
