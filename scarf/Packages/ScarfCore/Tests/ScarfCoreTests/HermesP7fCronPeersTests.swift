import Foundation
import Testing
@testable import ScarfCore

/// P7f (Hermes v0.21.5 parity) — the ScarfCore halves of the cron / peers
/// audit fixes. Each test fails if its fix is reverted.
@Suite struct HermesP7fCronPeersTests {
    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    // MARK: - cron run skip sentences

    /// The literals, verbatim from `tools/cronjob_tools.py:194-198` and
    /// `:716-717` @ v2026.9.24.
    static let paused = "Job is paused/disabled; resume it before running."
    static let missing = "Job no longer exists; nothing to run."
    static let claimLost = "Job is already being fired by the scheduler; not run again."
    static let fallback = "Already being fired by the scheduler; not run again."

    @Test func refusedMarkersAreTheSourceSentences() {
        #expect(HermesCLIMarkers.cronRunRefused.contains(Self.paused))
        #expect(HermesCLIMarkers.cronRunRefused.contains(Self.missing))
        // The already-firing tail matches BOTH spellings and no refusal.
        for sentence in [Self.claimLost, Self.fallback] {
            #expect(HermesCLIMarkers.cronRunAlreadyFiring.contains { sentence.contains($0) }, "\(sentence)")
            #expect(!HermesCLIMarkers.cronRunRefused.contains { sentence.contains($0) }, "\(sentence)")
        }
        #expect(HermesCLIMarkers.cronRanNowSucceeded == "Ran now: succeeded.")
    }

    // MARK: - duplicate: v0.21.4 scheduler-owned stamps

    static func jobWithRunStamps() throws -> HermesCronJob {
        // Shapes as v2026.9.21 writes them: `trigger_job` (`cron/jobs.py:2106-2115`),
        // `mark_preflight_alerted` (`:2243-2245`), and
        // `_record_delivery_verification` (`cron/scheduler_delivery.py:1278-1282`).
        let json = """
            {"id": "j1", "name": "Nightly", "prompt": "p", "enabled": true, "state": "scheduled",
             "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"},
             "reasoning_effort": "high",
             "manual_run_at": "2026-09-25T09:00:00+00:00",
             "manual_run_prompt": "also check the staging box",
             "preflight_alerted": true,
             "last_delivery_queued": {"bot_chat:alice": {"status": "queued", "delivery_id": "d1"}}}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    static let runStampKeys = ["manual_run_at", "manual_run_prompt", "preflight_alerted", "last_delivery_queued"]

    /// v0.21.4 has no `JOB_DEFINITION_FIELDS` allowlist, so only the denylist
    /// stands between the copy and the source's pending run prompt.
    @Test func v0214DuplicateDropsRunStamps() throws {
        for caps in [Self.v0214, Self.v0215] {
            let copy = try Self.jobWithRunStamps().duplicatedAsNewJob(
                id: "j2", existingNames: ["Nightly"], capabilities: caps)
            for key in Self.runStampKeys {
                #expect(copy.extra[key] == nil, "\(key)")
            }
            #expect(copy.extra["reasoning_effort"] == .string("high"))
        }
    }

    /// C1: v0.21.3 and older keep their exact carry.
    @Test func preV0214DuplicateKeepsRunStamps() throws {
        let source = try Self.jobWithRunStamps()
        for caps in [Self.v0213, HermesCapabilities.empty] {
            let copy = source.duplicatedAsNewJob(id: "j2", existingNames: ["Nightly"], capabilities: caps)
            for key in Self.runStampKeys {
                #expect(copy.extra[key] != nil, "\(key)")
                #expect(copy.extra[key] == source.extra[key], "\(key)")
            }
        }
    }

    // MARK: - peer run

    /// Four sequential `LIST_TIMEOUT_S = 30` requests (`peer.py:29`, `:193`,
    /// `:111`, `:123-125`, `:325-328` @ v2026.9.24) plus startup headroom.
    @Test func runTimeoutCoversFourRequestsWithHeadroom() {
        #expect(HermesPeerCLI.runProcessTimeout >= 150)
        #expect(HermesPeerCLI.runProcessTimeout > 4 * 30)
    }

    /// `_peer_run`'s own validation (`peer.py:313-317` @ v2026.9.24):
    /// 1-255 characters, no CR/LF/NUL. Keys are unique per call.
    @Test func generatedKeysPassHermesValidationAndAreUnique() {
        let a = HermesPeerCLI.newIdempotencyKey()
        let b = HermesPeerCLI.newIdempotencyKey()
        #expect(a != b)
        for key in [a, b] {
            #expect(!key.isEmpty && key.count <= 255)
            #expect(key.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\u{0}")) == nil)
        }
        let args = HermesPeerCLI.runArgs(target: "spark", message: "-v is broken", idempotencyKey: a)
        #expect(args == ["peer", "run", "--idempotency-key", a, "--json", "--", "spark", "-v is broken"])
    }
}
