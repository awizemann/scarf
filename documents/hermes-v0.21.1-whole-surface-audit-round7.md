# Whole-surface audit round 7 — after the P54–P59 remediation branch

Date: 2026-09-13. Branch `fix/whole-surface-audit-r6` (P54–P60, from `main` at `d53d3cbe`), merged to `main` as `merge(whole-surface-audit-r6)`. Round 6 is `documents/hermes-v0.21.1-whole-surface-audit-round6.md`; the brief is `documents/hermes-v0.21.1-parity-agent-brief.md` plus `documents/hermes-v0.21.1-round6-agent-addendum.md`; per-phase lessons are the "Whole-surface remediation — P54" … "P58" sections (each with a `b` subsection), "P59 — cross-phase remediation", "P60 — pre-merge remediation of the round-7 NEW findings", "Round-6 product decisions (Alan, 2026-09-13)" and "Round 6 — memory audit (2026-09-13)" in `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md`.

## Branch contents

| Phase | Commits | Subject |
|---|---|---|
| P54 | `018194b7`, `acefd89a`, `ccb1a8a4` | five CLI verdicts (`import --force` per decision 1 — every restore into a live home was exit 1 on the un-piped `input()`; `backup` complete/incomplete; `webhook remove|test` three arms each; `debug share` partial upload; curator prune-only note per decision 2); `MCPTestResult.confidence`; `--` on `profile`/`curator`; `kanban purge` deliberately WITHOUT `--` (`archive --rm nargs="+"` would starve); iOS `COLUMNS`. P54b `218ddf38`, `a3f4647a`, `28ba0cfb`: 22 catalogue rows, `OutcomeMessage.Kind` triad (the seal is a consumer too), `profile rename --`, C1 below v0.17 argued at v2026.3.30 |
| P55 | `ac135138`, `a275f59a`, `9d2c151e` | `hasKanban` 0.12 → 0.13 (tag, not release), `hasMCPIdentityHeader` → 0.20.1, `hasBotChatCreationCLI` → 0.20.5; `/goal`/`/subgoal` mirrors dropped per decision 3 (real TUI/gateway commands since v2026.5.7 / v2026.5.16, never in the ACP `_COMMANDS` table); decisions 4–5 doc-only. P55b `e6cfe38d`, `3696127c`, `475dec73`: `commands.py:103` @ v2026.5.7, `PlatformsViewModel.restartBanner` green-seal, three orphan rows, the `_parser.py` anchors |
| P56 | `d3db068c`, `e4e25ccb`, `9c882c65`, `e3eeaca7`, `058ea28c`, `070688ee` | iOS `buildJob` clears `next_run_at` on a schedule move (round-6 HIGH) + three `parse_schedule` refusals in the form (lesson 14); Review exits behind the NEW `hasKanbanReviewExits = isV0201OrLater` — decision 6 named `hasKanbanV015` and the tag walk found `complete_task` takes `review` only from v2026.8.13; fleet `--repeat` forwarded (decision 7), model-pin downgrade note at both seams (decision 8), drag-to-Running confirm sheet (decision 9); `--branch` deleted. P56b `6a641ee8`, `aa708b9c`, `e7e2d71e`: group-test membership, `jobs.py:757-758`, honest test doc |
| P57 | `ea83357d`, `a3a6564b`, `27b17954` | folded-continuation hoist (44/572 → 0), `boolishValue` trim-after-unquote + PyYAML int resolver (1041/2065 → 0), dotted-key `isBlock`. P57b `ccc21bcc`, `7e9f2ec2`, `172ded54`, `8dc79784`: double-quoted escapes decoded before the trim; `busy_ack_enabled` takes NO trim (Hermes's env bridge has none, `run.py:1816-1821`, `run_busy.py:727`) and quoted `yes`/`on` are strings; the dotted key must CROSS the section boundary; block scalars (`|`/`>`) captured verbatim — a `system_prompt: |` personality rendered empty before |
| P58 | `d0d4031c` … `b26c0a1f` (8) | `PipeReader` hoisted from ACP's `PipeLineReader` and generalised, the four streaming spawns off the pool (decision 10); iOS seam async via `asyncRunProcess` (decision 11, 11 sites); six main-actor env/`run()` sites; ACP close watchdog SIGINT→SIGTERM→SIGKILL; the sweep widened to eight needles with a counted baseline. P58b `081f4437`, `1e4c75b4`, `720dbdc2`: blank log lines were being dropped (a hoisted primitive carries its donor's semantics — `skipEmpty` is now a stated parameter), ceilings not bets, `proc.run()` needle |
| P59 | `64d87812` … `befa36c2` (7) | cross-phase: the sweep could not see `ctx.runHermes(` (nine ViewModel bodies + `KanbanToolsetDetector` converted, baseline 38 hits / 26 keys); three more `.unconfirmed` collapses; `No result: %@` row; Webhooks flag clearing; kanban onboarding gated on `hasKanban` (a 0.12 host was offered `hermes tools enable kanban`); `hasBotChatCreationCLI` moved to the v0.20.5 group; citation fixes; `ProcessDrainP43Tests` ceiling |
| P60 | `93ddd327`, `35820200`, `1a81eca1`, `8fbfb7b6`, `66bf7f40`, `3b31cc5a`, `20193227`, `83a0874c` | round-7 NEW findings fixed pre-merge: `+`-chomp phantom blank (48/160 → 0); OffPool needles 12 → 15 with per-root floors and a roster pin (baseline 49 hits / 32 keys); `onlyReadEndsLeak` min-of-three; kanban confirm after the plan; iOS cron titles as `LocalizedStringResource`; two `memory reset` rows + `%d` specifier in the scan; `profile create|delete|rename --` (BotsService and `ProfilesViewModel.create`); three doc claims |

