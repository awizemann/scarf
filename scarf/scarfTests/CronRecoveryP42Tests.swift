import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P42 — round-4 decisions 5 and 6, and the `friendlyCronFailure` MED.
///
/// P30 unified the recovery OFFER and P38 fixed its copy; what was left was
/// that the copy named a remedy with no button behind it, and that one arm
/// of the copy was chosen by a default rather than by evidence.
@MainActor
@Suite struct CronRecoveryP42Tests {

    /// P42b: the gaps list is host-shaped now — these three tests are about
    /// the RECORD-shaped half, so they pass a host that has every field.
    static let modernHost = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")

    static func job(
        state: String,
        kind: String,
        enabled: Bool = false,
        past: Bool = false,
        extra: String = ""
    ) throws -> HermesCronJob {
        let runAt = past ? "2020-01-01T09:00:00+00:00" : "2099-01-01T09:00:00+00:00"
        let schedule: String
        switch kind {
        case "cron":     schedule = #"{"kind":"cron","expr":"0 9 * * *"}"#
        case "interval": schedule = #"{"kind":"interval","minutes":30}"#
        default:         schedule = #"{"kind":"once","run_at":"\#(runAt)"}"#
        }
        let json = """
            {"id":"j1","name":"Nightly","prompt":"p","enabled":\(enabled),
             "state":"\(state)","schedule":\(schedule)\(extra.isEmpty ? "" : ",\(extra)")}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    // MARK: - The MED: `friendlyCronFailure`'s unknown-offer arm

    /// The `cron edit` race — the record turned terminal between load and
    /// click, so `jobs.first { $0.id == id }` came back nil and
    /// `runAndReload` had no job to compute an offer from.
    ///
    /// It used to default to naming "Resume & Run Now", which for a
    /// RECURRING job is a guaranteed exit 1: `rearm_oneshot` raises
    /// `_REARM_RECURRING_ERROR` for anything but `once`
    /// (`cron/jobs.py:2040-2042`, `:2065-2066` @ `v2026.9.7`, exit 1 through
    /// `hermes_cli/cron.py:691-695`). With no offer the only thing Scarf can
    /// truthfully assert is that duplicating works, because a `cron create`
    /// has no terminal guard on its path at all.
    @Test func anUnknownOfferNeverNamesTheReArmButton() {
        let refusal = "Cannot activate terminal cron job 'Nightly' (completed)"
        let message = CronViewModel.friendlyCronFailure(refusal, offer: nil)
        #expect(message != nil)
        #expect(message?.contains("Resume & Run Now") == false)
        #expect(message?.contains("duplicate") == true)
    }

    @Test func aKnownOfferDecidesTheReArmClauseBothWays() {
        let refusal = "Cannot activate terminal cron job 'Nightly' (completed)"
        let rearmable = CronViewModel.friendlyCronFailure(
            refusal, offer: CronRecoveryOffer(canRearm: true))
        #expect(rearmable?.contains("Resume & Run Now") == true)

        let deadEnd = CronViewModel.friendlyCronFailure(
            refusal, offer: CronRecoveryOffer(hint: CronRecoveryOffer.noFutureOccurrencesHint))
        #expect(deadEnd?.contains("Resume & Run Now") == false)
        #expect(deadEnd?.contains("duplicate") == true)
    }

    /// The live shape the MED describes: a recurring `completed` job, which
    /// is what `_advance_after_run` produces when a finite `repeat` runs out
    /// (`cron/jobs.py:2192-2215`). Its offer is a dead end, so neither the
    /// refusal sentence nor the CLI-failure sentence may name re-arm.
    @Test func aCompletedRecurringJobIsNeverPointedAtReArm() throws {
        let vm = CronViewModel(context: .local)
        vm.isV0206OrLater = true
        vm.isV021OrLater = true
        vm.isV0181OrLater = true
        let recurring = try Self.job(state: "completed", kind: "cron")
        let offer = vm.recoveryOffer(for: recurring)
        #expect(offer.isDeadEnd)

        for sentence in [
            CronViewModel.terminalRefusalMessage(recurring, offer: offer),
            CronViewModel.resumeRefusalMessage(recurring, offer: offer),
            CronViewModel.friendlyCronFailure(
                "Cannot activate terminal cron job 'Nightly' (completed)", offer: offer) ?? "",
        ] {
            #expect(!sentence.contains("Resume & Run Now"), "named re-arm in: \(sentence)")
            #expect(sentence.lowercased().contains("duplicate"), "no remedy in: \(sentence)")
        }
    }

    // MARK: - Decision 6: iOS names the door it now has

    /// iOS's terminal sentence used to send the user to the Mac. It has the
    /// re-arm itself now (`IOSCronViewModel.resumeAndRunNow(id:)`), so the
    /// two platforms name the SAME affordance — the parity the P30 suite
    /// asserts for the offer, extended to the copy.
    @Test func iOSNamesReArmItselfRatherThanPointingAtTheMac() throws {
        let oneShot = try Self.job(state: "completed", kind: "once")
        let offer = CronRecoveryOffer(canRearm: true)
        let ios = IOSCronViewModel.terminalRefusalMessage(oneShot, offer: offer)
        let mac = CronViewModel.terminalRefusalMessage(oneShot, offer: offer)
        #expect(ios.contains("Resume & Run Now"))
        #expect(mac.contains("Resume & Run Now"))
        // The pointer is gone — naming another app is not an affordance.
        #expect(!ios.contains("Mac app"))
    }

    /// Same for the past-deadline one-shot, the offer's third door.
    @Test func iOSNamesReArmForThePastDeadlineOneShotToo() throws {
        let past = try Self.job(state: "paused", kind: "once", past: true)
        let offer = CronRecoveryOffer(canRearm: true)
        let ios = IOSCronViewModel.resumeRefusalMessage(past, offer: offer)
        #expect(ios.contains("Resume & Run Now"))
        #expect(!ios.contains("Mac app"))
    }

    // MARK: - Decision 5: what a duplicate carries, and what it admits it drops

    /// A Duplicate is an ordinary create through the create FORM, which has
    /// no field for `--model`/`--provider`/`--reasoning-effort`/
    /// `--monitor-script`/`--monitor-url`/`--continuity`. Naming them is the
    /// sheet's job; producing the list is the model's.
    @Test func theDuplicateSheetNamesEverySettingItCannotCarry() throws {
        let bare = try Self.job(state: "completed", kind: "cron")
        #expect(bare.settingsACreateFormCannotCarry(caps: Self.modernHost).isEmpty)

        let loaded = try Self.job(
            state: "completed", kind: "cron",
            extra: #""model":"kimi-k2","provider":"nous","reasoning_effort":"high","monitor_script":"/s/check.sh","context_from":["self"]"#)
        let dropped = loaded.settingsACreateFormCannotCarry(caps: Self.modernHost)
        #expect(dropped.contains { $0.contains("kimi-k2") })
        #expect(dropped.contains { $0.contains("nous") })
        #expect(dropped.contains { $0.contains("high") })
        #expect(dropped.contains { $0.contains("/s/check.sh") })
        #expect(dropped.contains { $0.contains("continuity") })
    }

    /// `""` is Hermes's "not set" for these optional text fields
    /// (`_normalize_job_optional_text`, `cron/jobs.py:1583-1584` @
    /// `v2026.9.7`) — an empty monitor path must not raise a warning about a
    /// setting that isn't there.
    @Test func anEmptyOptionalTextFieldIsNotASettingToWarnAbout() throws {
        let blank = try Self.job(
            state: "completed", kind: "cron",
            extra: #""monitor_script":"","monitor_url":"   ","provider":"""#)
        #expect(blank.settingsACreateFormCannotCarry(caps: Self.modernHost).isEmpty)
        #expect(!blank.isMonitorJob)
    }

