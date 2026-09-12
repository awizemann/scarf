import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Whole-surface audit P18 — the sibling sites P15 left behind.
///
/// P15 taught `cron edit` to say "clear the skills" out loud. The same
/// "an emptied field is a real gesture" rule applies to the editor's two
/// other clearable text fields, and did not reach them: `updateJob` dropped
/// `--prompt` and `--repeat` on an empty string, so "the user deleted the
/// value" and "the user didn't touch it" produced identical argv and the
/// user got a green "Updated" for a write that never happened.
///
/// Both gestures are expressible and BOTH are ungated:
/// - `--prompt ""` — `_update_core_fields`'s guard is `if prompt is not
///   None` (`tools/cronjob_tools.py:689-697`, v2026.9.7), so an empty
///   string is a real update.
/// - `--repeat 0` — `normalize_repeat_value` folds `<= 0` to `None`, which
///   IS "run forever" (`cron/jobs.py:591-617`), reached through
///   `_update_run_fields`'s `if a["repeat"] is not None` (:787-792).
///
/// Floor walk (`pyproject.toml:5` read AT each of the 32 `v2026.*` tags):
/// `cron edit --prompt` / `--repeat` are both registered at
/// `hermes_cli/main.py:3943,3946` at tag `v2026.3.30` = **v0.6.0**, Scarf's
/// minimum supported Hermes, and unchanged through `v2026.9.7`; the
/// `<= 0 -> forever` fold first appears at `v2026.3.23` = v0.4.0, below the
/// floor as well. No capability flag: there is no supported host generation
/// that would reject either argv.
@Suite struct CronP18ClearGestureTests {

    // MARK: - Repeat

    /// The bug. Seeded with a finite count, emptied by the user: before the
    /// fix this produced NO `--repeat` flag, `updates` never carried the
    /// key, and the job still went terminal after N runs.
    @Test func emptiedRepeatClearsToForever() {
        #expect(CronViewModel.repeatEditArguments(existing: "3", newValue: "")
                == ["--repeat=0"])
    }

    /// Whitespace is not a value — the field is a plain `TextField`.
    @Test func whitespaceOnlyRepeatIsAnEmptying() {
        #expect(CronViewModel.repeatEditArguments(existing: "3", newValue: "   ")
                == ["--repeat=0"])
    }

    /// A form that opened blank (`repeatEditValue` is `""` for a job that
    /// already runs forever) and stayed blank must write nothing. This is
    /// the half that keeps the clear from firing on an untouched form.
    @Test func untouchedBlankRepeatWritesNothing() {
        #expect(CronViewModel.repeatEditArguments(existing: "", newValue: "").isEmpty)
    }

    /// `nil` = the caller never touched the field at all.
    @Test func nilRepeatWritesNothing() {
        #expect(CronViewModel.repeatEditArguments(existing: "3", newValue: nil).isEmpty)
    }

    /// A real count still goes through, trimmed — `--repeat` is
    /// `type=int` (`hermes_cli/subcommands/cron.py:97`), so a stray space
    /// would fail argparse.
    @Test func aRealRepeatCountIsForwarded() {
        #expect(CronViewModel.repeatEditArguments(existing: "", newValue: " 5 ")
                == ["--repeat=5"])
    }

    // MARK: - Prompt

    /// The same bug on the prompt field.
    @Test func emptiedPromptClears() {
        #expect(CronViewModel.promptEditArguments(existing: "check the logs", newValue: "")
                == ["--prompt="])
    }

    /// A job whose prompt was already empty (script-only, skills-only) must
    /// not be sent a no-op write on every unrelated save.
    @Test func untouchedBlankPromptWritesNothing() {
        #expect(CronViewModel.promptEditArguments(existing: "", newValue: "").isEmpty)
    }

    @Test func nilPromptWritesNothing() {
        #expect(CronViewModel.promptEditArguments(existing: "x", newValue: nil).isEmpty)
    }

    @Test func aRealPromptIsForwardedVerbatim() {
        // NOT trimmed: a prompt's leading/trailing whitespace is content,
        // and `_scan_cron_prompt` sees exactly what we send.
        #expect(CronViewModel.promptEditArguments(existing: "old", newValue: " new ")
                == ["--prompt= new "])
    }
}

