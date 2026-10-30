import Foundation
#if canImport(os)
import os
import os.signpost
#endif

/// Lightweight performance instrumentation for the Scarf app family.
///
/// Three primitives — `measure(...)`, `measureAsync(...)`, `event(...)` — drop
/// timing samples through whatever set of backends is currently active.
/// Backends are pluggable: an always-on `os_signpost` backend (free outside
/// Instruments), an in-memory ring buffer (drives the in-app panel), and an
/// `os.Logger` debug backend (off by default).
///
/// **Cost when off.** When no backends are registered, every entry point is
/// `@inline(__always)` and short-circuits to the body call without taking the
/// `ContinuousClock.now` reading. Open source build defaults to "signpost
/// only" — that backend pays one signpost emit per call, which Apple's runtime
/// elides when no Instruments session is recording.
///
/// **Privacy.** Names are `StaticString` so we cannot accidentally pass user
/// content through a metric tag. Optional `bytes:` field on `event` tracks
/// payload size, never payload contents. The ring buffer never leaves the
/// device unless the user explicitly hits "Copy as JSON" in the Diagnostics
/// panel.
public enum ScarfMon {

    // MARK: - Public API

    /// Synchronous timing wrapper. The body's return value flows through
    /// untouched; the time it took plus `(category, name)` are recorded.
    @inline(__always)
    public static func measure<T>(
        _ category: Category,
        _ name: StaticString,
        _ body: () throws -> T
    ) rethrows -> T {
        guard isActive else { return try body() }
        let start = ContinuousClock.now
        defer { record(category, name, start: start, end: ContinuousClock.now) }
        return try body()
    }

    /// Async variant. Same shape — the `defer` block fires after the body
    /// returns whether or not it threw, so cancelled / failed work still
    /// records its duration.
    ///
    /// Runs on the CALLER's isolation (`isolation`, defaulted to
    /// `#isolation`), so wrapping a call in it never adds an executor hop.
    /// As a plain nonisolated async func (Swift 5 mode) every call from the
    /// main actor hopped to the global executor first; two prompts sent
    /// back to back each took that hop, and the hops raced to `ACPClient`
    /// — the second prompt could get the lower JSON-RPC id.
    @inline(__always)
    public static func measureAsync<T>(
        _ category: Category,
        _ name: StaticString,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard isActive else { return try await body() }
        let start = ContinuousClock.now
        defer { record(category, name, start: start, end: ContinuousClock.now) }
        return try await body()
    }

    /// Single-shot timestamped event. Use for things that aren't intervals
    /// (token arrivals, buffer flushes) where count + optional payload size
    /// is the useful signal.
    @inline(__always)
    public static func event(
        _ category: Category,
        _ name: StaticString,
        count: Int = 1,
        bytes: Int? = nil
    ) {
        guard isActive else { return }
        recordEvent(category, name, count: count, bytes: bytes)
    }

    // MARK: - Backend management

    /// Install the desired backend set. Replaces the current set atomically.
    /// Call once at app boot from the launch sequence; safe to call again
    /// when the user toggles a setting on or off.
    public static func install(_ backends: [ScarfMonBackend]) {
        lock.lock()
        defer { lock.unlock() }
        installed = backends
        cachedActive = !backends.isEmpty
    }

