import Testing
import Foundation
@testable import ScarfCore

/// Whole-surface audit P15 — the cron read/format surfaces, pinned against
/// Hermes at tag `v2026.9.7`.
@Suite struct HermesCronP15ParityTests {

    // MARK: - `cron doctor` headers for ids that contain spaces

    /// A job id is whatever an id-keyed `jobs.json` map KEY says it is
    /// (`cron/jobs.py::load_jobs`, v2026.9.7 :1271 —
    /// `[{**v, "id": v.get("id") or k} …]`); nothing sanitizes it, so
    /// `nightly backup` is a legal id.
    ///
    /// `cron doctor` prints the header as `  {id} {name}`
    /// (`hermes_cli/cron.py::cron_doctor`), so splitting on the first space
    /// attributes the finding to a job called `nightly` — a row the UI can
    /// never match, and a real job that silently shows no warning.
    ///
    /// Fixture is the exact shape `cron_doctor` emits (colour disabled —
    /// `hermes_cli/colors.py::should_use_color` is `sys.stdout.isatty()`,
    /// always false for Scarf's piped runs).
    @Test func doctorHeaderResolvesAnIDContainingSpaces() throws {
        let output = """
            Cron doctor found 2 issue(s) across 2 job(s):

              nightly backup Nightly backup
                - workdir not found: /srv/gone

              4f2a9c1b7e03 Digest
                - last run failed: boom

            Next: fix the listed job config, then run `hermes cron doctor` again.
            """
        let findings = HermesCronDoctorParser.parse(
            text: output, knownJobIDs: ["nightly backup", "4f2a9c1b7e03"]
        )
        #expect(findings.count == 2)
        let backup = try #require(findings["nightly backup"])
        #expect(backup.jobName == "Nightly backup")
        #expect(backup.issues == ["workdir not found: /srv/gone"])
        #expect(findings["nightly"] == nil)
        #expect(try #require(findings["4f2a9c1b7e03"]).jobName == "Digest")
    }

    /// Longest prefix wins: `nightly` and `nightly backup` can both be real
    /// ids, and the header for the longer one starts with the shorter.
    @Test func doctorHeaderPrefersTheLongestKnownIDPrefix() throws {
        let output = """
            Cron doctor found 1 issue(s) across 1 job(s):

              nightly backup Nightly backup
                - workdir not found: /srv/gone
            """
        let findings = HermesCronDoctorParser.parse(
            text: output, knownJobIDs: ["nightly", "nightly backup"]
        )
        #expect(Array(findings.keys) == ["nightly backup"])
    }

