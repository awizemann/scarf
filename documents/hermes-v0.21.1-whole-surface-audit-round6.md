# Whole-surface audit round 6 — after the P47–P53 remediation branch

Date: 2026-09-12. Branch `fix/whole-surface-audit-r5` (P47–P53b, 43 code commits from `main` at `59fffa19`), merged to `main` as `merge(whole-surface-audit-r5)`. Round 5 is `documents/hermes-v0.21.1-whole-surface-audit-round5.md`; the brief is `documents/hermes-v0.21.1-parity-agent-brief.md` plus `documents/hermes-v0.21.1-round5-agent-addendum.md`; the per-phase lessons are the "Whole-surface remediation — P47" … "P53" sections (each with a `b` review-remediation subsection), the "Round-5 product decisions (Alan, 2026-09-12)" section, the "Round 5 — memory audit" section and the "P52 — cross-phase remediation" section of `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md`.

## Branch contents

| Phase | Commits | Subject |
|---|---|---|
| P47 | `f093af74`, `1e88ab3e`, `d1c46223` | four exit-0 refusal arms get output verdicts (`HermesPluginInstallOutcome.configWriteRefusal`, `HermesAuthLogoutVerdict`, `HermesMemoryResetVerdict`, `HermesSessionsOptimizeVerdict`); the Plugins pane takes the managed lock on activation only (decision 1) with the verdict as the env-var fallthrough; `auth logout`/`memory reset` neutral notes (decisions 2–3, Mac + iOS); `--` before positionals at six sites; P47b: the unconfirmed optimize strip, one reset alert, three corrected citations |
| P48 | `b34493a5` … `9cd3b986`, `d5abbe0a`, `8f0caf26`, `9acc8dbe`, `36395fc4`, `1376fd58` | `ProcessPipeDrainer` deleted onto `startDraining`/`waitDraining` (decision 4); `runProcess` timeout non-optional (decision 5) — which exposed that iOS `asyncRunProcess` never read its timeout; `StreamingChild` + `onTermination` + concurrent stderr on the four streaming spawns (decision 6); probe and script runner drain while they run; `Process.waitUntilExitAsync`; app-target waits off the pool with the P43c sweep widened to `scarf/scarf/` and `Task` closures; fixtures shrunk (decision 8); the repo-wide stability wave, 90 sites, scoping removed (decision 7); P48b: proxy Stop SIGTERMs before its grace, fd tests neighbour-insensitive, three bare `AppCoordinator()`s injected, iOS exec closes its channel via `withExec`, vacuous settle-poll, calibrated subscript matcher |
| P49 | `c718237d`, `b1cb58d7` | `hasACPSetSessionModel` retired (decision 9; `set_session_model` at `server.py:482` @ v2026.3.30 = 0.6.0), `hasYOLOSlashCommand` deleted (decision 10), `hasContextCompressionCount` re-documented; re-walk of 20 flags: `hasInsightsCommand` deleted (below minimum), `hasDashboardCommand` re-floored 0.16 → 0.9; P49b: the third compaction comment, `#filePath` exemption |
| P50 | `55e464f8`, `39b888d1`, `82881859`, `94c88e7f` | pre-v0.21 `error` hint names Duplicate (decision 11, walked at v2026.8.27); fleet `pre_run_script` downgrade note at both seams (decision 12 — `--script` exists but validates nothing at create); iOS `isValid` refuses a spent one-shot on create/duplicate only (decision 13); `KanbanWatchFilter` deleted; detail-pane Run now disabled; P50b: the editor's Enabled toggle locked like the row's, the missing `%lld` catalogue row + a file-scoped forward gate, the surviving `--json` claim, iOS Duplicate as a swipe action |
| P51 | `76206b4d`, `c838c562`, `c93c2287`, `6b7c5ffc`, `698bee29` | YAML reader trims space+tab only, PyYAML-faithful (decision 14; oracle on seven Unicode spaces); Signal/WhatsApp pairing disabled on remote with the host named (decision 15); exact override dedupe (decision 16); iOS `unsupportedLevelNotice` (decision 17); Auxiliary tab off-main; `allow_any_attachment` gated as a v0.15–v0.17 window (call sites counted per tag); Discord `history_backfill` floor-gated in `save`; Mattermost require-mention on config both ways; control-char refusal at `commitSave` for all fifteen forms; Ntfy `.env` half kept; P51b: mattermost's READ moved with its write (`sharedPlatformScalar` + `bridgeResolvedKeys`), decision 16's rule extracted to a function, the early guard |
| P52 | `189b3193`, `06698470`, `96089feb` | cross-phase remediation: `OffPool.run` (`withCheckedContinuation` + `Thread.detachNewThread`) replacing seven blocking `Task.detached` sites; the stability sweep counts URLs not basenames (335 files, floor 250, per-root non-zero); four wrong Scarf citations; the Discord window owns the v0.18+ and ≤v0.14 removals and joins `HermesCapabilitiesTests` |
| P53 | `1b0b641e` … `7abbdd45`, `5dfebff8` … `d0ff84ea` | round-6 NEW findings fixed pre-merge: brace-matched `OffPool` sweep with calibration; `scarf/Packages/ScarfIOS` in all three C10 sweep roots; `runSync(deadline:)`; iOS timeout keeps partial stdout (behavioural test); `auth logout` `.unconfirmed` third branch; mattermost's `{"false","0","no"}` coercion on both sides incl. PyYAML int spellings; Signal prerequisite row on remote; iOS editor lock note built from `ResumeRefusal { reason, remedy }`; three P50b test corrections; per-root floors on every sweep incl. `ScarfIOS/Tests`; analytics sweep recursive + `#filePath` |

