import Foundation

/// Whether the connected Hermes is a **package-manager-managed install**, and
/// which package manager owns it.
///
/// ## Why Scarf has to know
///
/// A managed Hermes refuses every config mutation, and it refuses them the
/// worst possible way: `is_managed()` makes `set_config_value`
/// (`hermes_cli/config.py:3450-3452` @ v2026.9.7), `unset_config_value`
/// (`:3549-3551`) and `save_config` (`:2316-2318`) print to **stderr** and
/// bare-`return`, which Python turns into **exit 0**. Every verdict Scarf
/// shells now carries ``HermesCLIMarkers/managedRefusal`` so a refused write
/// is at least reported as one (round-4 decision 1, first half).
///
/// This type is the second half: a single read-only probe at connect time, so
/// the config-writing surfaces can render read-only behind one banner instead
/// of offering controls whose every click ends in the same refusal.
///
/// ## What it probes, and what it deliberately cannot see
///
/// `get_managed_system()` (`hermes_cli/config.py:276-290` @ v2026.9.7) reads
/// **two** signals:
///
/// 1. the `HERMES_MANAGED` environment variable, and
/// 2. a `.managed` marker file in `HERMES_HOME`.
///
/// Only (2) is visible to Scarf. The env var belongs to the systemd service
/// Hermes runs under, not to the shell Scarf's transport opens, so probing it
/// would be a guess — and a wrong "not managed" is exactly what the marker
/// half of the fix already covers. So: a host that is managed **only** by the
/// env var renders normally and its refusals are caught by the verdicts. A
/// host with the marker file renders read-only up front. Neither can report a
/// success over a write that did not happen.
///
/// Charter C3/C10: this is a read, off the main actor, through the same
/// transport every other Hermes-home read uses.
public struct HermesManagedInstall: Sendable, Equatable {
    /// The owning package manager, exactly as `get_managed_system` would
    /// return it — `"nixos"`, `"home-manager"`, or whatever else the marker
    /// file names. `nil` means "not managed, as far as the marker file shows".
    public let system: String?

    public init(system: String?) {
        self.system = system
    }

    /// The state of a host with no marker file. Also the value every caller
    /// starts from, so a surface renders writable until the probe says
    /// otherwise — never the reverse.
    public static let notManaged = HermesManagedInstall(system: nil)

    public var isManaged: Bool { system != nil }

    // MARK: - Parsing

    /// `_MANAGED_TRUE_VALUES` — `("true", "1", "yes")`, `hermes_cli/config.py:264`.
    static let trueValues: Set<String> = ["true", "1", "yes"]

    /// `_LEGACY_MANAGED_SYSTEM` — `"nixos"`, `:267`. "Only the NixOS module
    /// ever wrote a bare `true` or an empty marker."
    static let legacySystem = "nixos"

    /// `_IGNORED_MANAGED_VALUES` — `frozenset({"brew", "homebrew"})`, `:273`.
    /// "Homebrew is no longer a supported distribution: these markers fall
    /// through to git/unknown detection instead of blocking config writes."
    /// A Homebrew marker therefore means **not managed**, and mirroring that
    /// is the difference between a correct read-only banner and one that locks
    /// a `brew`-installed Hermes out of its own Settings.
    static let ignoredValues: Set<String> = ["brew", "homebrew"]

    /// Mirror of `get_managed_system`'s marker-file half
    /// (`hermes_cli/config.py:276-290` @ v2026.9.7), given the file's raw
    /// contents (`nil` when the file is absent or unreadable — Hermes treats
    /// an `OSError` as an empty marker, but only once it knows the file
    /// exists, which is the distinction ``probe(context:)`` preserves).
    ///
    /// Hermes lowercases and strips before every comparison, so this does too.
    /// - Parameter readsMarkerContents: ``HermesCapabilities/hasManagedMarkerContents``
    ///   — whether this host's `get_managed_system` reads the marker at all.
    ///   Below v0.20.5 it does NOT: the whole marker half of the function is
    ///   `if managed_marker.exists(): return "NixOS"`
    ///   (`hermes_cli/config.py:327-330` @ v2026.6.19, identical through
    ///   v2026.8.18), so a marker holding `brew` — or anything else — means
    ///   managed, and the system name is that tag's literal `"NixOS"`.
    ///   Reading the contents on such a host would leave a genuinely managed
    ///   install writable.
    public static func system(fromMarker raw: String?, readsMarkerContents: Bool) -> String? {
        guard let raw else { return nil }
        guard readsMarkerContents else { return preContentsSystem }
        let marker = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ignoredValues.contains(marker) { return nil }
        if marker.isEmpty || trueValues.contains(marker) { return legacySystem }
        return marker
    }

    /// What `get_managed_system` returns for ANY present marker below
    /// v0.20.5 — verbatim, capital-S: `return "NixOS"`
    /// (`hermes_cli/config.py:330` @ v2026.6.19). Not ``legacySystem``, which
    /// is the lowercased `_LEGACY_MANAGED_SYSTEM` of the v0.20.5+ form.
    static let preContentsSystem = "NixOS"
}

extension HermesPathSet {
    /// `$HERMES_HOME/.managed` — the NixOS activation script's marker,
    /// `get_hermes_home() / ".managed"` (`hermes_cli/config.py:281`).
    public nonisolated var managedMarker: String { home + "/.managed" }
}