    /// A known id must match only at a TOKEN boundary, or `nightly` would
    /// claim a header belonging to `nightlyfoo`.
    @Test func knownIDMatchesOnlyAtATokenBoundary() {
        #expect(HermesCronDoctorParser.knownIDPrefix(
            of: "nightlyfoo Something", candidates: ["nightly"]) == nil)
        #expect(HermesCronDoctorParser.knownIDPrefix(
            of: "nightly Something", candidates: ["nightly"]) == "nightly")
        // A header with no name at all is still a header.
        #expect(HermesCronDoctorParser.knownIDPrefix(
            of: "nightly", candidates: ["nightly"]) == "nightly")
    }

    /// With no roster in hand — the cold-launch order, where `cron doctor`
    /// can answer before `jobs.json` is read — the parse must behave exactly
    /// as it did before, so nothing regresses on the common path.
    @Test func withoutARosterTheShapeHeuristicStillApplies() throws {
        let output = """
            Cron doctor found 1 issue(s) across 1 job(s):

              4f2a9c1b7e03 Digest
                - last run failed: boom
            """
        let findings = HermesCronDoctorParser.parse(text: output)
        #expect(try #require(findings["4f2a9c1b7e03"]).jobName == "Digest")
    }

    // MARK: - `_format_lateness` truncates and clamps

    /// `hermes_cli/cron.py::_format_lateness` (v2026.9.7 :88-91) opens with
    /// `seconds = max(0, int(seconds))`. Python's `int()` TRUNCATES toward
    /// zero — it does not round — and the `max` CLAMPS a negative value.
    @Test func latenessTruncatesRatherThanRounds() {
        // 59.7s: Hermes prints `59s`; rounding printed `1m`.
        #expect(Self.stamp(lateness: 59.7).latenessDisplay == "59s")
        #expect(Self.stamp(lateness: 59.0).latenessDisplay == "59s")
        #expect(Self.stamp(lateness: 60.9).latenessDisplay == "1m")
    }

    /// An EARLY dispatch (`dispatched_at` before `scheduled_at`) is clamped
    /// to zero, not rendered as negative lateness.
    @Test func negativeLatenessClampsToZero() {
        #expect(Self.stamp(lateness: -1.4).latenessDisplay == "0s")
        #expect(Self.stamp(lateness: -600).latenessDisplay == "0s")
    }

    /// The pre-existing `_format_lateness` quirk still holds: the minutes
    /// component is dropped once days are present (`minutes if not days
    /// else 0`), so 97200s reads `1d 3h`.
    @Test func daysStillSwallowMinutes() {
        #expect(Self.stamp(lateness: 97_200).latenessDisplay == "1d 3h")
        #expect(Self.stamp(lateness: 0).latenessDisplay == "0s")
    }

    /// `Int(_: Double)` traps on NaN/±inf and `lateness_seconds` is
    /// untrusted JSON. Hermes's own `_format_lateness` admits as much with
    /// its `except (TypeError, ValueError): return "?"` arm.
    @Test func aNonFiniteLatenessDegradesInsteadOfTrapping() {
        #expect(Self.stamp(lateness: .nan).latenessDisplay == "?")
        #expect(Self.stamp(lateness: .infinity).latenessDisplay == "?")
        #expect(Self.stamp(lateness: -.infinity).latenessDisplay == "?")
    }

    private static func stamp(lateness: Double) -> CronDispatchStamp {
        CronDispatchStamp(
            scheduledAt: "2026-09-07T09:00:00+00:00",
            dispatchedAt: "2026-09-07T09:00:59+00:00",
            kind: .late,
            latenessSeconds: lateness
        )
    }

    // MARK: - the edit form's Repeat field

    /// `repeatSpec` had no consumer: the editor opened with a blank Repeat
    /// field on every job, so a user changing anything else was shown
    /// "Optional count" for a job that had a finite one, and the save
    /// omitted `--repeat` entirely.
    @Test func repeatEditValueSeedsTheFormFromTheStoredCount() {
        #expect(Self.job(repeat: #"{"times": 3, "completed": 1}"#).repeatEditValue == "3")
        // `times: null` is Hermes's "forever" (`cron/jobs.py::create_job`
        // :1779), which the form spells as the empty field.
        #expect(Self.job(repeat: #"{"times": null, "completed": 4}"#).repeatEditValue == "")
        #expect(Self.job(repeat: "null").repeatEditValue == "")
        // Bare forms an id-keyed or hand-edited jobs.json can legitimately
        // hold, read through `normalize_repeat_value` (:591-617).
        #expect(Self.job(repeat: #""once""#).repeatEditValue == "1")
        #expect(Self.job(repeat: #""forever""#).repeatEditValue == "")
        #expect(Self.job(repeat: "5").repeatEditValue == "5")
        // No `repeat` key at all.
        #expect(Self.oneShot(runAt: "2026-09-07T06:00:00").repeatEditValue == "")
    }

    private static func job(repeat spec: String) -> HermesCronJob {
        let json = """
        {"id": "j1", "name": "n", "prompt": "go", "enabled": true,
         "schedule": {"kind": "cron", "expr": "0 9 * * *"}, "repeat": \(spec)}
        """
        return try! JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    // MARK: - naive one-shot timestamps get the ±12h window

    /// `cron/jobs.py::_ensure_aware` (v2026.9.7 :807-814) resolves a naive
    /// datetime in the process's *system-local* zone and converts to the
    /// *configured Hermes* zone — never UTC. Scarf can know neither, so a
    /// naive `run_at` is only treated as spent when it is past-grace in
    /// EVERY zone: the latest instant it can denote is `T + 12h` (UTC−12).
    ///
    /// Without the window, a job whose deadline is still hours in the future
    /// for its host was refused locally with a message the host would never
    /// have produced — a client-side refusal of a write Hermes accepts.
    @Test func naiveOneShotIsNotRefusedInsideTheTwelveHourWindow() {
        let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        // Six hours "in the past" as UTC — but only 12:00 in UTC−12 terms,
        // i.e. still six hours in the FUTURE for a westernmost host.
        let job = Self.oneShot(runAt: "2026-09-07T06:00:00")
        #expect(job.oneShotIsUnresumable(now: now) == false)
    }

    @Test func naiveOneShotPastGraceInEveryZoneIsStillRefused() {
        let now = ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z")!
        // 30 hours back: past-grace even read as UTC−12.
        let job = Self.oneShot(runAt: "2026-09-07T06:00:00")
        #expect(job.oneShotIsUnresumable(now: now) == true)
    }

    /// An OFFSET-bearing `run_at` names exactly one instant, so it keeps the
    /// tight `ONESHOT_GRACE_SECONDS` (120s, `cron/jobs.py` :96) comparison —
    /// widening it there would let through a resume `resume_job` refuses
    /// (`cron/jobs.py::resume_job`, v2026.9.7 :1986-2003).
    @Test func offsetBearingOneShotKeepsTheTightGraceWindow() {
        let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        #expect(Self.oneShot(runAt: "2026-09-07T11:00:00+00:00")
            .oneShotIsUnresumable(now: now) == true)
        #expect(Self.oneShot(runAt: "2026-09-07T11:59:00+00:00")
            .oneShotIsUnresumable(now: now) == false)
    }

    private static func oneShot(runAt: String) -> HermesCronJob {
        let json = """
        {"id": "j1", "name": "one shot", "prompt": "go", "enabled": false,
         "schedule": {"kind": "once", "run_at": "\(runAt)"}}
        """
        return try! JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }
}
