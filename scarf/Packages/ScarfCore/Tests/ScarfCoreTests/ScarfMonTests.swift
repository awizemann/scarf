import Testing
import Foundation
@testable import ScarfCore

/// `.serialized` because every test that exercises the wrappers
/// (`measure`, `measureAsync`, `event`) installs and uninstalls the
/// process-wide backend set, and parallel tests would race on that
/// shared state. Tests of the ring buffer in isolation don't need
/// serialization, but the suite-level annotation is the simplest way
/// to keep the global-state ones honest.
@Suite(.serialized) struct ScarfMonTests {

    /// Ring-buffer ordering — fewer than capacity, no wrap.
    @Test func ringBufferKeepsOrderBeforeWrap() {
        let ring = ScarfMonRingBuffer(capacity: 8)
        ring.record(.fixture(name: "a"))
        ring.record(.fixture(name: "b"))
        ring.record(.fixture(name: "c"))
        let names = ring.samples().map { $0.name.description }
        #expect(names == ["a", "b", "c"])
    }

    /// Ring-buffer wrap-around — the oldest entries are dropped, the
    /// newest entries appear at the end.
    @Test func ringBufferWrapsCorrectly() {
        let ring = ScarfMonRingBuffer(capacity: 4)
        ring.record(.fixture(name: "a"))
        ring.record(.fixture(name: "b"))
        ring.record(.fixture(name: "c"))
        ring.record(.fixture(name: "d"))
        ring.record(.fixture(name: "e"))
        ring.record(.fixture(name: "f"))
        let names = ring.samples().map { $0.name.description }
        #expect(names == ["c", "d", "e", "f"])
    }

    /// Reset clears the buffer and resets wrap state — subsequent reads
    /// see only post-reset entries.
    @Test func ringBufferResetClearsState() {
        let ring = ScarfMonRingBuffer(capacity: 4)
        ring.record(.fixture(name: "a"))
        ring.record(.fixture(name: "b"))
        ring.record(.fixture(name: "c"))
        ring.record(.fixture(name: "d"))
        ring.record(.fixture(name: "e"))
        ring.reset()
        ring.record(.fixture(name: "x"))
        let names = ring.samples().map { $0.name.description }
        #expect(names == ["x"])
    }

    /// Summary aggregates per (category, name) and computes percentiles.
    @Test func summaryAggregatesByCategoryAndName() {
        let ring = ScarfMonRingBuffer(capacity: 16)
        // Three "fast" intervals + two "slow" intervals on the same key.
        for nanos: UInt64 in [1_000_000, 2_000_000, 3_000_000, 50_000_000, 100_000_000] {
            ring.record(.fixture(name: "render", durationNanos: nanos))
        }
        let stats = ring.summary()
        #expect(stats.count == 1)
        let s = stats[0]
        #expect(s.count == 5)
        #expect(s.totalNanos == 156_000_000)
        // Nearest-rank p95 with 5 samples picks the 5th sorted value
        // (rank = ceil(5 * 0.95) = 5).
        #expect(s.p95Nanos == 100_000_000)
        // p50 with 5 samples picks the 3rd sorted value.
        #expect(s.p50Nanos == 3_000_000)
    }

    /// Events accumulate count + bytes without contributing to interval
    /// percentiles.
    @Test func eventsAccumulateBytesNotDuration() {
        let ring = ScarfMonRingBuffer(capacity: 16)
        ring.record(ScarfMon.Sample(
            category: .chatStream, name: "token", kind: .event,
            timestamp: Date(), durationNanos: 0, count: 1, bytes: 256
        ))
        ring.record(ScarfMon.Sample(
            category: .chatStream, name: "token", kind: .event,
            timestamp: Date(), durationNanos: 0, count: 1, bytes: 128
        ))
        let stats = ring.summary()
        #expect(stats.count == 1)
        #expect(stats[0].count == 2)
        #expect(stats[0].totalBytes == 384)
        #expect(stats[0].p95Nanos == 0)
    }

