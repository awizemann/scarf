import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Stable identifier for a server entry in the user's registry. Backed by
/// `UUID` so it round-trips through `servers.json` and SwiftUI window-state
/// restoration without collisions.
public typealias ServerID = UUID

/// Connection parameters for a remote Hermes installation reached over SSH.
/// All fields are optional except `host` — unset values defer to the user's
/// `~/.ssh/config` and the OpenSSH defaults.
public struct SSHConfig: Sendable, Hashable, Codable {
    /// Hostname or `~/.ssh/config` alias.
    public var host: String
    /// Remote username. `nil` → defer to `~/.ssh/config` or the local user.
    public var user: String?
    /// TCP port. `nil` → 22 (or whatever `~/.ssh/config` says).
    public var port: Int?
    /// Absolute path to a private key. `nil` → defer to ssh-agent /
    /// `~/.ssh/config` identity files.
    public var identityFile: String?
    /// Override for the remote `$HOME/.hermes` directory. `nil` uses
    /// `HermesPathSet.defaultRemoteHome` (`~/.hermes`, shell-expanded on the
    /// remote side).
    public var remoteHome: String?
    /// Resolved remote path to the `hermes` binary. Populated by
    /// `SSHTransport` after the first `command -v hermes` probe; cached here
    /// so subsequent calls skip the round trip.
    public var hermesBinaryHint: String?

    public init(
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        remoteHome: String? = nil,
        hermesBinaryHint: String? = nil
    ) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remoteHome = remoteHome
        self.hermesBinaryHint = hermesBinaryHint
    }
}

/// Distinguishes a local installation (the user's own `~/.hermes`) from a
/// remote one reached over SSH. Service behavior is identical in shape but
/// dispatches to different I/O primitives in Phase 2.
public enum ServerKind: Sendable, Hashable, Codable {
    case local
    case ssh(SSHConfig)
}

/// The per-server value that flows through `.environment` and gets handed to
/// every service and ViewModel. One `ServerContext` corresponds to one
/// Hermes installation; multi-window scenes construct one per window.
///
/// **Why every member is `nonisolated`.** Sibling extension methods in the
/// Mac app target (`ServerContext+Mac.swift`) touch `AppKit`
/// (`NSWorkspace.shared.open` in `openInLocalEditor`), which under Swift 6's
/// default-isolation rules pulls the whole struct to `@MainActor`.
/// `ServerContext` is a plain `Sendable` value — accessing `.local`, `.paths`,
/// `.isRemote`, or `makeTransport()` from a background actor must not trap
/// the caller into hopping MainActor. `nonisolated` on each member keeps
/// them callable from any context.
public struct ServerContext: Sendable, Hashable, Identifiable {
    public let id: ServerID
    public var displayName: String
    public var kind: ServerKind

    public init(
        id: ServerID,
        displayName: String,
        kind: ServerKind
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }

