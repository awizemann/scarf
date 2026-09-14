import Testing
import Foundation
@testable import ScarfCore

// MARK: - Verbatim fixtures, transcribed from the tagged Hermes source

/// Every string in this enum is what `hermes` PRINTS, reconstructed from the
/// `print(...)` calls at `v2026.9.7` in `~/.hermes/hermes-agent` (charter
/// C2). Each block names the emitting `file:line`, so a future tag walk can
/// re-open the exact call rather than trusting this file.
///
/// These are the drift alarms: if Hermes rewords a line, the fixture stops
/// matching the marker and the suite fails HERE rather than in a user's
/// Settings pane.
enum P54Fixtures {

    // MARK: backup — hermes_cli/backup.py

    /// `_run_backup_locked`'s clean path: the scan lines (`:627`, `:640`),
    /// the `Backup complete: ` block (`:666-670`) and the restore hint
    /// (`:681`).
    static let backupComplete = """
        Scanning ~/.hermes ...
        Backing up 812 files ...
          500/812 files ...

        Backup complete: /Users/alan/.hermes-backups/hermes-2026-09-13.zip
          Files:       812
          Original:    41.2 MB
          Compressed:  12.8 MB
          Time:        3.4s

        Restore with: hermes import hermes-2026-09-13.zip
        """

    /// The same run with two `errors` entries: the interpolation flips to
    /// `incomplete` (`:666`) and `_print_capped` adds
    /// `  Warnings (2 files skipped):` (`:679`). Note there is NO
    /// `Restore with:` line — the `else` at `:680-681` is skipped.
    static let backupIncomplete = """
        Scanning ~/.hermes ...
        Backing up 812 files ...

        Backup incomplete: /Users/alan/.hermes-backups/hermes-2026-09-13.zip
          Files:       812
          Original:    41.2 MB
          Compressed:  12.8 MB
          Time:        3.4s

          Warnings (2 files skipped):
            sessions/state.db: SQLite safe copy failed
            .env: [Errno 13] Permission denied
        """

    /// The empty-scan arm (`:633`), which `return`s before any archive is
    /// created — there is no zip on disk at all.
    static let backupNothing = """
        Scanning ~/.hermes ...
        No files to back up.
        """

    // MARK: import — hermes_cli/backup.py

    /// `run_import`'s clean path (`:939`, `:950`) with `--force` supplied,
    /// so `_confirm_import_overwrite` is never reached.
    static let importComplete = """
        Backup contains 812 files
        Target: ~/.hermes

        Importing 812 files ...

        Import complete: 812 files restored in 4.1s
          Target: ~/.hermes
        """

    /// Partial restore: `Warnings (N files skipped):` (`:955`) from
    /// `_import_members`' `errors` list (`:889`, `:911`).
    static let importWithWarnings = """
        Backup contains 812 files
        Target: ~/.hermes

        Importing 812 files ...

        Import complete: 809 files restored in 4.1s
          Target: ~/.hermes

          Warnings (3 files skipped):
            skills/evil/../../etc/passwd: path traversal blocked
            state.db: [Errno 13] Permission denied
        """

    /// The `db_shrunk` arm (`:958-964`) — the backup is OLDER than the live
    /// session store and the restore dropped rows. Hermes's own `⚠` glyph is
    /// included verbatim; ``HermesCLIVerdict/unglyphed(_:)`` strips it.
    static let importSessionsShrank = """
        Backup contains 812 files
        Target: ~/.hermes

        Importing 812 files ...

        Import complete: 812 files restored in 4.1s
          Target: ~/.hermes

          ⚠ Session data replaced by older backup contents:
            sessions/state.db: 41 session(s) / 9210 message(s) -> 29 / 6114
            Anything recorded after the backup was taken is not in it. Recover from a newer backup or snapshot: hermes snapshot list
        """