## Verdict

**P54–P59 hold.** Every round-6 finding on every surface was re-derived by the five round-7 reviewers and found fixed at `befa36c2`. Round 7 found **4 HIGH, 22 MED, 22 LOW** (plus 11 informational). Eleven NEW items (introduced by the branch or by its new machinery) were fixed pre-merge as P60. The PRE items are filed as P61–P65 with ten product decisions for Alan.

Defect classes, round 7:

1. **A sweep that names the wrapped call cannot see the wrapper — and a needle's wrappers are a derivable set.** P59 fixed `ctx.runHermes(`; the same round left `runHermesCLISplit(`, `runHermesSync(`, `capabilitiesSync(` (16 sites) and the guarded-store spellings. The rule the sweep still lacks: a needle must be accompanied by every one-call wrapper of it in the tree, mechanically enumerated.
2. **The sweep's DOMAIN is `Task.detached` bodies; a blocking seam in a plain `async func` or an actor method is invisible by construction.** Eleven sites in backup/restore/logs, none reachable by any sweep. The region, not the needle, is the gap.
3. **A hoisted primitive carries its donor's semantics.** P58 parameterised the trailing-partial branch and shipped the empty-frame skip unchanged; P60 found the `+`-chomp branch of P57b's block-scalar capture the same way. Enumerate every branch the donor's behaviour depends on and ask once per branch.
4. **A floor set by a Hermes comment is a release-note floor.** `hasXAIVoiceCloning` survived six rounds because the tag diff is real and lands on the right line — it is a comment. Open the implementation at the tag before, not the config default.
5. **The optimistic mirror's idle twin, one more time.** The dispatch confirm (decision 9) landed on `attemptMove`; `reassignTask` and `createTask` run the same board-wide pass unconfirmed. The Review-exit fix restated the Review-entrance refusal without citing it, and `request-review` exists at the same tag.
6. **An edited field computes other fields.** The round-6 HIGH was `next_run_at`; the round-7 MED is the model-pin snapshots one field over, and the duplicate's strip list one function over.

## Test-infrastructure state

At `befa36c2` (pre-P60): ScarfCore **3276 tests / 281 suites** (+42 / 3), ScarfIOS **60 / 12**, Mac `scarfTests` **serial 1421 / 209, 0 failures, ~134 s**, `scripts/tests` 20/20; Mac Debug and `scarf mobile` build. Load flakes: `ProcessDrainP43Tests` (ceiling raised in P59, not reproduced since), `OffPoolP52Tests.allArrived` and the `M4ACPIOSTests` initialize timeouts (parallel load only). **Mac PARALLEL `xcodebuild test` is red and has been: 84 issues / 8 suites on the branch, 124 / 12 on `main` at `d53d3cbe`** — shared-global-state suites; serial is the usable signal and every report must say so (filed on P63). UI tests were not run on this branch at Alan's request. Memory health after the round-6 audit: 71 → 52 flagged, `codeChanged` 52 → 33, zero broken relations; 13 notes still outside the six folders (the refile queue for Alan, unchanged).

