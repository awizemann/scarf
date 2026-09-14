# Whole-surface audit round 5 — after the P39–P46 remediation branch

Date: 2026-09-11. Branch `fix/whole-surface-audit-r4` (P39–P46), to be merged to `main` as `merge(whole-surface-audit-r4)`. Round 4 is `documents/hermes-v0.21.1-whole-surface-audit-round4.md`; the brief is `documents/hermes-v0.21.1-parity-agent-brief.md` plus `documents/hermes-v0.21.1-round4-agent-addendum.md`; the per-phase lessons are the "Whole-surface remediation — P39" … "P46" sections, the "Round-4 product decisions (Alan, 2026-09-11)" section, and the "Round 4 — memory audit" section of `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md`.

## Branch contents

| Phase | Commits | Subject |
|---|---|---|
| — | `7abc79b7`, `f28ac6a3`, `38f2f884` | Alan's own per-tier Memophant commits (`.memory/`, `tasks/`, `documents/`) made through the app's bar while the branch was checked out; left in place |
| P39 | `8f92f236`, `5b81476b`, `1f384a84`, `d4e4f6cf` | managed hosts (decision 1: `managedRefusalAnchored` + `.managed` probe + scoped read-only lock on Mac and iOS), `HermesConfigSet` with all ten `set_config_value` arms enumerated and the terminal `.env` mirror as a partial-write warning, bot `config unset` on `HermesConfigUnset` (decision 11), `hasManagedMarkerContents` @ 0.20.5, anchored failure markers (the four full `Cannot …` prefixes), six-locale strings |
| P40 | `ef79ccd4`, `455a0a89`, `07d8f3d1`, `4dcfa161`, `3055fb07`, `5fe72ef7` | `HermesGatewayServiceVerdict` (every backend walked: launchd incl. detached fallback, systemd, s6 silence, Windows, container refusal, foreground restart) with `HermesCLIOutcome.Confidence {confirmed, unconfirmed, failed}` and `UsageEvent.Outcome.unconfirmed` (decision 2), `mcp remove`/`mcp test` anchored, `plugins update` third state on the flagged line (decision 3), `config migrate` button removed with a managed-host variant of the hint (decision 4), `OAuthFlowController` drain ported with `ProcessOutputInbox` hoisted (t-bd119897 closed), `COLUMNS=400` on judged spawns, transport timeouts carry partial stdout |
| P41 | `2fb7cc08`, `d4a3ab4d`, `402442a1`, `151cdd3e`, `9f23018f`, `a2280ab6` | `HermesFileService.yamlScalar` → `YAMLScalar.quoteIfNeeded`; control-character and >1024-scalar key refusals in the MCP editor and the override field (decision 9); per-key `unquote` opt-in for `agent.reasoning_overrides` and `model_catalog.excluded_providers` (decision 10; `multiplex_profile_allowlist` has no Scarf writer → t-6e9a0985); quoted `approvals.mode`; `blockKeySpan` as the one block-key scanner; `\"` in quoted keys; PyYAML boundary lane made failable |
| P42 | `5e1550b6` … `4275fbfb`, `b30c3983`, `71e8bad9` | `HermesCLIOption` `--flag=value` (decision 7), Duplicate on four surfaces (decision 5), iOS re-arm (decision 6), fleet monitor partition (decision 8), tenant premise restated, `hasKanbanProviderOverride` re-floored to 0.19.1 after a real tag walk, past one-shot seed, `schedule_display` twin dropped, two new `friendlyCronFailure` arms |
| P43 | `65e26ec7` … `9c5d29a1`, `204e1284`, `f2a27cdf` | `Process.waitDraining` hoisted into ScarfCore, split into `startDraining`/`waitDraining(drain:)`, `waitDrainingAsync` on a detached thread, reader-per-pipe (decision 15); restore pump with `O_NONBLOCK` + `poll(2)` + stall ceiling and drained stderr in every give-up arm; `inspect()` cleanup; `enforceArchiveBounds` refuses (decision 16) incl. the singular `1 file,`; proxy `nullDevice`; `runShellProbe`; Spotify EOF latch + escalation; `AppRelauncher` nonisolated (t-b15ba4c3); P22 sweep floors |
| P44 | `a1e333cc`, `80d3522d`, `fdc2c981`, `0898bf07`, `40e8ab1f` | typed sub-floor `/steer`/`/queue` gated with a notice (decision 12), idle `/queue` as an ordinary prompt, effort picker widened with a notice that says what Hermes does (decision 13: `medium`, not "provider default"; disable aliases exempt behind `hasReasoningDisableAliases` @ 0.18.1), `hasACPSteerOnIdle` retired (decision 14), `HermesPlatformSharedKeys` for the Slack/Telegram bridge (t-6fa3fc84). `a1e333cc` also carries eleven P43b files (shared index; see lesson) |
| P45 | `5d0c682b`, `93d2237b`, `f2712241` | cross-phase review remediation: path-pattern stability sweep, `M5FeatureVMTests` traps, force-unwraps, shape-matched `has been disabled.`, normalised effort comparison, `.empty` test, anchored-list sweep, `settle()` on `writeChain`, "Hermes default" label, sorted catalog |
| P46 | `9ca4d384` … `b44dfefd`, `a856d981`, `b14e39f3`, `a9060755` | round-5 NEW findings fixed pre-merge: key-scoped `bridgeResolvedKeys` with the prefix resolved as the batch will leave the file; RAW row widening vs normalised notice; sweep scoped by branch-touched paths with `try? #require`/long-sleep rules (7 + 9 + 2 sites fixed); `BotAgentViewModel.perform` on a verdict, `HermesToolsToggle`; idle `/steer` as an ordinary prompt with Stop working; marker cache no longer memoises a transient `.empty`; flow arms opted into `unquote`; direct-YAML managed bounce; `(copy)` duplicate names; pump yields; iOS preflight on `HermesConfigSet` with a source sweep; stdout/stderr newline join. P46b (the review of P46): `pickerSelection(for:)` at every effort picker binding, `gateway_restart_notification` on the bridge for slack/telegram (+ the `batchTopLevel` self-defeat), the sweep's scope as a checked-in list (no git at test time), fractional-second sleep rule, marker-cache generation counter, `cached(for:capabilities:)`, quote-aware flow splitting; general bare-key block hazard → t-f655c541 |