    /// Path layout for this server. Cheap — all path components are computed
    /// on demand from `home`, no I/O.
    public nonisolated var paths: HermesPathSet {
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

    public nonisolated var isRemote: Bool {
        if case .ssh = kind { return true }
        return false
    }

    /// Construct the `ServerTransport` for this context. Local contexts get
    /// a `LocalTransport`; SSH contexts get an `SSHTransport` configured
    /// from `SSHConfig` by default, OR whatever `sshTransportFactory`
    /// returns if the host app has wired one. Each call returns a fresh
    /// value — transports are cheap and stateless beyond disk caches.
    ///
    /// **Cross-platform wiring.** On the Mac app the default
    /// `SSHTransport` (fork + exec `/usr/bin/ssh`) is the right thing,
    /// so `sshTransportFactory` stays `nil`. On iOS the Mac SSH binary
    /// doesn't exist, so `scarf-ios` wires this factory at launch to
    /// produce a Citadel-backed `ServerTransport`. All downstream
    /// services (`HermesDataService`, `HermesLogService`,
    /// `ProjectDashboardService`, …) then work on iOS unchanged.
    public nonisolated func makeTransport() -> any ServerTransport {
        switch kind {
        case .local:
            return LocalTransport(contextID: id)
        case .ssh(let config):
            if let factory = ServerContext.sshTransportFactory {
                return factory(id, config, displayName)
            }
            return SSHTransport(contextID: id, config: config, displayName: displayName)
        }
    }

    /// Override for `.ssh` transports. The iOS app sets this at launch to
    /// `{ id, cfg, name in CitadelServerTransport(contextID: id, config: cfg, displayName: name) }`
    /// so every `ServerContext.makeTransport()` call on a Citadel-backed
    /// iOS app returns the Citadel impl instead of the Mac/Linux
    /// `SSHTransport`. Mac leaves this `nil`.
    ///
    /// Set once, before any `makeTransport()` call is made. The
    /// `nonisolated(unsafe)` annotation mirrors the same pattern
    /// `SSHTransport.environmentEnricher` uses — single-write at app
    /// startup, many-read afterwards.
    ///
    /// **Test usage.** Production sets this once at launch. Tests that need
    /// to inject a fake transport must run inside `M5FeatureVMTests` (the
    /// canonical `.serialized` suite that owns this static) — running
    /// factory-touching tests across multiple parallel suites races on this
    /// var. `@TaskLocal` would scope cleanly, but the production hot paths
    /// dispatch DB/SFTP reads through `Task.detached` which severs
    /// TaskLocal inheritance, so the static-write pattern is the only one
    /// that survives the call stack.
    public typealias SSHTransportFactory = @Sendable (
        _ id: ServerID,
        _ config: SSHConfig,
        _ displayName: String
    ) -> any ServerTransport

    nonisolated(unsafe) public static var sshTransportFactory: SSHTransportFactory?

    // MARK: - Well-known singletons

    /// Stable UUID for the built-in "this machine" entry. Hard-coded so the
    /// local context has the same identity across launches, and so persisted
    /// window-state restorations that reference it continue to resolve even
    /// if `servers.json` hasn't been touched yet.
    nonisolated private static let localID = ServerID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The default "this machine" context. Used everywhere in Phase 0/1 and
    /// remains the fallback when no remote server is selected.
    public nonisolated static let local = ServerContext(
        id: localID,
        displayName: "Local",
        kind: .local
    )
}

// MARK: - Remote user-home resolution

/// Process-wide cache of each server's resolved user `$HOME`. Probed once per
/// `ServerID` via the transport, then memoized for the app's lifetime — home
/// directories don't change under us, and the probe is a ~5ms SSH round-trip
/// with ControlMaster. Used by anything that needs to hand a working
/// directory to the ACP agent or the Hermes CLI on the correct host.
private actor UserHomeCache {
    static let shared = UserHomeCache()
    private var cache: [ServerID: String] = [:]

    func resolve(for context: ServerContext) async -> String {
        if let cached = cache[context.id] { return cached }
        let resolved = await probe(context: context)
        cache[context.id] = resolved
        return resolved
    }

    func invalidate(contextID: ServerID) {
        cache.removeValue(forKey: contextID)
    }

    private func probe(context: ServerContext) async -> String {
        if !context.isRemote { return NSHomeDirectory() }
        let transport = context.makeTransport()
        let result = try? transport.runProcess(
            executable: "/bin/sh",
            args: ["-c", "echo $HOME"],
            stdin: nil,
            timeout: 10
        )
        let out = result?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Fall back to `~` (unexpanded) so ACP at least gets a plausible cwd
        // rather than a local Mac path. The remote side will expand it if
        // passed through a shell; if not, failures are surfaced by ACP itself.
        return out.isEmpty ? "~" : out
    }
}

extension ServerContext {
    /// Resolved absolute path to the user's home directory on the target host.
    /// Local: `NSHomeDirectory()`. Remote: probed `$HOME` over SSH, cached.
    /// Use this — not `NSHomeDirectory()` — whenever you're passing a `cwd`
    /// or user path to a process that runs on the target host.
    public func resolvedUserHome() async -> String {
        await UserHomeCache.shared.resolve(for: self)
    }

