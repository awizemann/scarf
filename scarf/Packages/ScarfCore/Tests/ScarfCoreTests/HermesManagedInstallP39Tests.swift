import Foundation
import Testing
@testable import ScarfCore

/// P39 / round-4 decision 1, second half — the connect-time probe of
/// `$HERMES_HOME/.managed` that renders Scarf's config-writing surfaces
/// read-only.
///
/// Every expectation here mirrors `get_managed_system`
/// (`hermes_cli/config.py:276-290` @ v2026.9.7) line for line, because a
/// mismatch in EITHER direction is a bug with teeth: reading "managed" off a
/// Homebrew marker locks a perfectly writable Hermes out of its own Settings,
/// and reading "not managed" off a real marker is the exit-0 silent-success
/// this whole phase exists to end.
@Suite("P39 — `.managed` marker probe")
struct HermesManagedInstallP39Tests {

    // MARK: - Marker parsing (`get_managed_system`, config.py:276-290)

    @Test func absentMarkerIsNotManaged() {
        #expect(HermesManagedInstall.system(fromMarker: nil, readsMarkerContents: true) == nil)
        #expect(HermesManagedInstall(system: HermesManagedInstall.system(fromMarker: nil, readsMarkerContents: true)).isManaged == false)
    }

    /// `if marker == "" or marker in _MANAGED_TRUE_VALUES: return
    /// _LEGACY_MANAGED_SYSTEM` (`:288-289`). "Only the NixOS module ever wrote
    /// a bare `true` or an empty marker" (`:266`).
    @Test(arguments: ["", "   ", "true", "TRUE", "1", "yes", "\n"])
    func emptyOrTrueMarkerIsTheLegacyNixosSystem(_ raw: String) {
        #expect(HermesManagedInstall.system(fromMarker: raw, readsMarkerContents: true) == "nixos")
    }

    /// `_IGNORED_MANAGED_VALUES = frozenset({"brew", "homebrew"})` (`:273`):
    /// "Homebrew is no longer a supported distribution: these markers fall
    /// through to git/unknown detection instead of blocking config writes."
    @Test(arguments: ["brew", "homebrew", "Homebrew", " BREW "])
    func homebrewMarkersMeanNotManaged(_ raw: String) {
        #expect(HermesManagedInstall.system(fromMarker: raw, readsMarkerContents: true) == nil)
    }

    /// Anything else is returned verbatim, lowercased and stripped (`:290`).
    @Test func anyOtherMarkerNamesThePackageManager() {
        #expect(HermesManagedInstall.system(fromMarker: "home-manager\n", readsMarkerContents: true) == "home-manager")
        #expect(HermesManagedInstall.system(fromMarker: "NixOS", readsMarkerContents: true) == "nixos")
        #expect(HermesManagedInstall.system(fromMarker: " guix ", readsMarkerContents: true) == "guix")
    }

    // MARK: - The cache

    @Test func theCacheProbesOncePerHomeAndMemoizes() {
        let counter = Counter()
        let cache = HermesManagedInstallCache(probe: { _ in
            counter.bump()
            return "nixos"
        })
        let ctx = Self.host(home: "/tmp/p39-home")

        let first = cache.managedInstall(for: ctx, capabilities: Self.modern)
        let second = cache.managedInstall(for: ctx, capabilities: Self.modern)

        #expect(first.system == "nixos")
        #expect(second == first)
        #expect(counter.value == 1)
    }

    /// A surface must render WRITABLE while the probe is in flight — the
    /// alternative is a read-only banner that flashes and is taken back.
    @Test func cachedIsNotManagedUntilAProbeLands() {
        let cache = HermesManagedInstallCache(probe: { _ in "nixos" })
        let ctx = Self.host(home: "/tmp/p39-home")

        #expect(cache.cached(for: ctx, capabilities: Self.modern).isManaged == false)
        _ = cache.managedInstall(for: ctx, capabilities: Self.modern)
        #expect(cache.cached(for: ctx, capabilities: Self.modern).isManaged)

        cache.invalidate(for: ctx)
        #expect(cache.cached(for: ctx, capabilities: Self.modern).isManaged == false)
    }

    @Test func aHostWithNoMarkerStaysWritable() {
        let cache = HermesManagedInstallCache(probe: { _ in nil })
        #expect(cache.managedInstall(for: Self.host(home: "/tmp/p39-home"), capabilities: Self.modern).isManaged == false)
    }

    /// The marker path is the one `get_managed_system` builds:
    /// `get_hermes_home() / ".managed"` (`:281`).
    @Test func theMarkerPathIsHomeDotManaged() {
        let paths = HermesPathSet(home: "/Users/a/.hermes", isRemote: false, binaryHint: nil)
        #expect(paths.managedMarker == "/Users/a/.hermes/.managed")
    }

    /// A v0.20.5+ host — the tag from which `get_managed_system` reads the
    /// marker's contents at all. See ``HermesCapabilities/hasManagedMarkerContents``.
    static let modern = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    static func host(home: String) -> ServerContext {
        ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: home))
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}