    /// What a restore looked like BEFORE `--force`: `_confirm_import_overwrite`
    /// (`:829-843`) printed the warning, `input()` hit EOF on the inherited
    /// stdin, and the handler printed `Aborted.` and `sys.exit(1)`. This is
    /// the HIGH finding's reproduction, kept so the fix cannot be quietly
    /// reverted.
    static let importAbortedNoForce = """
        Backup contains 812 files
        Target: ~/.hermes

        Warning: Target directory already has Hermes configuration.
        Importing will overwrite existing files with backup contents.

        Continue? [y/N]
        Aborted.
        """

    // MARK: webhook — hermes_cli/webhook.py

    /// `_cmd_remove`'s success (`:193`).
    static let webhookRemoved = "\n  Removed webhook subscription: github-ci\n"

    /// `_cmd_remove`'s not-found arm (`:188-190`).
    static let webhookRemoveNotFound = """
          No subscription named 'github-ci'.
          Note: Static routes from config.yaml cannot be removed here.
        """

    /// `webhook_command`'s platform gate (`:99-101`), which returns BEFORE
    /// any handler runs. The first two lines of `_setup_hint()` (`:69-73`).
    static let webhookDisabled = """

          Webhook platform is not enabled. To set it up:

          1. Run the gateway setup wizard:
             hermes gateway setup
        """

    /// `_cmd_test`'s delivered POST (`:214-216`).
    static let webhookTestResponse = """
          Sending test POST to http://localhost:8644/webhooks/github-ci
          Response (200): {"ok": true}
        """

    /// A gateway that answered NON-2xx. `urllib.request`'s default opener
    /// installs `HTTPErrorProcessor`, which raises `HTTPError` for any code
    /// outside `200..<300`, so this takes `_cmd_test`'s `except Exception`
    /// arm (`:217-219`) — Hermes never prints a `Response (500)` line.
    ///
    /// Note Hermes's second line is misleading here: the gateway IS running,
    /// it just refused. Scarf quotes both lines because the `Error:` half
    /// names the real status; the wrong half is Hermes's sentence, not ours.
    static let webhookTestHTTPError = """
          Sending test POST to http://localhost:8644/webhooks/github-ci
          Error: HTTP Error 500: Internal Server Error
          Is the gateway running? (hermes gateway run)
        """

    /// `_cmd_test`'s `except Exception` arm (`:217-219`) — a gateway that is
    /// simply not running. Exit 0.
    static let webhookTestGatewayDown = """
          Sending test POST to http://localhost:8644/webhooks/github-ci
          Error: <urlopen error [Errno 61] Connection refused>
          Is the gateway running? (hermes gateway run)
        """

    // MARK: debug share — hermes_cli/debug.py

    /// `run_debug_share`'s clean upload (`:490-492`).
    static let debugShareUploaded = """
        Collecting debug report...
        Uploading...

        Debug report uploaded:
          report  https://paste.example/abc123
          config  https://paste.example/def456

        ⏱  Pastes will auto-delete in 24 hours.
        To delete now:  hermes debug delete <url>
        """

    /// The partial arm (`:493-494`) — printed AFTER the success block, at
    /// exit 0.
    static let debugSharePartial = """
        Collecting debug report...
        Uploading...

        Debug report uploaded:
          report  https://paste.example/abc123

          (failed to upload: config, logs)

        ⏱  Pastes will auto-delete in 24 hours.
        """

    // MARK: curator run — hermes_cli/curator.py

    /// `_cmd_run` with `curator.consolidate` false: the prune-only note
    /// (`:159-163`) and the auto counters (`:172-176`). The background and
    /// dry-run lines (`:177-180`) do not fire on this arm; it returns 0 at
    /// `:186`.
    static let curatorPruneOnly = """
        curator: running review pass...
        curator: consolidation is off — running prune-only (deterministic stale/archive). Pass --consolidate or set `curator.consolidate: true` to enable the LLM merge pass.
        auto: checked=14 stale=2 archived=1 reactivated=0
        """

    /// The same verb with consolidation ON — no note.
    static let curatorFullRun = """
        curator: running review pass...
        auto: checked=14 stale=2 archived=1 reactivated=0
        """
}

// MARK: - backup

@Suite("hermes backup is judged by output (P54)")
struct HermesBackupVerdictP54Tests {

