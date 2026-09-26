import Testing
import Foundation
@testable import ScarfCore

/// P7e item 2: `hermes skills check` must be judged by exit code AND
/// Hermes's own closing line — never exit code alone (charter C5). Fixtures
/// are the literal lines from `do_check` (`hermes_cli/skills_hub.py:831-849`
/// @ v2026.9.24): the early return `No hub-installed skills to check.`
/// (:837) when nothing is hub-installed, or
/// `N update(s) available across M checked skill(s)` (:844) after the
/// table. Both are byte-identical back to at least v2026.7.1 (0.18.0), so
/// this needs no capability gate (C1).
@Suite struct SkillsCheckForUpdatesHonestyP7eTests {

    @Test func exitZeroWithTheNoSkillsLineIsComplete() {
        #expect(SkillsViewModel.checkForUpdatesCompleted(
            exitCode: 0, output: "No hub-installed skills to check.\n"))
    }

    @Test func exitZeroWithTheTallyLineIsComplete() {
        let output = """
        ┌──────────┬──────────┬────────────────┐
        │ Name     │ Source   │ Status         │
        ├──────────┼──────────┼────────────────┤
        │ reddit   │ official │ update_available│
        └──────────┴──────────┴────────────────┘
        1 update(s) available across 1 checked skill(s)
        """
        #expect(SkillsViewModel.checkForUpdatesCompleted(exitCode: 0, output: output))
    }

    /// The regression this item exists to fix: a crash (network exception
    /// before either closing line prints) must not be read as "no updates".
    @Test func exitZeroWithNeitherClosingLineIsNotComplete() {
        #expect(!SkillsViewModel.checkForUpdatesCompleted(
            exitCode: 0, output: "Traceback (most recent call last):\nConnectionError: timed out\n"))
    }

    @Test func nonZeroExitIsNeverComplete() {
        #expect(!SkillsViewModel.checkForUpdatesCompleted(
            exitCode: 1, output: "No hub-installed skills to check.\n"))
        #expect(!SkillsViewModel.checkForUpdatesCompleted(exitCode: -1, output: ""))
    }

    @Test func emptyOutputAtExitZeroIsNotComplete() {
        #expect(!SkillsViewModel.checkForUpdatesCompleted(exitCode: 0, output: ""))
    }
}
