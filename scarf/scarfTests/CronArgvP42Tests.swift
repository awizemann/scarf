import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P42 · decision 7, the cron half — a user-typed option VALUE beginning with
/// `-` must survive argparse. The primitive and the kanban/fleet half live in
/// `ScarfCoreTests/HermesCLIOptionP42Tests`; the cron builders are app-target
/// statics, so they are asserted here.
///
/// `--` is not the fix: it ends the OPTIONS, so it protects the trailing
/// schedule/prompt positionals and nothing else. `parse_args(["--name",
/// "-nightly"])` is `error: argument --name: expected one argument`, exit 2 —
/// argparse tests `-nightly` for option-ness before `--name` is given a value.
///
/// Flags walked at `v2026.9.7`: `hermes_cli/subcommands/cron.py:28-31`
/// (`create --name`/`--deliver`), `:32-37` (`--failure-deliver`), `:38`
/// (`--repeat`), `:39-40` (`--skill`, `action="append"`), `:41-49`
/// (`--script`), `:63-65` (`--workdir`), `:91-97` (`edit --schedule/--prompt/
/// --name/--deliver`), `:99-105` (`--skill`/`--add-skill`/`--remove-skill`).
/// Every one is a bare `add_argument` with no `nargs` — the only shape the
/// `=` form is valid for.
@Suite struct CronArgvP42Tests {
    // MARK: - cron create

    @Test func cronCreateCarriesEveryUserTextValueInOneToken() {
        let args = CronViewModel.createJobArguments(
            schedule: "0 9 * * *",
            prompt: "-check the feed",
            name: "-nightly",
            deliver: "-discord:ops",
            skills: ["--x"],
            script: "-run.sh",
            repeatCount: "3",
            workdir: "-/tmp/w",
            noAgent: false,
            failureDeliver: "-local"
        )
        #expect(args.contains("--name=-nightly"))
        #expect(args.contains("--deliver=-discord:ops"))
        #expect(args.contains("--failure-deliver=-local"))
        #expect(args.contains("--repeat=3"))
        #expect(args.contains("--skill=--x"))
        #expect(args.contains("--script=-run.sh"))
        #expect(args.contains("--workdir=-/tmp/w"))
        // Not one bare option/value PAIR is left: no element equals a flag
        // these builders emit with a value.
        for flag in ["--name", "--deliver", "--failure-deliver", "--repeat",
                     "--skill", "--script", "--workdir"] {
            #expect(!args.contains(flag), "\(flag) is still a two-token pair")
        }
        // The positionals still ride behind `--`, unchanged.
        #expect(Array(args.suffix(3)) == ["--", "0 9 * * *", "-check the feed"])
    }

    // MARK: - cron edit

    @Test func cronEditCarriesEveryUserTextValueInOneToken() {
        #expect(CronViewModel.promptEditArguments(existing: "old", newValue: "-new")
                == ["--prompt=-new"])
        // The documented clear gesture stays an EMPTY value, not a dropped flag.
        #expect(CronViewModel.promptEditArguments(existing: "old", newValue: "")
                == ["--prompt="])
        #expect(CronViewModel.repeatEditArguments(existing: "5", newValue: "")
                == ["--repeat=0"])
        #expect(CronViewModel.repeatEditArguments(existing: "", newValue: "2")
                == ["--repeat=2"])
        #expect(CronViewModel.skillEditArguments(
            existing: ["browse"], newSkills: ["--sum"], clearSkills: false)
                == ["--remove-skill=browse", "--add-skill=--sum"])
    }

}
