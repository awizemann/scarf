import Testing
import Foundation
@testable import ScarfCore

/// Release blocker 4, the ScarfCore half — `SkillsViewModel` (install /
/// uninstall) and `ProjectSkillsViewModel` (trust / untrust) each reached a
/// two-way `if` on an `.unconfirmed` verdict. The app-target half of this
/// suite (`mcp remove`, `tools enable|disable`, `pairing approve|revoke`)
/// lives in `scarf/scarfTests/HermesReleaseBlockerVerdictTests.swift`.
///
/// P54b's invariant: `.unconfirmed` is gated on the CONFIDENCE ALONE, never
/// on whether there is a line to quote. `HermesCLIVerdict.judge` still fills
/// `detail` with `lines.last` on that arm wherever `fallbackDetail` is on, so
/// a two-way `outcome.detail ?? "<verb> failed"` reaches the honest sentence
/// only when the output was EMPTY. Every test here drives a NON-EMPTY
/// unconfirmed output; an empty one passes against the old code and proves
/// nothing.
@Suite("Unconfirmed skills verdicts get their own sentence, not a failure")
struct UnconfirmedSkillsVerdictArmTests {

    private static let noisySilence = """
    Loading configuration…
    Done.
    """

    private static let neutralSuffix = "printed no result. Check the host."

    private func expectNeutral(
        _ summary: String,
        verb: String,
        notClaiming refusal: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(summary == "\(verb) \(Self.neutralSuffix)",
                "expected the neutral sentence for \(verb), got: \(summary)",
                sourceLocation: sourceLocation)
        #expect(!summary.contains(refusal),
                "the summary asserts a refusal Hermes never made: \(summary)",
                sourceLocation: sourceLocation)
        #expect(!summary.contains("Done."),
                "the run's unrelated tail line is being quoted as the reason: \(summary)",
                sourceLocation: sourceLocation)
    }

    // MARK: - 3 + 4. skills install / uninstall

    @Test("SkillsViewModel: a noisy exit-0 install is not called a failure")
    func skillsInstall() {
        let outcome = SkillsViewModel.installOutcome(exitCode: 0, output: Self.noisySilence)
        #expect(outcome.confidence == .unconfirmed)
        expectNeutral(SkillsViewModel.installFailureSummary(outcome: outcome),
                      verb: "hermes skills install", notClaiming: "Install failed")
    }

    @Test("SkillsViewModel: a noisy exit-0 uninstall neither fails nor quotes exit 0")
    func skillsUninstall() {
        let outcome = SkillsViewModel.uninstallOutcome(exitCode: 0, output: Self.noisySilence)
        #expect(outcome.confidence == .unconfirmed)
        let summary = SkillsViewModel.uninstallFailureSummary(outcome: outcome, exitCode: 0)
        expectNeutral(summary, verb: "hermes skills uninstall", notClaiming: "Uninstall failed")
        // The verdict reaches `.unconfirmed` only at exit 0, so the old
        // "(exit 0)" tail quoted a number the verdict had already declared
        // meaningless, beside a claim of failure.
        #expect(!summary.contains("exit 0"), "the meaningless exit code is still quoted: \(summary)")
    }

    // MARK: - 5. skills trust / untrust

    @Test("ProjectSkillsViewModel: a noisy exit-0 trust change is not called a failure",
          arguments: [true, false])
    func skillsTrust(trusted: Bool) {
        let outcome = HermesSkillsTrust.judge(output: Self.noisySilence, exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        expectNeutral(
            ProjectSkillsViewModel.trustFailureSummary(trusted: trusted, outcome: outcome),
            verb: trusted ? "hermes skills trust" : "hermes skills untrust",
            notClaiming: trusted ? "Trust failed" : "Untrust failed"
        )
    }
}