## Verdict

**P47–P52 hold.** Every round-5 finding re-derived by the five round-6 reviewers is genuinely fixed at HEAD. Round 6 found **4 HIGH, 17 MED, 15 LOW**. The NEW items (introduced by the branch, 9 in all) were fixed pre-merge as P53. The PRE items are filed as P54–P58 with eleven product decisions for Alan.

Defect classes, round 6:

1. **A lesson that stops at its own phase's files.** P48 named `Task.detached` as a false escape and shipped the thread cure; P51 reached for `Task.detached` three times for the same purpose and P48's file-local sweep could not object. P49b named basename exemptions a coincidence and fixed the sweep it was editing, while the sweep it had just read kept the shape. P53's sweep-roots widening added ScarfIOS *Sources* and not ScarfIOS *Tests*. The round-5 rule "walk the siblings" is applied to `case` arms and to a diff's own files; it is not yet applied to **the machinery a phase inherits from an earlier phase**.
2. **A number in a comment that nobody re-measured.** "484 test files" (actually 335); `HermesFileService.swift:2468-2484` copied to three sites (the real range is `:2566-2583`); "14 tests" (18). A claim in a comment gets the same audit as a claim in a test only when something executes it.
3. **A floor taken from a release note that announced its own revert.** `hasKanban` at 0.12 — the board landed and was reverted in the same release; the tag has no `kanban.py`. Nine consumers. C2 in its purest form, and the round-5 rule "count call sites, not symbols" has a corollary: **cite a tag, never a release**.
4. **A verdict's `.unconfirmed` arm reaching a two-way `if`.** Fixed for `sessions optimize` in P47b, left on its sibling `auth logout` from the same commit. When a verdict grows a `confidence`, grep every consumer for a two-way branch.
5. **C1 argued on the axis the author chose.** The Discord window's C1 paragraph defended v0.15–v0.17 and never mentioned the v0.18–v0.20 users who actually lose a row. For every gate ADDED to a previously ungated surface, the question is "which version ranges render differently than in the last release", and the answer belongs in the source.
6. **iOS writes what the CLI would have validated.** The iOS cron editor forwards a stale `next_run_at` across a schedule change because no argparse stands behind a `jobs.json` write; every validation `cron edit` performs has to live in the form. P50b named this rule; the round-6 HIGH is its first instance.