Final independent pass on the merge candidate: head `83a0874c` — Mac Debug and `scarf mobile` build; ScarfCore **3281 / 282 suites** (+42 / 3); ScarfIOS **60 / 12**; Mac `scarfTests` serial **1427 / 209 suites, 0 failures, 142 s**; `scripts/tests` 20/20. No reruns needed.

## Product decisions for Alan (calls, not bugs)

1. **Web Dashboard row** (P61): gate on `hasDashboardCommand` (hides it on v0.6–v0.8 hosts, C1-visible), or keep visible with an honest "this Hermes has no `dashboard` verb"? Reviewer's read: gate it.
2. **Pairing's bare refusal** (P61): `HermesPairingVerdict` runs `fallbackDetail: false` on purpose; the third state needs a neutral sentence, not a quoted tail — wording to confirm.
3. **`/new <name>`** (P62): withdraw the argument hint now and file the feature (reviewer's read), or implement `startNewSession(name:)` (ACP `session/new` carries no title at any tag, so the name is Scarf-side or CLI)?
4. **`ChatViewModel.launchTerminal`'s main-actor env probe** (P63): split it now (the `SpotifyAuthFlow` shape) or leave another round?
5. **Backup/Restore blocking seams** (P63): convert the eleven `runProcess` calls to `asyncRunProcess` now (one line each, shipped surface — reviewer's read: yes) or defer to t-02f830f4?
6. **YAML anchors** (P64): refuse a config carrying `&`/`*` with a read-only banner, or teach the reader anchors/aliases? Today it silently drops a subtree.
7. **`str()` trailing comments** (P64): route free-form `str()` through `normalizedScalar`'s comment rule (PyYAML-faithful, changes ~60 Settings fields' display), or keep the verbatim value and gate the write-back?
8. **Duplicate top-level sections** (P64): writer edits last-wins to match the reader, or refuse with "this config has two `slack:` blocks"?
9. **Review entrance** (P65): add running/ready → review via `kanban request-review` behind `hasKanbanReviewExits` (confirm for `--force`), or keep it locked and reword the refusal?
10. **Unconfirmed dispatch twins** (P65): confirm sheet on `reassignTask`/`createTask` too, or stop dispatching from those gestures?

## Proposed remediation phases (P61+)

Filed as Memophant tasks: **P60** (done pre-merge, this branch); **P61** `t-11371e30` CLI verdict residue (decisions 1–2); **P62** `t-fa0043f6` capability floors (decision 3; relates t-54ec6eb3, ~21 flags left); **P63** `t-d2000dc5` C10 residue (HIGH; decisions 4–5); **P64** `t-d1d324ff` YAML writer/reader residue (HIGH; decisions 6–8); **P65** `t-ad965a68` cron/kanban residue (decisions 9–10). Still open and relevant: t-02f830f4, t-406d56d6, t-54ec6eb3, t-295ef4d2, t-f655c541, t-8f55df7d, t-3bcd1d7f, t-e9c464a9, t-b74c65a4, t-b290817d, t-78ced4d2, t-fc4d3a6f, t-62dee8aa, t-46f089cf, t-a9ef75f0 (SectionSweep UI test), t-1febd6fa, t-848d3adc, t-6e9a0985, t-d02dd23e, t-1eaf1579, t-15013d78.

---

# Per-surface reviewer reports (condensed)

Five read-only reviewers at `befa36c2`. NEW = introduced by this branch or by machinery it built (fixed in P60). PRE = pre-existing (P61–P65). Every round-6 finding on every surface was re-derived and found fixed.

## Cron, Kanban, Sessions, Fleet apply

- **MED · PRE** iOS cron form edits `model` and forwards stale `provider_snapshot`/`model_snapshot` in `extra` (`CronListView.swift:398,589`; `update_job` recomputes at `cron/jobs.py:1951-1963`; drift guard `cron/scheduler.py:1569-1591` skips the job with a warning Scarf never shows) · P65.
- **MED · PRE** `duplicatedAsNewJob` (`HermesCronJob.swift:551-556`) carries `run_claim`/`fire_claim`/`created_at`/`failure_streak`/snapshots that `create_job` (`:1760-1797`) stamps fresh; a duplicate of a mid-run `once` job is permanently stuck (`:2919-2923`, `:2862`) · P65.
- **MED · PRE** the Review ENTRANCE refusal is false: `kanban request-review` (`kanban_parser.py:312-320`, `kanban_db.py:2992-3060`) exists from v2026.8.13, the floor `hasKanbanReviewExits` already carries · P65, decision 9.
- **MED · PRE** `reassignTask` (`KanbanBoardViewModel.swift:464`) and `createTask` (`:500`) run the board-wide dispatch unconfirmed · P65, decision 10.
- **MED · PRE** `FleetApplyExecutor` parks up to four pool threads on sync `ctx.runHermes` per job per host (`:142-172`, `:341`, `:417`) · P63.
- **MED · PRE** `GuardedJSONStore(`/`store.inspect(`/`GuardedTextFile(` inside `Task.detached` at six sites in five files, no needle · P63.
- **LOW · NEW** the dispatch confirm was raised BEFORE the plan, so a refused source asked first and failed after (`KanbanBoardViewModel.swift:313-322`) · fixed in P60.
- **LOW · NEW** the `"Edit cron job"` catalogue row was unreachable: `.navigationTitle(title)` took the `StringProtocol` overload verbatim (`CronListView.swift:300,409`) · fixed in P60.
- **LOW · PRE** `cronExpressionHasParseableShape` splits on fewer whitespace characters than Python's `str.split()` · P65. **LOW · PRE** `beginExport` comment contradicts its own remote guard · P65. **LOW · NEW** `CommandDef("kanban")` cited to `kanban.py` instead of `commands.py:163` · fixed in P60.
- Test quality: `FleetModelPinNoteP56Tests` pins exact code spellings (P65); `KanbanDispatchConfirmP56Tests` lacked the refused-destination case (P60).
- Verified sound: ~45 `cron/jobs.py` ranges, the whole `subcommands/cron.py` and `sessions.py`, `kanban_parser.py`, `kanban_db.py`, `kanban_output.py`; tags walked both ways for `complete_task`, `reopen-review`, `request-review`, `kanban.py`; the `review → blocked` scoping; C3/C6/C10 timeouts across the surface; `scheduleFormRefusal` rendered and matching `compute_next_run`'s three nil paths.

## Settings, YAML writers/readers, config reads and writes, managed hosts, platform-setup forms

Oracle: PyYAML 6.0.3 from a scratch SwiftPM harness linking ScarfCore — 600 `yaml.dump` docs / 2663 leaves; 1451 bool scalars × 4 readers; 120 block-scalar docs; 89 writer round-trips; 11 bridge shapes; 42 structural probes.

- **HIGH · PRE** `GatewayConfigWriter.keyLineKind` (`:542-549`) treats `key: |` as `.inlineValue`; `setListChecked` orphans the body → ScannerError → `load_config` discards the whole config.yaml layer (`gateway/config.py:775-791`). 4/4 · P64.
- **MED · NEW** every `+`-chomped block scalar gained one spurious trailing newline (36/36 `|+`/`>+`/`|2+`; the phantom `""` from the document's terminating newline) · fixed in P60.
- **MED · PRE** a blank line inside a folded quoted scalar is a newline, Scarf joins with a space (41/2663) · P64.
- **MED · PRE** duplicate top-level section: writer first-wins, PyYAML last-wins · P64, decision 8. **MED · PRE** anchored key → dangling alias → ComposerError · P64. **MED · PRE** anchored SECTION drops its subtree in the reader · P64, decision 6. **MED · PRE** `str()` keeps ` # comment` and the Settings field writes it back (`HermesConfig+YAML.swift:191-194`, `TerminalTab.swift:18`) · P64, decision 7.
- **MED · NEW** `runHermesCLISplit(` invisible to the OffPool sweep (8 sites) · fixed in P60.
- **LOW · PRE** nulls read as text; `ProfileRoutesWriter` wholesale line endings; `parseFlatFlowList` nested brackets; multi-document files; deleting a platform's last key moves the bridge source · P64.
- Verified sound: the P57/P57b hoist, trim, `busyAckEnabled`, `mattermostRequireMention` at 0 disagreements on every corpus; `bridgeSourcePrefix` 11/11; every non-`+` block-scalar header 84/84; CRLF/BOM/`---`/duplicate keys/quoted keys; `setMapChecked` 0 collateral; `_SHARED_KEYS` 27/27 (round 6 said 25); `HermesManagedInstall.system` line for line; `HermesConfigSet` nine refusal arms; iOS twins share the readers.

## CLI outcome verdicts

134 hermes-argv invocation sites (68 app / 61 ScarfCore / 5 iOS) with the widened vocabulary; handlers opened at v2026.9.7 for every verb Scarf shells.

- **MED · PRE** seven `.unconfirmed` arms still reach a two-way `if` (`MCPServersViewModel:157-167`, `ToolsViewModel:81-92`, `SkillsViewModel:953-974`, `ProjectSkillsViewModel:85-94`, `GatewayViewModel:581-615`) · P61.
- **MED · PRE** Web Dashboard row ungated; `dashboard` absent at v2026.3.30; `hasDashboardCommand` has zero consumers; the spawn is unbounded · P61, decision 1.
- **LOW-MED · NEW** two `memory reset` localized keys with no catalogue row (`HermesCLIOutcome.swift:2135,2137`) · fixed in P60.
- **LOW · NEW** `BotsService.swift:340,355,357` `profile create|delete|rename` without `--` (the Mac twin has it) · fixed in P60.
- **LOW · PRE** `curator rollback|adopt` without `--`; `SkillsViewModel:972` quotes the exit code; memory-reset alert two-state; `migrateXAISummary` else-arm unconditional · P61.
- Verified sound: every round-6 item; `COLUMNS=400` unconditional in all three spawn families; all 24 `OutcomeMessageBar(` sites pass `kind:`; 43 of 44 branch-added `String(localized:)` keys with six locales; P54b/P59 citations re-verified to the line.

## Capabilities, floors and gates, chat/ACP

29 flags walked with the blob opened at the floor tag and the tag before (list in `t-fa0043f6`); ~21 remain on t-54ec6eb3.

- **MED · PRE** `hasImageGenModel` floored 0.13; real floor 0.11.0 (`tools/image_generation_tool.py:495-508` @ v2026.4.23) · P62.
- **MED · PRE** `hasXAIVoiceCloning` floored 0.13 on a Hermes COMMENT (`config.py:887` @ v2026.5.7); `_generate_xai_tts` byte-identical across the boundary · P62.
- **MED · PRE** the unknown-slash notice is a two-name allowlist; every other non-roster name still burns a turn silently on both targets · P62.
- **MED · PRE** `hasNewWithSessionName` arms a `/new [<name>]` hint both consumers discard · P62, decision 3.
- **MED · PRE** `ChatViewModel.deleteSession:2591` blocks the main actor on a spawn; its twin `SessionsViewModel.confirmDelete` hops off · P62.
- **MED · PRE** two flags in no test (`hasSkillsUninstallYes` — also in the wrong group; `hasEssentialHermesAgentSkill`), seven absent from `HermesCapabilitiesTests` → mechanical guard · P62.
- **LOW · PRE** `hasCronWorkdir` doc names `--context-from` (no tag); `hasVercelTerminal` is a window · P62.
- **NEW: none on the flags themselves.** C4 clean; every ACP method present at v2026.3.30; the roster equals `_COMMANDS`; the P58 channel keeps `cancelAfterDrainingPipe` and the watchdog escalation.

## Concurrency and spawn discipline (C10), transports, templates/backup/restore, iOS twins, test health

- **HIGH · NEW** sixteen blocking spawns inside `Task.detached` behind three wrapper spellings no needle covers (`runHermesCLISplit(`, `runHermesSync(`, `capabilitiesSync(`) · fixed in P60 (needles, calibration, conversions/baseline).
- **HIGH · PRE** the sweep's domain is `Task.detached` bodies; eleven blocking seams in plain `async func`s/actor methods (`RemoteBackupService`, `RemoteRestoreService`, `HermesLogService.readLastLines`, `UserHomeCache.probe`) · P63, decision 5.
- **MED · NEW** the P52 sweep's per-root floor was `> 0` and its roots had no roster pin · fixed in P60.
- **MED · NEW** `SpawnDisciplineP43Tests.onlyReadEndsLeak` is a process-wide fd bet that loses under parallel load on this branch · fixed in P60 (min-of-three).
- **LOW · NEW** `PipeEOFSignal` one-waiter contract undocumented; `runSync`'s backstop `partialStdout: Data()` · fixed in P60 (doc lines).
- CALLs: `launchTerminal`'s main-actor env (decision 4); backup/restore (decision 5).
- `PipeReader` fuzz clean: 12 cases incl. byte-at-a-time, 8 MB chunks, split code points, 10.5 MB single line, invalid UTF-8 strict/lenient, consumer drop ×50, `cancelAfterDrainingPipe` — fd count 4 → 4 throughout.
- Verified sound: 22 `Process()` sites all bounded/drained/pid-guarded; 6 stream producers with `onTermination`; 11 `asyncRunProcess` sites bounded with real partial stdout; 8 `runSync` callers; the 7 allowed fixed sleeps; 12 timing assertions classified (8 ceilings, 4 fd bets — 3 mitigated, 1 fixed in P60).
