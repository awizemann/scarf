import Foundation
import Testing
@testable import ScarfCore

/// P3 (Hermes v0.21.4 / v0.21.5 parity) — CLI outcome judges. Every fixture
/// is the literal text the tagged Hermes source prints (cited per fixture),
/// so each test fails if the matching fix is reverted.
@Suite struct HermesV0214CLIOutcomeTests {
    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    // MARK: - Capability floors

    @Test func v0214FlagsOnAtFloorOffOneReleaseBelow() {
        for caps in [Self.v0214, Self.v0215] {
            #expect(caps.hasSessionsOptimizeForce)
            #expect(caps.hasBackupPartialExitNonZero)
            #expect(caps.hasCronModelPin)
            #expect(caps.hasCronIncidentResolvedState)
            #expect(caps.hasSkillsSearchRegistryFallback)
            #expect(caps.hasPeerDMNoResendOutcomes)
        }
        for caps in [Self.v0213, HermesCapabilities.empty] {
            #expect(!caps.hasSessionsOptimizeForce)
            #expect(!caps.hasBackupPartialExitNonZero)
            #expect(!caps.hasCronModelPin)
            #expect(!caps.hasCronIncidentResolvedState)
            #expect(!caps.hasSkillsSearchRegistryFallback)
            #expect(!caps.hasPeerDMNoResendOutcomes)
        }
    }

    /// `cron/job_definition.py` first ships at v2026.9.24.
    @Test func jobDefinitionFieldsFlagIsV0215Only() {
        #expect(Self.v0215.hasCronJobDefinitionFields)
        #expect(!Self.v0214.hasCronJobDefinitionFields)
        #expect(!HermesCapabilities.empty.hasCronJobDefinitionFields)
    }

    // MARK: - sessions optimize (held-store refusal)

    /// `held_store_refusal` (`hermes_state_holders.py:481-515` @ v2026.9.24),
    /// with two foreign holders and the default profile selector.
    static let optimizeRefusal = """
        Refusing `hermes sessions optimize`: another process is using /Users/u/.hermes/state.db.
          PID 4242 (hermes gateway run): state.db, state.db-wal
          PID 777 (scarf): state.db, state.db-shm
        Rewriting the database under a live writer is how every agent ends up refusing turns with the retired state.db-wal error. Nothing is lost.
        Stop them first (`hermes gateway stop`, quit the Desktop app, pause cron), then re-run.
        Override with --force if you accept the risk.
        Recovery guide: https://hermes-agent.nousresearch.com/docs/user-guide/session-storage-recovery
        """

