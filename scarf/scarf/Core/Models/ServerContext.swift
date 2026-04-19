import Foundation
import SwiftUI
import AppKit

/// Stable identifier for a server entry in the user's registry. Backed by
/// `UUID` so it round-trips through `servers.json` and SwiftUI window-state
/// restoration without collisions.
typealias ServerID = UUID

/// Connection parameters for a remote Hermes installation reached over SSH.
/// All fields are optional except `host` — unset values defer to the user's
/// `~/.ssh/config` and the OpenSSH defaults.
struct SSHConfig: Sendable, Hashable, Codable {
    /// Hostname or `~/.ssh/config` alias.
    var host: String
    /// Remote username. `nil` → defer to `~/.ssh/config` or the local user.
    var user: String?
    /// TCP port. `nil` → 22 (or whatever `~/.ssh/config` says).
    var port: Int?
    /// Absolute path to a private key. `nil` → defer to ssh-agent /
    /// `~/.ssh/config` identity files.
    var identityFile: String?
    /// Override for the remote `$HOME/.hermes` directory. `nil` uses
    /// `HermesPathSet.defaultRemoteHome` (`~/.hermes`, shell-expanded on the
    /// remote side).
    var remoteHome: String?
    /// Resolved remote path to the `hermes` binary. Populated by
    /// `SSHTransport` after the first `command -v hermes` probe; cached here
    /// so subsequent calls skip the round trip.
    var hermesBinaryHint: String?
}

/// Distinguishes a local installation (the user's own `~/.hermes`) from a
/// remote one reached over SSH. Service behavior is identical in shape but
/// dispatches to different I/O primitives in Phase 2.
enum ServerKind: Sendable, Hashable, Codable {
    case local
    case ssh(SSHConfig)
}

/// The per-server value that flows through `.environment` and gets handed to
/// every service and ViewModel in Phase 1. One `ServerContext` corresponds to
/// one Hermes installation; multi-window scenes in Phase 3 will construct
/// one per window.
struct ServerContext: Sendable, Hashable, Identifiable {
    let id: ServerID
    var displayName: String
    var kind: ServerKind

    /// Path layout for this server. Cheap — all path components are computed
    /// on demand from `home`, no I/O.
    var paths: HermesPathSet {
        switch kind {
        case .local:
            return HermesPathSet(
                home: HermesPathSet.defaultLocalHome,
                isRemote: false,
                binaryHint: nil
            )
        case .ssh(let config):
            return HermesPathSet(
                home: config.remoteHome ?? HermesPathSet.defaultRemoteHome,
                isRemote: true,
                binaryHint: config.hermesBinaryHint
            )
        }
    }

    var isRemote: Bool {
        if case .ssh = kind { return true }
        return false
    }

    /// Construct the `ServerTransport` for this context. Local contexts get
    /// a `LocalTransport`; SSH contexts get an `SSHTransport` configured
    /// from `SSHConfig`. Each call returns a fresh value — transports are
    /// cheap and stateless beyond disk caches.
    func makeTransport() -> any ServerTransport {
        switch kind {
        case .local:
            return LocalTransport(contextID: id)
        case .ssh(let config):
            return SSHTransport(contextID: id, config: config, displayName: displayName)
        }
    }

    // MARK: - Well-known singletons

    /// Stable UUID for the built-in "this machine" entry. Hard-coded so the
    /// local context has the same identity across launches, and so persisted
    /// window-state restorations that reference it continue to resolve even
    /// if `servers.json` hasn't been touched yet.
    private static let localID = ServerID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The default "this machine" context. Used everywhere in Phase 0/1 and
    /// remains the fallback when no remote server is selected.
    static let local = ServerContext(
        id: localID,
        displayName: "Local",
        kind: .local
    )
}

// MARK: - Convenience file I/O via the right transport

/// Centralized file I/O entry points for VMs that don't own a service. Every
/// call goes through the context's transport, so reads/writes hit the local
/// disk for `.local` and ssh/scp for `.ssh` automatically.
///
/// **Always** prefer `context.readText(...)` over `String(contentsOfFile: ...)`
/// when the path comes from `context.paths`. The Foundation file APIs are
/// LOCAL ONLY — using them with a remote path silently returns nil because
/// the remote path doesn't exist on this Mac.
extension ServerContext {
    /// Read a UTF-8 text file. `nil` on any error (missing, transport down,
    /// invalid encoding).
    func readText(_ path: String) -> String? {
        guard let data = try? makeTransport().readFile(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Read raw bytes. `nil` on any error.
    func readData(_ path: String) -> Data? {
        try? makeTransport().readFile(path)
    }

    /// Atomic write. Returns `true` on success, `false` on any error
    /// (caller is expected to surface failures via UI when relevant).
    @discardableResult
    func writeText(_ path: String, content: String) -> Bool {
        guard let data = content.data(using: .utf8) else { return false }
        do {
            try makeTransport().writeFile(path, data: data)
            return true
        } catch {
            return false
        }
    }

    /// Existence check. Local: `FileManager`. Remote: `ssh test -e`.
    func fileExists(_ path: String) -> Bool {
        makeTransport().fileExists(path)
    }

    /// File modification timestamp, or `nil` if the file doesn't exist.
    func modificationDate(_ path: String) -> Date? {
        makeTransport().stat(path)?.mtime
    }

    /// Invoke the `hermes` CLI on this server and return its combined output
    /// + exit code. Local: spawns the local binary via `Process`. Remote:
    /// rounds through `ssh host hermes …`. Use this from any VM that needs
    /// to fire off a CLI command — never spawn `hermes` via `Process()`
    /// directly, because that path bypasses the transport for remote.
    @discardableResult
    func runHermes(_ args: [String], timeout: TimeInterval = 60, stdin: String? = nil) -> (output: String, exitCode: Int32) {
        let result = HermesFileService(context: self).runHermesCLI(args: args, timeout: timeout, stdinInput: stdin)
        return (result.output, result.exitCode)
    }

    /// Reveal the file at `path` in the user's local editor (via
    /// `NSWorkspace.open`). For remote contexts this is a no-op — the
    /// file doesn't exist on this Mac, so opening it would fail silently
    /// or worse, open the wrong file from the local filesystem.
    /// Returns `true` if opened, `false` if the call was skipped.
    @discardableResult
    func openInLocalEditor(_ path: String) -> Bool {
        guard !isRemote else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return true
    }
}

// MARK: - SwiftUI environment plumbing

/// `ServerContext` is a value type, so SwiftUI's `.environment(_:)` (which
/// requires an `@Observable` class) doesn't accept it directly. We expose it
/// through a custom `EnvironmentKey` — views read it with
/// `@Environment(\.serverContext) private var serverContext`.
private struct ServerContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: ServerContext = .local
}

extension EnvironmentValues {
    var serverContext: ServerContext {
        get { self[ServerContextEnvironmentKey.self] }
        set { self[ServerContextEnvironmentKey.self] = newValue }
    }
}
