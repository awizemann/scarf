import Testing
import Foundation
@testable import ScarfCore

/// W7 of the Hermes v0.21.0 parity cycle — the cron surfaces.
///
/// Everything here is pinned against real Hermes source at the audited
/// tag: `cron/jobs.py` (`load_jobs`, `normalize_repeat_value`,
/// `is_terminal_job`), `hermes_cli/cron.py` (`cron_incidents`,
/// `cron_doctor`, `cron_runs`) and `hermes_cli/subcommands/cron.py`
/// (the argparse surface). Fixtures are the exact bytes those printers
/// emit with color disabled — which is always, for Scarf's piped runs
/// (`hermes_cli/colors.py::should_use_color` requires a tty).
@Suite struct HermesV021CronParityTests {

    // MARK: - jobs.json decoder liberalization (item 1)

    private func decodeFile(_ json: String) throws -> CronJobsFile {
        try JSONDecoder().decode(CronJobsFile.self, from: Data(json.utf8))
    }

    private static let minimalJob = """
        {"id":"j1","name":"One","prompt":"p","enabled":true,"state":"scheduled",
         "schedule":{"kind":"interval","minutes":30}}
        """

    @Test func decodesCanonicalJobsArray() throws {
        let file = try decodeFile("""
            {"jobs":[\(Self.minimalJob)],"updated_at":"2026-08-31T00:00:00"}
            """)
        #expect(file.jobs.map(\.id) == ["j1"])
        #expect(file.updatedAt == "2026-08-31T00:00:00")
    }

    /// `load_jobs` flattens `{"jobs": {"<id>": {...}}}` with
    /// `{**v, "id": v.get("id") or k}` — the inline id wins, otherwise
    /// the map key is adopted.
    @Test func decodesIDKeyedJobsMap() throws {
        let file = try decodeFile("""
            {"jobs":{
              "key-a":{"name":"A","prompt":"p","enabled":true,"state":"scheduled",
                       "schedule":{"kind":"interval","minutes":5}},
              "key-b":{"id":"inline-b","name":"B","prompt":"p","enabled":false,"state":"paused",
                       "schedule":{"kind":"cron","expr":"0 9 * * *"}}
            }}
            """)
        // Ordered by MAP KEY (not by resolved id) so the board doesn't
        // shuffle between reloads of an unordered JSON object.
        #expect(file.jobs.map(\.id) == ["key-a", "inline-b"])
        #expect(file.jobs.map(\.name) == ["A", "B"])
        #expect(file.jobs[1].enabled == false)
    }

    /// Non-dict values in the id-keyed map are junk Hermes skips with a
    /// warning; Scarf must not let one blank the board.
    @Test func idKeyedMapSkipsNonObjectEntries() throws {
        let file = try decodeFile("""
            {"jobs":{
              "junk": "not-a-job",
              "ok":{"name":"OK","prompt":"p","enabled":true,"state":"scheduled",
                    "schedule":{"kind":"interval","minutes":5}}
            }}
            """)
        #expect(file.jobs.map(\.id) == ["ok"])
    }