    @Test func aCompleteBackupConfirms() {
        let outcome = HermesBackupVerdict.judge(output: P54Fixtures.backupComplete, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.confidence == .confirmed)
        #expect(outcome.warning == nil)
    }

    /// The MED finding: exit 0, an archive on disk, and files missing from
    /// it. A success — the zip is real — but never a silent one.
    @Test func anIncompleteBackupSucceedsWithTheWarningsLine() throws {
        let outcome = HermesBackupVerdict.judge(output: P54Fixtures.backupIncomplete, exitCode: 0)
        #expect(outcome.succeeded)
        let warning = try #require(outcome.warning)
        #expect(warning.contains(HermesBackupVerdict.incompleteNote))
        // Hermes's own count rides along — it lives nowhere else.
        #expect(warning.contains("Warnings (2 files skipped):"))
        #expect(outcome.detail?.hasPrefix("Backup incomplete: ") == true)
    }

    /// The two prefixes must not be able to match the same line, or the
    /// incomplete arm would also satisfy the complete one.
    @Test func theIncompletePrefixIsNotASubstringOfTheCompleteOne() {
        #expect(!HermesBackupVerdict.incompletePrefix.hasPrefix(HermesBackupVerdict.successPrefix))
        #expect(!HermesBackupVerdict.successPrefix.hasPrefix(HermesBackupVerdict.incompletePrefix))
        // And the complete fixture must not trip the incomplete branch.
        let complete = HermesBackupVerdict.judge(output: P54Fixtures.backupComplete, exitCode: 0)
        #expect(complete.warning == nil)
    }

    @Test func anEmptyScanIsASuccessWithANeutralNote() {
        let outcome = HermesBackupVerdict.judge(output: P54Fixtures.backupNothing, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning == HermesBackupVerdict.nothingToBackUpNote)
    }

    /// C5's third state: exit 0 with none of the three markers.
    @Test func silenceIsUnconfirmedNotSuccess() {
        let outcome = HermesBackupVerdict.judge(output: "", exitCode: 0)
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .unconfirmed)
    }

    @Test func aNonZeroExitIsAFailure() {
        let outcome = HermesBackupVerdict.judge(output: "Traceback...\nOSError: disk full", exitCode: 1)
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
        #expect(outcome.detail == "OSError: disk full")
    }

    @Test func theArgvIsBare() {
        #expect(HermesBackupVerdict.baseArgv == ["backup"])
    }
}

// MARK: - import

@Suite("hermes import passes --force and is judged by output (P54)")
struct HermesImportVerdictP54Tests {

