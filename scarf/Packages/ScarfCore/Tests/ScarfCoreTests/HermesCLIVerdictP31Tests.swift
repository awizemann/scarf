import Testing
import Foundation
@testable import ScarfCore

/// Phase P31 of the round-3 whole-surface audit: the two `pairing` verbs that
/// were judged by exit code, and the `skills update` failure detail that was
/// poisoned by a warning `do_install` prints on every single update.
///
/// Every fixture is VERBATIM emitter text — the exact bytes `print()` /
/// `Console.print` produce at tag **v2026.9.7**
/// (`git -C ~/.hermes/hermes-agent show v2026.9.7:hermes_cli/pairing.py`,
/// `…:hermes_cli/skills_hub.py`), with only the interpolated user/platform/
/// path values filled in. Rich markup (`[bold red]…[/]`) is stripped by Rich
/// itself when stdout is not a TTY, which is always the case for Scarf.
@Suite("Hermes CLI verdicts — P31 pairing and skills update")
struct HermesCLIVerdictP31Tests {

    // MARK: - pairing revoke

    /// `_cmd_revoke` (pairing.py:84-90): success prints
    /// `\n  Revoked access for user {user_id} on {platform}.\n`.
    @Test func aRevokeHermesPerformedIsASuccess() {
        let outcome = HermesPairingVerdict.revoke(output: """

          Revoked access for user 987654321 on telegram.

        """, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.detail == nil)
    }

    /// The whole finding: `store.revoke` returned falsey, so Hermes printed
    /// its refusal — and returned `None`, i.e. exit 0. Judging by the exit
    /// code called this a success and the row was removed from the list.
    @Test func aRefusedRevokeIsAFailureAtExitZero() {
        let outcome = HermesPairingVerdict.revoke(output: """

          User 987654321 not found in approved list for telegram.

        """, exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail == "User 987654321 not found in approved list for telegram.")
    }

    /// C5's own rule: exit 0 with neither line is not a success. `pairing`
    /// with an unknown action prints the usage banner and returns `None`
    /// (pairing.py:15-17).
    @Test func revokeWithNeitherLineIsNotASuccess() {
        let outcome = HermesPairingVerdict.revoke(output: """
        Usage: hermes pairing {list|approve|revoke|clear-pending}
        Run 'hermes pairing --help' for details.
        """, exitCode: 0)
        #expect(outcome.succeeded == false)
        // `fallbackDetail` is off: the last line here is a hint, not a reason.
        #expect(outcome.detail == nil)
    }

    // MARK: - pairing approve

    /// `_cmd_approve`'s success arm (pairing.py:68-69). The success line is
    /// indented two spaces, which is why the marker is anchored only after
    /// the trim `significantLines` already does.
    @Test func anApproveHermesPerformedIsASuccess() {
        let outcome = HermesPairingVerdict.approve(output: """

          Approved! User Ada Lovelace (987654321) on telegram can now use the bot~
          They'll be recognized automatically on their next message.

        """, exitCode: 0)
        #expect(outcome.succeeded)
    }

