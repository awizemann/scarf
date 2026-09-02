import Testing
import Foundation
@testable import ScarfCore

/// Fix package F5 — MANAGE sub-cluster (section audit 2026-09): the
/// cron one-shot round-trip and its formatter branch.
///
/// The fixtures below are the exact schedule dicts
/// `cron/jobs.py::parse_schedule` emits at Hermes tag `v2026.8.31`:
///
///     {"kind": "once",     "run_at": "<ISO>", "display": "once at 2026-02-03 14:00"}
///     {"kind": "interval", "minutes": 30,     "display": "every 30m"}
///     {"kind": "cron",     "expr": "0 9 * * *", "display": "0 9 * * *"}
///
/// The bug these pin: the edit sheet seeded its Schedule field from
/// `display`, so editing a one-shot sent `--schedule "once at 2026-02-03
/// 14:00"` — a string `parse_schedule` has no branch for (not `every …`,
/// not 5 cron fields, no leading `\d{4}-\d{2}-\d{2}`, no `T`), so it fell
/// through to `parse_duration` and the edit always failed.
@Suite("SectionAuditF5Manage")
struct SectionAuditF5ManageTests {

    private let onceISO = "2026-02-03T14:00:00+00:00"

    private func onceSchedule(kind: String = "once", runAt: String? = nil) -> CronSchedule {
        CronSchedule(
            kind: kind,
            runAt: runAt ?? onceISO,
            display: "once at 2026-02-03 14:00"
        )
    }

    // MARK: - editValue round-trip

    @Test func oneShotEditValueIsTheRunAtTimestampNotTheDisplayLabel() {
        let value = onceSchedule().editValue
        #expect(value == onceISO)
        #expect(!value.contains("once at"))
    }

    @Test func intervalEditValueRebuildsFromStoredMinutes() {
        let schedule = CronSchedule(kind: "interval", display: "every 30m", minutes: 30)
        #expect(schedule.editValue == "every 30m")
    }

    @Test func cronEditValuePrefersExpressionOverDisplay() {
        let schedule = CronSchedule(kind: "cron", display: "Daily standup", expression: "0 9 * * *")
        #expect(schedule.editValue == "0 9 * * *")
    }

    @Test func oneShotWithoutRunAtFallsBackRatherThanCrashing() {
        let schedule = CronSchedule(kind: "once", runAt: nil, display: "once at 2026-02-03 14:00")
        #expect(schedule.editValue == "once at 2026-02-03 14:00")
    }

    /// Decoded straight from the Hermes-shaped JSON, so the CodingKeys
    /// (`run_at`, `expr`) are exercised alongside `editValue`.
    @Test func editValueSurvivesDecodingTheRealHermesShape() throws {
        let json = #"{"kind":"once","run_at":"2026-02-03T14:00:00+00:00","display":"once at 2026-02-03 14:00"}"#
        let schedule = try JSONDecoder().decode(CronSchedule.self, from: Data(json.utf8))
        #expect(schedule.editValue == "2026-02-03T14:00:00+00:00")
    }

    // MARK: - Formatter one-shot branch

    /// The dead branch: Hermes calls this kind `"once"`, never `"runat"`,
    /// and it always writes a `display` — so the old `case "runat"` sat
    /// behind an early `return display` AND matched a kind string that
    /// never occurs. One-shots rendered as the raw `once at …` stamp.
    @Test func oneShotFormatsAsADateNotTheRawStamp() {
        let text = CronScheduleFormatter.humanReadable(from: onceSchedule())
        #expect(text.hasPrefix("Once on "))
        #expect(!text.contains("once at 2026-02-03 14:00"))
    }

    @Test func legacyRunAtKindSpellingsAlsoFormat() {
        for kind in ["runat", "run_at", "ONCE"] {
            let text = CronScheduleFormatter.humanReadable(from: onceSchedule(kind: kind))
            #expect(text.hasPrefix("Once on "), "kind \(kind) did not take the one-shot branch")
        }
    }

    @Test func unparseableRunAtFallsBackToTheRawValue() {
        let schedule = CronSchedule(kind: "once", runAt: "not-a-timestamp", display: nil)
        #expect(CronScheduleFormatter.humanReadable(from: schedule) == "Once on not-a-timestamp")
    }

    @Test func oneShotWithNoRunAtAtAllStillReadsAsOneOff() {
        let schedule = CronSchedule(kind: "once", runAt: nil, display: nil)
        #expect(CronScheduleFormatter.humanReadable(from: schedule) == "One-off")
    }

    /// Guard against the one-shot branch swallowing the other kinds.
    @Test func intervalAndCronFormattingAreUnchanged() {
        let interval = CronSchedule(kind: "interval", display: "every 30m", minutes: 30)
        #expect(CronScheduleFormatter.humanReadable(from: interval) == "every 30m")
        let cron = CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *")
        #expect(CronScheduleFormatter.humanReadable(from: cron) == "Daily at 9 AM")
    }
}