    /// **The HIGH finding.** Decision 1: `--force` is passed, the separator
    /// follows it, and the path is last. Without `--force` every restore
    /// into a live home died on `_confirm_import_overwrite`'s `input()`.
    @Test func theArgvCarriesForceThenTheSeparatorThenThePath() {
        #expect(HermesImportVerdict.argv(path: "/Users/alan/b.zip")
                == ["import", "--force", "--", "/Users/alan/b.zip"])
    }

    /// The separator is what makes a dash-leading path reachable, and the
    /// flag must come BEFORE it — argparse reads everything past `--` as a
    /// positional, so `["import", "--", "-x.zip", "--force"]` would exit 2.
    @Test func theFlagPrecedesTheSeparator() throws {
        let argv = HermesImportVerdict.argv(path: "-weird.zip")
        let separator = try #require(argv.firstIndex(of: "--"))
        let force = try #require(argv.firstIndex(of: "--force"))
        #expect(force < separator)
        #expect(argv.last == "-weird.zip")
    }

    @Test func aCleanRestoreConfirms() {
        let outcome = HermesImportVerdict.judge(output: P54Fixtures.importComplete, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    @Test func skippedFilesRideAlongAsAWarning() throws {
        let outcome = HermesImportVerdict.judge(output: P54Fixtures.importWithWarnings, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(try #require(outcome.warning) == HermesImportVerdict.skippedNote)
    }

    /// Silent data loss: the restore worked and threw away newer sessions.
    @Test func aShrunkSessionStoreIsNamed() throws {
        let outcome = HermesImportVerdict.judge(output: P54Fixtures.importSessionsShrank, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(try #require(outcome.warning) == HermesImportVerdict.sessionsShrankNote)
    }

    /// Both arms can fire on one run, and the shrink is reported first
    /// because it is the more serious of the two.
    @Test func bothPartialArmsAreReportedTogether() throws {
        let both = P54Fixtures.importWithWarnings + "\n"
            + "  ⚠ Session data replaced by older backup contents:\n"
            + "    sessions/state.db: 41 session(s) / 9210 message(s) -> 29 / 6114"
        let warning = try #require(HermesImportVerdict.judge(output: both, exitCode: 0).warning)
        let shrink = try #require(warning.range(of: HermesImportVerdict.sessionsShrankNote))
        let skipped = try #require(warning.range(of: HermesImportVerdict.skippedNote))
        #expect(shrink.lowerBound < skipped.lowerBound)
    }

    /// The regression this phase exists to close: the pre-`--force` output,
    /// which arrived at exit 1 and must read as a failure with Hermes's own
    /// last line rather than a bare "Restore failed".
    @Test func theAbortedRunIsAFailureCarryingItsOwnLine() {
        let outcome = HermesImportVerdict.judge(
            output: P54Fixtures.importAbortedNoForce, exitCode: 1
        )
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
        #expect(outcome.detail == "Aborted.")
    }

    @Test func silenceIsUnconfirmed() {
        let outcome = HermesImportVerdict.judge(output: "", exitCode: 0)
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .unconfirmed)
    }
}

// MARK: - webhook

@Suite("hermes webhook remove/test are judged by output (P54)")
struct HermesWebhookVerdictsP54Tests {

    @Test func removeArgvCarriesTheSeparator() {
        #expect(HermesWebhookRemoveVerdict.argv(name: "github-ci")
                == ["webhook", "remove", "--", "github-ci"])
    }

    @Test func testArgvCarriesTheSeparator() {
        #expect(HermesWebhookTestVerdict.argv(name: "github-ci")
                == ["webhook", "test", "--", "github-ci"])
    }

    @Test func aRealRemovalConfirms() {
        let outcome = HermesWebhookRemoveVerdict.judge(
            output: P54Fixtures.webhookRemoved, exitCode: 0
        )
        #expect(outcome.succeeded)
    }

    @Test func removingAMissingRouteFailsWithHermesOwnLine() {
        let outcome = HermesWebhookRemoveVerdict.judge(
            output: P54Fixtures.webhookRemoveNotFound, exitCode: 0
        )
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
        #expect(outcome.detail == "No subscription named 'github-ci'.")
    }

    /// The gate returns before the handler, so NOTHING was removed — and it
    /// exits 0, which is how three arms all read as "Removed".
    @Test func theDisabledPlatformGateIsAFailureOnBothVerbs() {
        for outcome in [
            HermesWebhookRemoveVerdict.judge(output: P54Fixtures.webhookDisabled, exitCode: 0),
            HermesWebhookTestVerdict.judge(output: P54Fixtures.webhookDisabled, exitCode: 0),
        ] {
            #expect(!outcome.succeeded)
            #expect(outcome.confidence == .failed)
            #expect(outcome.detail == HermesWebhookGate.disabledNote)
        }
    }

    @Test func aDeliveredTestConfirmsAndKeepsItsStatus() throws {
        let outcome = HermesWebhookTestVerdict.judge(
            output: P54Fixtures.webhookTestResponse, exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(try #require(outcome.detail).contains("Response (200)"))
    }

    /// **A non-2xx is a FAILURE, and it never wears a `Response (…)` line.**
    /// The first draft of this verdict claimed a `Response (500)` was a
    /// delivered-but-rejected test; `HTTPErrorProcessor` makes that line
    /// unreachable, so the fixture was fabricated and the rationale with it.
    /// The real shape is the `except` arm, and the HTTP status survives
    /// inside Hermes's own `Error:` text.
    @Test func aNonTwoHundredResponseIsAFailureCarryingItsStatus() throws {
        let outcome = HermesWebhookTestVerdict.judge(
            output: P54Fixtures.webhookTestHTTPError, exitCode: 0
        )
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
        #expect(try #require(outcome.detail).contains("HTTP Error 500"))
    }

    /// The success marker can only ever carry a 2xx, so the verdict must not
    /// be taught to expect anything else.
    @Test func theSuccessMarkerIsNotAStatusTest() {
        #expect(HermesWebhookTestVerdict.successPrefix == "Response (")
        let ok = HermesWebhookTestVerdict.judge(
            output: "  Response (202): queued", exitCode: 0)
        #expect(ok.succeeded)
    }

    /// The MED finding: `except Exception` prints and returns at exit 0.
    @Test func aDownGatewayIsAFailureWithBothLines() throws {
        let outcome = HermesWebhookTestVerdict.judge(
            output: P54Fixtures.webhookTestGatewayDown, exitCode: 0
        )
        #expect(!outcome.succeeded)
        let detail = try #require(outcome.detail)
        #expect(detail.contains("Connection refused"))
        #expect(detail.contains("Is the gateway running?"))
    }

    @Test func testingAMissingRouteFails() {
        let outcome = HermesWebhookTestVerdict.judge(
            output: "  No subscription named 'nope'.", exitCode: 0
        )
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
    }

    @Test func silenceIsUnconfirmedOnBothVerbs() {
        #expect(HermesWebhookRemoveVerdict.judge(output: "", exitCode: 0).confidence == .unconfirmed)
        #expect(HermesWebhookTestVerdict.judge(output: "", exitCode: 0).confidence == .unconfirmed)
    }
}

// MARK: - debug share

@Suite("hermes debug share reports a partial upload (P54)")
struct HermesDebugShareVerdictP54Tests {

    @Test func aCleanUploadConfirms() {
        let outcome = HermesDebugShareVerdict.judge(
            output: P54Fixtures.debugShareUploaded, exitCode: 0, local: false
        )
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    /// The MED finding: `(failed to upload: …)` comes AFTER the success
    /// block, at exit 0.
    @Test func aPartialUploadCarriesTheFailedTargets() throws {
        let outcome = HermesDebugShareVerdict.judge(
            output: P54Fixtures.debugSharePartial, exitCode: 0, local: false
        )
        #expect(outcome.succeeded)
        let warning = try #require(outcome.warning)
        #expect(warning.contains(HermesDebugShareVerdict.partialNote))
        #expect(warning.contains("config, logs"))
    }

    /// `--local` never prints `Debug report uploaded:` — judging it by that
    /// marker would turn every local collection into `.unconfirmed`, which
    /// is why `local` is a parameter rather than a guess.
    @Test func aLocalRunIsJudgedByItsExitCodeAlone() {
        let local = HermesDebugShareVerdict.judge(
            output: "=== config.yaml ===\nmodel: sonnet", exitCode: 0, local: true
        )
        #expect(local.succeeded)
        let remote = HermesDebugShareVerdict.judge(
            output: "=== config.yaml ===\nmodel: sonnet", exitCode: 0, local: false
        )
        #expect(!remote.succeeded)
        #expect(remote.confidence == .unconfirmed)
    }

    @Test func aTotalFailureExitsNonZero() {
        let outcome = HermesDebugShareVerdict.judge(
            output: "Upload failed: all paste targets refused", exitCode: 1, local: false
        )
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
    }
}

// MARK: - curator

@Suite("curator run surfaces the prune-only note (P54)")
struct HermesCuratorRunNoteP54Tests {

    /// Decision 2: the note is Hermes's own sentence, surfaced beside the
    /// success rather than discarded.
    @Test func thePruneOnlyRunIsNamed() throws {
        let note = try #require(HermesCuratorRunNote.pruneOnlyNote(in: P54Fixtures.curatorPruneOnly))
        #expect(note.hasPrefix("curator: consolidation is off"))
        #expect(note.contains("prune-only"))
    }

    @Test func aFullRunHasNoNote() {
        #expect(HermesCuratorRunNote.pruneOnlyNote(in: P54Fixtures.curatorFullRun) == nil)
    }

    @Test func anOlderHostThatPrintsNothingIsANoOp() {
        #expect(HermesCuratorRunNote.pruneOnlyNote(in: "") == nil)
    }
}

// MARK: - the `--` separators, and the one place there must NOT be one

@Suite("curator and kanban argv separators (P54)")
struct P54SeparatorTests {

    /// `pin`, `unpin`, `restore` and `archive` all take the shared `_SKILL`
    /// positional (`hermes_cli/curator.py:595`), so all four get the
    /// separator. Read from the source rather than by running the verbs:
    /// `CuratorService` needs a live transport to construct.
    @Test func allFourCuratorSkillVerbsCarryTheSeparator() throws {
        let source = try String(contentsOf: P54Sources.curatorService, encoding: .utf8)
        for verb in ["pin", "unpin", "restore", "archive"] {
            #expect(
                source.contains("[\"curator\", \"\(verb)\", \"--\", name]"),
                "curator \(verb) lost its `--` separator"
            )
        }
    }

    /// **The correction.** The round-6 report listed `kanban purge` as `--`
    /// residue. It is not: `archive` carries BOTH `task_ids` (`nargs="*"`)
    /// and `--rm`/`purge_ids` (`nargs="+"`), so a `--` after `--rm` hands the
    /// ids to the POSITIONAL and leaves the destructive flag empty — an
    /// exit-2, or a silent archive where the user asked for a delete.
    @Test func kanbanPurgeDoesNotCarryASeparator() throws {
        let source = try String(contentsOf: P54Sources.kanbanService, encoding: .utf8)
        let purge = try #require(source.range(of: "public func purge(taskIds:"))
        // Anchored on the function's own last statement rather than a fixed
        // character window: a longer body would have let a re-added `"--"`
        // slide out of a `prefix(n)` slice and the test would still pass.
        let end = try #require(source.range(
            of: "verb: \"purge\")", range: purge.upperBound..<source.endIndex))
        let body = source[purge.lowerBound..<end.upperBound]
        #expect(body.contains("prefix(\"archive\", \"--rm\")"))
        #expect(!body.contains("\"--\""), "kanban purge must not take a `--`; see the doc comment")
        // And the non-`--rm` form, whose only consumer IS the positional,
        // must keep its separator.
        #expect(KanbanService.archiveArgv(taskIds: ["a", "b"]).contains("--"))
    }
}

/// Repo paths the source-reading tests above resolve, computed from
/// `#filePath` so the suite works from any checkout.
enum P54Sources {
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
    }
    static var curatorService: URL {
        packageRoot.appendingPathComponent("Sources/ScarfCore/Services/CuratorService.swift")
    }
    static var kanbanService: URL {
        packageRoot.appendingPathComponent("Sources/ScarfCore/Services/KanbanService.swift")
    }
}

// MARK: - MCPTestResult's third state

@Suite("MCPTestResult carries the verdict's confidence (P54)")
struct MCPTestResultConfidenceP54Tests {

    /// The default keeps every pre-P54 constructor meaning what it did.
    @Test func theDefaultMirrorsTheBool() {
        #expect(MCPTestResult(serverName: "a", succeeded: true, output: "", tools: [], elapsed: 1)
                    .confidence == .confirmed)
        #expect(MCPTestResult(serverName: "a", succeeded: false, output: "", tools: [], elapsed: 1)
                    .confidence == .failed)
    }

    /// The state the bool could not carry: exit 0, neither marker.
    @Test func unconfirmedSurvivesTheRoundTrip() {
        let outcome = HermesMCPTestVerdict.judge(output: "", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let result = MCPTestResult(
            serverName: "a", succeeded: outcome.succeeded, output: "",
            tools: [], elapsed: 1, confidence: outcome.confidence
        )
        #expect(!result.succeeded)
        #expect(result.confidence == .unconfirmed)
    }
}