    /// The unknown/expired arm (pairing.py:80-81) — exit 0, and Scarf used to
    /// post no message at all.
    @Test func anExpiredCodeIsAFailureQuotingHermesVerbatim() {
        let outcome = HermesPairingVerdict.approve(output: """

          Pairing request or code 'ABC123' not found or expired for platform 'telegram'.
          Run 'hermes pairing list' to see pending requests.

        """, exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(
            outcome.detail
                == "Pairing request or code 'ABC123' not found or expired for platform 'telegram'."
        )
    }

    /// The same arm's pre-v2026.8.3 wording (`Code '<code>' not found or
    /// expired…`, v2026.6.19:95). The marker is the tail both spellings
    /// share, so an older host is judged identically (C1).
    @Test func theOlderExpiredCodeWordingIsJudgedTheSameWay() {
        let outcome = HermesPairingVerdict.approve(output: """

          Code 'ABC123' not found or expired for platform 'telegram'.
          Run 'hermes pairing list' to see pending codes.

        """, exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail == "Code 'ABC123' not found or expired for platform 'telegram'.")
    }

    /// Decision 3: the lockout's countdown is quoted VERBATIM alongside the
    /// refusal. It is a second printed line (pairing.py:77), so a verdict that
    /// quotes only the marker line leaves the operator without the one piece
    /// of information that tells them what to do — wait.
    @Test func theLockoutRefusalCarriesItsCountdownVerbatim() {
        let outcome = HermesPairingVerdict.approve(output: """

          Platform 'telegram' is locked out after too many failed approval attempts.
          Lockout clears in ~12 minute(s).
          To reset sooner, delete the '_lockout:telegram' entry from ~/.hermes/platforms/pairing/_rate_limits.json

        """, exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(
            outcome.detail
                == "Platform 'telegram' is locked out after too many failed approval attempts. "
                + "Lockout clears in ~12 minute(s)."
        )
    }

    /// A host below v2026.5.7 has no lockout branch at all, so the only two
    /// shapes it can print are the ones above — and a `0 minute(s)` countdown
    /// must still be quoted rather than dropped as falsey.
    @Test func aZeroMinuteCountdownIsStillQuoted() {
        let outcome = HermesPairingVerdict.approve(output: """

          Platform 'discord' is locked out after too many failed approval attempts.
          Lockout clears in ~0 minute(s).

        """, exitCode: 0)
        #expect(outcome.detail?.hasSuffix("Lockout clears in ~0 minute(s).") == true)
    }

    /// ANSI is stripped before anchoring — a `FORCE_COLOR` environment (or an
    /// SSH wrapper that sets one) must not turn a success into a failure.
    @Test func colouredOutputIsStillJudgedCorrectly() {
        let esc = "\u{1B}"
        let outcome = HermesPairingVerdict.approve(
            output: "\n  \(esc)[32mApproved! User 987654321 on slack can now use the bot~\(esc)[0m\n",
            exitCode: 0
        )
        #expect(outcome.succeeded)
    }

    /// A nonzero exit is still a failure, whatever was printed.
    @Test func aNonZeroExitIsAFailureEvenWithASuccessLine() {
        let outcome = HermesPairingVerdict.approve(output: """
          Approved! User 987654321 on telegram can now use the bot~
        """, exitCode: 2)
        #expect(outcome.succeeded == false)
    }

    // MARK: - skills update failure detail

    /// The P21 regression. `do_update` calls `do_install(..., force=True)`
    /// (hermes_cli/skills_hub.py:868) and `do_install` prints
    /// `Warning: '<name>' is already installed at <path>` (:682)
    /// unconditionally — the lock ALWAYS has an entry for a skill being
    /// updated — before it checks `force` at :683. With that string in the
    /// failure set and `failureDetail` taking the FIRST match, every real
    /// refusal was reported as the warning.
    ///
    /// The P21 fixtures omitted the warning line entirely, so they asserted on
    /// output the emitter cannot produce.
    @Test func aBlockedUpdateQuotesTheBlockNotTheAlwaysPrintedWarning() {
        let report = HermesSkillsHubParser.parseUpdateReport("""
        Updating: reddit
        Warning: 'reddit' is already installed at research/reddit
        Quarantined to quarantine/reddit-a1b2c3
        Installation blocked: dangerous verdict (3 findings)
        Updated 1 skill(s).
        """)
        #expect(report.attemptedCount == 1)
        #expect(report.installedCount == 0)
        #expect(report.failureDetail == "Installation blocked: dangerous verdict (3 findings)")
    }

    /// An update that WORKED prints the same warning. It must leave no
    /// failure detail behind at all — a successful update that carries a
    /// quotable "reason" is one bad branch away from being rendered.
    @Test func aSucceedingUpdateHasNoFailureDetailDespiteTheWarning() {
        let report = HermesSkillsHubParser.parseUpdateReport("""
        Updating: reddit
        Warning: 'reddit' is already installed at research/reddit
        Quarantined to quarantine/reddit-a1b2c3
        Installed: research/reddit
        Files: SKILL.md, scripts/fetch.py
        Updated 1 skill(s).
        """)
        #expect(report.installedCount == 1)
        #expect(report.failureDetail == nil)
    }

    /// The suppression is scoped to the update path. A plain `skills install`
    /// of an already-installed skill is refused by exactly that pair of lines
    /// (:682, :684), so they stay load-bearing in `skillsInstallFailure`.
    @Test func thePlainInstallPathStillRefusesOnTheAlreadyInstalledPair() {
        #expect(HermesCLIMarkers.skillsInstallFailure.contains("is already installed at"))
        #expect(HermesCLIMarkers.skillsInstallFailure.contains("Use --force to reinstall."))
        #expect(HermesCLIMarkers.skillsUpdateFailure.contains("is already installed at") == false)
        #expect(HermesCLIMarkers.skillsUpdateFailure.contains("Use --force to reinstall.") == false)
        // Everything else survives — the update set is a subtraction, not a
        // rewrite, so a new install refusal is picked up by both.
        #expect(HermesCLIMarkers.skillsUpdateFailure.contains("Installation blocked:"))
        #expect(HermesCLIMarkers.skillsUpdateFailure.count == HermesCLIMarkers.skillsInstallFailure.count - 2)
    }

    // MARK: - argv: `--` before every user-supplied positional

    /// `skills update` takes `name` (`nargs="?"`) and `--force`
    /// (`hermes_cli/subcommands/skills.py:79-83` @ v2026.9.7). The flag has to
    /// precede the `--`: argparse reads everything after the first `--` as a
    /// positional, so `skills update -- reddit --force` exits 2 with
    /// `unrecognized arguments: --force`.
    @Test func forceUpdateArgsEndOptionsBeforeTheSkillName() {
        #expect(SkillsViewModel.forceUpdateArgs("reddit") == ["skills", "update", "--force", "--", "reddit"])
        let args = SkillsViewModel.forceUpdateArgs("-weird-name")
        #expect(args.last == "-weird-name")
        #expect(args.firstIndex(of: "--")! < args.count - 1)
        #expect(args.firstIndex(of: "--force")! < args.firstIndex(of: "--")!)
    }
}