    /// Continuity is not a field: Hermes stores it as `"self"` in
    /// `context_from` (`tools/cronjob_job_args.py:313-321` @ `v2026.9.7`),
    /// which `build_prompt` resolves to the job's own id
    /// (`cron/scheduler_prompt.py:77-79`). Both spellings count; another
    /// job's id does not.
    @Test func continuityIsReadFromContextFromInBothSpellings() throws {
        #expect(try Self.job(state: "scheduled", kind: "cron",
                             extra: #""context_from":["self"]"#).hasRunToRunContinuity)
        #expect(try Self.job(state: "scheduled", kind: "cron",
                             extra: #""context_from":[" SELF "]"#).hasRunToRunContinuity)
        #expect(try Self.job(state: "scheduled", kind: "cron",
                             extra: #""context_from":["j1"]"#).hasRunToRunContinuity)
        #expect(!(try Self.job(state: "scheduled", kind: "cron",
                               extra: #""context_from":["other"]"#).hasRunToRunContinuity))
        #expect(!(try Self.job(state: "scheduled", kind: "cron").hasRunToRunContinuity))
    }

    /// iOS creates by rewriting `jobs.json`, so its duplicate is a fresh
    /// RECORD. It must carry the config and drop the run — a copy born in
    /// `completed` would be exactly as unrunnable as its source, because
    /// `effective_job_state` preserves a terminal state regardless of
    /// `enabled` (`cron/jobs.py:488-503` @ `v2026.9.7`).
    @Test func theIOSDuplicateCarriesConfigAndDropsTheRun() throws {
        let spent = try Self.job(
            state: "completed", kind: "cron",
            extra: #""model":"kimi-k2","monitor_script":"/s/check.sh","paused_at":"2020-01-01T00:00:00Z","repeat":{"times":3,"completed":3},"next_run_at":"2020-01-01T09:00:00Z","last_run_at":"2020-01-01T09:00:00Z""#)
        #expect(spent.isTerminal)

        let copy = spent.duplicatedAsNewJob(id: "job_new", existingNames: [])
        #expect(copy.id == "job_new")
        #expect(!copy.isTerminal)
        #expect(copy.effectiveState == "scheduled")
        #expect(copy.enabled)
        #expect(copy.nextRunAt == nil)
        #expect(copy.lastRunAt == nil)
        // Config survives — unlike the Mac's form-shaped duplicate, a JSON
        // write loses nothing.
        #expect(copy.model == "kimi-k2")
        #expect(copy.monitorScript == "/s/check.sh")
        // …except the NAME, which may not survive: `resolve_job_ref` matches
        // on a case-folded name and raises `AmbiguousJobReference` for BOTH
        // jobs once two share one (`cron/jobs.py:1840-1845` @ `v2026.9.7`),
        // so a verbatim copy broke `hermes cron run <name>` for the source
        // too (P46 finding 9).
        #expect(copy.name == spent.name + " (copy)")
        #expect(copy.prompt == spent.prompt)
        // The repeat LIMIT stays; the run COUNT resets, or the copy would be
        // retired by `_advance_after_run` on its very first run.
        #expect(copy.repeatSpec.times == 3)
        #expect(copy.repeatSpec.completed == 0)
    }

    // MARK: - Decision 8: fleet-copied monitor jobs

    /// A monitor job runs the agent only when its source's output CHANGED.
    /// `cronCreateArgs` forwards neither `--monitor-script` nor
    /// `--monitor-url` (`hermes_cli/subcommands/cron.py:51-62` @
    /// `v2026.9.7`), so a copy used to become an ordinary agent job that ran
    /// on every tick under a green "created". It is declined instead, and it
    /// shows up in the plan preview the user approves.
    @Test func aMonitorJobIsPartitionedOutOfTheFleetCopySet() throws {
        let projectID = UUID()
        let tag = FleetApplyPlan.projectCronTag(projectID)
        func tagged(_ name: String, extra: String = "") throws -> HermesCronJob {
            var job = try Self.job(state: "scheduled", kind: "cron", enabled: true, extra: extra)
            job = HermesCronJob(
                id: name, name: tag + name, prompt: job.prompt, skills: nil, model: nil,
                schedule: job.schedule, enabled: true, state: "scheduled", deliver: nil,
                nextRunAt: nil, lastRunAt: nil, lastError: nil, preRunScript: nil,
                deliveryFailures: nil, lastDeliveryError: nil, timeoutType: nil,
                timeoutSeconds: nil, silent: nil, workdir: nil, contextFrom: nil,
                noAgent: nil, attachToSession: nil, extra: job.extra)
            return job
        }
        let plain = try tagged("plain")
        let scripted = try tagged("scripted", extra: #""monitor_script":"/s/check.sh""#)
        let urled = try tagged("urled", extra: #""monitor_url":"https://x/y""#)

        let set = FleetApplyPlan.copyableCronJobs(
            from: [plain, scripted, urled], projectID: projectID)
        #expect(set.copyable.map(\.id) == ["plain"])
        #expect(set.monitor.map(\.id) == ["scripted", "urled"])
        // Declined for the same reason `scriptOnly` is, and summed with it
        // where the verdict is the same.
        #expect(set.declined.count == 2)
        #expect(FleetApplyPlan.shouldSkipMonitorJob(scripted))
        #expect(!FleetApplyPlan.shouldSkipMonitorJob(plain))
    }

    /// The verdict: a pass that created nothing because every job was
    /// declined is `.skipped`, never `.applied` — telling the user a field
    /// applied while not one job landed is the lie the `no_agent` case used
    /// to tell.
    @Test func aPassThatOnlyDeclinedMonitorJobsIsSkippedNotApplied() {
        #expect(FleetApplyExecutor.cronFieldStatus(
            created: 0, failed: 0, scriptOnlySkipped: 2) == .skipped)
        #expect(FleetApplyExecutor.cronFieldStatus(
            created: 1, failed: 0, scriptOnlySkipped: 1) == .applied)
    }
}
