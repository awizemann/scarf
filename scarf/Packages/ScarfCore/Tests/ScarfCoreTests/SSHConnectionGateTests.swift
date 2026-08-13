import Testing
import Foundation
@testable import ScarfCore

/// Unit tests for the gh#138 per-host SSH circuit breaker. All time is
/// injected via `now:` so the backoff schedule is tested deterministically.
@Suite struct SSHConnectionGateTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let key = SSHConnectionGate.key(host: "example.com", port: nil)

    private func makeGate() -> SSHConnectionGate {
        SSHConnectionGate(failureThreshold: 3, baseDelay: 30, maxDelay: 300)
    }

    @Test func keyIncludesPortWithDefault() {
        #expect(SSHConnectionGate.key(host: "h", port: nil) == "h:22")
        #expect(SSHConnectionGate.key(host: "h", port: 2222) == "h:2222")
    }

    @Test func closedGateAdmitsEveryone() {
        let gate = makeGate()
        #expect(gate.admit(key, now: t0) == .allowed)
        gate.recordFailure(key, now: t0)
        gate.recordFailure(key, now: t0)
        // Two failures — still under threshold, still admitting.
        #expect(gate.admit(key, now: t0) == .allowed)
        #expect(!gate.isOpen(key, now: t0))
    }

    @Test func opensAtThresholdAndBlocks() {
        let gate = makeGate()
        for _ in 0..<3 { gate.recordFailure(key, now: t0) }
        #expect(gate.isOpen(key, now: t0))
        #expect(gate.admit(key, now: t0) == .blocked(retryAt: t0.addingTimeInterval(30)))
    }

    @Test func admitsSingleProbeAfterDelayAndBlocksConcurrents() {
        let gate = makeGate()
        for _ in 0..<3 { gate.recordFailure(key, now: t0) }
        let afterDelay = t0.addingTimeInterval(31)
        // First caller after the delay is the probe…
        #expect(gate.admit(key, now: afterDelay) == .allowed)
        // …and claiming the slot re-blocks everyone else immediately.
        #expect(gate.admit(key, now: afterDelay) == .blocked(retryAt: afterDelay.addingTimeInterval(30)))
    }

    @Test func failedProbeDoublesDelayUpToCap() {
        let gate = makeGate()
        for _ in 0..<3 { gate.recordFailure(key, now: t0) }
        var now = t0
        var expectedDelay: TimeInterval = 30
        // Walk the schedule: 30 → 60 → 120 → 240 → 300 (cap) → 300…
        for _ in 0..<6 {
            now = now.addingTimeInterval(expectedDelay + 1)
            #expect(gate.admit(key, now: now) == .allowed) // probe slot
            gate.recordFailure(key, now: now)              // probe failed
            expectedDelay = min(expectedDelay * 2, 300)
            #expect(gate.admit(key, now: now) == .blocked(retryAt: now.addingTimeInterval(expectedDelay)))
        }
        // Delay is pinned at the cap.
        #expect(gate.admit(key, now: now) == .blocked(retryAt: now.addingTimeInterval(300)))
    }

    @Test func successFullyClosesGate() {
        let gate = makeGate()
        for _ in 0..<3 { gate.recordFailure(key, now: t0) }
        let probeTime = t0.addingTimeInterval(31)
        #expect(gate.admit(key, now: probeTime) == .allowed)
        gate.recordSuccess(key)
        #expect(!gate.isOpen(key, now: probeTime))
        #expect(gate.admit(key, now: probeTime) == .allowed)
        // History is wiped: it takes a full threshold of NEW failures to
        // re-open, and the backoff restarts at base.
        gate.recordFailure(key, now: probeTime)
        gate.recordFailure(key, now: probeTime)
        #expect(gate.admit(key, now: probeTime) == .allowed)
        gate.recordFailure(key, now: probeTime)
        #expect(gate.admit(key, now: probeTime) == .blocked(retryAt: probeTime.addingTimeInterval(30)))
    }

    @Test func successBelowThresholdResetsCounter() {
        let gate = makeGate()
        gate.recordFailure(key, now: t0)
        gate.recordFailure(key, now: t0)
        gate.recordSuccess(key)
        gate.recordFailure(key, now: t0)
        gate.recordFailure(key, now: t0)
        // 2 (reset) + 2 = never reached 3 consecutively → still closed.
        #expect(gate.admit(key, now: t0) == .allowed)
    }

    @Test func resetClearsOpenGate() {
        let gate = makeGate()
        for _ in 0..<3 { gate.recordFailure(key, now: t0) }
        #expect(gate.isOpen(key, now: t0))
        gate.reset(key)
        #expect(!gate.isOpen(key, now: t0))
        #expect(gate.admit(key, now: t0) == .allowed)
    }

    @Test func hostsAreIndependent() {
        let gate = makeGate()
        let other = SSHConnectionGate.key(host: "other.com", port: nil)
        for _ in 0..<3 { gate.recordFailure(key, now: t0) }
        #expect(gate.isOpen(key, now: t0))
        #expect(gate.admit(other, now: t0) == .allowed)
        #expect(!gate.isOpen(other, now: t0))
    }
}