    /// `isActive` flips off when the backend set is empty so the
    /// hot-path short-circuit kicks in.
    @Test func installEmptyBackendsDeactivates() {
        ScarfMon.install([])
        #expect(ScarfMon.isActive == false)
        ScarfMon.install([ScarfMonRingBuffer(capacity: 4)])
        #expect(ScarfMon.isActive == true)
        ScarfMon.install([])
    }

    /// `measure` records a duration into every installed backend.
    @Test func measureFlowsThroughInstalledBackends() throws {
        let ring = ScarfMonRingBuffer(capacity: 8)
        ScarfMon.install([ring])
        defer { ScarfMon.install([]) }

        let result: Int = ScarfMon.measure(.render, "unit") {
            return 42
        }
        #expect(result == 42)
        let samples = ring.samples()
        #expect(samples.count == 1)
        #expect(samples[0].kind == .interval)
        #expect(samples[0].name.description == "unit")
    }

    /// `measureAsync` records duration even when the body throws — the
    /// `defer` in the wrapper must fire on rethrow.
    @Test func measureAsyncRecordsDurationEvenOnThrow() async {
        struct Boom: Error {}
        let ring = ScarfMonRingBuffer(capacity: 8)
        ScarfMon.install([ring])
        defer { ScarfMon.install([]) }

        await #expect(throws: Boom.self) {
            try await ScarfMon.measureAsync(.chatStream, "throws") {
                throw Boom()
            }
        }
        let samples = ring.samples().filter { $0.name.description == "throws" }
        #expect(samples.count == 1)
        #expect(samples[0].name.description == "throws")
    }

    /// `event(...)` records a count entry without taking a clock reading.
    @Test func eventRecordsCountSample() {
        let ring = ScarfMonRingBuffer(capacity: 8)
        ScarfMon.install([ring])
        defer { ScarfMon.install([]) }

        ScarfMon.event(.chatStream, "token", count: 1, bytes: 32)
        let samples = ring.samples()
        #expect(samples.count == 1)
        #expect(samples[0].kind == .event)
        #expect(samples[0].count == 1)
        #expect(samples[0].bytes == 32)
        #expect(samples[0].durationNanos == 0)
    }

    /// Boot configure flips the active backend set without leaking
    /// across tests.
    @Test func bootConfigureModesInstallExpectedBackends() {
        defer { ScarfMon.install([]) }

        ScarfMonBoot.configure(mode: .off)
        #expect(ScarfMon.currentBackends.isEmpty)
        #expect(ScarfMonBoot.sharedRingBuffer == nil)

        ScarfMonBoot.configure(mode: .signpostOnly)
        #expect(ScarfMon.currentBackends.count == 1)
        #expect(ScarfMonBoot.sharedRingBuffer == nil)

        let ring = ScarfMonBoot.configure(mode: .full)
        #expect(ring != nil)
        #expect(ScarfMon.currentBackends.count == 3)
        #expect(ScarfMonBoot.sharedRingBuffer === ring)
    }

    /// JSON export round-trips through `JSONSerialization` — proves the
    /// per-line format is valid JSON the user can paste into a feedback
    /// tool.
    @Test func exportJSONIsParseable() throws {
        let ring = ScarfMonRingBuffer(capacity: 8)
        ring.record(.fixture(name: "a", durationNanos: 1_500_000))
        ring.record(ScarfMon.Sample(
            category: .chatStream, name: "token", kind: .event,
            timestamp: Date(), durationNanos: 0, count: 1, bytes: 64
        ))
        let json = ring.exportJSON()
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let arr = parsed as? [[String: Any]]
        #expect(arr?.count == 2)
    }
}

private extension ScarfMon.Sample {
    static func fixture(
        category: ScarfMon.Category = .render,
        name: StaticString,
        durationNanos: UInt64 = 1_000_000
    ) -> ScarfMon.Sample {
        ScarfMon.Sample(
            category: category,
            name: name,
            kind: .interval,
            timestamp: Date(),
            durationNanos: durationNanos,
            count: 1,
            bytes: nil
        )
    }
}