    /// A `jobs` array carrying one undecodable job must still surface as
    /// an ARRAY decode failure, not get mis-diagnosed as an id-keyed map.
    @Test func arrayWithABadJobRethrowsTheArrayError() {
        #expect(throws: DecodingError.self) {
            _ = try decodeFile("""
                {"jobs":[{"name":"no id or enabled","schedule":{"kind":"interval"}}]}
                """)
        }
    }

    /// Bare top-level array — `load_jobs` wraps it back into
    /// `{"jobs": [...]}` on the next save.
    @Test func decodesBareTopLevelArray() throws {
        let file = try decodeFile("[\(Self.minimalJob)]")
        #expect(file.jobs.map(\.id) == ["j1"])
        #expect(file.updatedAt == nil)
    }

    // MARK: - repeat normalization (item 1, `normalize_repeat_value`)

    @Test(arguments: [
        ("\"forever\"", nil), ("\"INFINITE\"", nil), ("\"inf\"", nil),
        ("\"none\"", nil), ("\"\"", nil),
        ("\"once\"", 1), ("\"one\"", 1), ("\"1x\"", 1),
        ("\"7\"", 7), ("3", 3), ("0", nil), ("-4", nil),
        ("\"bogus\"", nil), ("null", nil),
    ] as [(String, Int?)])
    func normalizesBareRepeatValues(raw: String, expected: Int?) throws {
        let file = try decodeFile("""
            {"jobs":[{"id":"j","name":"n","prompt":"p","enabled":true,"state":"scheduled",
              "schedule":{"kind":"interval","minutes":5},"repeat":\(raw)}]}
            """)
        #expect(file.jobs[0].repeatSpec.times == expected)
        #expect(file.jobs[0].repeatSpec.completed == 0)
    }

    @Test func normalizesObjectRepeatValue() throws {
        let file = try decodeFile("""
            {"jobs":[{"id":"j","name":"n","prompt":"p","enabled":true,"state":"scheduled",
              "schedule":{"kind":"interval","minutes":5},
              "repeat":{"times":"once","completed":2}}]}
            """)
        #expect(file.jobs[0].repeatSpec.times == 1)
        #expect(file.jobs[0].repeatSpec.completed == 2)
    }

    /// Scarf reads `repeat` through `normalizeRepeatValue` but must NOT
    /// normalize on Hermes's behalf — the raw value round-trips verbatim.
    @Test func bareRepeatSurvivesRoundTrip() throws {
        let file = try decodeFile("""
            {"jobs":[{"id":"j","name":"n","prompt":"p","enabled":true,"state":"scheduled",
              "schedule":{"kind":"interval","minutes":5},"repeat":"forever"}]}
            """)
        let out = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(file.jobs[0])
        ) as? [String: Any]
        #expect(out?["repeat"] as? String == "forever")
    }

    // MARK: - monitor_* / *_snapshot passthrough (item 7)

    @Test func monitorAndSnapshotFieldsSurviveRoundTrip() throws {
        let raw = """
            {"jobs":[{"id":"m1","name":"Monitor","prompt":"p","enabled":true,"state":"scheduled",
              "schedule":{"kind":"interval","minutes":15},
              "monitor_script":"~/.hermes/scripts/check.py",
              "monitor_url":"https://example.test/health",
              "monitor_state":{"last_hash":"abc123","consecutive_failures":2,"seen":["a","b"]},
              "provider_snapshot":"openrouter",
              "model_snapshot":"anthropic/claude-opus-4",
              "run_claim":null}]}
            """
        let file = try decodeFile(raw)
        let job = file.jobs[0]
        // Round-trip through the model, including a state-mutating copy —
        // the pause/resume path is where strips historically happened.
        let encoded = try JSONEncoder().encode(job.withEnabled(false))
        let out = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(out?["monitor_script"] as? String == "~/.hermes/scripts/check.py")
        #expect(out?["monitor_url"] as? String == "https://example.test/health")
        #expect(out?["provider_snapshot"] as? String == "openrouter")
        #expect(out?["model_snapshot"] as? String == "anthropic/claude-opus-4")
        let monitorState = out?["monitor_state"] as? [String: Any]
        #expect(monitorState?["last_hash"] as? String == "abc123")
        #expect(monitorState?["consecutive_failures"] as? Int == 2)
        #expect((monitorState?["seen"] as? [Any])?.count == 2)
        // Explicit nulls are preserved too (absent != null for a re-save).
        #expect(out?.keys.contains("run_claim") == true)
    }

    // MARK: - terminal states (item 2, `is_terminal_job`)

    @Test(arguments: [
        ("completed", true), ("error", true),
        ("scheduled", false), ("running", false), ("paused", false),
    ] as [(String, Bool)])
    func terminalStateDetection(state: String, expected: Bool) throws {
        let file = try decodeFile("""
            {"jobs":[{"id":"j","name":"n","prompt":"p","enabled":false,"state":"\(state)",
              "schedule":{"kind":"interval","minutes":5}}]}
            """)
        #expect(file.jobs[0].isTerminal == expected)
    }

    // MARK: - cron incidents (item 3)

    @Test func incidentsArgvBuilders() {
        #expect(HermesCronIncidentsParser.listArgs() == ["cron", "incidents"])
        #expect(HermesCronIncidentsParser.listArgs(state: "alerted")
                == ["cron", "incidents", "--state", "alerted"])
        // Not in argparse `choices` — forwarding it would fail the whole
        // invocation, so the flag is dropped.
        #expect(HermesCronIncidentsParser.listArgs(state: "reviewed") == ["cron", "incidents"])
        #expect(HermesCronIncidentsParser.ackArgs(incidentID: "inc-9")
                == ["cron", "incidents", "ack", "inc-9"])
    }

    private static let incidentsOutput = """

        ┌─────────────────────────────────────────────────────────────────────────┐
        │                         Cron Failure Incidents                          │
        └─────────────────────────────────────────────────────────────────────────┘

          inc-aaa  detected
            Job:        job-1
            Type:       rate_limit
            First seen: 2026-08-30T09:00:00
            Last seen:  2026-08-31T09:00:00
            Error:      429 rate limit exceeded for provider: openrouter
            Output:     /Users/x/.hermes/cron/output/job-1-2026-08-31.txt

          inc-bbb  closed
            Job:        job-2
            Type:       unknown
            First seen: 2026-08-29T01:00:00
            Last seen:  2026-08-29T02:00:00
            Error:      boom

          2 incident(s)  |  ack one with: hermes cron incidents ack <id>
        """

    @Test func parsesIncidentsListing() {
        let incidents = HermesCronIncidentsParser.parse(text: Self.incidentsOutput)
        #expect(incidents.count == 2)
        let first = incidents[0]
        #expect(first.id == "inc-aaa")
        #expect(first.state == "detected")
        #expect(first.jobID == "job-1")
        #expect(first.failureType == "rate_limit")
        #expect(first.firstSeenAt == "2026-08-30T09:00:00")
        #expect(first.lastSeenAt == "2026-08-31T09:00:00")
        // The error itself contains a colon — only the LABEL colon splits.
        #expect(first.error == "429 rate limit exceeded for provider: openrouter")
        #expect(first.outputFile == "/Users/x/.hermes/cron/output/job-1-2026-08-31.txt")
        #expect(first.isOpen)

        let second = incidents[1]
        #expect(second.id == "inc-bbb")
        #expect(second.outputFile == nil)
        #expect(!second.isOpen)
    }

    @Test func parsesEmptyIncidentsSentinel() {
        #expect(HermesCronIncidentsParser.parse(text: "No cron failure incidents recorded.").isEmpty)
        #expect(HermesCronIncidentsParser.parse(
            text: "No cron failure incidents recorded.\n  (filtered by state 'closed')"
        ).isEmpty)
        #expect(HermesCronIncidentsParser.parse(text: "").isEmpty)
    }

    /// Defensive: a tty-allocating transport (or a future FORCE_COLOR)
    /// would wrap the id/state in SGR codes.
    @Test func stripsANSIFromIncidents() {
        let colored = "\u{1B}[33minc-ccc\u{1B}[0m  \u{1B}[31mdetected\u{1B}[0m\n"
            + "    Job:        job-9\n    Type:       auth\n"
            + "    First seen: t1\n    Last seen:  t2\n    Error:      401\n"
        let incidents = HermesCronIncidentsParser.parse(text: colored)
        #expect(incidents.count == 1)
        #expect(incidents[0].id == "inc-ccc")
        #expect(incidents[0].state == "detected")
        #expect(incidents[0].failureType == "auth")
    }

    // MARK: - cron doctor (item 4)

    @Test func doctorArgv() {
        #expect(HermesCronDoctorParser.args() == ["cron", "doctor"])
    }

    @Test func parsesDoctorFindings() {
        let output = """
            Cron doctor found 3 issue(s) across 2 job(s):

              job-1 Nightly digest
                - last run failed: provider returned 500
                - next_run_at is 3.2h overdue — job is not firing (is the scheduler running?)

              job-2 (unnamed)
                - workdir not found: /gone/away

            Next: fix the listed job config, then run `hermes cron doctor` again.
            """
        let findings = HermesCronDoctorParser.parse(text: output)
        #expect(findings.count == 2)
        #expect(findings["job-1"]?.jobName == "Nightly digest")
        #expect(findings["job-1"]?.issues.count == 2)
        #expect(findings["job-1"]?.issues.first == "last run failed: provider returned 500")
        #expect(findings["job-2"]?.jobName == "(unnamed)")
        #expect(findings["job-2"]?.issues == ["workdir not found: /gone/away"])
    }

    /// **The one that mattered.** `_cron_doctor_issues_for_job` emits
    /// `f"last run failed: {last_error}"`, and for a script job the
    /// scheduler stored `last_error` as `"stderr:\n" + stderr`
    /// (`cron/scheduler.py:4457-4458`) — a whole Python traceback.
    /// `cron.py:674` bullets only the FIRST physical line of that string;
    /// the rest arrive at the traceback's own indentation.
    ///
    /// The old prefix-based parse read every one of those lines as a new
    /// job header, inventing findings keyed `Traceback` / `File` /
    /// `subprocess.CalledProcessError:` and truncating the real issue to
    /// "last run failed: stderr:". This fixture is that output.
    @Test func parsesAMultiLineLastErrorAsOneIssue() {
        let output = """
            Cron doctor found 3 issue(s) across 2 job(s):

              4f2a9c1b7e03 Backup snapshot
                - last run failed: stderr:
            Traceback (most recent call last):
              File "/Users/alan/.hermes/cron/scripts/backup.py", line 41, in <module>
                main()
              File "/Users/alan/.hermes/cron/scripts/backup.py", line 27, in main
                subprocess.run(["restic", "backup", target], check=True)
            subprocess.CalledProcessError: Command '['restic', 'backup', '/srv']' returned non-zero exit status 1.
                - next_run_at is 6.4h overdue — job is not firing (is the scheduler running?)
              9b0d1e5af244 (unnamed)
                - workdir not found: /gone/away

            Next: fix the listed job config, then run `hermes cron doctor` again.
            """
        let findings = HermesCronDoctorParser.parse(text: output)

        // Exactly two jobs — no `Traceback`/`File`/`subprocess…` ghosts.
        #expect(findings.count == 2)
        #expect(Set(findings.keys) == ["4f2a9c1b7e03", "9b0d1e5af244"])

        let backup = findings["4f2a9c1b7e03"]
        #expect(backup?.jobName == "Backup snapshot")
        #expect(backup?.issues.count == 2)
        // The traceback is retained whole, on the issue it belongs to.
        let failure = backup?.issues.first ?? ""
        #expect(failure.hasPrefix("last run failed: stderr:"))
        #expect(failure.contains("Traceback (most recent call last):"))
        #expect(failure.contains("line 27, in main"))
        #expect(failure.hasSuffix("returned non-zero exit status 1."))
        // The bullet AFTER the traceback is still its own issue.
        #expect(backup?.issues.last?.hasPrefix("next_run_at is 6.4h overdue") == true)

        // The job header that follows a multi-line issue is still a header.
        #expect(findings["9b0d1e5af244"]?.jobName == "(unnamed)")
        #expect(findings["9b0d1e5af244"]?.issues == ["workdir not found: /gone/away"])
    }

    /// `cron doctor` exits **1** on the normal "found issues" path, so the
    /// exit code can't tell a real run from a failed invocation. The
    /// sentinel check is what lets `CronViewModel` memoize a success and
    /// retry a failure instead of caching "no findings" forever.
    @Test func doctorOutputIsRecognizableWithoutTheExitCode() {
        #expect(HermesCronDoctorParser.looksLikeDoctorOutput("✓ Cron doctor found no issues\n  Checked 4 active job(s)."))
        #expect(HermesCronDoctorParser.looksLikeDoctorOutput("Cron doctor found 1 issue(s) across 1 job(s):"))
        #expect(HermesCronDoctorParser.looksLikeDoctorOutput("") == false)
        #expect(HermesCronDoctorParser.looksLikeDoctorOutput(
            "usage: hermes cron [-h] ...\nhermes cron: error: argument: invalid choice: 'doctor'") == false)
    }

    @Test func parsesCleanDoctorRun() {
        let output = "✓ Cron doctor found no issues\n  Checked 4 active job(s).\n"
        #expect(HermesCronDoctorParser.parse(text: output).isEmpty)
        #expect(HermesCronDoctorParser.parse(
            text: "✓ Cron doctor found no issues\n  No active jobs configured.\n"
        ).isEmpty)
    }

    // MARK: - supportsCronDeliver (item 6)

    private func caps(_ line: String) -> HermesCapabilities {
        HermesCapabilities.parseLine(line)
    }

    @Test func botChatDeliveryIsVersionGated() {
        let v0205 = caps("Hermes Agent v0.20.5 (2026.8.19)")
        let v0206 = caps("Hermes Agent v0.20.6 (2026.8.27)")
        let v021 = caps("Hermes Agent v0.21.0 (2026.8.31)")

        #expect(v0205.hasCronBotChatDelivery == false)
        #expect(v0206.hasCronBotChatDelivery)

        // The regression this fixes: pre-0.20.6 used to return `true` for
        // everything but `all`, so bot-chat sailed through and killed the
        // whole `cron create` at argparse on the receiving host.
        #expect(v0205.supportsCronDeliver("bot-chat") == false)
        #expect(v0205.supportsCronDeliver("bot-chat:coder") == false)
        #expect(v0206.supportsCronDeliver("bot-chat"))
        #expect(v021.supportsCronDeliver("bot-chat:coder"))

        // Unchanged behaviour for everything else.
        #expect(v0205.supportsCronDeliver(nil))
        #expect(v0205.supportsCronDeliver("discord:general"))
        #expect(v0205.supportsCronDeliver("telegram:123"))
        #expect(v0205.supportsCronDeliver("all"))  // v0.14+ floor, met here
        #expect(caps("Hermes Agent v0.13.0 (2026.5.7)").supportsCronDeliver("all") == false)
        // Not the sentinel — a platform literally named "bot-chatter".
        #expect(v0205.supportsCronDeliver("bot-chatter"))
    }

    @Test func resumeRunNowAndIncidentsAndDoctorFloors() {
        let v0205 = caps("Hermes Agent v0.20.5 (2026.8.19)")
        let v0206 = caps("Hermes Agent v0.20.6 (2026.8.27)")
        let v021 = caps("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(v0205.hasCronResumeRunNow == false)
        #expect(v0206.hasCronResumeRunNow)
        #expect(v0205.hasCronIncidents == false)
        #expect(v0206.hasCronIncidents)
        // Doctor is the one that is genuinely new at v0.21.
        #expect(v0206.hasCronDoctor == false)
        #expect(v021.hasCronDoctor)
    }

    // MARK: - cron runs format is unchanged at v0.21 (item 8)

    /// Byte-for-byte the f-string `hermes_cli/cron.py::cron_runs` prints
    /// at v0.21.0 — identical to v0.20, so `HermesCronRunsParser` needs
    /// no change. This test is the drift alarm.
    @Test func cronRunsFormatUnchangedAtV021() {
        let output = """
            e1  completed  job=job-1  source=scheduler  2026-08-31T09:00:00
            e2  failed     job=job-1  source=manual  2026-08-30T09:00:00
                boom: provider 500
            """
        let runs = HermesCronRunsParser.parse(text: output)
        #expect(runs.count == 2)
        #expect(runs[0].id == "e1")
        #expect(runs[0].status == "completed")
        #expect(runs[0].source == "scheduler")
        #expect(runs[0].claimedAt == "2026-08-31T09:00:00")
        #expect(runs[1].error == "boom: provider 500")
    }
}
