import Testing
import Foundation
@testable import scarf
import ScarfCore

/// S7 (Hermes v0.21.6 … v0.22.5 parity) — the Mac-side halves:
/// `HermesV0216CLIFixesTests` holds the ScarfCore verdicts.
@Suite struct HermesV0216CLIFixesAppTests {

    // MARK: - Cron duplicate: `--interpreter`

    /// `cron create --interpreter` (`hermes_cli/subcommands/cron.py:80` @
    /// v0.21.6) is an option, so it precedes the end-of-options marker.
    @Test func createCarriesInterpreterBeforeEndOfOptions() throws {
        let args = CronViewModel.createJobArguments(
            schedule: "0 9 * * *", prompt: "", name: "n", deliver: "", skills: [],
            script: "report.py", repeatCount: "", interpreter: "~/venvs/r/bin/python")
        let flag = try #require(args.firstIndex(of: "--interpreter=~/venvs/r/bin/python"))
        let end = try #require(args.firstIndex(of: "--"))
        #expect(flag < end)
        let plain = CronViewModel.createJobArguments(
            schedule: "0 9 * * *", prompt: "p", name: "n", deliver: "", skills: [],
            script: "", repeatCount: "")
        #expect(!plain.contains { $0.hasPrefix("--interpreter") })
    }

    // MARK: - Health: v0.22.0 "Newer than stable release"

    /// `_startup_fast.py:231-232` @ v0.22.5 — ahead of stable is a known,
    /// no-update status, not "update status unknown".
    @Test func newerThanStableIsKnownAndNotAnUpdate() {
        let status = HealthViewModel.parseUpdateStatus(lines: [
            "Hermes Agent v0.22.5 (2026.10.22)",
            "Newer than stable release v0.22.4 — 'hermes update' moves back to it",
        ])
        #expect(!status.hasUpdate)
        #expect(!status.unknown)
        #expect(status.hasUpdateStatusSection)
    }
}
