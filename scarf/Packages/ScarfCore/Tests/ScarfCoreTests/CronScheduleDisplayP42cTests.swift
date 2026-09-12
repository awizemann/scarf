import Testing
import Foundation
@testable import ScarfCore

/// P42c · the re-audit of P42b's own commit (`b30c3983`).
///
/// `schedule_display` is a DERIVED field that Hermes re-stamps on every read
/// — `_normalize_job_record` sets
/// `normalized["schedule_display"] = _schedule_display_for_job(normalized)`
/// (`cron/jobs.py:470` @ `v2026.9.7`) — and `_schedule_display_for_job`
/// (`:438-446`) PREFERS the stored top-level value whenever it is non-empty,
/// only then falling back to `schedule.display` / `value` / `expr` /
/// `run_at`. Scarf never modelled the key, so it rides in `extra` and
/// `HermesCronJob.encode` re-emits it verbatim: any writer that carries a
/// record's `extra` across a schedule change hands every future reader the
/// OLD schedule's label in front of the NEW time.
///
/// P42b dropped `schedule.display` from the iOS duplicate and stopped there.
@Suite struct CronScheduleDisplayP42cTests {

    /// A record in the shape `cron/jobs.json` actually holds after a Hermes
    /// read: the top-level derived label beside the nested one, plus the
    /// unmodeled keys a duplicate is supposed to carry.
    static let realRecord = #"""
    {
      "id": "job_abc",
      "name": "nightly digest",
      "prompt": "summarise",
      "schedule": {"kind": "once", "run_at": "2020-01-01T09:00:00Z",
                   "display": "once at 2020-01-01 09:00"},
      "schedule_display": "once at 2020-01-01 09:00",
      "enabled": false,
      "state": "completed",
      "monitor_url": "https://example.com/health",
      "repeat": {"every": 3, "completed": 3}
    }
    """#

    static func decoded() throws -> HermesCronJob {
        try JSONDecoder().decode(HermesCronJob.self, from: Data(Self.realRecord.utf8))
    }

    /// The decode itself: the key is unmodeled, so it lands in `extra` and is
    /// live on the wire. If this ever stops holding the rest of the suite is
    /// testing nothing.
    @Test func theKeyRidesInExtraAndIsReEncoded() throws {
        let job = try Self.decoded()
        #expect(job.extra["schedule_display"] == .string("once at 2020-01-01 09:00"))
        let wire = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(job)) as? [String: Any]
        #expect(wire?["schedule_display"] as? String == "once at 2020-01-01 09:00")
    }

    /// The fix, at the primitive.
    @Test func theHelperDropsOnlyThatKey() {
        let cleaned = HermesCronJob.droppingDerivedScheduleDisplay(
            ["schedule_display": .string("x"), "monitor_url": .string("u")])
        #expect(cleaned["schedule_display"] == nil)
        #expect(cleaned["monitor_url"] == .string("u"))
        #expect(HermesCronJob.droppingDerivedScheduleDisplay([:]).isEmpty)
    }

    /// The finding: P42b blanked `schedule.run_at` and `schedule.display` on
    /// the iOS duplicate, but the TOP-LEVEL label outranks both at
    /// `_schedule_display_for_job` — so the copy the user was about to give a
    /// new time to still announced 2020 to every reader, including `cron
    /// list`. Now it is dropped, and Hermes re-derives it.
    @Test func theDuplicateNoLongerCarriesTheDerivedLabel() throws {
        let copy = try Self.decoded().duplicatedAsNewJob(id: "job_new", existingNames: [])
        #expect(copy.extra["schedule_display"] == nil)
        // The rest of P42b's contract is unchanged.
        #expect(copy.schedule.runAt == nil)
        #expect(copy.schedule.display == nil)
        #expect(copy.extra["monitor_url"] == .string("https://example.com/health"))
        // …and it is gone from the bytes iOS writes, not just from the model.
        let wire = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(copy)) as? [String: Any]
        #expect(wire?["schedule_display"] == nil)
        #expect(wire?["monitor_url"] as? String == "https://example.com/health")
    }

    /// A duplicate of a job whose schedule is fine loses the label too, and
    /// that is deliberate rather than collateral: the field has no authority
    /// Hermes does not re-grant it on the very next read (`:470`), so
    /// dropping can only ever cost a derivation.
    @Test func aRecurringDuplicateAlsoDropsIt() throws {
        let json = #"""
        {"id":"j","name":"n","prompt":"p",
         "schedule":{"kind":"cron","expr":"0 9 * * 1-5"},
         "schedule_display":"stale label","enabled":true,"state":"scheduled"}
        """#
        let job = try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
        #expect(job.extra["schedule_display"] == .string("stale label"))
        #expect(job.duplicatedAsNewJob(id: "j2", existingNames: []).extra["schedule_display"] == nil)
    }

    // MARK: - The iOS editor's ordinary save

    /// The worse half of the finding, and the reason this is not a
    /// duplicate-only bug: `CronEditorView.buildJob` is the ONE writer behind
    /// both the iOS duplicate sheet and an ordinary iOS edit, and it forwarded
    /// `existing?.extra` unconditionally. Re-timing a live job from the phone
    /// therefore left the previous time's label in front of the new one for
    /// every reader.
    ///
    /// There is no runtime seam to assert on — `buildJob` is `private` to a
    /// SwiftUI view in the iOS target, which neither test host builds — so the
    /// alarm is the SHAPE in the source, the P38 sweep precedent. Watched
    /// failing against the pre-fix file.
    @Test func theIOSEditorDropsTheLabelWheneverTheScheduleMoved() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("scarf/Scarf iOS/Cron/CronListView.swift"),
            encoding: .utf8)
        let body = try #require(Self.buildJobBody(of: source), "buildJob() not found")
        #expect(body.contains("HermesCronJob.droppingDerivedScheduleDisplay"),
                "buildJob no longer drops the derived label")
        #expect(body.contains("existing?.schedule != schedule"),
                "buildJob no longer decides on whether the schedule moved")
        #expect(!body.contains("extra: existing?.extra ?? [:]"),
                "buildJob forwards `extra` verbatim again — the stale label is back")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    /// The text of `buildJob()` — from its declaration to the end of the file,
    /// which is where it sits. Deliberately crude: the assertions above are
    /// about presence and absence of a handful of spellings, and a brace
    /// counter here would be one more thing that can be wrong.
    private static func buildJobBody(of source: String) -> String? {
        guard let start = source.range(of: "private func buildJob() -> HermesCronJob {") else {
            return nil
        }
        return String(source[start.lowerBound...])
    }
}
