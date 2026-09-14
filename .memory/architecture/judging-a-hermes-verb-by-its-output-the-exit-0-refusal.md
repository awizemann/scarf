---
title: Judging a Hermes verb by its output: the exit-0 refusal FAMILY and the anchored-prefix rule
type: note
permalink: scarf/architecture/judging-a-hermes-verb-by-its-output-the-exit-0-refusal
tags: [hermes-cli, verification, capability-gating, round-4]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift]
source_paths_inferred: false
source_sha: 720dbdc26d8e55d9c470297b4108454262ab4d45
created: 2026-09-11
updated: 2026-09-13
reviewed: 2026-09-13
reviewed_by: claude-opus-5
---

Round 4 (P39–P40) turned two one-off lessons into rules for every `HermesCLIVerdict` call site. Both are about the same failure mode: Scarf shells a Hermes verb, gets exit 0, and reports success for a run Hermes refused — or the mirror image, reports failure for a run that worked.

The judge lives in `ScarfCore/Services/HermesCLIOutcome.swift` (`HermesCLIVerdict.judge(output:exitCode:successMarkers:failureMarkers:anchoredFailureMarkers:failureWins:)`).

## Observations
- [invariant] The exit-0 refusal is a FAMILY, not a handler. A Python `-> None` handler cannot signal failure by status, so EVERY refusal on that verb's path exits 0. When a phase touches one CLI verdict, enumerate every handler on that verb's path from the TAGGED source and judge them all — `pairing approve`/`revoke` (one `-> None` dispatcher, two `-> None` handlers), the five managed-lock verbs, the gateway and plugins verbs were each found this way #verification
- [invariant] A failure marker that can appear inside USER TEXT must be matched ANCHORED at column 0, never as a bare substring. `set_config_value` echoes the user's value (`✓ Set {key} = {value} in {config_path}`, `hermes_cli/config.py:3521` @ v2026.9.7), so a bare `is managed by` inside a QuickCommands prompt flipped a completed write to failure. `judge` takes `anchoredFailureMarkers` and the shared set is `HermesCLIMarkers.managedRefusalAnchored = ["Cannot "]` #verification
- [gotcha] A refusal and a success line arrive in the SAME run at exit 0, so any verdict on a `save_config` door needs `failureWins: true` — the marker alone is not enough. Mid-sentence markers that CANNOT appear in user text (the plugins sets) stay substrings and carry the anchored list alongside #hermes-cli
- [gotcha] `HermesCLIMarkers.managedRefusal` (the UNANCHORED `is managed by` constant) was DELETED in round 4 — it had no caller left and was a loaded gun for the next one. Reach for `managedRefusalAnchored`; the per-verb sets (`configSetFailure`, `configUnsetFailure`, `skillsTrustFailure`, `memoryOffFailure`, `gatewayServiceFailureAnchored`, `mcpRemoveFailure`) each PREPEND it #hermes-cli
- [gotcha] An anchored marker is not a claim about WHY. `["Cannot "]` proves a refusal happened, not that the host is managed; copy that names a cause needs its own citation on the same line #verification

## Round 5 (P47) — what the family grew, and the third answer it needed

Round 5 enumerated the family by grepping `runHermesCLI(` / `runHermes(` callers across
`scarf/scarf`, `scarf/Packages/ScarfCore/Sources` and `scarf/Scarf iOS` rather than by verb, and
found five more. P46 took the branch-adjacent ones (`tools enable|disable`, the iOS chat preflight,
`BotAgentViewModel.perform`); P47 took the rest.

- [invariant] **A "nothing to do" arm is a SUCCESS with a neutral note, not a failure** — the
  gateway `nothingWasRunningNote` shape, now the house answer for three verbs. `auth logout`'s two
  arms (`No provider is currently logged in.` `hermes_cli/auth.py:2180`, `No auth state found for
  {name}.` `:2185`) and `memory reset --yes`'s `Nothing to reset — no memory files found in …`
  (`hermes_cli/main_agent_cmds.py:33`) all exit 0 having changed nothing. The user asked for the
  provider to be logged out / the memory to be empty, and it is; the `warning` is what stops the
  banner claiming a removal happened. Both walked at `v2026.6.19`, `v2026.7.30`, `v2026.8.19` and
  `v2026.9.7` — byte-identical, so C1 holds #verification
- [gotcha] **`plugins install --enable` is the SIXTH `save_config` door**, and it was missed in
  round 4 because the enable is a half of a different verb. `cmd_install`
  (`hermes_cli/plugins_cmd.py:702`) → `_set_plugin_enabled` (`:754`) → `_write_config_value`
  (`:115-120`) → `save_config`, and `:755` prints `✓ Plugin <name> enabled.` over the refusal at
  exit 0. The lesson generalises: **a door is any call path that reaches `save_config`, not any
  verb named after a config write** #hermes-cli
- [gotcha] **A success marker that is a PREFIX of the verb's own in-progress line proves nothing.**
  `sessions optimize` prints `Optimizing session store (FTS merge + VACUUM)…`
  (`hermes_cli/sessions_cmd.py:811`) on EVERY run, before it can fail; the success line is
  `Optimized {n} FTS index(es).` (`:817`). The trailing space in the marker `"Optimized "` is what
  separates them, and its failure arm — `Error: optimization failed: {e}` (`:815`), caught and
  returned — exits 0 like the rest of the family #verification