## Test-infrastructure state

Post-P53b head: ScarfCore **3128 tests / 252 suites**, ScarfIOS **58 / 11**, Mac `scarfTests` serial (see the final-pass line below), `scripts/tests` 20/20; Mac Debug and `scarf mobile` build. The only recurring failure remains the parallel-load flake class (`ACPClientStartIdempotenceTests`, and once `ProcessDrainP43Tests`' zip duel under full parallel load), green in isolation — t-f3820038 was closed in P48 on the idempotence diagnosis; the zip duel is a fixture bet, not a bug. UI tests were not run on this branch at Alan's request. Memory health after the round-5 audit: 56 → 32 flags, zero broken relations; 13 notes still outside the six folders (the refile queue for Alan, unchanged); 12 `codeChanged` left deliberately (anchors moved, subjects did not).

Final independent pass on the merge candidate: head `d0ff84ea` — Mac Debug and `scarf mobile` build; ScarfCore **3128 / 252 suites**; Mac `scarfTests` serial **1337 / 195 suites, 0 failures, 126 s**; `scripts/tests` 20/20. No reruns needed.

## Product decisions for Alan (calls, not bugs)

1. **`hermes import` without `--force`** (P54): pass `--force` and treat Scarf's restore sheet as the consent (every restore into a live home currently fails on the un-piped `input()`), or attach a stdin pipe and answer `y`? Reviewer's read: `--force`.
2. **`curator run` with consolidation off** (P54): render Hermes's "prune-only" line as a note beside the success (the pin/unpin shape), or offer `--consolidate` on the Run Now button when `curator.consolidate` is false?
3. **`/goal` and `/subgoal`** (P55): drop the optimistic mirrors and give the `default:` arm a "sent as an ordinary prompt" notice (the P44 `/steer`/`/queue` shape), or keep the goal pill with the toast saying it is Scarf-local? Hermes has never had these slash names.
4. **Quoted `"off"` reasoning effort** (P55): drop `off` from `disablingSpellings` so the "not supported" notice fires (over-warns on a bare `off`, which PyYAML makes `false`), or keep it and let the quoted case pass silently?
5. **`hasGatewayAllowlists`** (P55): per-platform floors (`allowed_channels`/`allowed_chats` are v0.12, `allowed_rooms` v0.13), or accept the one-release hide and say so in the doc?
6. **Kanban Review column** (P56): add `review → done` (`kanban complete`) and `review → upNext` (`kanban reopen-review`) behind `hasKanbanV015`, or keep Review drag-locked with an honest refusal and a context-menu Approve?
7. **Fleet-copied `repeat`** (P56): forward `--repeat` (Hermes accepts it at the tag), or note it as a downgrade like `pre_run_script`?
8. **Fleet-copied model pin** (P56): downgrade note at both seams (the P50 shape), or forward `--model/--provider/--reasoning-effort` and accept that the target host may lack the model?
9. **Dispatch on drag-to-Running** (P56): `--max 1` plus copy saying a dispatcher pass ran, or a confirm sheet naming what a board-wide pass does?
10. **The four streaming spawns' read loop** (P58): port ACP's `DispatchSourceRead` line reader (zero threads parked; already written and tested for `ProcessACPChannel`), or move the loop to `Thread.detachNewThread`?
11. **The iOS `runProcess` seam** (P58): make it async now (the `asyncRunProcess` path exists; ~12 iOS call sites), or leave `runSync(deadline:)` bounded and take the seam with t-02f830f4's Mac half?

## Proposed remediation phases (P54+)

Filed as Memophant tasks: **P53** (done pre-merge, this branch); **P54** `t-daf369c1` CLI verdict residue (HIGH, MED ×4, LOW ×5; decisions 1–2; supersedes t-4edfd804); **P55** `t-a7eb12e5` capability floors (HIGH, MED ×3, LOW ×3; decisions 3–5; relates t-54ec6eb3); **P56** `t-19ba24a5` cron/kanban/fleet residue (HIGH, MED ×4, LOW ×2; decisions 6–9); **P57** `t-b24e5fba` YAML reader residue (MED ×2, LOW; no decision); **P58** `t-10161ba1` C10 residue (HIGH, MED ×2, LOW ×2; decisions 10–11; folds t-f30054a8). Still open and relevant: t-02f830f4 (sync `runProcess` seam, both halves), t-406d56d6 (~26 blocking `Task.detached` sites), t-54ec6eb3 (~47 flags un-walked), t-295ef4d2 (five `.whitespaces` YAML readers, 41 sites), t-f655c541, t-8f55df7d (seven panes still outside the managed lock), t-3bcd1d7f (21 unlocalized `.help` literals + `"Edit cron job"`), t-38ae4f26, t-1febd6fa, t-848d3adc, t-6e9a0985, t-d02dd23e, t-a9ef75f0 (SectionSweep UI test), t-1eaf1579, t-15013d78.

---

# Per-surface reviewer reports (condensed)

Five read-only reviewers at `96089feb`. Items marked NEW were fixed in P53 before the merge; PRE items are in P54–P58. Every round-5 finding on every surface was re-derived and found fixed.

## Cron, Kanban, Sessions, Fleet apply

- **HIGH · PRE** iOS `buildJob` forwards `nextRunAt: existing?.nextRunAt` across a schedule change (`CronListView.swift:571`); `_evaluate_due_job` fires on the stored value (`cron/jobs.py:2925`), `_retire_expired_oneshot` (`:2853-2865`) retires a moved one-shot without running it; only `kind == cron` is repaired (`:2801-2819`). `clearingNextRunAt()` exists and is applied only on the `setEnabled` fallback · P56.
- **MED · PRE** Review column dead end: no `.review` source arm in `KanbanService.plan(for:)` (`:589-635`); the refusal says no CLI path exists, but `kb.complete_task` accepts `review -> done` (`kanban_db.py:2524-2534`) and `kanban reopen-review` exists (`kanban_parser.py:323`) · P56.
- **MED · PRE** fleet copy drops `repeat` (`FleetApplyPlan.swift:370-372,:422`; the doc's reason is false since P38's `repeatSpec`) · P56.
- **MED · PRE** fleet copy drops the model pin with no note at either seam (`:378-380`) · P56.
- **MED · PRE** drag-to-Running runs `kanban dispatch --json` board-wide (`KanbanBoardViewModel.swift:566-582`) · P56.
- **LOW · NEW** iOS locked-Enabled footer named two gestures unreachable from the sheet · fixed in P53 (`ResumeRefusal { reason, remedy }`, sheet-local sentence).
- **LOW · NEW** three weak assertions in `HermesP50bTests` (24-space indentation pin; `passed >= sites` vacuous; `--json` per-line) · fixed in P53/P53b.
- **LOW · PRE** `"Edit cron job"` uncatalogued; `--branch` ungated in `KanbanCreateRequest.argv()` (v0.15, no caller today) · P56 / t-3bcd1d7f.
- Verified sound: every P42/P50/P50b item; every cron and kanban argv re-opened at the tag (`--paused`/`--failure-deliver` absent at v2026.8.31; `--board` a global; `--ids` two tokens with `--`; `--triage` at the first kanban tag); the exit-0 family per handler (`cron run`'s `Ran now: failed.`, `incidents ack`, `cron doctor` exit 1 on issues, `sessions export`); C1/C3/C6/C10 across the surface; the shared offer's three doors at all four consumers; Duplicate on all five surfaces that render a hint.

## Settings, YAML writers/readers, config reads and writes, managed hosts, platform-setup forms

- **MED · PRE** folded-scalar continuation join runs after the comment skip and behind `!isListItem` (`HermesYAML.swift:212,:215,:225`); PyYAML's 80-column fold puts `- ` and `#` at the start of continuation lines: truncation + phantom list entry, or a dropped closing quote. 1450/4000 adversarial dumps · P57.
- **MED · PRE** `boolishValue`/`boolTrueDefault` compare the quoted body verbatim; Hermes strips (`gateway/config.py:29-32`); `" false"` → default `true`. PyYAML also types `01`/`+1`/`0x1` as ints. 60/59 372 oracle disagreements · P57.
- **MED · NEW** mattermost's falsy set is `{"false","0","no"}` with no `off` (`adapter.py:504-505`); P51's `.env` fallback used a truthy allowlist and the config side `boolishValue`'s wider set · fixed in P53 (+ P53b's PyYAML int spellings: `0x0`, `0b0`, `0_0`; `0o0` is a string to PyYAML).
- **MED · NEW-adjacent** Signal's prerequisite row still rendered the local `detectSignalCLI()` on a remote context · fixed in P53.
- **LOW · PRE** `isBlock` answers true for a flat dotted `slack.enabled:` key that PyYAML treats as independent; `bridgeSourcePrefix` then picks a section Hermes does not bridge · P57.
- Residue confirmed open: t-295ef4d2 (41 sites in five readers), t-38ae4f26, t-f655c541, t-8f55df7d.
- Verified sound: `quoteIfNeeded`/`unquote` 220 312 inputs through PyYAML 6.0.3, 0 failures; `setMapChecked`/`setListChecked` 6 000 writes, 0 failures, 0 round-trip losses on the two opted-in keys; `HermesPlatformSharedKeys.names` = `_SHARED_KEYS` (25); `bridgeSourcePrefix` = `platform_section`'s two steps; `HermesManagedInstall.system` mirrors `get_managed_system` line for line; all 13 `managed_error` sites enumerated, the four on Scarf's paths anchored; `_redirect_platform_display_key` cannot move a Scarf write; C9, C10 clean; iOS twins for the lock, the `config set` verdict and decision 17.

## CLI outcome verdicts — Skills, Plugins, Health, Gateway, MCP, pairing, auth, memory, sessions, webhook, backup/import, curator

- **MED · NEW** `auth logout`'s `.unconfirmed` arm reached a two-way `if` → "Remove failed: exit 0" (`CredentialPoolsViewModel.swift:454-464`) · fixed in P53 (`removeFailureSummary`, three branches, six locales).
- **HIGH · PRE** `hermes import <path>` without `--force` → `_confirm_import_overwrite`'s bare `input()` on an inherited `/dev/null`/EOF stdin → `EOFError` → exit 1 (`backup.py:830-839,:942-943`). Every restore into a live home fails with a bare "Restore failed" · P54, decision 1.
- **MED · PRE** `backup` reports `Backup incomplete:` + `Warnings (N files skipped):` at exit 0 as "Backup saved" (`backup.py:666-679`) · P54.
- **MED · PRE** `webhook remove|test` exit-code judged over three exit-0 arms each (`webhook.py:99-101,:184-187,:197-198,:213-215`) · P54.
- **MED · PRE** `curator run` hides the prune-only arm (`curator.py:159-163,:186`) · P54, decision 2.
- **MED · PRE** `debug share` reports a partial upload as complete (`debug.py:493-494`) · P54.
- **LOW · PRE** `--` residue in `profile`, `curator`, `kanban purge`; `mcp test` bool collapse; unlocalized banners; iOS spawns without `COLUMNS`; `migrate xai`'s `No changes written` arm mis-worded · P54.
- Corrections to t-4edfd804: `curator pin/unpin` already fixed; `kanban specify|decompose` has no Scarf caller; `migrate xai` is output-judged.
- Verified sound: 110 invocation sites enumerated (66 app, 43 ScarfCore, 1 iOS), every verb's handler opened; exit-code propagation re-derived (`main.py:3397-3401` raises non-zero handler returns; the `_forward_command` list at `:1755-1798`); `acp --setup-browser --yes` cleared; every verdict family walked for siblings; the nine three-state consumers re-checked; anchoring, `COLUMNS=400`, C6, C10 across the surface.

## Capabilities, floors and gates, chat/ACP

- **HIGH · PRE** `hasKanban` floored 0.12; `hermes_cli/kanban.py` absent at v2026.4.30 (reverted in #16098 per `RELEASE_v0.12.0.md:438`), first at v2026.5.7 = 0.13.0. Nine consumers light up and every `hermes kanban` argv routes to the agent on a 0.12 host · P55.
- **MED · PRE** `hasMCPIdentityHeader` at 0.20.4; all three members at v2026.8.13 = 0.20.1 · P55.
- **MED · PRE** `hasBotChatCreationCLI` at 0.21; `--query-file` at v2026.8.19 = 0.20.5 · P55.
- **MED · PRE** `/goal` and `/subgoal` are ungated optimistic mirrors for slash names in `_COMMANDS` at no tag · P55, decision 3.
- **LOW · PRE** `off` in `disableAliases` (never in Hermes's set); `hasHermesAudit` doc names a non-verb; `hasGatewayAllowlists` per-member floors · P55, decisions 4–5.
- **NEW: none.** The Discord window re-walked independently and found correct with its four-test group.
- Verified sound: all round-5 items (idle `/steer` on Mac and iOS; `pickerSelection(for:)` at every binding; the three P49 retirements re-derived at the tags); C4 (no `SCHEMA_VERSION` detection); `HERMES_TARGET_TAG` = README; every ACP method Scarf sends present at v2026.3.30; the nine-name roster; **38 flags re-walked with the blob opened at the floor tag and the tag before** (listed in the reviewer's full report; 3 wrong, all above), ~47 remaining on t-54ec6eb3.

## Concurrency and spawn discipline (C10), transports, templates/backup/restore, iOS twins, test health

- **HIGH · PRE** the four streaming spawns' stdout loop blocks a cooperative-pool thread in `availableData` for the stream's life (`LocalTransport.swift:375-414,:452-501`; `SSHTransport.swift:736-801,:839-897`); `HermesLogService` runs `tail -F`. `ProcessACPChannel.swift:276-290` documents the identical bug and its `DispatchSourceRead` cure · P58, decision 10.
- **MED · NEW** the P52 `OffPool` sweep matched per line; four multi-line closures with its own needles passed · fixed in P53 (brace-matched, calibrated; P53b: comment-stripped, region exemption).
- **MED · NEW** `scarf/Packages/ScarfIOS/Sources` in none of the three C10 sweep roots · fixed in P53 (all three roots, per-root floors, root-membership assertion; P53b: `ScarfIOS/Tests` in the test-quality sweeps).
- **MED · PRE** `CitadelServerTransport.runSync` blocks a pool thread on a pool task with an unbounded `semaphore.wait()` · bounded in P53 (`runSync(deadline:)`), seam still sync · P58, decision 11.
- **MED · NEW** iOS timeout threw `partialStdout: Data()` · fixed in P53 (shared accumulator; P53b: behavioural test over an injectable chunk sequence).
- **MED · PRE** five main-actor spawn/env sites (`SpotifyAuthFlow:133`, `OAuthFlowController:252`, `MCPLoginController:237`, `HealthViewModel:1182`, `HermesProxyService:82/:130`) · P58.
- **LOW · NEW** two sweeps without per-root floors; analytics sweep one-level and basename-exempt · fixed in P53.
- **LOW · PRE** ACP close watchdog never escalates; `HermesLogService` doc claims an iOS path that is an M3 stub · P58.
- Verified sound: 22 `Process()` sites (9 app, 13 ScarfCore, 0 iOS), every one bounded, drained before the parent's last write, launch-failure arm clean, SIGKILL pid-guarded; the fd retraction re-measured and correct; `ProcessPipeDrain.collect` a genuine latch; `OffPool` proven by rendezvous not stopwatch; all three sweeps calibrated with honest floors; analytics dedupe on the injected tracker; templates/backup/restore drained and bounded; iOS execs bound and channel-closing.