## Verdict

**P39–P45 hold.** Every round-4 finding re-derived by the five round-5 reviewers is genuinely fixed at HEAD (each surface's "Verified sound" list is below). Round 5 found **~9 HIGH, ~25 MED, ~30 LOW**. The NEW items (introduced by the branch, 17 in all) were fixed pre-merge as P46. The PRE items are filed as P47–P51 with seventeen product decisions for Alan.

Defect classes, round 5:

1. **A fix that scopes by the wrong axis.** P44 gated the shared-key rewrite by *platform* when the readers resolve by *(platform, key)*; P45 scoped the stability sweep by file *name* when the branch's worst offenders had no phase name; P45 normalised the picker's *membership* test while the control binds the *raw* tag. Each was correct for the case its author had in hand and wrong one axis over. Fixed in P46; the lesson is the round-4 "grep both targets" rule generalised — ask which axis the consumer keys on.
2. **The exit-0 family is still growing.** Round 4 enumerated `config set`/`unset`/`save_config`'s named callers; round 5 found `plugins install --enable` (a sixth `save_config` door), `tools enable|disable`, `auth logout`, `sessions optimize`, `memory reset`, and the iOS chat preflight and the bot pane's `perform` that judged by exit code one layer above a correct verdict. P46 fixed the branch-adjacent ones; P47 carries the rest. Enumerate by grepping `runHermesCLI(` callers, not by verb.
3. **A hint the branch itself wrote is a button.** P30's "edit the schedule" remedy on `completed` was fixed in P38; its sibling on the pre-v0.21 `error` arm names the same refused gesture (P50). Copy that names a remedy has to be walked on every arm it renders for.
4. **The optimistic mirror has an idle twin.** P44b fixed idle `/queue`; idle `/steer` had the same shape plus an un-cancellable turn (fixed in P46).
5. **Two agents on one index.** `a1e333cc` swept eleven staged P43b files into a P44 commit. Content is complete; authorship is mixed. Rule: on a shared tree, `git commit -- <paths>`.

## Test-infrastructure state

Post-P46b head `a9060755`: ScarfCore **3003/3003** (the only recurring failure is the `ACPClientStartIdempotenceTests` parallel-load flake, t-f3820038, 5/5 in isolation); Mac `scarfTests` **1253/1253** serial in 125 s; `scripts/tests` 20/20; `check-hermes-tables.py --tag v2026.9.7` → `OK … lanes=5/5`; Mac Debug and `scarf mobile` build green with no new warnings in branch-touched files. UI tests were not run on this branch at Alan's request. Memory health after the round-4 audit: 82 → 20 flags, zero drift, three notes added, thirteen long-standing notes still outside the six folders (a refile queue for Alan).

## Product decisions for Alan (calls, not bugs)

1. **`plugins install --enable` on a managed host** (P47): judge the run (banner "Installed; the enable was refused by the managed layer") or extend t-8f55df7d's read-only lock to the Plugins pane (over-refuses: the install itself succeeds)? Reviewer's read: the verdict.
2. **`auth logout` with no auth state** (P47): failure, or a success-with-note like the gateway's "nothing was running" (round-4 decision 2)?
3. **`memory reset --yes` with no files** (P47): same question; the same neutral note keeps the two consistent.
4. **`ProcessPipeDrainer`** (P48): retire it onto `Process.startDraining`/`waitDraining` (deletes a file, touches the hottest spawn path) or bound `Capture.wait(grace:)` and move its readers to threads in place?
5. **`ServerTransport.runProcess`'s optional `timeout`** (P48): make it non-optional (compile error for a latent C10 hole; one signature across two conformers and the doubles)?
6. **The four streaming spawns** (P48): `onTermination` + `terminate()` only, or a rewrite onto a drained, bounded primitive off the cooperative pool?
7. **The remaining 90 stability-sweep sites in 35 files** (P48, t-f43f0af5): take the whole wave in one phase, or burn down per phase?
8. **Test fixtures** (P48): shrink the 300 MB bomb and the 64 MB drain duel (~30 s of the 121 s serial run) by starting the clock before `Process.run()`, or keep the wall time?
9. **`hasACPSetSessionModel`** (P49): retire the flag outright (`set_session_model` predates Scarf's supported minimum; turns the model chip on for 0.6.0–0.12 hosts, a permissive change like round-3 decision 5) or pin it at the first adapter tag as documentation?
10. **`hasYOLOSlashCommand`** (P49): re-floor to 0.7.0 or delete it with the other consumerless P34 survivors?
11. **The pre-v0.21 recurring-`error` hint** (P50): replace "edit the schedule to re-arm it" with "duplicate it" (the adjacent button), or drop the version sentence and give this arm the `completed` copy?
12. **Fleet-copied `pre_run_script`** (P50): surface as a downgrade note (the P42 shape) or promote to a skip like `no_agent` and monitor?
13. **iOS `CronEditorView.isValid` blocks edits to a spent one-shot** (P50): keep the blanket refusal, or restrict it to create/duplicate and let a prompt-only edit through?
14. **Unicode spaces in YAML scalars** (P51): stop trimming U+00A0 etc. in the parser (faithful to PyYAML; a pasted NBSP becomes an invisible permanent value) or keep trimming and say so at the field?
15. **Signal/WhatsApp pairing on a remote context** (P51): disable the embedded terminal with a sentence naming the host (the `runBackup` posture), or run the pairing over SSH?
16. **Reasoning-override key casing** (P51): keep the case-insensitive collapse (deletes a key Hermes matches case-sensitively) or go exact and let two casings coexist?
17. **iOS reasoning-effort affordance** (P51): render `unsupportedLevelNotice` beside the read-only value, or leave the phone read-only-and-silent?

## Proposed remediation phases (P47+)

Filed as Memophant tasks: **P46** (done pre-merge, this branch); **P47** `t-a498595f` CLI verdict residue (HIGH, MED, LOW ×4; decisions 1–3); **P48** `t-86311c5a` transports and C10 residue (HIGH ×3, MED ×6, LOW ×5; decisions 4–8; folds t-10eb7c17 and t-12d04477); **P49** `t-89264409` capability floors (MED, LOW ×2; decisions 9–10; relates t-1febd6fa); **P50** `t-a397264c` cron/kanban residue (MED ×2, LOW ×4; decisions 11–13); **P51** `t-f406c932` settings/forms residue (MED ×7, LOW ×4; decisions 14–17). Still open and relevant from round 4: t-f3820038 (ACP idempotence flake — now with a diagnosis in P48), t-a9ef75f0 (SectionSweep UI test), t-1eaf1579 (`.env` overrides), t-15013d78 (design gallery slash rows), t-6e9a0985, t-38ae4f26, t-d02dd23e, t-f46dfedb, t-3bcd1d7f, t-8f55df7d, t-74df283e, t-51a29de2, t-038695a3, t-25748a3b, t-f3d7bdd2, t-f655c541.

---

# Per-surface reviewer reports (condensed)

Five read-only reviewers at `f2712241`. Items marked NEW were fixed in P46 before the merge; PRE items are in P47–P51. Each reviewer's full "Verified sound" list is summarised; the round-4 findings on every surface were re-derived and found fixed.

## Cron, Kanban, Sessions, Fleet apply

- **MED · PRE** `errorNeedsNewerHermesHint` names "edit the schedule" on hosts in [0.20.6, 0.21.0) where `cron edit --schedule` on a recurring `error` job raises (`cron/jobs.py:2310,2322,2345,2367-2375` @ v2026.8.27) · P50.
- **MED · NEW** Duplicate seeded the source name verbatim; `resolve_job_ref` raises `AmbiguousJobReference` on a case-folded collision (`:1841-1845`) · fixed in P46 (`(copy)`, `(copy N)`).
- **MED · PRE** fleet-copied agent job loses `pre_run_script` silently (`FleetApplyPlan.swift:412-427`; `subcommands/cron.py:41-46`) · P50.
- **LOW · PRE** completion-contract `.help` key unlocalized (fixed in P46); `KanbanWatchFilter` dead with a false `--json` doc; detail-pane "Run now" not disabled for terminal jobs; three `friendlyCronFailure` arms unlocalized (fixed in P46).
- Verified sound: every P42/P42b/P42c item; every converted `--flag=value` option re-opened at the tag as a bare `store`/`append`; `--ids` correctly two tokens; Duplicate is a real `cron create` on all four surfaces; iOS re-arm gated on the shared offer with no JSON fallback; `provider_override` floor re-walked at all 32 tags; C5/C1/C10/C6 across the surface.

## Settings, YAML writers/readers, config reads and writes, managed hosts, platform-setup forms

- **HIGH · NEW** Telegram's mixed batch splits its own block under P44's platform-scoped resolver · fixed in P46 (key-scoped pairs; prefix resolved as the batch will leave the file).
- **HIGH · NEW** P45's normalisation blanked the picker for `Max`/`" high "` · fixed in P46.
- **HIGH · NEW/PRE** iOS model preflight was the one `config set` never given P39's verdict (`Scarf iOS/Chat/ChatView.swift:1371-1388`) · fixed in P46 with a source sweep over every `config set` argv.
- **HIGH · NEW** `BotAgentViewModel.perform` (`:441`) discarded the managed refusal `isBenignUnset` surfaced; `setMCPServer`/`setToolset` exit-code judged · fixed in P46 (`HermesToolsToggle` walked at `tools_config_mcp.py:237-285`).
- **MED · PRE** reader trims Unicode `Zs` that PyYAML keeps (`HermesYAML.swift:159,:207,:250,:258-259`) · P51.
- **MED · NEW** flow arms bypassed the per-key `unquote` opt-in · fixed in P46.
- **MED · NEW** `saveDirectYAML` had no managed bounce · fixed in P46.
- **MED · NEW** `HermesManagedInstallCache` memoised a transient `.empty` pessimism · fixed in P46.
- **MED · PRE** Auxiliary tab SSH read on the main actor in `onAppear`; Discord `allow_any_attachment` dead and ungated; Discord `history_backfill` written below its floor; Mattermost require-mention split across config/.env; Signal/WhatsApp pairing spawns locally on a remote context; override editor's case-insensitive dedupe deletes a live key · P51.
- **LOW** forms without `YAMLScalar` refusals; Ntfy drops the proven `.env` half; two main-actor `enrichedEnvironment()` calls; iOS effort value with no affordance; two off-by-one citations (fixed in P46).
- Verified sound: `quoteIfNeeded` 15 757 inputs and `setMapChecked`/`setListChecked` 14 626 inputs each through PyYAML 6.0.3, 0 failures; every round-4 MED/LOW on this surface; `HermesConfigMirror` correct; managed-lock scoping and iOS mirror; C10 across Settings loads; `HermesPlatformSharedKeys.names` matches `_SHARED_KEYS`.

## CLI outcome verdicts — Skills, Plugins, Health, Gateway, MCP, pairing, auth

- **HIGH · PRE** `plugins install --enable` is a sixth `save_config` door (`plugins_cmd.py:702,753-755,115-120`; `config.py:2315-2318`) · P47.
- **MED · PRE** `auth logout` two exit-0 arms (`auth.py:2180,2185`) judged by exit code · P47.
- **LOW · NEW** `runHermesCLI` joined stdout+stderr without a separator · fixed in P46.
- **LOW · PRE** `sessions optimize` exit-0 failure arm; `memory reset` "Nothing to reset" arm; `--` divergence on `sessions rename`/`auth`/`webhook`; iOS `skills update --yes` doc · P47.
- Verified sound: every round-4 finding; the `.unconfirmed` consumer sweep complete; no anchored list passed unanchored; `_NO_BACKEND_MESSAGES` re-walked; `doctor`, `profile`, `auth add/remove/reset`, `sessions delete/rename`, `plugins remove`, `version` exit-code-safe; C6; C10.

## Capabilities, floors and gates, chat/ACP

- **HIGH · PRE→fixed** idle `/steer` painted "Guidance queued", suppressed the working indicator and left `turnGeneration` nil so Stop could not cancel (`acp_adapter/server.py:667-689,:789,:792-798`) · fixed in P46 as the P44b `/queue` shape.
- **MED · NEW** P45 normalisation blank picker (see Settings) · fixed in P46.
- **MED · PRE** `hasACPSetSessionModel` floored at v0.13; present at every adapter tag from v2026.3.17 · P49.
- **LOW · PRE** `hasYOLOSlashCommand` floor (first at v2026.4.3); `hasContextCompressionCount` gates a field absent at every tag · P49.
- **LOW · NEW** iOS "Hermes default" bare String; AgentTab comment; AuxiliaryTab "Default"; citation drifts; a11y double label · fixed in P46.
- Verified sound: all three branch flags walked independently; ten older flags sampled (eight correct); every ACP method and slash name gated correctly at the v0.6.0 tag; README/`HERMES_TARGET_TAG`; `check-hermes-tables.py` exits 0; C1 traced on three branch-added surfaces.

## Concurrency and spawn discipline (C10), transports, templates/backup/restore, iOS twins, test health

- **HIGH · PRE** `ProcessPipeDrainer.Capture.wait()` unbounded; readers on the global queue; four streaming spawns orphan their child · P48.
- **HIGH · NEW** `gateway_restart_notification` write-only under P44 (`GatewayBehaviorViewModel.swift:209-219`) · fixed in P46.
- **HIGH · NEW** stability sweep name-scoped · fixed in P46 (path-scoped over branch-touched files; 90 sites in 35 files remain → t-f43f0af5).
- **MED · NEW** pump had no suspension point; `ProcessAsyncWaitP43cTests` overclaimed · fixed/narrowed in P46.
- **MED · PRE** `TestConnectionProbe` reads after the wait; `SSHScriptRunner` judges before EOF; `HermesProxyService.stop()` no escalation; `AnalyticsFeatureUsageEventsTests` serialized against a process global; `M4ACPIOSTests`/`ACPClientStartIdempotenceTests`/`M0bTransportTests` timing bets diagnosed · P48.
- **LOW** launch-failure fd leaks in both transports and the proxy; `timeout == nil` arm; a 900 ms nap; guard-style inconsistency; stale `HermesFileService.swift:2795-2796` doc (fixed in P46).
- Verified sound: 22 `Process()` sites enumerated, 0 on iOS; every round-4 C10 item; `ProcessPipeDrain.collect` a genuine latch; `saveForm`'s config read degrades safely; P45's `isBlock` fix; iOS twins for P39/P42/P44 present; the serial run's wall time attributed (four fixture-heavy suites ≈ half).
