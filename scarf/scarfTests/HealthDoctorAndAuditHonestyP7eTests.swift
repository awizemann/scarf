import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P7e items 3 and 4: `hermes doctor` and `hermes security audit` must not
/// claim more than Hermes actually printed.
@Suite struct HealthDoctorAndAuditHonestyP7eTests {

    // MARK: - item 3: doctor completeness

    /// `run_doctor` returns `int(bool(total.issues or total.manual_issues))`
    /// (`hermes_cli/doctor.py:188` @ v2026.9.24) — 1 means findings, same
    /// three-state shape as `security audit` — so a normal run with real
    /// findings (ending in `_print_summary`'s block, `:153-159`) parses
    /// sections and must NOT get the "did not complete" row.
    @Test func normalRunWithSectionsIsUnchanged() {
        let output = """
        ◆ Configuration
        ✓ model: gpt-5
        ⚠ api key: using env var fallback

        ────────────────────────────────────────────────────────────
          Found 1 issue(s) to address:

          1. api key: using env var fallback

          Tip: run 'hermes doctor --fix' to auto-fix what's possible.
        """
        let sections = HealthViewModel.doctorSections(output: output, exitCode: 1)
        #expect(sections.count == 1)
        #expect(sections[0].title == "Configuration")
        #expect(!sections.contains { $0.title == "Doctor" })
    }

    /// The regression this item exists to fix: nothing crashed the DOCTOR_CHECKS
    /// loop wraps no `warn_on_error` around it (`doctor.py:174-176`), so an
    /// uncaught exception prints a bare Python traceback and exits non-zero
    /// with zero `◆` sections ever printed.
    @Test func zeroSectionsAddsADidNotCompleteRow() {
        let output = """
        Traceback (most recent call last):
          File "hermes_cli/doctor.py", line 176, in run_doctor
            total.merge(check(should_fix))
        KeyError: 'model'
        """
        let sections = HealthViewModel.doctorSections(output: output, exitCode: 1)
        #expect(sections.count == 1)
        #expect(sections[0].title == "Doctor")
        #expect(sections[0].checks.first?.status == .error)
    }

    /// A timeout (`runHermesCLI`'s `-1` sentinel) always adds the row, even
    /// when some sections DID parse before the host stopped responding —
    /// partial output is still not "doctor completed".
    @Test func timeoutAddsTheRowEvenWithPartialSections() {
        let output = "◆ Configuration\n✓ model: gpt-5\nCommand timed out after 120s."
        let sections = HealthViewModel.doctorSections(output: output, exitCode: -1)
        #expect(sections.count == 2)
        #expect(sections.last?.title == "Doctor")
        #expect(sections.last?.checks.first?.label == "Doctor timed out")
    }

    // MARK: - P9 (t-d6384e2e item 3): completion needs the summary line

    /// A check that raises MID-run: the `DOCTOR_CHECKS` loop
    /// (`doctor.py:179-182` @ v2026.9.24) has no per-check guard, so the
    /// earlier sections are already on stdout when the traceback lands and
    /// the exit is 1 — identical to a clean run with findings. Before P9
    /// the parsed sections alone read as a complete report.
    @Test func midRunCrashWithPartialSectionsAddsTheRow() {
        let output = """
        ◆ Security Advisories
        ✓ No active advisories
        ◆ Python Environment
        ✓ Python 3.12.4
        Traceback (most recent call last):
          File "hermes_cli/doctor.py", line 182, in run_doctor
            total.merge(check(should_fix))
        OSError: [Errno 24] Too many open files
        """
        let sections = HealthViewModel.doctorSections(output: output, exitCode: 1)
        #expect(sections.count == 3)
        #expect(sections.last?.title == "Doctor")
        #expect(sections.last?.checks.first?.label == "Doctor did not complete")
        #expect(sections.last?.checks.first?.status == .error)
    }

    /// Each of `_print_summary`'s three closing lines (`doctor.py:142-163`,
    /// literals verbatim) proves completion, whatever the exit code.
    @Test(arguments: [
        ("  All checks passed! 🎉", Int32(0)),
        ("  Found 2 issue(s) to address:", Int32(1)),
        ("  Fixed 3 issue(s). 1 issue(s) require manual intervention.", Int32(1)),
    ])
    func eachSummaryLineProvesCompletion(_ summary: String, exitCode: Int32) {
        let rule = String(repeating: "─", count: 60)
        let output = "◆ Configuration\n✓ model: gpt-5\n\n\(rule)\n\(summary)\n"
        let sections = HealthViewModel.doctorSections(output: output, exitCode: exitCode)
        #expect(sections.count == 1)
        #expect(!sections.contains { $0.title == "Doctor" })
    }

    /// `-1` is `runHermesCLI`'s sentinel for EVERY non-exit: a missing local
    /// binary (empty output) or a non-timeout transport error must not be
    /// labelled "timed out".
    @Test(arguments: ["", "Can't reach host.example. Check the hostname, network, and SSH config."])
    func nonTimeoutSpawnFailureIsNotLabelledATimeout(_ output: String) {
        let sections = HealthViewModel.doctorSections(output: output, exitCode: -1)
        #expect(sections.last?.title == "Doctor")
        #expect(sections.last?.checks.first?.label == "Doctor could not run")
    }

    /// The exact bug named in the audit: a bare `Key: value`-shaped line
    /// from a traceback (`KeyError: 'model'`) must not be recorded as a
    /// passing check inside `parseOutputStatic`'s generic fallback.
    @Test func exceptionLinesInsideASectionDoNotCountAsPassing() {
        let output = """
        ◆ Configuration
        ✓ model: gpt-5
        KeyError: 'provider'
        """
        let sections = HealthViewModel.parseOutputStatic(output)
        #expect(sections.count == 1)
        #expect(sections[0].checks.count == 1)
        #expect(sections[0].checks[0].label == "model")
    }

    /// A real Hermes check-echo line keeps working — the guard is specific
    /// to exception-class-shaped keys, not every bare `Key: value` line.
    @Test func realKeyValueLinesStillParse() {
        let output = """
        ◆ Configuration
        Provider: openai
        """
        let sections = HealthViewModel.parseOutputStatic(output)
        #expect(sections[0].checks.first?.label == "Provider")
        #expect(sections[0].checks.first?.detail == "openai")
    }

    // MARK: - item 4: security audit "Advisories found" requires a parsed count

    /// `cmd_security_audit` returns 1 ONLY from `int(any(severity >=
    /// threshold for f in findings))` (`security_audit.py:311-312`) — every
    /// other path is `return 2` (:293, :307). An exit 1 whose output does
    /// not carry `_render_human`'s `Found N …` head is unexplained by
    /// anything in that function, so it must be judged like `.failed`,
    /// never "Advisories found" (which would invent a report Hermes never
    /// printed).
    @Test func findingsRequireAParseableCount() {
        #expect(HermesSecurityAuditReport.parse("garbled or truncated output").findingCount == 0)
    }

    @Test func realFindingsHeadParses() {
        let output = "Found 2 known vulnerability finding(s) across 5 component(s):\n[pip]\n  HIGH  requests==2.1  GHSA-xxxx"
        #expect(HermesSecurityAuditReport.parse(output).findingCount == 2)
    }
}
