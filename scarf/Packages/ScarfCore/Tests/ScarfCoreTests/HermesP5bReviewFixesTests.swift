import Foundation
import Testing
@testable import ScarfCore

/// P5b (Hermes v0.21.4 / v0.21.5 parity) — the ScarfCore halves of the
/// fresh-eyes review fixes. Each test fails if its fix is reverted.
@Suite struct HermesP5bReviewFixesTests {
    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    // MARK: - (1) peer dm process timeout

    /// `DM_TIMEOUT_S = 600` starts only after up to two `LIST_TIMEOUT_S = 30`
    /// requests (`peer.py:28-29`, `:111`, `:123-125`, `:348-351` @ v2026.9.21).
    @Test func dmTimeoutCoversTheCLIsWholeWorstCase() {
        #expect(HermesPeerCLI.dmProcessTimeout(capabilities: Self.v0214) >= 600 + 2 * 30 + 30)
        #expect(HermesPeerCLI.dmProcessTimeout(capabilities: Self.v0215) >= 600 + 2 * 30 + 30)
        // C1.
        #expect(HermesPeerCLI.dmProcessTimeout(capabilities: Self.v0213) == 600)
        #expect(HermesPeerCLI.dmProcessTimeout(capabilities: .empty) == 600)
    }

    /// The exact stderr `runHermesCLISplit` produces for a transport timeout.
    @Test func localTimeoutIsRecognisedOnlyByTheTransportsOwnSentence() {
        let cap: TimeInterval = 720
        let transport = TransportError.timeout(seconds: cap, partialStdout: Data()).errorDescription ?? ""
        #expect(transport == "Command timed out after 720s.")
        #expect(HermesPeerCLI.isLocalDMTimeout(exitCode: -1, stderr: transport, timeout: cap))
        // Another cap's sentence, a different -1, and every CLI exit are not it.
        #expect(!HermesPeerCLI.isLocalDMTimeout(exitCode: -1, stderr: "Command timed out after 600s.", timeout: cap))
        #expect(!HermesPeerCLI.isLocalDMTimeout(exitCode: -1, stderr: "hermes binary not found", timeout: cap))
        #expect(!HermesPeerCLI.isLocalDMTimeout(exitCode: 1, stderr: transport, timeout: cap))
        let stillRunning = "Peer 'spark' accepted the message but its turn is still running after 600s: the message is already in its Bot Chat (session s1) and will be answered there. The reply cannot come back on this call. Do NOT resend."
        #expect(!HermesPeerCLI.isLocalDMTimeout(exitCode: 1, stderr: stillRunning, timeout: cap))
    }

    // MARK: - (2) nested multiplex_profiles: null

    private func status(_ yaml: String, _ caps: HermesCapabilities) -> HermesProfileRoutes.MultiplexStatus {
        ProfileRoutesYAML.parse(yaml).multiplexStatus(capabilities: caps)
    }

    /// `gateway/config.py:756-758`, `:781` @ v2026.9.21: a nested `null`
    /// stays `None` — unset, the implicit default — not a chosen `true`.
    @Test func nestedNullMultiplexIsUnsetOnV0214() {
        for spelling in ["null", "~", "Null", "NULL"] {
            let yaml = "gateway:\n  multiplex_profiles: \(spelling)\n"
            #expect(status(yaml, Self.v0214) == .defaultOn, "\(spelling)")
            #expect(!ProfileRoutesYAML.parse(yaml).multiplexIsSet, "\(spelling)")
        }
        // Both spellings null: still unset.
        #expect(status("multiplex_profiles: ~\ngateway:\n  multiplex_profiles: null\n", Self.v0214) == .defaultOn)
        // A real nested value is still honoured.
        #expect(status("gateway:\n  multiplex_profiles: true\n", Self.v0214) == .on)
        #expect(status("gateway:\n  multiplex_profiles: false\n", Self.v0214) == .retiredOptOut)
        // A quoted empty string is a str, not None.
        #expect(ProfileRoutesYAML.parse("gateway:\n  multiplex_profiles: ''\n").multiplexIsSet)
    }

    /// C1: a pre-v0.21.4 host reads the same `.off` it always did.
    @Test func nestedNullMultiplexUnchangedBelowV0214() {
        let parsed = ProfileRoutesYAML.parse("gateway:\n  multiplex_profiles: null\n")
        #expect(parsed.multiplexStatus(capabilities: Self.v0213) == .off)
        #expect(!parsed.multiplexProfiles)
        #expect(!parsed.multiplexIsTopLevel)
    }

    // MARK: - (3) cron duplicate: scheduler-owned stamps

    static func jobWithSchedulerStamps() throws -> HermesCronJob {
        // Shapes as `cron/jobs.py` / `cron/occurrences.py` write them at
        // v2026.9.21 (`pending_slot_stamp`, `:70-74`; fire claim `:2292`).
        let json = """
            {"id": "j1", "name": "Nightly", "prompt": "p", "enabled": true, "state": "scheduled",
             "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"},
             "reasoning_effort": "high",
             "pending_slot": {"scheduled_at": "2026-09-25T09:00:00+00:00", "at": "2026-09-25T09:00:01+00:00", "by": "host:123"},
             "fire_claim": {"at": "2026-09-25T09:00:01+00:00", "by": "host:123"},
             "run_claim": null,
             "failure_streak": 4, "created_at": "2026-09-01T00:00:00+00:00",
             "last_fire_error": {"at": "2026-09-24T09:00:00+00:00", "error": "boom"}}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    @Test func v0214DuplicateDropsSchedulerOwnedStamps() throws {
        for caps in [Self.v0214, Self.v0215] {
            let copy = try Self.jobWithSchedulerStamps().duplicatedAsNewJob(
                id: "j2", existingNames: ["Nightly"], capabilities: caps)
            for key in ["pending_slot", "fire_claim", "run_claim", "failure_streak", "created_at", "last_fire_error"] {
                #expect(copy.extra[key] == nil, "\(key)")
            }
            // Authored config still travels.
            #expect(copy.extra["reasoning_effort"] == .string("high"))
        }
    }

    /// C1: v0.21.3 and older keep their exact carry.
    @Test func preV0214DuplicateUnchanged() throws {
        let source = try Self.jobWithSchedulerStamps()
        for caps in [Self.v0213, HermesCapabilities.empty] {
            let copy = source.duplicatedAsNewJob(id: "j2", existingNames: ["Nightly"], capabilities: caps)
            for key in ["pending_slot", "fire_claim", "failure_streak", "created_at", "last_fire_error"] {
                #expect(copy.extra[key] == source.extra[key], "\(key)")
                #expect(copy.extra[key] != nil, "\(key)")
            }
        }
    }
}
