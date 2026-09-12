import Testing
import Foundation
@testable import ScarfCore

/// P17 — remediation of the cross-phase fresh-eyes review over
/// `fix/whole-surface-audit`. Each test here fails without its fix.
@Suite("P17 cross-phase remediation")
struct HermesP17RemediationTests {

    // MARK: - Finding 5 — the false-default boolish sweep

    /// config.yaml is loaded by **PyYAML**, so `yes` / `on` / `no` / `off`
    /// are already Python bools and `1` / `0` are truthy/falsy ints before
    /// ANY Hermes reader sees them (`hermes_cli/config.py::_load_config_impl`
    /// at v2026.9.7 → `yaml.safe_load`). The coercion is in the LOADER, not
    /// the per-key reader, so it applies to every boolean key whatever module
    /// reads it — which is why a literal `== "true"` compare in Scarf read
    /// `compact: yes` as OFF while the host had it ON.
    ///
    /// P13 fixed the true-default direction and two keys; this covers the
    /// remaining false-default readers across every settings section.
    @Test(arguments: [
        "display.compact", "display.bell_on_complete", "display.timestamps",
        "display.show_cost", "display.streaming",
        "network.force_ipv4", "privacy.redact_pii",
        "telemetry.shared_metrics.enabled", "browser.record_sessions",
        "platforms.telegram.extra.status_indicator",
        "platforms.signal.extra.require_mention",
        "secrets.bitwarden.enabled", "delegation.independent_completions",
    ])
    func falseDefaultBooleansReadYAMLTruthyWordsAsOn(key: String) {
        for truthy in ["yes", "on", "1", "True", "true  # for now", "\"yes\""] {
            let config = HermesConfig(yaml: yamlLine(key: key, value: truthy))
            #expect(
                Self.flag(config, forKey: key) == true,
                "\(key): `\(truthy)` must read as ON — PyYAML hands Hermes a truthy value"
            )
        }
        for falsy in ["no", "off", "0", "False", "false  # for now"] {
            let config = HermesConfig(yaml: yamlLine(key: key, value: falsy))
            #expect(
                Self.flag(config, forKey: key) == false,
                "\(key): `\(falsy)` must read as OFF"
            )
        }
        // Absent stays at the false default for every key in this list.
        #expect(Self.flag(HermesConfig(yaml: "model:\n  default: x\n"), forKey: key) == false)
    }

    /// `telegram.require_mention`'s reader is boolish like every other. Its
    /// DEFAULT was P17's deliberate divergence (Scarf said `true`, Hermes's
    /// only reader says `false`) and P20 corrected it — see
    /// `HermesP20ConfigDefaultsTests`. What this test still pins is the
    /// boolish vocabulary.
    @Test func telegramRequireMentionIsBoolish() {
        #expect(HermesConfig(yaml: yamlLine(key: "telegram.require_mention", value: "no")).telegram.requireMention == false)
        #expect(HermesConfig(yaml: yamlLine(key: "telegram.require_mention", value: "yes")).telegram.requireMention == true)
        #expect(HermesConfig(yaml: yamlLine(key: "telegram.require_mention", value: "1")).telegram.requireMention == true)
        #expect(HermesConfig(yaml: yamlLine(key: "telegram.require_mention", value: "off")).telegram.requireMention == false)
    }

    /// The two keys this suite used to sweep as FALSE-default and P20 moved:
    /// `memory.memory_enabled` is `True` in the schema at every supported tag,
    /// and `display.show_reasoning` became a sentinel (its shipped default
    /// flipped at v0.18.1). Both keep the boolish reader.
    @Test func showReasoningAndMemoryEnabledStayBoolish() {
        for truthy in ["yes", "on", "1", "True", "true  # for now", "\"yes\""] {
            #expect(HermesConfig(yaml: yamlLine(key: "display.show_reasoning", value: truthy)).showReasoning == true)
            #expect(HermesConfig(yaml: yamlLine(key: "memory.memory_enabled", value: truthy)).memoryEnabled == true)
        }
        for falsy in ["no", "off", "0", "False", "false  # for now"] {
            #expect(HermesConfig(yaml: yamlLine(key: "display.show_reasoning", value: falsy)).showReasoning == false)
            #expect(HermesConfig(yaml: yamlLine(key: "memory.memory_enabled", value: falsy)).memoryEnabled == false)
        }
    }

    /// Build a config.yaml carrying exactly one dotted key.
    private func yamlLine(key: String, value: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        var out = ""
        for (depth, part) in parts.enumerated() {
            let indent = String(repeating: "  ", count: depth)
            out += depth == parts.count - 1
                ? "\(indent)\(part): \(value)\n"
                : "\(indent)\(part):\n"
        }
        return out
    }

    private static func flag(_ c: HermesConfig, forKey key: String) -> Bool {
        switch key {
        case "display.compact": return c.display.compact
        case "display.bell_on_complete": return c.display.bellOnComplete
        case "display.timestamps": return c.display.timestamps
        case "display.show_cost": return c.showCost
        case "display.streaming": return c.streaming
        case "network.force_ipv4": return c.forceIPv4
        case "privacy.redact_pii": return c.security.redactPII
        case "telemetry.shared_metrics.enabled": return c.telemetry.sharedMetricsEnabled
        case "browser.record_sessions": return c.browser.recordSessions
        case "platforms.telegram.extra.status_indicator": return c.telegram.statusIndicator
        case "platforms.signal.extra.require_mention": return c.signal.requireMention
        case "secrets.bitwarden.enabled": return c.bitwarden.enabled
        case "delegation.independent_completions": return c.delegation.independentCompletions
        default:
            Issue.record("unmapped key \(key)")
            return false
        }
    }

    // MARK: - Finding 8 — cron doctor: a traceback may not become a job header

    /// `cron_doctor` (`hermes_cli/cron.py:517-536` at v2026.9.7) prints ONE
    /// header shape, `  {id} {name}` at indent 2, and issues as
    /// `    - {issue}` at indent 4. `last run failed: {last_error}` embeds
    /// the stored error VERBATIM, so a multi-line Python traceback lands in
    /// the middle of a job's issue list carrying its own indentation —
    /// including `  File "…"` at exactly the header's indent.
    ///
    /// The roster branch (`knownIDPrefix`) runs BEFORE the shape heuristic,
    /// so this pins that ordering: a known id is strictly stronger evidence
    /// than "looks like an id", and neither `File` nor `Traceback` may open
    /// a fabricated finding mid-issue.
    @Test func doctorTracebackLinesAtHeaderIndentNeverOpenAFinding() throws {
        let output = """
        Cron doctor found 2 issue(s) across 2 job(s):

          nightly-backup Nightly backup
            - last run failed: Traceback (most recent call last):
          File "/opt/hermes/cron/runner.py", line 88, in _run
            raise RuntimeError("nightly-backup exploded")
        RuntimeError: nightly-backup exploded

          4f2a9c1b7e03 Digest
            - workdir not found: /srv/gone

        Next: fix the listed job config, then run `hermes cron doctor` again.
        """
        let findings = HermesCronDoctorParser.parse(
            text: output, knownJobIDs: ["nightly-backup", "4f2a9c1b7e03"]
        )
        #expect(findings.count == 2)
        #expect(findings["File"] == nil)
        #expect(findings["Traceback"] == nil)
        #expect(findings["RuntimeError:"] == nil)
        let backup = try #require(findings["nightly-backup"])
        #expect(backup.jobName == "Nightly backup")
        // The whole traceback stays attached to the issue it belongs to.
        #expect(backup.issues.count == 1)
        #expect(try #require(backup.issues.first)
            .contains("RuntimeError: nightly-backup exploded"))
        #expect(try #require(findings["4f2a9c1b7e03"]).jobName == "Digest")
    }

    /// The known-id branch itself must not fire on a traceback line: the
    /// match is anchored at the START of the trimmed line and needs a token
    /// boundary, so a path that merely CONTAINS the id does not qualify.
    @Test func knownIDDoesNotMatchInsideATracebackPath() {
        #expect(HermesCronDoctorParser.knownIDPrefix(
            of: "File \"/opt/hermes/jobs/nightly-backup.py\", line 3, in run",
            candidates: ["nightly-backup"]
        ) == nil)
    }

    // MARK: - Finding 7 — the skills-hub status doc names a case that exists

    /// `HermesSkillUpdateStatus` has no `.unknown` member; an unrecognised
    /// status word fails `init(rawValue:)` and the ROW is skipped.
    @Test func unknownSkillUpdateStatusIsDroppedNotDecoded() {
        #expect(HermesSkillUpdateStatus(rawValue: "quantum_pending") == nil)
        #expect(HermesSkillUpdateStatus.allCases.map(\.rawValue).contains("unknown") == false)
        let output = """
        Skill Updates
        │ Name │ Source │ Status │
        │ alpha │ hub │ quantum_pending │
        │ beta │ hub │ update_available │
        """
        let rows = HermesSkillsHubParser.parseUpdateList(output)
        #expect(rows.map(\.identifier) == ["beta"])
    }

    // MARK: - Finding 9 — the legacy singular `skill` field

    /// Scarf reads `cron/jobs.json` DIRECTLY
    /// (`HermesFileService.loadCronJobsOutcome`), so the normalisation
    /// `cron list` applies (`list_jobs` → `_normalize_job_record` →
    /// `_apply_skill_fields`, `cron/jobs.py:1849/456/400` at v2026.9.7)
    /// never runs on that path. A pre-multi-skill job carries ONLY the
    /// singular `skill`, and `cron edit` still resolves its own
    /// `existing_skills` through `_normalize_skill_list` (`:384-397`) — so
    /// reading `skills` alone made Scarf's diff believe the job had none,
    /// emit no `--remove-skill`, and leave a just-unticked skill in place.
    @Test func legacySingularSkillIsNormalisedIntoTheSkillsList() throws {
        let job = try Self.decodeJob("""
        {"id": "j1", "name": "Legacy", "prompt": "p", "skill": "research",
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        // What the diff does with that list is covered in the app target
        // (`CronViewModel.skillEditArguments`); what matters here is that the
        // list is no longer empty.
        #expect(job.skills == ["research"])
    }

    /// `skills` PRESENT wins outright, even when empty — `_normalize_skill_list`
    /// only consults `skill` when `skills is None`.
    @Test func presentSkillsListBeatsTheLegacySingular() throws {
        let job = try Self.decodeJob("""
        {"id": "j1", "name": "n", "prompt": "p", "skill": "research", "skills": [],
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        #expect(job.skills == [])
        let both = try Self.decodeJob("""
        {"id": "j2", "name": "n", "prompt": "p", "skill": "research", "skills": ["writing"],
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        #expect(both.skills == ["writing"])
    }

    /// `skills: null` is `skills is None`, which is the arm that falls back
    /// to `skill` — not an explicit empty list.
    @Test func nullSkillsFallsBackToTheLegacySingular() throws {
        let job = try Self.decodeJob("""
        {"id": "j1", "name": "n", "prompt": "p", "skill": "research", "skills": null,
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        #expect(job.skills == ["research"])
    }

    /// A bare STRING `skills` is a one-element list upstream
    /// (`isinstance(skills, str)`), and must not fail the decode — a throw
    /// here blanks the WHOLE cron board, not one row.
    @Test func bareStringSkillsDecodesAsAOneElementList() throws {
        let job = try Self.decodeJob("""
        {"id": "j1", "name": "n", "prompt": "p", "skills": "research",
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        #expect(job.skills == ["research"])
    }

    /// Trim, drop blanks, de-duplicate preserving order — the rest of
    /// `_normalize_skill_list`.
    @Test func skillListIsTrimmedDedupedAndOrderPreserving() throws {
        let job = try Self.decodeJob("""
        {"id": "j1", "name": "n", "prompt": "p",
         "skills": ["  writing ", "", "research", "writing"],
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        #expect(job.skills == ["writing", "research"])
    }

    /// No skill key at ALL stays `nil` — distinct from an explicit empty
    /// list, which is what lets the editor tell "untouched" from "cleared".
    @Test func noSkillKeyAtAllStaysNil() throws {
        let job = try Self.decodeJob("""
        {"id": "j1", "name": "n", "prompt": "p",
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        #expect(job.skills == nil)
    }

    /// The legacy key must survive a round trip: it is swept into `extra`
    /// rather than listed in `CodingKeys`, so re-encoding a job Scarf read
    /// does not silently strip it.
    @Test func legacySkillKeyRoundTripsThroughExtra() throws {
        let job = try Self.decodeJob("""
        {"id": "j1", "name": "n", "prompt": "p", "skill": "research",
         "schedule": {"kind": "interval", "minutes": 60}}
        """)
        let data = try JSONEncoder().encode(job)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["skill"] as? String == "research")
    }

    private static func decodeJob(_ json: String) throws -> HermesCronJob {
        try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }
}