/// P18 — the cold-launch ordering hole P15 opened.
///
/// `cron doctor` prints its header as `  {id} {name}` and a job id may
/// itself contain spaces (`cron/jobs.py::load_jobs` adopts a `jobs.json`
/// map key verbatim), so the parse needs the id roster to know where the id
/// ends. On a cold launch `onAppear` starts `load()` and `loadDoctor()`
/// together and `jobs.json` wins, so the doctor parsed against an EMPTY
/// roster and fell back to the weak `isPlausibleJobID` heuristic — and the
/// re-parse in `load()` was gated on `hasLoadedDoctorFindings`, which is set
/// at the END of the doctor run and so is false at exactly the moment the
/// race needs it.
///
/// The fix retains the doctor's raw stdout and RE-PARSES it against the new
/// roster. No re-spawn, which is also why it needs no capability gate (C1):
/// a host that never ran the verb has no retained output.
@Suite struct CronP18DoctorRosterOrderingTests {

    static let output = """
        Cron doctor found 2 issue(s) across 2 job(s):

          nightly backup Nightly backup
            - workdir not found: /srv/gone

          4f2a9c1b7e03 Digest
            - last run failed: boom

        Next: fix the listed job config, then run `hermes cron doctor` again.
        """

    /// Doctor answers FIRST, roster lands second — the cold-launch order.
    /// Before the fix nothing re-parsed and `nightly backup` stayed filed
    /// under the fallback's guess, so the real job carried no warning.
    @Test @MainActor func aRosterThatArrivesAfterTheDoctorStillReKeysTheFindings() throws {
        let vm = CronViewModel()
        vm.adoptDoctorOutput(Self.output)
        // Parsed with no roster: the spacey id could only be guessed at.
        #expect(vm.doctorFindings["nightly backup"] == nil)

        vm.jobs = [Self.job(id: "nightly backup"), Self.job(id: "4f2a9c1b7e03")]
        vm.reparseDoctorFindings()

        let backup = try #require(vm.doctorFindings["nightly backup"])
        #expect(backup.jobName == "Nightly backup")
        #expect(backup.issues == ["workdir not found: /srv/gone"])
        #expect(vm.doctorFindings["nightly"] == nil)
    }

    /// Roster FIRST, doctor second — the same correct keys, proving the
    /// parse uses the roster current at completion time rather than a
    /// snapshot taken before the run hopped off the main actor.
    @Test @MainActor func aDoctorRunThatFinishesSecondUsesTheRosterItFinds() throws {
        let vm = CronViewModel()
        vm.jobs = [Self.job(id: "nightly backup"), Self.job(id: "4f2a9c1b7e03")]
        vm.adoptDoctorOutput(Self.output)
        #expect(try #require(vm.doctorFindings["nightly backup"]).jobName == "Nightly backup")
    }

    /// C1: a host that never ran `cron doctor` has nothing retained, so the
    /// re-parse `load()` calls on every roster change is a pure no-op —
    /// no spawn, no findings, byte-identical rendering.
    @Test @MainActor func aHostWithoutTheVerbGainsNothingFromTheReparse() {
        let vm = CronViewModel()
        vm.jobs = [Self.job(id: "a")]
        vm.reparseDoctorFindings()
        #expect(vm.doctorFindings.isEmpty)
        #expect(vm.isLoadingDoctor == false)
        #expect(vm.hasLoadedDoctorFindings == false)
    }

    static func job(id: String) -> HermesCronJob {
        HermesCronJob(
            id: id, name: id, prompt: "p",
            schedule: CronSchedule(kind: "cron", expression: "0 3 * * *"),
            enabled: true, state: "scheduled"
        )
    }
}
