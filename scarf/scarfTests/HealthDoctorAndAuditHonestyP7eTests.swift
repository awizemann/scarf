import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P7e items 3 and 4: `hermes doctor` and `hermes security audit` must not
/// claim more than Hermes actually printed.
@Suite struct HealthDoctorAndAuditHonestyP7eTests {

    // MARK: - item 3: doctor completeness

    /// `run_doctor` returns `int(bool(total.issues or total.manual_issues))`
    /// (`hermes_cli/doctor.py:181` @ v2026.9.24) — 1 means findings, same
    /// three-state shape as `security audit` — so a normal run with real
    /// findings parses sections and must NOT get the "did not complete" row.
    @Test func normalRunWithSectionsIsUnchanged() {
        let output = """
        ◆ Configuration
        ✓ model: gpt-5
        ⚠ api key: using env var fallback
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
        let output = "◆ Configuration\n✓ model: gpt-5\n"
        let sections = HealthViewModel.doctorSections(output: output, exitCode: -1)
        #expect(sections.count == 2)
        #expect(sections.last?.title == "Doctor")
        #expect(sections.last?.checks.first?.label == "Doctor timed out")
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