    /// Currently-installed backends. Test-only — callers should not iterate
    /// this in production.
    public static var currentBackends: [ScarfMonBackend] {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    /// Cheap "are we recording anything?" check. The flag is updated only
    /// when `install(...)` runs, so the hot path doesn't take the lock.
    @inline(__always)
    public static var isActive: Bool { cachedActive }

    // MARK: - Internals

    private static let lock = ScarfMonLock()
    nonisolated(unsafe) private static var installed: [ScarfMonBackend] = []
    nonisolated(unsafe) private static var cachedActive: Bool = false

    @inline(__always)
    private static func record(
        _ category: Category,
        _ name: StaticString,
        start: ContinuousClock.Instant,
        end: ContinuousClock.Instant
    ) {
        let duration = end - start
        let nanos = nanoseconds(of: duration)
        let backends = snapshotBackends()
        let sample = Sample(
            category: category,
            name: name,
            kind: .interval,
            timestamp: Date(),
            durationNanos: nanos,
            count: 1,
            bytes: nil
        )
        for backend in backends {
            backend.record(sample)
        }
    }

    @inline(__always)
    private static func recordEvent(
        _ category: Category,
        _ name: StaticString,
        count: Int,
        bytes: Int?
    ) {
        let backends = snapshotBackends()
        let sample = Sample(
            category: category,
            name: name,
            kind: .event,
            timestamp: Date(),
            durationNanos: 0,
            count: count,
            bytes: bytes
        )
        for backend in backends {
            backend.record(sample)
        }
    }

    private static func snapshotBackends() -> [ScarfMonBackend] {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    private static func nanoseconds(of duration: Duration) -> UInt64 {
        // Duration is (seconds: Int64, attoseconds: Int64). Avoid Double
        // for the seconds term to keep precision on long intervals.
        let comps = duration.components
        let secondsAsNanos = UInt64(max(0, comps.seconds)) &* 1_000_000_000
        let attoAsNanos = UInt64(max(0, comps.attoseconds) / 1_000_000_000)
        return secondsAsNanos &+ attoAsNanos
    }
}

// MARK: - Categories

extension ScarfMon {
    /// Stable category vocabulary. Add cases here when new subsystems get
    /// instrumented; renames are breaking changes for any saved JSON dumps
    /// users have shared, so prefer adding over renaming.
    public enum Category: String, CaseIterable, Sendable, Codable {
        case chatRender
        case chatStream
        case sessionLoad
        case transport
        case sqlite
        case diskIO
        case render
        case other
    }
}

// MARK: - Sample

/// One recorded sample. All fields are value types so the struct is trivially
/// `Sendable` across backend queues without locks.
public struct ScarfMonSample: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case interval
        case event
    }
    public let category: ScarfMon.Category
    /// Static name string captured at the call site. Not a `String` — keeping
    /// it `StaticString` proves at compile time that names cannot leak user
    /// data through this channel.
    public let name: StaticString
    public let kind: Kind
    public let timestamp: Date
    public let durationNanos: UInt64
    public let count: Int
    public let bytes: Int?

    public init(
        category: ScarfMon.Category,
        name: StaticString,
        kind: Kind,
        timestamp: Date,
        durationNanos: UInt64,
        count: Int,
        bytes: Int?
    ) {
        self.category = category
        self.name = name
        self.kind = kind
        self.timestamp = timestamp
        self.durationNanos = durationNanos
        self.count = count
        self.bytes = bytes
    }

    /// `StaticString` does not conform to `Hashable` natively (it doesn't
    /// promise a stable hash). We hash via its UTF-8 representation so two
    /// samples with the same source-literal name compare equal.
    public static func == (lhs: ScarfMonSample, rhs: ScarfMonSample) -> Bool {
        lhs.category == rhs.category
            && lhs.kind == rhs.kind
            && lhs.timestamp == rhs.timestamp
            && lhs.durationNanos == rhs.durationNanos
            && lhs.count == rhs.count
            && lhs.bytes == rhs.bytes
            && lhs.name.description == rhs.name.description
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(category)
        hasher.combine(kind)
        hasher.combine(timestamp)
        hasher.combine(durationNanos)
        hasher.combine(count)
        hasher.combine(bytes)
        hasher.combine(name.description)
    }
}

extension ScarfMon {
    public typealias Sample = ScarfMonSample
}

// MARK: - Backend protocol

/// One sink for samples. Implementations must be cheap on the hot path —
/// callers hold no lock while invoking `record`, but the hot path runs from
/// every instrumented site, so allocations and disk I/O are off-limits here.
public protocol ScarfMonBackend: Sendable {
    func record(_ sample: ScarfMon.Sample)
}

// MARK: - Lock

/// Tiny `os_unfair_lock` wrapper. CLAUDE.md says "Use os_unfair_lock (not
/// NSLock) for simple boolean flags accessed from multiple threads."
@usableFromInline
final class ScarfMonLock: @unchecked Sendable {
    private let _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = .allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }
    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }
    @usableFromInline func lock()   { os_unfair_lock_lock(_lock) }
    @usableFromInline func unlock() { os_unfair_lock_unlock(_lock) }
}