    @Test func optimizeRefusalNamesTheHoldersVerbatim() throws {
        let holders = try #require(
            HermesSessionsOptimizeVerdict.heldStoreHolders(output: Self.optimizeRefusal, exitCode: 1))
        #expect(holders == [
            "PID 4242 (hermes gateway run): state.db, state.db-wal",
            "PID 777 (scarf): state.db, state.db-shm",
        ])
    }

    @Test func optimizeRefusalDetailIsTheRefusalNotTheDocsURL() {
        let outcome = HermesSessionsOptimizeVerdict.judge(output: Self.optimizeRefusal, exitCode: 1)
        #expect(!outcome.succeeded)
        #expect(outcome.detail?.hasPrefix("Refusing `hermes sessions optimize`:") == true)
    }

    /// The fail-closed arm (`:503`) still counts as a refusal.
    @Test func incompleteHolderScanIsARefusalToo() throws {
        let output = """
            Refusing `hermes sessions optimize`: another process is using /h/state.db.
              cannot prove the database is quiet (holder scan incomplete: open-file scan failed: boom)
            Override with --force if you accept the risk.
            """
        let holders = try #require(HermesSessionsOptimizeVerdict.heldStoreHolders(output: output, exitCode: 1))
        #expect(holders.count == 1)
        #expect(holders.first?.hasPrefix("cannot prove the database is quiet") == true)
    }

    /// C1: an ordinary non-zero exit is not a refusal and keeps its old detail.
    @Test func ordinaryFailureIsNotARefusal() {
        let output = "Traceback (most recent call last):\nsqlite3.OperationalError: disk I/O error"
        #expect(HermesSessionsOptimizeVerdict.heldStoreHolders(output: output, exitCode: 1) == nil)
        #expect(HermesSessionsOptimizeVerdict.judge(output: output, exitCode: 1).detail
                == "sqlite3.OperationalError: disk I/O error")
        #expect(HermesSessionsOptimizeVerdict.heldStoreHolders(output: "Optimized 2 FTS index(es).", exitCode: 0) == nil)
    }

    @Test func forceFlagOnlyWhereItParses() {
        #expect(HermesSessionsOptimizeVerdict.forceArguments(capabilities: Self.v0214) == ["--force"])
        #expect(HermesSessionsOptimizeVerdict.forceArguments(capabilities: Self.v0213) == [])
        #expect(HermesSessionsOptimizeVerdict.argv == ["sessions", "optimize"])
    }

    // MARK: - backup (partial archive exits 1)

    /// `_run_backup_locked` (`hermes_cli/backup.py:693-760` @ v2026.9.24)
    /// with two errors; `main.py:2270` turns the False into exit 1.
    static let partialBackup = """
        Scanning ~/.hermes ...
        Backing up 812 files ...

        Backup incomplete: /Users/u/hermes-backup-2026-09-26-101500.zip
          Files:       812
          Original:    41.2 MB
          Compressed:  12.0 MB
          Time:        3.1s

          Archive kept, but 2 file(s) could not be added:
            state.db: SQLite safe copy failed
            memories/x.md: [Errno 13] Permission denied
        """

    @Test func partialArchiveIsAPartialSuccessOnV0214() throws {
        let outcome = HermesBackupVerdict.judge(output: Self.partialBackup, exitCode: 1, capabilities: Self.v0214)
        #expect(outcome.succeeded)
        #expect(outcome.detail == "Backup incomplete: /Users/u/hermes-backup-2026-09-26-101500.zip")
        let warning = try #require(outcome.warning)
        #expect(warning.contains(HermesBackupVerdict.incompleteNote))
        #expect(warning.contains("Archive kept, but 2 file(s) could not be added:"))
    }

    /// C1: below the floor an exit-1 backup is a failure, exactly as before.
    @Test func exitOneStaysAFailureBelowTheFloor() {
        let outcome = HermesBackupVerdict.judge(output: Self.partialBackup, exitCode: 1, capabilities: Self.v0213)
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
    }

    /// A hard failure on v0.21.4 (no kept archive) is still a failure —
    /// `BackupInProgressError` exits 2 (`backup.py:689-690`), a missing home
    /// exits 1 (`:681-682`), neither prints `Archive kept, but `.
    @Test func hardFailureOnV0214IsStillAFailure() {
        let busy = HermesBackupVerdict.judge(
            output: "Error: another backup is already running", exitCode: 2, capabilities: Self.v0214)
        #expect(!busy.succeeded)
        let noHome = HermesBackupVerdict.judge(
            output: "Error: Hermes home directory not found at /x", exitCode: 1, capabilities: Self.v0214)
        #expect(!noHome.succeeded)
    }

    // MARK: - skills install / update ("Not installed:")

    /// `_install_blocked(..., label="Not installed:")` (`skills_hub.py:730`
    /// @ v2026.9.24) with `_scan_block_message`'s text (`:505-518`).
    static let scanBlocked = """
        Quarantined to skills/.hub/quarantine/foo

        Not installed: the security scan found 2 high-risk pattern(s) in 'foo' (listed above). Re-run with --force to install anyway. Review the findings or ask the author to fix them; to read the skill without installing, run `hermes skills inspect foo`.
        """

    @Test func scanBlockedInstallIsAFailureWithItsReason() {
        let outcome = SkillsViewModel.installOutcome(exitCode: 0, output: Self.scanBlocked)
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
        #expect(outcome.detail?.hasPrefix("Not installed: the security scan found") == true)
    }

    @Test func scanBlockedUpdateQuotesTheReason() {
        let report = HermesSkillsHubParser.parseUpdateReport("Updating: foo\n" + Self.scanBlocked)
        #expect(report.failureDetail?.hasPrefix("Not installed:") == true)
    }

    // MARK: - cron doctor closing hint

    /// `cron_doctor` @ v2026.9.21 (`hermes_cli/cron.py:655-667`).
    @Test func v0214ClosingHintIsNotPartOfTheLastIssue() throws {
        let output = """
            Cron doctor found 1 issue(s) across 1 job(s):

              abc123def456 Nightly
                - last run failed: boom

            Review the findings above, then run `hermes cron doctor` again.
            """
        let findings = HermesCronDoctorParser.parse(text: output)
        let finding = try #require(findings["abc123def456"])
        #expect(finding.issues == ["last run failed: boom"])
    }

    // MARK: - cron incidents `resolved`

    @Test func resolvedIncidentIsNotOpen() throws {
        let output = """
              inc-ccc  resolved
                Job:        job-3
                Type:       rate_limit
                First seen: 2026-09-20T09:00:00
                Last seen:  2026-09-20T09:00:00
                Error:      429
            """
        let incident = try #require(HermesCronIncidentsParser.parse(text: output).first)
        #expect(incident.state == "resolved")
        #expect(!incident.isOpen)
    }

    @Test func resolvedFilterOnlyWhereArgparseTakesIt() {
        #expect(HermesCronIncidentsParser.listArgs(state: "resolved", capabilities: Self.v0214)
                == ["cron", "incidents", "--state", "resolved"])
        #expect(HermesCronIncidentsParser.listArgs(state: "resolved", capabilities: Self.v0213)
                == ["cron", "incidents"])
        #expect(HermesCronIncidentsParser.listArgs() == ["cron", "incidents"])
    }

    // MARK: - profile delete (settlement pending)

    /// `ProfileIdentitySettlementPending` (`profiles.py:1663-1678` @
    /// v2026.9.24) through `_die(f"Error: {e}")` (`profile_cmd.py:295`).
    static let settlementPending = """
        ✓ Removed /Users/u/.hermes/profiles/bot1

        Profile 'bot1' deleted.
        Error: Profile 'bot1' was deleted, but its session/routing identity settlement is still pending — run: hermes profile purge-identity bot1
        """

    @Test func settlementPendingIsACompletedDeleteWithAWarning() {
        #expect(HermesProfileDeleteVerdict.settlementPendingWarning(output: Self.settlementPending, exitCode: 1)
                == "Profile 'bot1' was deleted, but its session/routing identity settlement is still pending — run: hermes profile purge-identity bot1")
    }

    @Test func otherDeleteExitsKeepTheirMeaning() {
        #expect(HermesProfileDeleteVerdict.settlementPendingWarning(output: Self.settlementPending, exitCode: 0) == nil)
        #expect(HermesProfileDeleteVerdict.settlementPendingWarning(
            output: "Error: Could not remove profile directory /x: [Errno 66] Directory not empty", exitCode: 1) == nil)
    }

    // MARK: - peer dm

    /// `_peer_dm`'s queued arm (`peer.py:368-375` @ v2026.9.21), `--json`.
    @Test func queuedDMIsDeliveredNotNoReply() throws {
        let stdout = #"{"peer": "spark", "profile": null, "session_id": "s-1", "status": "queued", "delivery_id": "d-9"}"#
        let dm = try HermesPeerCLI.parseDM(exitCode: 0, stdout: stdout, stderr: "").get()
        #expect(dm.delivery == .queued(status: "queued"))
        #expect(dm.sessionID == "s-1")
    }

    /// `peer.py:362-365` @ v2026.9.21 — exit 1 on stderr.
    @Test func acceptedTimeoutIsNotADeliveryFailure() throws {
        let stderr = "Peer 'spark' accepted the message but its turn is still running after 600s: the message is already in its Bot Chat (session s-1) and will be answered there. The reply cannot come back on this call. Do NOT resend.\n"
        let dm = try HermesPeerCLI.parseDM(exitCode: 1, stdout: "", stderr: stderr).get()
        guard case .stillRunning(let notice) = dm.delivery else {
            Issue.record("expected stillRunning, got \(dm.delivery)")
            return
        }
        #expect(notice.hasSuffix("Do NOT resend."))
    }

    /// C1: the pre-v0.21.4 shapes are unchanged.
    @Test func olderDMShapesUnchanged() throws {
        let replied = try HermesPeerCLI.parseDM(
            exitCode: 0, stdout: #"{"peer": "spark", "profile": null, "session_id": "s", "reply": ""}"#, stderr: ""
        ).get()
        #expect(replied.delivery == .replied)
        #expect(replied.reply.isEmpty)
        let unreachable = HermesPeerCLI.parseDM(
            exitCode: 1, stdout: "", stderr: "Peer 'spark': could not reach http://spark.lan:8377: timed out")
        guard case .failure(let failure) = unreachable else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.kind == .delivery)
    }

    @Test func dmTimeoutHasHeadroomOnlyWhereTheNoticeExists() {
        #expect(HermesPeerCLI.dmProcessTimeout(capabilities: Self.v0214) > 600)
        #expect(HermesPeerCLI.dmProcessTimeout(capabilities: Self.v0213) == 600)
    }

    // MARK: - cron duplicate (iOS JSON seed)

    static func jobWithRuntimeExtras() throws -> HermesCronJob {
        let json = """
            {"id": "j1", "name": "Nightly", "prompt": "p", "enabled": true, "state": "scheduled",
             "schedule": {"kind": "interval", "minutes": 60, "display": "every 60m"},
             "provider": "openrouter", "reasoning_effort": "high",
             "repeat": {"times": 3, "completed": 2},
             "quota_hold_until": "2026-09-26T12:00:00+00:00",
             "provider_snapshot": "nous", "model_snapshot": "hermes-4",
             "created_at": "2026-09-01T00:00:00+00:00", "failure_streak": 4}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    /// v0.21.4 hold (`cron/quota_hold.py:27,97`) must not park the copy.
    @Test func duplicateNeverCarriesAQuotaHold() throws {
        for caps in [HermesCapabilities.empty, Self.v0213, Self.v0214, Self.v0215] {
            let copy = try Self.jobWithRuntimeExtras().duplicatedAsNewJob(
                id: "j2", existingNames: ["Nightly"], capabilities: caps)
            #expect(copy.extra["quota_hold_until"] == nil)
        }
    }

    /// v0.21.5+: only `JOB_DEFINITION_FIELDS` (+ `repeat`) survive.
    @Test func v0215DuplicateKeepsOnlyAuthoredFields() throws {
        let copy = try Self.jobWithRuntimeExtras().duplicatedAsNewJob(
            id: "j2", existingNames: ["Nightly"], capabilities: Self.v0215)
        #expect(copy.extra["provider"] == .string("openrouter"))
        #expect(copy.extra["reasoning_effort"] == .string("high"))
        #expect(copy.extra["provider_snapshot"] == nil)
        #expect(copy.extra["created_at"] == nil)
        #expect(copy.extra["failure_streak"] == nil)
        guard case .object(let repeatSpec)? = copy.extra["repeat"] else {
            Issue.record("repeat dropped")
            return
        }
        #expect(repeatSpec["completed"] == .int(0))
    }

    /// C1: below v0.21.5 the old denylist stands — v2026.9.14's scheduler
    /// still reads `*_snapshot` (`cron/scheduler.py:1355-1369`).
    @Test func preV0215DuplicateKeepsTheOldCarry() throws {
        let copy = try Self.jobWithRuntimeExtras().duplicatedAsNewJob(
            id: "j2", existingNames: ["Nightly"], capabilities: Self.v0214)
        #expect(copy.extra["provider_snapshot"] == .string("nous"))
        // P5b: v0.21.4 drops the scheduler-owned stamps by name (see
        // `schedulerOwnedExtraKeys`); v0.21.3 carries them exactly as before.
        #expect(copy.extra["created_at"] == nil)
        let older = try Self.jobWithRuntimeExtras().duplicatedAsNewJob(
            id: "j2", existingNames: ["Nightly"], capabilities: Self.v0213)
        #expect(older.extra["created_at"] != nil)
    }

    // MARK: - model pin

    @Test func isModelPinnedIsHermesStoredModelTest() {
        let pinned = HermesCronJob(id: "a", name: "a", prompt: "p", model: "gpt-5",
                                   schedule: CronSchedule(kind: "interval"), enabled: true, state: "scheduled")
        let blank = HermesCronJob(id: "b", name: "b", prompt: "p", model: "  ",
                                  schedule: CronSchedule(kind: "interval"), enabled: true, state: "scheduled")
        #expect(pinned.isModelPinned)
        #expect(!blank.isModelPinned)
    }

    /// `_apply_pin_update(pinned=False)` clears provider with the model
    /// (`cron/jobs.py:1902-1916` @ v2026.9.21).
    @Test func emptyingTheModelReleasesTheProviderOnV0214() {
        let extra: [String: JSONValue] = ["provider": .string("openrouter"), "origin": .string("cli")]
        let released = HermesCronJob.releasingModelPin(
            extra, previousModel: "gpt-5", newModel: nil, capabilities: Self.v0214)
        #expect(released["provider"] == nil)
        #expect(released["origin"] == .string("cli"))
        // Below the floor, and when the model is kept, nothing changes.
        #expect(HermesCronJob.releasingModelPin(
            extra, previousModel: "gpt-5", newModel: nil, capabilities: Self.v0213) == extra)
        #expect(HermesCronJob.releasingModelPin(
            extra, previousModel: "gpt-5", newModel: "gpt-5", capabilities: Self.v0214) == extra)
        #expect(HermesCronJob.releasingModelPin(
            extra, previousModel: nil, newModel: nil, capabilities: Self.v0214) == extra)
    }
}