    /// Called when a server is removed from the registry, so the process-wide
    /// caches keyed by `ServerID` don't hold stale entries forever.
    public static func invalidateCaches(for contextID: ServerID) async {
        await UserHomeCache.shared.invalidate(contextID: contextID)
    }

    /// Static convenience for callers that have the ServerID but not
    /// a full ServerContext (e.g. RootModel.softDisconnect). Mirrors
    /// the instance method above.
    public static func invalidateCachedHome(forServerID id: ServerID) async {
        await UserHomeCache.shared.invalidate(contextID: id)
    }
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
    /// invalid encoding). Use this when the caller genuinely can't tell
    /// the difference (e.g. "if a manifest exists, parse it, otherwise
    /// use defaults"). Prefer `readTextThrowing` when the UI needs to
    /// distinguish "file doesn't exist" from "transport failed" — pass-1
    /// M7 #8 showed that silent nils from transport errors masqueraded
    /// as empty files in the Memory editor for ~1 minute before the
    /// SFTP-tilde fix was found.
    public nonisolated func readText(_ path: String) -> String? {
        try? readTextThrowing(path)
    }

    /// Read a UTF-8 text file. Throws on transport errors. Returns:
    /// - `.some(content)` when the file was read successfully,
    /// - `.none` when the file is genuinely absent (the transport's
    ///   `fileExists` returned false),
    /// - throws the underlying transport error otherwise.
    ///
    /// This is the version to call from VMs that can surface a real
    /// error to the UI — e.g. Memory, Settings, Cron. The nil-returning
    /// shim above is fine for "probably there, probably not" cases.
    public nonisolated func readTextThrowing(_ path: String) throws -> String? {
        let transport = makeTransport()
        guard transport.fileExists(path) else { return nil }
        let data = try transport.readFile(path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransportError.other(message: "File at \(path) is not valid UTF-8.")
        }
        return text
    }

    /// Read raw bytes. `nil` on any error.
    public nonisolated func readData(_ path: String) -> Data? {
        try? makeTransport().readFile(path)
    }

    /// Atomic write. Returns `true` on success, `false` on any error
    /// (caller is expected to surface failures via UI when relevant).
    @discardableResult
    public nonisolated func writeText(_ path: String, content: String) -> Bool {
        guard let data = content.data(using: .utf8) else { return false }
        do {
            try makeTransport().writeFile(path, data: data)
            return true
        } catch {
            return false
        }
    }

    /// Existence check. Local: `FileManager`. Remote: `ssh test -e`.
    public nonisolated func fileExists(_ path: String) -> Bool {
        makeTransport().fileExists(path)
    }

    /// File modification timestamp, or `nil` if the file doesn't exist.
    public nonisolated func modificationDate(_ path: String) -> Date? {
        makeTransport().stat(path)?.mtime
    }
}

// MARK: - SwiftUI environment plumbing

/// `ServerContext` is a value type, so SwiftUI's `.environment(_:)` (which
/// requires an `@Observable` class) doesn't accept it directly. We expose it
/// through a custom `EnvironmentKey` — views read it with
/// `@Environment(\.serverContext) private var serverContext`.
///
/// Guarded on `canImport(SwiftUI)` so ScarfCore still compiles on Linux
/// (swift-corelibs-foundation has no SwiftUI). Apple platforms — the real
/// runtime targets — compile the SwiftUI plumbing unchanged.
#if canImport(SwiftUI)
private struct ServerContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: ServerContext = .local
}

extension EnvironmentValues {
    public var serverContext: ServerContext {
        get { self[ServerContextEnvironmentKey.self] }
        set { self[ServerContextEnvironmentKey.self] = newValue }
    }
}
#endif