- [convention] **Once a verdict exists, the failure branch must stop quoting the exit code.**
  "Optimize failed (exit 0)" is the original bug in a new voice; quote the emitter's own reason
  line, and where the run printed nothing recognisable say THAT rather than naming a status the
  verdict has just declared meaningless #ux



## Round 6 (P54) — the family's last five, and three rules the round added

P54 took the remainder of the round-5 enumeration (`t-4edfd804`, folded in): `backup`, `import`, `webhook remove|test`, `debug share`, plus `curator run`'s prune-only note and `migrate xai`'s second exit-0 arm. All verified at `v2026.6.19`, `v2026.7.30`, `v2026.8.19`, `v2026.9.7`.

- [gotcha] **A verb can be UNREACHABLE, not merely mis-judged.** `hermes import` never once restored into a live Hermes home from Scarf. `run_import` gates on `not args.force and not _confirm_import_overwrite(...)` (`hermes_cli/backup.py:942` @ `v2026.9.7`) and that confirm calls a bare `input()` (`:836`) on a stdin the GUI child inherits closed — `EOFError` → `Aborted.` → `sys.exit(1)` (`:837-839`). The pane showed "Restore failed" with no hint. **When a verb's failure rate is 100%, suspect a prompt before suspecting the user's input**, and look for the `--force`/`--yes` the CLI offers for exactly this (round-6 decision 1: the GUI's own confirm sheet IS the consent; never pipe `y` — that is Scarf consenting on the user's behalf) #hermes-cli
- [invariant] **`.unconfirmed` must be gated on the CONFIDENCE ALONE, never on `detail` being empty.** `judge` fills `detail` with `lines.last` on every arm including the unconfirmed one, and that tail is usually an unrelated progress line — so `confidence == .unconfirmed && detail.isEmpty` falls through to the FAILURE voice and renders "Backup failed: Scanning ~/.hermes ..." — a progress line presented as Hermes's reason for a refusal it never made. Five helpers shipped this in P54's first draft and passed their own tests, because every unconfirmed fixture in the suite was the EMPTY string. **A three-state test suite needs an unconfirmed case WITH output** #verification
- [gotcha] **`urllib.request` raises on any non-2xx**, so `hermes webhook test` can never print `Response (500)` — `HTTPErrorProcessor` sends it to `_cmd_test`'s `except Exception`, which prints `Error: HTTP Error 500: …` plus a misleading `Is the gateway running?`. A whole rationale and a test fixture were built on the unreachable line. **Before citing an output line as reachable, read the library call that would have to produce it**, not just the `print` #hermes-cli
- [gotcha] **`--` is not universally safe on a verb with two list-valued parsers.** `kanban archive` carries BOTH `task_ids` (`nargs="*"`) and `--rm`/`purge_ids` (`nargs="+"`) — `hermes_cli/kanban_parser.py:335-338` — so `archive --rm -- a b` hands the ids to the POSITIONAL and leaves the destructive flag empty: an exit-2, or a silent ARCHIVE where the user asked for a permanent delete. The round-6 report listed this as `--` residue; it is the one place the separator must NOT go, and the absence is pinned by a test. The P47 rule ("safe wherever the parser is a plain positional") holds — this verb's parser is not one #hermes-cli
- [convention] **A success may carry a `detail`, but only where the emitter's line is the RESULT.** Two documented exceptions now: `webhook test`'s `Response ({status}): {body}` (the gateway's own answer, the whole point of the button) and `backup`'s `Backup incomplete: {path}` (which archive is the partial one). Every other verdict leaves it `nil` on success, and the struct's doc names both so a consumer rendering `detail` unconditionally knows to check #conventions



## Relations
- relates_to [[A managed Hermes install refuses every config write at exit 0 — one marker, five verbs, one probe]]
- relates_to [[Hermes pairing approve/revoke refuse at exit 0 — judge by the printed marker]]
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]


## Round 6 (P54b) — the SEAL is a consumer of the verdict too

- [invariant] **A three-state verdict needs a three-state seal; a two-state renderer silently re-collapses the work.** P54 taught `HermesCLIOutcome` to answer `.succeeded` / `.failed` / `.unconfirmed`, and the CHROME around it stayed binary: `SettingsViewModel.runBackup`/`runRestore` routed `.unconfirmed` through `showSaveFailure`/`.failure`, and `WebhooksViewModel` set `messageIsError = !outcome.succeeded`. So "Hermes printed no result I can read" arrived under the red triangle, announced "Failed: …" — the same lie the judge was built to stop, one layer out. `OutcomeMessage` carries a `Kind` now and `OutcomeMessageBar` takes `kind:` with **NO default** across all 24 call sites (an added state with a default is an added state nobody adopts); the neutral arm is `questionmark.circle.fill` in `ScarfColor.warning`, the spelling `MCPServerTestResultView` already used for this verdict (`a3f4647a`). And the seal is not only an icon: P55b `3696127c` found `PlatformsViewModel`/`PluginsViewModel` painting a green seal on a restart nobody confirmed. **Enumerate every renderer of a verdict when the verdict gains a state** #verification
- [gotcha] **A verdict's call sites are also C10 sites.** The six `Task.detached { … fileService.runHermesCLI(…) }` blocks P54 edited are blocking process waits that belong in `OffPool.run { }`; P54 left them as it found them and P58 owns them (`SettingsViewModel.runBackup()`/`runRestore(fromPath:)`, `WebhooksViewModel.test(_:)` + its `runAndReload`, `ProfilesViewModel.runAndReload`, `HealthViewModel.runDebugShare(local:)`). Editing a line is not adopting its discipline — say which phase owns it #c10