/// Process-wide, per-home cache for the `.managed` probe.
///
/// Deliberately the small sibling of ``HermesVersionCache`` rather than a
/// second copy of it: the marker file is a single stat + read, there is no
/// version parsing to get wrong, and — unlike `hermes --version` — a probe
/// that cannot reach the host must be treated as **not managed**, because the
/// alternative is locking a reachable-but-slow host out of its own Settings on
/// a transport hiccup. A wrong "not managed" costs nothing: the verdicts
/// (``HermesCLIMarkers/managedRefusal``) still catch the refusal.
///
/// Thread-safety: one `NSLock` around one dictionary; the probe runs outside
/// the lock so a slow SSH round-trip to one host never blocks a read for
/// another (charter C10).
public final class HermesManagedInstallCache: @unchecked Sendable {
    public static let shared = HermesManagedInstallCache()

    /// Reads `$HERMES_HOME/.managed`. Returns `nil` when the file is absent,
    /// and `""` when it exists but its bytes could not be read — which is
    /// exactly what `get_managed_system` does with an `OSError` (`:285-286`).
    public typealias Probe = @Sendable (ServerContext) -> String?

    private let probe: Probe
    private let lock = NSLock()
    private var cached: [String: HermesManagedInstall] = [:]

    /// - Parameter timeout: the ceiling on one probe. Injectable only so a
    ///   test can prove the fall-open path in milliseconds instead of
    ///   ``probeTimeout`` seconds; production takes the default.
    public init(
        probe: @escaping Probe = HermesManagedInstallCache.transportProbe,
        timeout: TimeInterval = HermesManagedInstallCache.probeTimeout
    ) {
        self.probe = probe
        self.timeout = timeout
    }

    private let timeout: TimeInterval

    /// The connect-time read. Blocking — call it off the main actor.
    /// Memoized per Hermes home for the life of the process; call
    /// ``invalidate(for:)`` if the host is re-provisioned under Scarf.
    public func managedInstall(
        for context: ServerContext,
        capabilities: HermesCapabilities
    ) -> HermesManagedInstall {
        let key = Self.key(for: context)
        lock.lock()
        if let hit = cached[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let marker = probeWithinTimeout(context) else {
            // The probe did not answer inside ``probeTimeout``. NOT cached:
            // the next surface that asks gets a fresh attempt rather than a
            // process-lifetime "not managed" won by a slow SSH round-trip.
            return .notManaged
        }

        let result = HermesManagedInstall(system: HermesManagedInstall.system(
            fromMarker: marker,
            readsMarkerContents: capabilities.hasManagedMarkerContents
        ))

        lock.lock()
        cached[key] = result
        lock.unlock()
        return result
    }

    /// How long the connect-time probe may block before Scarf gives up and
    /// renders the pane writable.
    ///
    /// Named because the number is a product choice, not an implementation
    /// detail: it is the ceiling on how long Settings' detached load can sit
    /// on one `.managed` stat+read over SSH. A host that misses it is treated
    /// as not managed — the documented fail-open direction, since the
    /// verdicts (``HermesCLIMarkers/managedRefusalAnchored``) still catch
    /// every refusal, whereas a wrong read-only lock has no recovery.
    public static let probeTimeout: TimeInterval = 5

    /// Runs ``probe`` with a ``probeTimeout`` ceiling. The outer optional is
    /// "did it answer at all"; the inner is the probe's own `nil` for
    /// "no marker file".
    private func probeWithinTimeout(_ context: ServerContext) -> String??  {
        let box = ProbeBox()
        let semaphore = DispatchSemaphore(value: 0)
        let probe = self.probe
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(probe(context))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    /// One answer, one lock — the probe thread writes it and the caller reads
    /// it only after the semaphore, but the box outlives a timed-out probe
    /// that is still running, so the write needs the lock all the same.
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String??
        func set(_ value: String?) {
            lock.lock(); stored = .some(value); lock.unlock()
        }
        var value: String?? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    /// The last probed answer without probing. `.notManaged` until one lands,
    /// so a surface renders writable while the read is in flight rather than
    /// flashing a read-only banner it may have to take back.
    public func cached(for context: ServerContext) -> HermesManagedInstall {
        let key = Self.key(for: context)
        lock.lock()
        defer { lock.unlock() }
        return cached[key] ?? .notManaged
    }

    public func invalidate(for context: ServerContext) {
        let key = Self.key(for: context)
        lock.lock()
        cached.removeValue(forKey: key)
        lock.unlock()
    }

    public func invalidateAll() {
        lock.lock()
        cached.removeAll()
        lock.unlock()
    }

    /// The Hermes home is the whole identity here: the marker lives inside it,
    /// and two Scarf windows pointed at the same home are the same install.
    static func key(for context: ServerContext) -> String {
        (context.paths.isRemote ? "remote:" : "local:") + context.paths.home
    }

    /// The production probe. `readTextThrowing` distinguishes the two cases
    /// Hermes distinguishes: `nil` for genuinely absent, a throw for "the file
    /// is there and the bytes did not come back" — which Hermes reads as an
    /// empty marker, i.e. managed.
    /// ONE `fileExists` and at most one read, against ONE transport. The
    /// previous shape called `readTextThrowing` (itself a `fileExists` + a
    /// read) and then a second `fileExists` on the catch path — three
    /// round-trips on a remote host to answer a one-byte question.
    public static let transportProbe: Probe = { context in
        let path = context.paths.managedMarker
        let transport = context.makeTransport()
        guard transport.fileExists(path) else { return nil }
        do {
            let data = try transport.readFile(path)
            // `errors="replace"` on Hermes's side: undecodable bytes are not
            // an error there either.
            return String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        } catch {
            // Present but unreadable. `get_managed_system` catches the
            // `OSError` and treats the marker as EMPTY (`:285-286`), which
            // resolves to the legacy system — i.e. managed.
            return ""
        }
    }
}
