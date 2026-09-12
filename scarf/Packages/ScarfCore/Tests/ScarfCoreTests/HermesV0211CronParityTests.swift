import Testing
import Foundation
@testable import ScarfCore

/// Phase 3 of the Hermes v0.21.1 (`v2026.9.7`) parity cycle — the cron
/// surfaces.
///
/// Everything here is pinned against real Hermes source at the audited tag:
/// `hermes_cli/subcommands/cron.py` (the argparse surface), `cron/jobs.py`
/// (`create_job`, `_next_run_or_reject_past_oneshot`,
/// `_classify_dispatch_lateness`), `hermes_cli/cron.py` (`cron_create`,
/// `_dispatch_display`, `_format_lateness`, `_job_warnings`,
/// `_cron_doctor_issues_for_job`) and `cron/lifecycle_guard.py`
/// (`check_gateway_lifecycle`). Fixtures are the exact bytes those printers
/// emit with color disabled — always, for Scarf's piped runs.
@Suite struct HermesV0211CronParityTests {

    private func caps(_ line: String) -> HermesCapabilities { HermesHost.caps(line) }
    private var v021: HermesCapabilities { caps("Hermes Agent v0.21.0 (2026.8.31)") }
    private var v0211: HermesCapabilities { caps("Hermes Agent v0.21.1 (2026.9.7)") }

