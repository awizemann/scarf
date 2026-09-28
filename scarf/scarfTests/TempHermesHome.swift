import Foundation
import ScarfCore

/// A disposable Hermes home under the system temp dir, paired with a
/// `ServerContext.local(home:)` that steers every ScarfCore service's file
/// I/O into it.
///
/// Replaces the old `SCARF_HERMES_HOME` env-redirect + global
/// `TestRegistryLock` pattern that app-target suites used to isolate their
/// `~/.hermes` writes. Because the home is per-instance and `.local(home:)`
/// resolves `paths.*` from `localHomeOverride` — bypassing
/// `HermesProfileResolver`/`HermesPathSet.defaultLocalHome` and the global
/// env entirely — suites that adopt this share NO mutable process state.
/// They need no cross-suite serialization, which removes the
/// `@MainActor`-blocking deadlock that the shared `NSLock` produced (see
/// the `testregistrylock-…-deadlocks-across-parallel-suites` memory note
/// and `scarfcore-tests-inject-a-temp-hermes-home-via-servercontext-local-home`).
///
/// Usage:
/// ```swift
/// let home = try TempHermesHome()
/// defer { home.cleanup() }
/// let vm = ProjectsViewModel(context: home.context)
/// ```
struct TempHermesHome {
    /// Root of the throwaway home (e.g. `/var/folders/…/scarf-test-home-<uuid>`).
    let url: URL

    /// A `.local`-kind context whose `paths.*` resolve under `url` instead
    /// of the developer's real `~/.hermes`. Keeps `id == ServerContext.local.id`
    /// so `vm.context.id == ServerContext.local.id` assertions still hold —
    /// only `paths.home` differs. Recomputed cheaply on each access.
    var context: ServerContext { .local(home: url) }

    /// The home directory as a plain path string, for building fixture
    /// paths by hand (e.g. `home.path + "/scarf/projects.json"`).
    var path: String { url.path }

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scarf-test-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Run `body` with `HERMES_HOME` pointing at this home in the process
    /// environment, restored afterwards.
    ///
    /// `.local(home:)` redirects Scarf's own FILE reads and writes only. A
    /// view model that spawns `hermes` still runs the developer's real binary,
    /// and without `HERMES_HOME` that binary reads their real `~/.hermes`
    /// (`get_default_hermes_root`, `hermes_constants.py:217-234` @
    /// `v2026.9.24`, anchors `-p <name>` to `HERMES_HOME` too when it lies
    /// outside `~/.hermes`). Use this around any such spawn, the way
    /// `BotConversationCLITransportE2ETests` pins its CLI. Prefer a scripted
    /// transport where the code under test takes one (see
    /// `KanbanDispatchConfirmP56Tests`).
    ///
    /// `HERMES_HOME` is process-wide and the body suspends, so pins are
    /// serialized through `ProcessHermesHomePinLock` across ALL suites: two
    /// interleaved pins would otherwise restore each other's value and let a
    /// spawn reach the real home. (An async lock, not an `NSLock`, which
    /// deadlocks `@MainActor` suites.)
    func pinningProcessHermesHome<T>(_ body: () async throws -> T) async rethrows -> T {
        await ProcessHermesHomePinLock.shared.acquire()
        let saved = ProcessInfo.processInfo.environment["HERMES_HOME"]
        setenv("HERMES_HOME", path, 1)
        func restore() async {
            if let saved { setenv("HERMES_HOME", saved, 1) } else { unsetenv("HERMES_HOME") }
            await ProcessHermesHomePinLock.shared.release()
        }
        do {
            let result = try await body()
            await restore()
            return result
        } catch {
            await restore()
            throw error
        }
    }

    /// Recursively remove the temp home. Safe in a `defer`; ignores the
    /// "already gone" case.
    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Serializes every test that sets the process-wide `HERMES_HOME`
/// (`TempHermesHome.pinningProcessHermesHome`,
/// `BotConversationCLITransportE2ETests`). FIFO; never blocks a thread.
actor ProcessHermesHomePinLock {
    static let shared = ProcessHermesHomePinLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
