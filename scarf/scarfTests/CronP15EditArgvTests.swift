import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Whole-surface audit P15 — `cron edit`'s skill flags.
///
/// Grounded in `hermes_cli/cron.py::cron_edit` at tag `v2026.9.7`
/// (:606-618): `_normalize_skills` returns **None** for an absent or empty
/// `--skill` list, and `final_skills` stays `None` unless `--clear-skills`,
/// a non-empty replacement, or an add/remove pair was given. A `None`
/// reaches `update_job` as "field untouched", so sending zero `--skill`
/// flags is NOT "the job has no skills".
///
/// Floor walk for the three flags (`--clear-skills`, `--add-skill`,
/// `--remove-skill`): first tagged at `v2026.3.17` = Hermes **v0.3.0**
/// (`hermes_cli/main.py:2854-2857`), absent at `v2026.3.12` = v0.2.0;
/// relocated to `hermes_cli/subcommands/cron.py:98-104` by the v0.17
/// modularisation (`v2026.6.19`) and unchanged through `v2026.9.7`. That is
/// below Scarf's minimum supported Hermes (v0.6.0), so the argv is the same
/// on every host generation Scarf speaks to — see
/// `skillArgvIsIdenticalOnTheOldestSupportedHost`.
@Suite struct CronP15EditArgvTests {

    // MARK: - The bug: an emptied skill set

    /// Before the fix this produced an argv with NO skill flag at all, which
    /// `cron_edit` reads as "leave skills alone" — the user's untick was
    /// silently discarded.
    @Test func emptiedSkillSetClearsInsteadOfSayingNothing() {
        let args = CronViewModel.skillEditArguments(
            existing: ["research", "browse"], newSkills: [], clearSkills: false
        )
        #expect(args == ["--clear-skills"])
    }

    /// …and the same when every entry is blank (the editor's text rows can
    /// leave empty strings behind).
    @Test func blankSkillEntriesCountAsEmpty() {
        let args = CronViewModel.skillEditArguments(
            existing: ["research"], newSkills: ["", ""], clearSkills: false
        )
        #expect(args == ["--clear-skills"])
    }

    /// A job that already has no skills must not be sent a pointless write.
    @Test func emptyToEmptySendsNothing() {
        #expect(CronViewModel.skillEditArguments(
            existing: [], newSkills: [], clearSkills: false
        ).isEmpty)
    }

    /// `nil` = the caller never touched the field. Still nothing.
    @Test func untouchedSkillsSendNothing() {
        #expect(CronViewModel.skillEditArguments(
            existing: ["research"], newSkills: nil, clearSkills: false
        ).isEmpty)
    }

    // MARK: - The diff

    @Test func nonEmptySetIsSentAsAddRemoveDiff() {
        let args = CronViewModel.skillEditArguments(
            existing: ["research", "browse"], newSkills: ["research", "summarize"],
            clearSkills: false
        )
        #expect(args == ["--remove-skill=browse", "--add-skill=summarize"])
        // Never a replacement `--skill`: that would be computed against the
        // form's snapshot and would wipe a skill added between load and save,
        // where the diff is applied to `existing_skills` as Hermes reads them
        // at edit time (`hermes_cli/cron.py:606`).
        #expect(!HermesCLIOption.contains("--skill", in: args))
    }

    @Test func anUnchangedSetSendsNoSkillFlagsAtAll() {
        #expect(CronViewModel.skillEditArguments(
            existing: ["research", "browse"], newSkills: ["browse", "research"],
            clearSkills: false
        ).isEmpty)
    }

    /// The explicit "Clear all skills on save" toggle still wins outright.
    @Test func explicitClearToggleBeatsTheDiff() {
        #expect(CronViewModel.skillEditArguments(
            existing: ["research"], newSkills: ["research", "browse"], clearSkills: true
        ) == ["--clear-skills"])
    }

    // MARK: - C1: identical argv on a pre-target host

    /// The floor is v0.3.0, below Scarf's v0.6.0 minimum, so there is no
    /// host generation that gets a different argv — this pins that the
    /// builder is capability-free and cannot acquire a gate by accident.
    @Test func skillArgvIsIdenticalOnTheOldestSupportedHost() {
        // The builder takes no capabilities at all; a v0.6.0 host and a
        // v0.21.1 host therefore receive byte-identical flags.
        let v06 = HermesCapabilities.parse("Hermes Agent v0.6.0")
        let v0211 = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(v06.isV0206OrLater == false)     // genuinely a pre-target host
        #expect(v0211.isV0211OrLater == true)
        let flags = CronViewModel.skillEditArguments(
            existing: ["research"], newSkills: [], clearSkills: false
        )
        #expect(flags == ["--clear-skills"])
    }

}

/// Whole-surface audit P15 — the post-mutation diagnostic refresh.
///
/// `runAndReload` used to re-read `jobs.json` only, so the `cron doctor`
/// findings and the open-incident badges kept describing the job as it was
/// BEFORE the edit — a user who fixed exactly what the doctor flagged still
/// saw the warning until they left and re-entered the section.
@Suite struct CronP15DiagnosticRefreshTests {

    /// The C1 half: `cron incidents` is v0.20.6 and `cron doctor` is v0.21,
    /// and the view only calls them when the capability says so. The refresh
    /// must therefore fire ONLY for a probe that has already answered on
    /// this host — a pre-target host must not start spawning a verb it never
    /// spawned before. A fresh VM has answered neither, so the refresh is a
    /// no-op and no CLI run is started.
    @Test @MainActor func aHostThatNeverRanTheProbesGainsNoSpawn() {
        let vm = CronViewModel()
        #expect(vm.hasLoadedDoctorFindings == false)
        #expect(vm.hasLoadedIncidentList == false)

        vm.refreshDiagnosticsAfterMutation()

        // `loadDoctor`/`loadIncidents` set their in-flight flag
        // synchronously, before hopping off the main actor — so a flag that
        // is still false proves neither was entered.
        #expect(vm.isLoadingDoctor == false)
        #expect(vm.isLoadingIncidents == false)
    }
}