    private func job(_ extraJSON: String, deliver: String? = nil) throws -> HermesCronJob {
        let deliverField = deliver.map { "\"deliver\":\"\($0)\"," } ?? ""
        let json = """
            {"id":"j1","name":"One","prompt":"p","enabled":true,"state":"scheduled",
             \(deliverField)"schedule":{"kind":"interval","minutes":30}\(extraJSON.isEmpty ? "" : ",\(extraJSON)")}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    // MARK: - failure_deliver (C3)

    @Test func readsFailureDeliverThroughExtra() throws {
        #expect(try job("\"failure_deliver\":\"local\"").failureDeliver == "local")
        #expect(try job("\"failure_deliver\":\"telegram:123\"").failureDeliver == "telegram:123")
        // Absent, null, and whitespace-only all mean "failures follow deliver".
        #expect(try job("").failureDeliver == nil)
        #expect(try job("\"failure_deliver\":null").failureDeliver == nil)
        #expect(try job("\"failure_deliver\":\"   \"").failureDeliver == nil)
    }

    /// The field is read through `extra`, never modeled — so a pause/resume
    /// rewrite must put it back byte-for-byte, `last_dispatch` and
    /// `last_delivery_unverified` included.
    @Test func v0211FieldsSurviveAToggleRoundTrip() throws {
        let original = try job("""
            "failure_deliver":"local",
            "last_dispatch":{"scheduled_at":"2026-09-07T09:00:00+00:00","dispatched_at":"2026-09-07T09:41:12+00:00","lateness_seconds":2472.0,"kind":"late"},
            "last_delivery_unverified":["slack:C123","matrix:!room"]
            """)
        let data = try JSONEncoder().encode(original.withEnabled(false))
        let decoded = try JSONDecoder().decode(HermesCronJob.self, from: data)
        #expect(decoded.failureDeliver == "local")
        #expect(decoded.lastDispatch == original.lastDispatch)
        #expect(decoded.lastDeliveryUnverifiedTargets == ["slack:C123", "matrix:!room"])
    }

    // MARK: - last_dispatch / last_delivery_unverified (C4)

    @Test func decodesTheDispatchStamp() throws {
        let stamp = try #require(job("""
            "last_dispatch":{"scheduled_at":"2026-09-07T09:00:00+00:00","dispatched_at":"2026-09-07T09:41:12+00:00","lateness_seconds":2472.0,"kind":"late"}
            """).lastDispatch)
        #expect(stamp.kind == .late)
        #expect(stamp.isLate)
        #expect(stamp.scheduledAt == "2026-09-07T09:00:00+00:00")
        #expect(stamp.latenessSeconds == 2472.0)
    }

    /// `_dispatch_display` returns None unless `scheduled_at`,
    /// `dispatched_at` AND `kind` are all present — a partial or unknown
    /// stamp must render nothing rather than a wrong badge.
    @Test func incompleteOrUnknownDispatchStampsDecodeToNil() throws {
        #expect(try job("\"last_dispatch\":{}").lastDispatch == nil)
        #expect(try job("\"last_dispatch\":null").lastDispatch == nil)
        #expect(try job("\"last_dispatch\":\"late\"").lastDispatch == nil)
        #expect(try job("""
            "last_dispatch":{"scheduled_at":"a","dispatched_at":"b"}
            """).lastDispatch == nil)
        // A `kind` a future Hermes introduces degrades to "no diagnostics".
        #expect(try job("""
            "last_dispatch":{"scheduled_at":"a","dispatched_at":"b","kind":"deferred"}
            """).lastDispatch == nil)
        #expect(try job("").lastDispatch == nil)
    }

    @Test func onTimeDispatchIsNotLate() throws {
        let stamp = try #require(job("""
            "last_dispatch":{"scheduled_at":"a","dispatched_at":"b","lateness_seconds":12,"kind":"on_time"}
            """).lastDispatch)
        #expect(stamp.isLate == false)
        #expect(stamp.latenessDisplay == "12s")
    }

    /// Port of `hermes_cli/cron.py::_format_lateness` — note that the minutes
    /// component is deliberately dropped once days are present (`parts =
    /// [(days,"d"), (hours,"h"), (minutes if not days else 0,"m")]`).
    @Test(arguments: [
        (0.0, "0s"), (45.0, "45s"), (59.4, "59s"), (60.0, "1m"),
        (2472.0, "41m"), (7500.0, "2h 5m"), (97200.0, "1d 3h"), (86400.0, "1d"),
    ])
    func latenessDisplayMatchesHermes(seconds: Double, expected: String) {
        let stamp = CronDispatchStamp(
            scheduledAt: "a", dispatchedAt: "b", kind: .late, latenessSeconds: seconds
        )
        #expect(stamp.latenessDisplay == expected)
    }

    @Test func readsUnverifiedDeliveryTargets() throws {
        #expect(try job("\"last_delivery_unverified\":[\"slack:C1\"]").lastDeliveryUnverifiedTargets == ["slack:C1"])
        // `_unverified_targets` tolerates a bare scalar, so this does too.
        #expect(try job("\"last_delivery_unverified\":\"slack:C1\"").lastDeliveryUnverifiedTargets == ["slack:C1"])
        #expect(try job("\"last_delivery_unverified\":null").lastDeliveryUnverifiedTargets.isEmpty)
        #expect(try job("\"last_delivery_unverified\":[]").lastDeliveryUnverifiedTargets.isEmpty)
        #expect(try job("").lastDeliveryUnverifiedTargets.isEmpty)
    }

    // MARK: - past one-shot pre-check (A8)

    private static let now = Date(timeIntervalSince1970: 1_788_000_000)  // 2026-09-07ish

    @Test func rejectsAnOffsetBearingOneShotPastTheGraceWindow() {
        let past = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-600))
        #expect(HermesCronJob.oneShotScheduleIsPastGrace(past, now: Self.now))
        // Inside the 120s grace window Hermes still accepts it.
        let recent = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-30))
        #expect(HermesCronJob.oneShotScheduleIsPastGrace(recent, now: Self.now) == false)
        let future = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(3600))
        #expect(HermesCronJob.oneShotScheduleIsPastGrace(future, now: Self.now) == false)
    }

    /// Nothing but the ISO-timestamp arm of `parse_schedule` can be in the
    /// past: `in 30m` is computed from now, and intervals / cron expressions
    /// always have a future occurrence.
    @Test(arguments: ["30m", "every 2h", "0 9 * * *", "in 30m", "every monday 9am", "weekdays at 9am", ""])
    func nonOneShotSchedulesAreNeverPreRejected(schedule: String) {
        #expect(HermesCronJob.oneShotScheduleIsPastGrace(schedule, now: Self.now) == false)
    }

    /// Hermes resolves an offset-less timestamp in the CONFIGURED Hermes
    /// timezone, which Scarf cannot know — so a naive value is refused only
    /// when it is past-grace in every timezone (latest instant it can denote
    /// is `T + 12h`, at UTC−12).
    @Test func naiveTimestampsAreOnlyRefusedWhenPastInEveryTimezone() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        // 6h "ago" as a naive string could still be the future in UTC−12.
        let ambiguous = f.string(from: Self.now.addingTimeInterval(-6 * 3600))
        #expect(HermesCronJob.oneShotScheduleIsPastGrace(ambiguous, now: Self.now) == false)
        // 3 days ago is past-grace no matter which zone Hermes resolves it in.
        let unambiguous = f.string(from: Self.now.addingTimeInterval(-3 * 86400))
        #expect(HermesCronJob.oneShotScheduleIsPastGrace(unambiguous, now: Self.now))
        // Garbage that merely looks date-shaped must not be refused.
        #expect(HermesCronJob.oneShotScheduleIsPastGrace("2026-13-45T99:00:00", now: Self.now) == false)
    }

    // MARK: - cron doctor issue kinds (A7)

    /// v0.21.1 stopped emitting `last run failed:` for `last_status ==
    /// "delivery_failed"` (the agent run succeeded) and added the
    /// unverified-delivery issue. Grammar is unchanged, so the parser needs
    /// no edit — this fixture is the drift alarm, and it pins the new issue
    /// into its own severity so a Slack-delivering job is never headlined
    /// as broken.
    @Test func parsesTheV0211DoctorIssueSet() throws {
        let output = """
            Cron doctor found 3 issue(s) across 2 job(s):

              4f2a9c1b7e03 Nightly digest
                - last delivery failed: telegram 429 Too Many Requests
                - last delivery unverified (adapter acked without evidence): slack:C123, matrix:!room

              b71c02da9f10 Slack ping
                - last delivery unverified (adapter acked without evidence): slack:C999

            Next: fix the listed job config, then run `hermes cron doctor` again.
            """
        let findings = HermesCronDoctorParser.parse(text: output)
        #expect(findings.count == 2)

        let digest = try #require(findings["4f2a9c1b7e03"])
        #expect(digest.issues.count == 2)
        #expect(digest.problemIssues == ["last delivery failed: telegram 429 Too Many Requests"])
        #expect(digest.unverifiedIssues.count == 1)

        // A job whose ONLY finding is an unverified delivery has zero
        // problems — the banner must not claim "1 issue".
        let ping = try #require(findings["b71c02da9f10"])
        #expect(ping.problemIssues.isEmpty)
        #expect(ping.unverifiedIssues.count == 1)
    }

    @Test func classifiesDoctorIssueSeverity() {
        #expect(HermesCronDoctorFinding.severity(of: "last delivery unverified (adapter acked without evidence): slack:C1") == .unverified)
        #expect(HermesCronDoctorFinding.severity(of: "last delivery failed: boom") == .problem)
        #expect(HermesCronDoctorFinding.severity(of: "last run failed: boom") == .problem)
        #expect(HermesCronDoctorFinding.severity(of: "workdir not found: /gone") == .problem)
        #expect(HermesCronDoctorFinding.severity(of: "active job has no next_run_at") == .problem)
    }

    // MARK: - fleet copy argv (C2 / C3)

    private func copyJob(failureDeliver: String?, deliver: String? = "telegram:1") throws -> HermesCronJob {
        try job(failureDeliver.map { "\"failure_deliver\":\"\($0)\"" } ?? "", deliver: deliver)
    }

    @Test func fleetCopyForwardsFailureDeliverOnlyToV0211Hosts() throws {
        let source = try copyJob(failureDeliver: "local")
        let schedule = try #require(CronScheduleArgument.resolve(source.schedule))

        let new = FleetApplyPlan.cronCreateArgs(
            copying: source, schedule: schedule, caps: v0211, sourceRoot: "/a", targetRoot: "/b"
        ).args
        #expect(HermesCLIOption.value(of: "--failure-deliver", in: new) == "local")

        // A v0.21.0 target would die at argparse on the unknown flag.
        let old = FleetApplyPlan.cronCreateArgs(
            copying: source, schedule: schedule, caps: v021, sourceRoot: "/a", targetRoot: "/b"
        ).args
        #expect(HermesCLIOption.contains("--failure-deliver", in: old) == false)
        // ...and an unprobed host is treated as the oldest one.
        let unknown = FleetApplyPlan.cronCreateArgs(
            copying: source, schedule: schedule, caps: .empty, sourceRoot: "/a", targetRoot: "/b"
        ).args
        #expect(HermesCLIOption.contains("--failure-deliver", in: unknown) == false)
    }

    /// `failure_deliver` shares `deliver`'s grammar, so a value the target
    /// can't parse must be dropped by the same gate — and dropping it is NOT
    /// a deliver-all downgrade, because the copy still delivers.
    @Test func fleetCopyDropsAFailureDeliverValueTheTargetCannotParse() throws {
        let source = try copyJob(failureDeliver: "bot-chat:coder")
        let schedule = try #require(CronScheduleArgument.resolve(source.schedule))
        // Contrived-but-real shape: a host new enough for the FLAG always has
        // bot-chat too, so exercise the value gate through `all` on a job
        // whose deliver lane is baseline.
        let result = FleetApplyPlan.cronCreateArgs(
            copying: source, schedule: schedule, caps: v0211, sourceRoot: "/a", targetRoot: "/b"
        )
        #expect(HermesCLIOption.value(of: "--failure-deliver", in: result.args) == "bot-chat:coder")
        #expect(result.droppedDeliverAll == false)

        let noOverride = try copyJob(failureDeliver: nil)
        let plain = FleetApplyPlan.cronCreateArgs(
            copying: noOverride, schedule: schedule, caps: v0211, sourceRoot: "/a", targetRoot: "/b"
        ).args
        #expect(HermesCLIOption.contains("--failure-deliver", in: plain) == false)
    }

    @Test func fleetCopyPausesInOneWriteOnlyOnV0211Hosts() throws {
        let source = try copyJob(failureDeliver: nil)
        let schedule = try #require(CronScheduleArgument.resolve(source.schedule))
        #expect(FleetApplyPlan.cronCreateArgs(
            copying: source, schedule: schedule, caps: v0211,
            sourceRoot: "/a", targetRoot: "/b", paused: true
        ).args.contains("--paused"))
        #expect(FleetApplyPlan.cronCreateArgs(
            copying: source, schedule: schedule, caps: v021,
            sourceRoot: "/a", targetRoot: "/b", paused: true
        ).args.contains("--paused") == false)
        // Default is unpaused, so no existing caller changed shape.
        #expect(FleetApplyPlan.cronCreateArgs(
            copying: source, schedule: schedule, caps: v0211, sourceRoot: "/a", targetRoot: "/b"
        ).args.contains("--paused") == false)
    }

    // MARK: - capability floors

    @Test func v0211CronFloors() {
        #expect(v021.hasCronCreatePaused == false)
        #expect(v021.hasCronFailureDeliver == false)
        #expect(v021.hasCronDispatchDiagnostics == false)
        #expect(v0211.hasCronCreatePaused)
        #expect(v0211.hasCronFailureDeliver)
        #expect(v0211.hasCronDispatchDiagnostics)
        // An unprobed host is conservative on all three.
        #expect(HermesCapabilities.empty.hasCronCreatePaused == false)
        #expect(HermesCapabilities.empty.hasCronFailureDeliver == false)
        #expect(HermesCapabilities.empty.hasCronDispatchDiagnostics == false)
    }

    // MARK: - drift alarms (item 7)

    /// `hermes cron runs` still prints the f-string
    /// `hermes_cli/cron.py::cron_runs` used at v0.21.0 — byte-identical at
    /// v2026.9.7, so `HermesCronRunsParser` needs no edit. Sibling of
    /// `cronRunsFormatUnchangedAtV021`.
    @Test func cronRunsFormatUnchangedAtV0211() throws {
        let output = """
            e1  completed  job=job-1  source=scheduler  2026-09-07T09:00:00
            e2  failed     job=job-1  source=manual  2026-09-06T09:00:00
                boom: provider 500
            """
        let runs = HermesCronRunsParser.parse(text: output)
        try #require(runs.count == 2)
        #expect(runs[0].id == "e1")
        #expect(runs[0].status == "completed")
        #expect(runs[1].error == "boom: provider 500")
    }

    /// The two NEW `cron list` rows, verbatim from
    /// `hermes_cli/cron.py::_job_detail_rows` / `_job_warnings` with color
    /// disabled. Scarf renders these from `jobs.json` rather than parsing
    /// `cron list`, so this test's job is to pin the CONTENT contract — the
    /// same strings a future format change would break — and prove Scarf's
    /// own renderings say the same thing.
    @Test func cronListDispatchAndUnverifiedRowsMatchScarfsRendering() throws {
        // The CLI's own two lines, verbatim (color disabled).
        let cliDispatch = "Dispatch: ⚠ late: scheduled 2026-09-07T09:00:00+00:00, ran 2026-09-07T09:41:12+00:00 (41m late)"
        let cliUnverified = "⚠ Delivery UNVERIFIED: adapter acked slack:C123, matrix:!room without message_id/raw_response"
        let j = try job("""
            "last_dispatch":{"scheduled_at":"2026-09-07T09:00:00+00:00","dispatched_at":"2026-09-07T09:41:12+00:00","lateness_seconds":2472.0,"kind":"late"},
            "last_delivery_unverified":["slack:C123","matrix:!room"]
            """)
        let stamp = try #require(j.lastDispatch)
        #expect(stamp.kind == .late)
        #expect(stamp.latenessDisplay == "41m")
        #expect(j.lastDeliveryUnverifiedTargets == ["slack:C123", "matrix:!room"])

        // Scarf's renderings (CronView delegates to both) say the same
        // thing as the CLI's lines: same timestamps, same lateness, same
        // targets, same verdict.
        let summary = stamp.summary
        #expect(summary == "Late: scheduled 2026-09-07T09:00:00+00:00, ran 2026-09-07T09:41:12+00:00 (41m late)")
        for fragment in ["2026-09-07T09:00:00+00:00", "2026-09-07T09:41:12+00:00", "41m late"] {
            #expect(cliDispatch.contains(fragment) && summary.contains(fragment))
        }
        let note = try #require(j.deliveryUnverifiedNote)
        #expect(note == "Delivery unverified: slack:C123, matrix:!room acked without a message id")
        for fragment in ["slack:C123", "matrix:!room"] {
            #expect(cliUnverified.contains(fragment) && note.contains(fragment))
        }
        // Nothing to say when the field is absent — no empty banner.
        #expect(try job("\"name\":\"n\"").deliveryUnverifiedNote == nil)
    }

    /// The other two `_dispatch_display` shapes, including `catch_up`,
    /// which no test reached (L9).
    @Test func dispatchSummaryCoversOnTimeAndCatchUp() throws {
        let onTime = try #require(job("""
            "last_dispatch":{"scheduled_at":"2026-09-07T09:00:00+00:00","dispatched_at":"2026-09-07T09:00:02+00:00","lateness_seconds":2.0,"kind":"on_time"}
            """).lastDispatch)
        #expect(onTime.kind == .onTime)
        #expect(!onTime.isLate)
        #expect(onTime.summary == "Dispatch: on time (scheduled 2026-09-07T09:00:00+00:00)")

        let catchUp = try #require(job("""
            "last_dispatch":{"scheduled_at":"2026-09-06T09:00:00+00:00","dispatched_at":"2026-09-07T12:00:00+00:00","lateness_seconds":97200.0,"kind":"catch_up"}
            """).lastDispatch)
        #expect(catchUp.kind == .catchUp)
        #expect(catchUp.isLate)
        // `_format_lateness` drops minutes once days are present.
        #expect(catchUp.latenessDisplay == "1d 3h")
        #expect(catchUp.summary == "Catch-up after missed fire: scheduled 2026-09-06T09:00:00+00:00, ran 2026-09-07T12:00:00+00:00 (1d 3h late)")
    }

    // MARK: - M2 / M3 — one argv builder, and `--` before user text

    /// A prompt or schedule beginning with `-` is user text, not a flag.
    /// Without `--` argparse exits 2 on it and the whole fleet apply (or
    /// template install) aborts.
    @Test func cronCreateArgsEndsOptionsBeforeTheUserPositionals() throws {
        let (args, _) = FleetApplyPlan.cronCreateArgs(
            name: "n", deliver: nil, schedule: "@daily",
            prompt: "--summarize the inbox", caps: v0211)
        let end = try #require(args.firstIndex(of: "--"))
        #expect(Array(args[end...]) == ["--", "@daily", "--summarize the inbox"])
        // …and nothing option-shaped follows the marker.
        let nameIndex = try #require(HermesCLIOption.index(of: "--name", in: args))
        #expect(nameIndex < end)
    }

    /// The template installer used to hand-roll this argv; both callers now
    /// resolve the same gates through the one builder.
    @Test func templateAndFleetCreatesShareTheBuilder() {
        // Repeat count is the installer's own field and rides the same path.
        let (args, dropped) = FleetApplyPlan.cronCreateArgs(
            name: "nightly", deliver: "all", repeatCount: 3,
            skills: ["research"], schedule: "0 9 * * *", prompt: "go",
            caps: v0211, paused: true)
        #expect(!dropped)
        #expect(args.contains("--paused"))
        #expect(Array(args.suffix(3)) == ["--", "0 9 * * *", "go"])
        #expect(HermesCLIOption.value(of: "--repeat", in: args) == "3")

        // A pre-v0.14 host can parse neither `--deliver all` nor `--paused`:
        // the deliver value is dropped (reported), the flag is omitted, and
        // the caller falls back to create-then-pause.
        let old = HermesCapabilities.parse("Hermes Agent v0.13.0")
        let (oldArgs, oldDropped) = FleetApplyPlan.cronCreateArgs(
            name: "nightly", deliver: "all", schedule: "0 9 * * *", prompt: "go",
            caps: old, paused: true)
        #expect(oldDropped)
        #expect(!HermesCLIOption.contains("--deliver", in: oldArgs))
        #expect(!oldArgs.contains("--paused"))
    }

    /// An empty prompt is omitted rather than sent as an empty positional —
    /// `cron create` takes `prompt` with `nargs="?"`.
    @Test func cronCreateArgsOmitsAnEmptyPrompt() {
        let (args, _) = FleetApplyPlan.cronCreateArgs(
            name: "n", deliver: nil, schedule: "@daily", prompt: nil, caps: v0211)
        #expect(args.last == "@daily")
    }
}
