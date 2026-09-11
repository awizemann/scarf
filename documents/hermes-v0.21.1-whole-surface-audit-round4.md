# Whole-surface audit round 4 — after the P30–P38 remediation branch

Date: 2026-09-10/11. Branch `fix/whole-surface-audit-r3` (P30–P38), merged to `main` as `merge(whole-surface-audit-r3)`. Round 3 is `documents/hermes-v0.21.1-whole-surface-audit-round3.md`; the brief is `documents/hermes-v0.21.1-parity-agent-brief.md`; the per-phase lessons are the "Whole-surface remediation — P30" … "P38" sections and the "Round-3 product decisions (Alan, 2026-09-10)" section of `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md`.

## Branch contents

| Phase | Commits | Subject |
|---|---|---|
| — | `39f43ac6` | stray P28 test fix left uncommitted on main (a starved load vs a wrong read) |
| P30 | `017be699` | cron recovery: Hermes's three doors (`isRecoverableErrorJob`, `isRearmableOneShot`, `recoveryOffer`), `hasCronRecoverableErrorResume` @ 0.21.0, Mac/Bots/iOS through one offer, pause-marker truthiness, re-arm toast (decision 1) |
| P31 | `45ec3777`, `7abf07c1` | `HermesPairingVerdict` by success marker with the lockout countdown verbatim (decision 3), `skillsUpdateFailure` minus the unconditional warning (decision 2), five `--` argv sites with `--force` before `--`, `_plugin_status` re-quoted, `dashboardListenerPID` drained concurrently |
| P32 | `ee0f9591` | `ProfileRoutesWriter.quoted` and `HermesBotProfileYAML.quoted` deleted, all scalars through `YAMLScalar.quoteIfNeeded`; control characters refused in both editors (decision 6); C0/C1 escapes in `doubleQuoted` + `unquote`; `parseNestedYAML` last-wins for the whole block; decision 7 deferred as t-1eaf1579 |
| P33 | `0e64b7fe`, `30616b14`, `871ced40` | `loadConfigProven` + `FormSnapshot.configFailure` + `loadRefusal` latch for all 15 setup forms (absent saveable, unreadable refused); `saveDirectYAML` on `writeChain`; `Process.waitDraining` for `unzip`/`zip`/`open`; dead `SessionsViewModel.runHermes` removed; decision 9 documented |
| P34 | `99412912` | ACP slash roster = adapter's nine names (decision 4): seven dead rows dropped, `reset`/`context`/`version` added (no flag — present at the first adapter tag, below v0.6.0), `yolo`/`sessions`/`codex-runtime` docs corrected to CLI-only |
| P35 | `b08b2eea` … `8e77f5b0` | `hasReasoningEffortMax` @ 0.18.1 / `hasReasoningEffortUltra` @ 0.19.0 (decision 5); `KnownPlatforms.reconcile` selection snap-back (decision 8); "Host default" row → `hermes config unset` behind `hasConfigUnset` on both twins, output-judged (decision 10); one `mcp-tokens/` listing; `sse_read_timeout` residue; `ALIASES` fall-through + script-test skip policy; citations |
| P36 | `3e68bdad`, `ca6ae1e8` | 24 citations re-anchored at v2026.9.7; README target → v0.21.1 pinned to `HERMES_TARGET_TAG` by a script test |
| P37 | `43781219` … `8a41879a` | cross-phase review remediation: P36's cron re-anchorings that never landed (real range `:664-692` @ v2026.8.31), `hasACPSteer` @ 0.13.0, one `YAMLScalar.unquote` (three unquoters collapsed, `\x+9` hole closed), `hasConfigUnset` gate inside `unsetSetting(_:capabilities:)`, refused `.env` read no longer blanks the form, `AuxiliaryReasoningEffort` retired, nine new strings localized in six locales, P22 scan re-calibrated for `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |
| P38 | `ea65ff90`, `fa4d1414`, `87f0ca40`, `43b594bd`, `e9055e55`, `6db90fe2` | round-4 NEW findings fixed pre-merge: cron hint Hermes refuses → "duplicate it", context menu + iOS gate through `recoveryOffer`, past-deadline one-shot as the third door behind new `hasCronPastOneShotResumeRefusal` @ 0.18.1 (`resume_job` raise first at v2026.7.7), `friendlyCronFailure` takes the offer; `parseNestedYAML` purges `values[path]`/`maps[path]` and keeps flat dotted siblings; `unsetSetting` no-ops on nothing-stored; `groups`/`legacyGroup` in the refusal; two false `config set` docs corrected; `dashboardListenerPID` on `waitDraining`, nonisolated, allowance removed (t-cd9fd829 closed); pairing prefix tag v2026.7.30 + split-f-string grep trap; skills_hub lines; ACP docs + dead `hasActiveSession` + per-version dispatch set; test-host stability sweeps over the 17 phase suites (repo-wide ~100 pre-existing sites → t-f43f0af5); `ProvenConfig.exists` deleted; env-read sweep over all 15 forms. Post-P38: Mac 1079/1079 serial, ScarfCore 2685/2685, scripts 20/20. |

## Verdict

**P30–P37 hold.** Every round-3 finding re-derived by the five reviewers is genuinely fixed (each "Verified sound" section below is larger than round 3's); the cross-phase review's 14 items were remediated in P37 and re-verified here. Round 4 found **~10 HIGH, ~20 MED, ~30 LOW**. The NEW items (introduced by P30–P37, 25 in all, mostly incompleteness and doc drift; two test-host stability violations) were fixed pre-merge as P38. The PRE items are filed as P39–P44 with sixteen product decisions for Alan.

Defect classes, round 4:

1. **The exit-0 refusal has a family.** P9/P21/P31/P35 judged one `-> None` handler at a time; round 4 enumerated them: `is_managed()` makes `config set`, `config unset` and `save_config` print-and-return at exit 0, and `save_config`'s callers (`plugins enable/disable`, `mcp remove`, `skills trust`) then print their own success line. `gateway start|stop|restart` and `mcp remove` have their own exit-0 arms. P39/P40 (decision 1: managed hosts).
2. **A fix that lands in the app target misses its ScarfCore twin.** P33's `waitDraining` fixed three app-target spawns; `RemoteRestoreService`/`RemoteBackupService` hold the same unbounded wait and cannot see the helper (P43, decision 15). `HermesFileService.yamlScalar` is the third emitter P32 left standing, and it has the exact control-character hole P32 closed elsewhere (P41).
3. **A hint can be a dead end as surely as a button.** P30's "edit the schedule" copy names the one gesture Hermes refuses on a `completed` job (`_apply_schedule_update` writes `next_run_at`, `update_job` raises). Fixed in P38; Duplicate affordance is decision 5.
4. **One offer, four sites.** P30 unified three consumers and missed the Mac row context menu; iOS checked `oneShotIsUnresumable` before the offer so its re-arm branch was dead. Fixed in P38 by folding the past-deadline door into `recoveryOffer` (Mac gains the pre-refusal it lacked).
5. **The false claim written while fixing its twin.** P35/P37 fixed `config unset`'s exit-0 arm and wrote "every `config set` refusal `sys.exit(1)`s" into two doc comments; false at every tag from v2026.3.28. Docs fixed in P38, verdict in P39.
6. **A sweep that adds a path prefix is not a walk.** P37 qualified `skills_hub.py` citations without opening the blob; four numbers in one cluster and three in another were still wrong. Fixed in P38.
7. **The test-host stability rule needs a scan, not a memory.** Two new P35 tests violated it (`servers[0]` after a count expect; `try! #require`). Fixed in P38 with a sweep of every test file the branch added.

## Test-infrastructure state

Post-P37 head `8a41879a`, independently: ScarfCore **2667/2667**; Mac `scarfTests` **1062/1062** serial; `scripts/tests` **20/20**; `check-hermes-tables.py --tag v2026.9.7` → `OK … lanes=5/5`; Mac Debug build green. The only recurring parallel-load flake remains `ACPClientStartIdempotenceTests` (t-f3820038), green in isolation; `M0bTransportTests` once (t-f3f2602c). One UI test is red and pre-existing on main (`SectionSweepUITests.testEverySectionRenders`, t-a9ef75f0). The memory auditor could not find the Hermes checkout because it looked at `~/Developer/ScarfBox/Vendor/hermes-agent` (the compatibility-target note's stale pointer); the checkout is `~/.hermes/hermes-agent` — corrected in the Round 4 memory section.

## Product decisions for Alan (calls, not bugs)

1. **Managed (NixOS / package-managed) Hermes hosts** (P39): `is_managed()` refuses `config set`/`unset`/`save_config` at exit 0 and callers print success anyway. (a) a shared `is managed by` refusal marker in every config-mutating verdict with `failureWins`; (b) detect managed mode once at connect and render every write surface read-only with one banner; (c) both. Reviewer's read: (c) with (b) doing the visible work.
2. **Gateway start/stop/restart banner copy once the verdict is real** (P40): stay "requested" with only the failure arm changing, or claim "started"/"stopped"? And is `✗ No gateway running for this profile` on Stop a failure or a success (desired end state already true)?
3. **`plugins update` whose security scan disables the plugin** (P40): failure, or a third state "Updated — disabled by the security scan" quoting the reason?
4. **`hermes config migrate` from Scarf** (P40): it prompts on stdin with an unguarded `input()` and can abort after applying migrations before stamping the version. Pipe blank lines (accept defaults silently), warn in the pane, or hide the button and point at the host?
5. **`completed` recurring job** (P42): P38 changed the hint to "duplicate it". Add a Duplicate button in the detail pane (an ordinary create, not a re-arm), or leave it as copy?
6. **iOS re-arm** (P42): wire `cron resume --run-now` into `IOSCronViewModel` (a new write path on the phone) or keep "re-arm it from the Mac app" and accept the wording differs by platform?
7. **Dash-leading user text in option values** (P42): `--name -nightly` exits 2 and `--` does not help. Emit `--name=<value>` everywhere, or refuse a leading `-` in the editors (decision-6 posture)?
8. **Fleet-copied monitor jobs** (P42): forward `--monitor-script/--monitor-url/--continuity` behind floors (the script path is not replicated), or skip-and-surface like `no_agent` jobs?
9. **Control characters in the MCP entry editor and the reasoning-override pattern field** (P41): extend decision 6's refusal to both, or fix only the emitter and accept silent reshaping there?
10. **Which Scarf-written blocks the shared decoder covers** (P41): `agent.reasoning_overrides`, `model_catalog.excluded_providers`, `gateway.multiplex_profile_allowlist` are written via `quoteIfNeeded` and read via `stripYAMLQuotes`. Move them onto `YAMLScalar.unquote` (per-key opt-in inside `parseNestedYAML`, which also reads Hermes-written values), or narrow the doc claim?
11. **Bot model-pin clears** (P39): gate `BotAgentConfigService.unsetValue` on `hasConfigUnset` and output-judge it (bot surface starts showing a hint on pre-0.19), or leave exit-code-judged?
12. **Typed sub-floor `/steer`/`/queue`** (P44): on a pre-v0.13 host, (a) gate the optimistic chip/hint and send as an ordinary prompt with a normal working indicator, (b) also show a one-line notice, or (c) leave as the documented `/goal`-style caveat and only fix the working indicator?
13. **A stored effort level above the host's floor** (P44): widen the picker to show `ultra`/`max` (matching `ReasoningOverridesSection`/`WebToolsBackendRoster`), render blank as today, or show it with a "not supported on this host" affordance?
14. **The unreachable idle-steer grey-out** (P44): keep `hasACPSteerOnIdle`'s arm and its six-locale string as defence-in-depth, or retire them?
15. **`Process.waitDraining` into ScarfCore now** (P43): `RemoteRestoreService`/`RemoteBackupService` run `unzip`/`zip` on user archives with no timeout at all. Hoist and convert now, or file?
16. **`enforceArchiveBounds` fail-open** (P43): a listing Scarf could not read currently proceeds (documented). Refuse for a `.scarftemplate` from a `scarf://` URL or an emailed file (a Mac with a broken `unzip` then opens no templates), or stay fail-open?

## Proposed remediation phases (P39+)

Filed as Memophant tasks: **P38** `t-79143f86` (done pre-merge); **P39** `t-ba727c07` managed-install refusals, `config set`/`save_config` verdicts, bot `config unset` door (HIGH ×2, MED, PRE; decisions 1, 11); **P40** `t-1559ec68` gateway/mcp/plugins/skills verdicts + `OAuthFlowController` drain (HIGH ×3, MED ×3, PRE; decisions 2–4; closes t-bd119897); **P41** `t-f3ffabf9` `yamlScalar` onto `YAMLScalar`, MCP editor control chars, quoted `approvals.mode`, reader coverage (HIGH, MED ×2, PRE; decisions 9, 10); **P42** `t-8e9ddad0` cron/kanban residue (MED ×3, PRE; decisions 5–8; folds t-dafcc4a5); **P43** `t-e23f78e6` C10 residue in ScarfCore and the proxy (HIGH ×2, MED ×3, PRE; decisions 15, 16); **P44** `t-83c1e3b5` chat/settings residue (MED ×3, PRE; decisions 12–14; closes t-6fa3fc84). Still open and relevant: t-f3820038 (ACP idempotence flake), t-a9ef75f0 (SectionSweep UI test), t-b15ba4c3 (`AppRelauncher` main-actor wait), t-1eaf1579 (`.env` overrides), t-15013d78 (design gallery slash rows), t-32794e9f (fold into P39).

---

# Per-surface reviewer reports (verbatim)

The five read-only reviewers' full output follows. Items marked NEW were fixed in P38 before the merge; PRE items are in P39–P44.

## Cron, Kanban, Sessions, Fleet apply

### HIGH

- **HIGH · NEW (P30) · The one thing Scarf offers a `completed` recurring job — "edit the schedule to run it again" — is itself refused by Hermes.** A completed record is `enabled=False, state="completed", next_run_at=None`; a `cron edit --schedule` on it runs `_apply_schedule_update`, which writes a real `next_run_at` because `state != "paused"`, and the second `_reject_terminal_activation` at `update_job` `:1965` then raises on `updated.get("next_run_at") is not None`. `_advance_after_run` retires a `cron`/`interval` job as `completed` the moment `repeat.times` is exhausted (`jobs.py:2192-2215`), so any recurring job with a finite repeat lands here. · `CronRecoveryOffer.swift:45-47`, rendered `CronView.swift:631-638`, `BotRoutinesView.swift:146-148`, `IOSCronViewModel.swift:236` · `cron/jobs.py:1865-1878`, `:1941`, `:1965`, `_advance_after_run:2192` @ `v2026.9.7` · Fix: the only door Hermes leaves open for this shape is re-creation — say "This job has no runs left — duplicate it to schedule a new one" (the wording `friendlyCronFailure` already uses), and mention `--repeat` when the record carries an exhausted finite repeat.

### MED

- **MED · NEW (P30 incomplete) · The Mac row context menu is the fourth offer site and P30 did not unify it.** `Button(job.enabled ? "Pause" : "Resume")` — a `completed` recurring job gets an enabled "Resume" whose only outcome is the local refusal banner; "Resume & Run Now" is unreachable from the menu for a terminal one-shot; "Run Now" is offered for terminal jobs. · `CronView.swift:433-444` · `cron/jobs.py:1865-1878`, `:2012` @ `v2026.9.7` · Fix: drive the items off `viewModel.recoveryOffer(for: job)` exactly as `actionBar` does.
- **MED · NEW (P30) · On iOS the re-arm half of the shared offer is unreachable.** `setEnabled` checks `prev.oneShotIsUnresumable(now:)` before the offer, and that predicate returns `true` for every terminal one-shot (`HermesCronJob.swift:400`), so `terminalRefusalMessage`'s `offer.canRearm` branch is dead code and the P30 parity test (offer only, never the gate) passes over the divergence. · `IOSCronViewModel.swift:158-186`, `:225-234`; `HermesCronJob.swift:384-400`; `CronRecoveryOfferP30Tests.swift:34` · `cron/jobs.py:2045-2072` @ `v2026.9.7` · Fix: run the offer first; fall through to the one-shot precondition only when `!job.isTerminal`.
- **MED · PRE · `friendlyCronFailure` still names "Resume & Run Now" for every terminal refusal, recurring included** — the race path when the job turns terminal between load and click. It is `static` over CLI text and cannot discriminate. · `CronViewModel.swift:492-499` · `cron/jobs.py:2065-2066`, `hermes_cli/cron.py:691-695` · Fix: pass the job/offer in and drop the re-arm clause unless `isRearmableOneShot`.
- **MED · PRE · A user-typed value beginning with `-` makes argparse exit 2 wherever Scarf passes it as a separate option-value token.** `--` protects positionals only: `parse_args(["--name", "-nightly"])` is `expected one argument`. Live for `--name/--deliver/--prompt/--workdir/--failure-deliver` in the cron builders and `--author/--result/--summary` in kanban. · `CronViewModel.swift:637-651`, `:784-800`; `FleetApplyPlan.swift:408-437`; `KanbanService.swift:333-343`, `:347-365` · `hermes_cli/subcommands/cron.py:25-31,88-96` · Fix: the single-token `--name=<value>` form.
- **MED · PRE · `KanbanTenantResolver`'s founding premise is false at the target tag.** "Hermes Kanban has no `project_id` column" — the `tasks` DDL has `project_id TEXT`, `_TASK_DICT_FIELDS` emits it, `create_task` has project plumbing. · `KanbanTenantResolver.swift:7-11` · `hermes_cli/kanban_db.py:866-869`, `:1096-1176`; `kanban_output.py:18-24` · Fix: re-verify and either restate the rationale or adopt `project_id`.
- **MED · PRE · A fleet-copied monitor job silently becomes a full agent job that runs every tick.** `cronCreateArgs(copying:)` drops `monitor_script`/`monitor_url` and `--continuity` with no note. · `FleetApplyPlan.swift:340-384` · `hermes_cli/subcommands/cron.py:51-66,80-84` · Fix: forward behind floors, or skip-and-surface like `no_agent` (`FleetApplyExecutor.swift:302-305`).

### LOW

- **LOW · PRE · The detail-pane state badge reads `job.enabled`, not `effectiveState`.** · `CronView.swift:564-565` vs `HermesCronJob.swift:500` · `cron/jobs.py:488-503`
- **LOW · NEW (P30) · `isTruthyPauseMarker`'s doc mis-states the function it ports** — `_has_pause_marker` is `state == "paused" or bool(paused_at)` (`cron/jobs.py:477-479`). · `HermesCronJob.swift:515-519`
- **LOW · PRE · `modelOverride`'s decode comment is false at target** — `list --json` also emits it via `_task_to_dict` (`hermes_cli/kanban.py:429`, `:381`). · `HermesKanbanTask.swift:190-196`
- **LOW · PRE · `CronScheduleArgument` still says "verified at tag `v2026.8.31`".** · `CronScheduleArgument.swift:6`
- **LOW · NEW · `exportAllExcludesTrace`'s first cite starts inside a docstring.** `sessions_cmd.py:383-388` → `:385-389`. · `SessionsViewModel.swift:652-657`
- **LOW · PRE · `kanban complete` appends its ids with no `--` while `unblock` does.** · `KanbanService.swift:363`
- **LOW · PRE (t-dafcc4a5) · `project_id` / `provider_override` emitted and never decoded.** · `HermesKanbanTask.swift:142-159`; `KanbanInspectorPane.swift:220` · `hermes_cli/kanban_output.py:20,22`

#### Verified sound

- P30's floor walk re-derived: `_is_recoverable_error_job` absent at `v2026.8.27` (bare `if is_terminal_job(job) and (…)` at `:2367-2375`), present at `v2026.8.31` `:2583-2595` with the exemption; `rearm_oneshot` absent at `v2026.8.19`, both guards in place at its first tag `v2026.8.27` (`:2466-2471`, `:2490-2494`). `hasCronRecoverableErrorResume = isV021OrLater` and "re-arm needs no new flag" are correct.
- The three-predicate split is modelled correctly, with `refusesTerminalJobLocally` deliberately the bare `is_terminal_job` (`trigger_job` `:2012`), pinned by a test. `isTerminal` cannot diverge from `is_terminal_job` (`effective_job_state` `:490-491`).
- Every citation in the P30 diff re-opened is exact at `v2026.9.7`: `:1865-1878`, `:1941`, `:1965`, `:2012`, `:1986-2003`, `:2040-2042`, `:2066`, `hermes_cli/cron.py:691-697`, `:428-436`/`:1949`, `:482-485`/`:2509`, `cron/scheduler_provider.py:261`, `subcommands/cron.py:165-172`, `hermes_cli/cron.py:272`.
- `exportAllExcludesTrace`'s hard cites are right (`sessions_cmd.py:425-434`, `:435`, `:439`, `:395`, `:382-383`).
- C6 holds for sessions export (`availableExportFormats` drops path formats on `isRemote`; `confirmExportOptions` re-checks).
- C5 on the write verbs: `cron_create/edit/resume` all `return 1` through `forward_return=True` (`hermes_cli/main.py:1779`); `cron run` remains output-judged and `runOutcome` matches `_job_action`/`_run_outcome`.
- C10 across the surface: every kanban verb through the `KanbanService` actor with 15–60 s timeouts; fleet, export, delete, rename and cron spawns `Task.detached` with named timeouts; `SessionsViewModel.runHermes` gone.
- `--` placement in `createJobArguments`, `updateJob`, `cronCreateArgs`, `KanbanService.comment/block/unblock` correct for positionals.

#### Product decisions

1. What a `completed` recurring job should be told: (a) "duplicate it" + a Duplicate button, (b) make the edit work (it cannot), (c) state the cause. Is (a) plus Duplicate the "invented re-arm gesture" decision 1 ruled out, or is duplicate-and-create an ordinary create?
2. Should iOS offer re-arm at all, or keep the pointer to the Mac and delete the dead `canRearm` branch?
3. Dash-leading user text: `--flag=value` repo-wide, or validate-and-refuse in the editors?
4. Fleet-copied monitor jobs: forward behind floors, or skip-and-surface?

## Settings, YAML writers/readers, config reads and writes

### HIGH

- **HIGH · PRE · `HermesFileService.yamlScalar`'s double-quoted arm escapes only `\\` and `\"`, so any C0/C1 control, DEL, NEL or U+2028/9 in an MCP `env:`/`headers:` value, header value, tool name, cert path or `command` goes out RAW — PyYAML's reader refuses the document and Hermes discards the whole config.yaml layer.** P32's H1/H2 in the one routine P32 left standing; the tab gap was closed, the control gap never looked at. Fuzzed 7 k inputs through PyYAML 6.0.3: `quoteIfNeeded` 0 failures; `yamlScalar` 3953. Neither editor guards it (`containsControlCharacter` is wired only into `BotsViewModel`/`HermesProfileRoute`), and `patchMCPServerField(expecting:)` builds its expectation from the same rows, so the verifier passes a file PyYAML rejects. · `HermesFileService.swift:2281-2330` (emitted `:2109`, `:2208-2211`, `:2257-2259`, `:699/721/751/846/867`) · `gateway/config.py:775-791` @ `v2026.9.7` · Fix: delete `yamlScalar`'s body and forward to `YAMLScalar.quoteIfNeeded` (reader is already `YAMLScalar.unquote`); add the `MCPServerEditorViewModel` control-char refusal for decision 6 parity.

### MED

- **MED · PRE · A seventh `hermes config unset` site exists outside the P37 helper, ungated and judged by exit code.** `BotAgentConfigService.unsetValue` hand-builds the argv, takes no capabilities, and `BotAgentViewModel.isBenignUnset` opens with `guard result.exitCode != 0 else { return true }` — exactly the exit-0 managed refusal P35 documented. · `BotAgentConfigService.swift:514-524`, `BotAgentViewModel.swift:385-388` · `hermes_cli/config.py:3547-3551` (`managed_error` `:453-455`) · Fix: route through `HermesConfigUnset.argv/judge`, thread `capabilities`, test `Config key not set:` on both exit codes.
- **MED · NEW (P32/P37) · `parseNestedYAML`'s last-wins purge drops the earlier block's descendants but not `maps[path]` itself**, so `sharedPlatformScalar`'s `maps[section]?[key]` fallback reads the FIRST block's `require_mention` on a config carrying `slack:` twice. Related, weaker: on a re-open the descendant sweep deletes a flat dotted sibling (`gateway:` … `gateway.enabled: true` … `gateway:`), which PyYAML keeps. · `HermesYAML.swift:234-245`, consumed `HermesConfig+YAML.swift:91,94` · Fix: also remove `values[path]` and `maps[path]`.
- **MED · PRE · The "one decoder every Scarf-written scalar is read back through" claim is false for three blocks.** `agent.reasoning_overrides` (keys and values), `model_catalog.excluded_providers`, `gateway.multiplex_profile_allowlist` go through `HermesYAML.stripYAMLQuotes`, which returns a double-quoted body verbatim; all three are written through `quoteIfNeeded`. The reasoning-override pattern is free text (`AgentTab.swift:259`) with no control refusal, so a pasted ESC round-trips as the literal `a\x1bb`. · `YAMLScalar.swift:262-263`, `HermesYAML.swift:151,303,509-519`, `PowerSettingsWriter.swift:78,117` · Fix: route the three readers through `YAMLScalar.unquote` or narrow the claim.
- **MED · PRE · `HermesApprovalMode.normalize` sees an already-unquoted scalar, so a QUOTED `approvals.mode: "no"`/`"false"` renders "Never ask" on a host that enforces `manual`.** Same raw-vs-typed discriminator P29 hand-carved for `0`/`1`, applied one layer too late; unsafe direction. · `HermesApprovalMode.swift:71-84`, `HermesConfig.swift:1528-1531`, `HermesConfig+YAML.swift:169-171` · `tools/approval_context.py:198-214` (`_VALID_MODES` `:195`) · Fix: gate the bool arm on `YAMLScalar.resolvesToBool(raw)` before quote-stripping, as `boolishOptional:2372` does.

### LOW

- **LOW · PRE · Two past-EOF citations for `config unset`.** `BotAgentViewModel.swift:380` (`config.py:6009,6041,6059`), `BotAgentConfigService.swift:290` (`:6058-6060`); file is 3891 lines; sites are `:3542`, `:3561`, `:3579`.
- **LOW · NEW (P35/P37) · The "is there anything to clear" guard exists in one of seven clear rows** (`setApprovalMode` only); the other six produce a red "Couldn't clear …" for a no-op. · `SettingsViewModel.swift:616-617` vs `:666,729,812,855,953,964` · Fix: move the no-op into `unsetSetting`.
- **LOW · PRE · `PowerSettingsWriter.setReasoningOverrides` trims the key for the emptiness test and writes it untrimmed.** · `PowerSettingsWriter.swift:71-73` vs `:113-115`
- **LOW · NEW (P32) · `BotDraft.controlCharacterFieldLabel` omits `groups`/`legacyGroup`**, both emitted through `quoteIfNeeded` (`:437,:441`). · `BotsViewModel.swift:215-227`

#### Verified sound

- `YAMLScalar.quoteIfNeeded` after P32's control arm: 0 failures over ~7 000 inputs through PyYAML 6.0.3. The TAB-is-not-in-the-set decision is right.
- `YAMLScalar.unquote` is a genuine single decoder for the three surfaces that claim it (`HermesFileService.unquote:2410-2411`, `HermesBotProfileYAML.unquote:757-758` forwarders; `ProfileRoutesYAML.swift:340`); the hex arm's `allSatisfy(\.isHexDigit)` closes the `\x+9` hole.
- P32's route/bot writers genuinely deleted; `quotedID:220-222` is one policy line over one rule with `''` doubling; both editors' refusals wired; the Role/`description` line-break exemption is correct and lossless through `yaml.safe_dump`.
- P35's `max`/`ultra` re-floor re-walked: 5 levels at `v2026.7.1:794`, `+max` at `v2026.7.7:794`/`v2026.7.7.2:794`, `+ultra` at `v2026.7.20:835-837`, `v2026.9.7:873`. P37's retirement of `AuxiliaryReasoningEffort` complete; `effortOptions(current:)` keeps a hand-edited alias selectable.
- P35's `config unset` gate inside the helper: `capabilities` non-optional; `HermesConfigUnset.argv/judge/belowFloorHint` single source; `isUnset(_:)` positional; argv verified `subcommands/config.py:33-34`; success `✓ Unset {key} from …` `:3562`/`:3582`; failures cover `managed_error` exit-0 `:3549-3551`, `_exit_if_key_managed` `:3363-3371`, `Config key not set:` `:3542/3561/3579`. Repo-wide grep finds no other `"unset"` argv besides the `BotAgentConfigService` site.
- The approvals sentinel matches on both twins (Mac `setApprovalMode:615-620`; iOS `clearAction:216-226`, `save():230-251` before `valueToWrite`, `SettingsView.swift:187` feeds the STORED value; `IOSSettingsViewModel.unsetValue:171-198` off-main with a 15 s bound).
- `saveDirectYAML:1090-1110` captures `previous = writeChain`, awaits it, assigns synchronously before suspension — same shape as `runConfigMigrate:1254-1267`; refusal arms surface.
- P33's proven config read: `loadConfigProven:111-127` via `GuardedTextFile.load`; `rawText` `""` for absent; `config`/`rawConfigText` nil only on refusal; `EmailSetupViewModel:94` guards; P37's `envFailure`-only `apply` guard is right (the halves are not symmetric); `commitSave` bounces on the latch; `loadConfigResult` keeps its one caller (`DashboardViewModel.swift:154`).
- P35's `mcp-tokens/` listing: one `listDirectory` (`loadMCPServers:393-399`), `hasToken(serverName:tokenDirEntries:)` tests both sanitised spellings; `sse_read_timeout` gone.
- Every round-3 LOW citation on this surface re-anchored and exact at the tag.
- `_normalize_approval_mode` re-derived (`:195`, `:203-204`, `:205-210`, `:211`); P29's `0`/`1` carve-out correct.

#### Product decisions

1. Control characters in the MCP entry editor and the reasoning-override field: extend decision 6's refusal, or emitter-only?
2. Which Scarf-written blocks the shared decoder covers: move the three readers onto `YAMLScalar.unquote` (per-key opt-in inside `parseNestedYAML`), or narrow the claim?
3. Bot model-pin clears: gate and output-judge (a hint appears on pre-0.19), or leave exit-code-judged?

## CLI outcome verdicts / Skills / Plugins / Health / Gateway / MCP

### HIGH

- **HIGH · NEW · `hermes config set`'s managed-install arm refuses at exit 0, and this branch wrote the opposite claim into the code twice.** `set_config_value` opens `if is_managed(): managed_error("set configuration values"); return` — stderr, exit 0. `unsetSetting`'s doc says "Every `config set` refusal `sys.exit(1)`s" and `WriteVerdict`'s doc repeats it. Both false at the tag, so on a managed host every write through `enqueueConfigWrite`'s default arm banners "Saved" over an untouched file — and so does `PlatformSetupHelpers.commitSave`'s loop for all 15 forms. Managed arm from v2026.3.28; success lines `✓ Set {key} = … in {path}` / `✓ Set {key} in {env}` at all 32 tags. · `SettingsViewModel.swift:223-224`, `:269-273`, `:295-296`, `:210-212`; `PlatformSetupHelpers.swift:104-108` · `hermes_cli/config.py:3450-3452`, `:445-455`, `:3468`, `:3521` @ v2026.9.7 · Fix: `HermesCLIMarkers.configSetSuccess = ["Set "]` / `configSetFailure = ["Cannot set", "✗ Invalid config key", "Config key not set:"]`, `HermesConfigSet.judge`, non-optional verdict for `config set`, `commitSave` through it.
- **HIGH · PRE · `gateway start|stop|restart` are judged by exit code and each has an exit-0 failure arm — five call sites, two feeding Analytics.** `_cmd_stop` prints `✗ No gateway processes found` (`:5993`) or `✗ No gateway running for this profile` (`:5998`) and returns; `launchd_start` returns without `✓ Service started` when bootstrap fails (`:3926-3928`, `:3938-3939`); `_no_backend_exit` has `None`-code entries (`:5828`, `:5844`, `:5873-5874`); `gateway_command` returns `None` (`:5659-5667`, `:6164-6167`) and `cmd_gateway` discards it (`hermes_cli/main.py:1736-1742`). Markers stable at every tag; `✗ No gateway running for this profile` from v2026.4.30 (C1-safe). · `GatewayViewModel.swift:491`, `:498-513`; `HealthViewModel.swift:512-516`, `:537-542`; `HermesFileService.swift:2487-2491`; `scarfApp.swift:613-615` · `hermes_cli/gateway.py:3914-3940, 5870-5887, 5957-6000, 6019-6029` · Fix: one `HermesGatewayServiceVerdict`; `stopHermes()`'s boolean becomes the verdict.
- **HIGH · PRE · On a managed install Hermes prints its own success line after a refused write.** `save_config` refuses (`if is_managed(): managed_error("save configuration"); return`) while callers print success afterwards: `cmd_enable`/`cmd_disable` → `✓ Plugin … enabled.` / `⊘ Plugin … disabled.`; `cmd_mcp_remove` → `✓ Removed '<name>' from config`; `_cmd_skills_trust` → `Trusted: <root>`. `pluginsEnableSuccess`/`pluginsDisableSuccess` fire on a write that never landed. From v2026.3.28. · `PluginsViewModel.swift:368-380`, `:391-397`; `MCPServersViewModel.swift:147-166`; `ProjectSkillsViewModel.swift:47-78` · `hermes_cli/config.py:2315-2318`, `:453-455`; `plugins_cmd.py:115-120, 1022-1023, 1196-1198`; `mcp_config.py:110-121, 523` · Fix: one shared `managedRefusal` marker in every config-mutating verdict with `failureWins: true`.
- **HIGH · PRE · `mcp remove` is judged by exit code and `cmd_mcp_remove`'s not-found arm exits 0.** `_lookup_server` prints `✗ Server '<name>' not found in config.` and returns None; `cmd_mcp_remove` returns (`:518-519`), as does the "Cancelled." arm; `mcp_command` returns None for every handler except `install` and `cmd_mcp` is `forward_return=False`. `deleteServer` flashes "Removed" and the row disappears until the reload restores it — the shape P31 fixed for `pairing revoke`. · `MCPServersViewModel.swift:150-158`; `HermesFileService.swift:880-883` · `hermes_cli/mcp_config.py:98-107, 515-532, 878-913` · Fix: `HermesMCPRemoveVerdict`, anchored.
- **HIGH · PRE · `t-bd119897` still reproduces verbatim: `OAuthFlowController` judges before the pipe reports EOF.** Termination handler nils `readabilityHandler` and hops to main on one Task while chunks arrive on separate unordered Tasks; a late `did not return credentials` / `Token exchange failed` chunk is dropped; `succeeded = exitCode == 0 && !outputFailed` fails toward false success. `MCPLoginController` next door has the cure (`OutputInbox`, `markEOF`, `pump()`, `scheduleDrainDeadline`, `ProcessFactory`). · `OAuthFlowController.swift:129-151`, `:232-252` · cure at `MCPLoginController.swift:101-167` · Fix: port, or hoist into a shared `DrainedProcessRun` (`NousAuthFlow.swift:118`, `SpotifyAuthFlow.swift:109`, `HermesProxyService.swift:102` share the shape).

### MED

- **MED · PRE · A `plugins update` whose post-pull security scan DISABLES the plugin still reports "Updated".** `_rescan_after_update` prints `Plugin '<name>' has been disabled.` then `cmd_update` prints `✓ Plugin <name> updated.` (`:828`); both exit 0; `pluginsUpdateFailure` lacks the marker and `pluginsUpdateSuccess`'s `"updated."` is unanchored. · `HermesCLIOutcome.swift:362-390`; `PluginsViewModel.swift:334-341` · `hermes_cli/plugins_cmd.py:810, 832-851` · Fix: add `"has been disabled."` to `pluginsUpdateFailure` (already `failureWins: true`).
- **MED · PRE · `mcp test`'s verdict is a bare `output.contains("✗")` over plugin- and server-authored text.** `_print_tools` prints each tool's description on the success path; a stdio server's stderr is merged. · `HermesFileService.swift:906-925` · `hermes_cli/mcp_config.py:33-36, 49-52, 583-621` · Fix: anchored `Connected (` / `Tools discovered:` vs `Connection failed (` / `not found in config.`.
- **MED · PRE · `t-6fa3fc84` still reproduces.** `SlackSetupViewModel.save()` writes `platforms.slack.require_mention` and `extra.reply_in_thread` unconditionally; `platform_section` bridges shared keys from ONE section — a top-level `slack:` block replaces the nested one. Read side models this (`sharedPlatformScalar`); write does not. · `SlackSetupViewModel.swift:64-66` · `gateway/config_loader.py:171-180`, `:197-200` · Fix: the `multiplexProfilesKey(isTopLevel:)` shape.
- **MED · PRE · `hermes config migrate` prompts on stdin, so Scarf's Migrate button can abort mid-migration.** `migrate_config(interactive=True)` → `_prompt_and_save_env` → `line_input` → bare `input()` with no `EOFError` guard; Scarf gives no stdin; `_config_version` stamp at `:1375-1378` never runs. · `SettingsViewModel.swift:1249-1271`; `AdvancedTab.swift:178` · `hermes_cli/config.py:1289-1297, 1354-1369, 1375-1382, 3653-3690`; `cli_output.py:29-37` · Fix: pipe blank lines, or gate the button.
- **MED · NEW (P33) · `waitDraining`'s doc names `HealthViewModel.dashboardListenerPID` as the shape it was hoisted from, and that site was never migrated** — it still hand-rolls the lock-box + semaphore + bounded wait with a private `drainGrace`, and never closes `output.fileHandleForReading` (one fd per "Stop Dashboard"). · `HealthViewModel.swift:1190-1249`; claim at `ProcessTimeout.swift:81-85` · Fix: `lsof.waitDraining(timeout: Self.lsofTimeout, pipes: [output])`.

### LOW

- **LOW · PRE · Missing `--` at six argv sites:** `mcp remove/test <name>` (`HermesFileService.swift:882`, `:889`; `subcommands/mcp.py:44-50`); `mcp add <name> --command …` positional before flags (`HermesMCPAdd.swift:255`, `:284`; `:27-42`); `skills trust|untrust <root>` (`ProjectSkillsScanner.swift:142`; `subcommands/skills.py:28-35`); `config set <key> <value>` / `config unset <key>` (`SettingsViewModel.swift:211`; `HermesCLIOutcome.swift:656`; `subcommands/config.py:24-34`).
- **LOW · NEW (P31) · The `pairing approve` refusal's prefix landed at v2026.7.30, not v2026.8.3.** Behaviour unaffected (marker is the shared tail). The lockout marker is a source-split f-string below v2026.9.7 (`v2026.8.31:91-93`), so a source grep reports it absent from v2026.5.7–v2026.8.31 while the emitted text is byte-identical. · `HermesCLIOutcome.swift:456-461` · `hermes_cli/pairing.py:80` @ v2026.7.30 / `:77` @ v2026.7.20.
- **LOW · PRE · Two stale `skills_hub.py` citation clusters that P37's sweep walked past.** `HermesCLIVerdictP21Tests.swift:213-216`: `do_audit` `:879-880`, `_print_error` `:891`, `Auditing … skill(s)...` `:893`, `No hub-installed skills to audit.` `:887`; `:249-252`: `do_update` `:831-832`, nested `do_install` `:868`, `Installation blocked:` `:699`.
- **LOW · PRE · `ProjectSkillsViewModel.setTrusted` discards the CLI output entirely**; `_cmd_skills_trust`'s `Not a directory:` / `Not inside a git checkout…` arms exit 0. · `ProjectSkillsViewModel.swift:53-78` · `hermes_cli/main_agent_cmds.py:179-205, 218-235`

#### Verified sound

- P31's pairing verdicts correctly and completely implemented in both arms (`HermesCLIOutcome.swift:499-545`; `GatewayViewModel.swift:455-462`, `:531-556`, `:557-582`; `GatewayView.swift:255-266`); every cited line resolves; marker stability re-walked independently across all 32 tags; no flag needed (C1).
- P31's `skillsUpdateFailure` split correct at every tag (the `if not force:` guard sits below the warning print at v2026.3.17:346-349, v2026.6.19:598-601, v2026.8.31:684-687, v2026.9.7:682-685).
- `finishForceUpdate` genuinely fixed; `forceUpdateArgs` = `["skills","update","--force","--",name]`.
- `plugins remove` correctly exit-code-judged (every refusal `sys.exit(1)`, `plugins_cmd.py:407-416`, `:80-83`, `:895`); `plugins compat`'s inverted exit contract handled; `plugins enable/disable` markers and floors re-derived; `HermesPluginList`'s P31 re-anchoring is a real quote (`:1290-1293`, `:1324-1331`).
- P24's transport discriminator reorder landed and matches `_is_http` (`tools/mcp_tool_health.py:27`), `mcp_tool_discovery.py:484`, `mcp_tool_transport.py:412`.
- P35's two MCP residue items landed. Round-3's `ProcessTimeout` MED fixed properly (SIGTERM → bounded poll → pid-guarded SIGKILL → bounded poll).
- `MCPLoginController`'s drain choreography survives re-derivation; `--` before the server name; `--flow` gated at 0.21.1.
- `config unset`'s verdict right end to end; P37's move of the gate inside `unsetSetting(_:capabilities:)` makes it uncheckable-by-omission.
- `hermes doctor` and `config check` need no verdict and have none.
- `unglyphed`'s glyph set matches every emitter; `stripANSI`'s ESC is real.
- argv re-verified against the tagged argparse for `pairing`, `skills`, `plugins`, `mcp login/list/catalog/remove/test`, `gateway list`, `config set/unset/check/migrate`.

#### Product decisions

1. Is a managed Hermes a supported Scarf host: (a) per-verb refusal markers, (b) connect-time detection + read-only surfaces with one banner, (c) both?
2. Gateway verdict banner copy: "requested" or "started"/"stopped"; is "nothing was running" on Stop a failure or a success?
3. `plugins update` security-disable: failure or a third state?
4. `config migrate`: pipe blank lines, warn, or hide the button?

## Capabilities, floors and gates, chat/ACP

### HIGH

*(none — every HIGH-class defect round 3 filed on this surface is genuinely fixed)*

### MED

- **MED · PRE · The typed-slash optimistic mirrors for `/queue` and `/steer` are ungated**: on a pre-v0.13 host typing `/queue foo` paints "Queued — runs after current turn." plus a chip, and `isNonInterruptiveSlash` suppresses the working indicator for the real turn the LLM then runs. · `ChatViewModel.swift:1267,1293-1299`; iOS `ChatView.swift:1679-1686,1705-1707` · `acp_adapter/server.py:170-171` @ `v2026.5.7`; `acp_adapter/commands.py:88-95` @ `v2026.9.7` · Fix: gate on `hasACPQueue`/`hasACPSteer`.
- **MED · PRE · The two top-level reasoning-effort pickers offer `levels(capabilities:)` with no widening for the value on disk**, so a 0.18.x host with `ultra` renders a blank picker; `ReasoningOverridesSection` already has `effortOptions(current:)`. · `AgentTab.swift:40`, `AuxiliaryTab.swift:277` (vs `AgentTab.swift:248,280-283`) · `hermes_constants.py:794` @ `v2026.7.7` / `:835-837` @ `v2026.7.20` · Fix: `levels(capabilities:selected:)` for all three.
- **MED · NEW · `nonInterruptiveCommands`' doc still says "Fronted by Hermes v2026.4.23+ … listed unconditionally … no-op gracefully"** — `acp_adapter/` at v2026.4.23/4.30 has no `steer`; an unknown ACP name burns a turn. · `RichChatViewModel.swift:653-660` · Fix: the v2026.5.7 floor and pointers to `hasACPSteer`/`hasACPQueue`.

### LOW

- **LOW · NEW · `hasCronRecoverableErrorResume`'s doc names `_reject_terminal_activation` at `v2026.8.31`, where it does not exist** (two inline `update_job` guards `:2583-2595`, `:2684-2696`; extracted at `v2026.9.7:1865`). Line ranges themselves all exact. · `HermesCapabilities.swift:1359-1362`
- **LOW · PRE · `hasGoals`' doc claims RichChatViewModel adds `/goal` to the non-interruptive list**, which `nonInterruptiveCommands`' NOTE denies. · `HermesCapabilities.swift:183-187` · `hermes_cli/commands.py:103` @ `v2026.5.7`, `:113` @ `v2026.9.7`
- **LOW · PRE · `hasACPQueue` has no citation at all.** · `HermesCapabilities.swift:190-191` · `acp_adapter/server.py:171` @ `v2026.5.7`, absent at `v2026.4.30`
- **LOW · NEW · `alwaysAvailableCommands`' rewritten doc asserts an Always/Active-session split the body no longer implements; `hasActiveSession:` is never read.** · `RichChatViewModel.swift:742-778`
- **LOW · PRE · `AgentTab`'s inline comment still credits v0.20 for both effort tiers.** · `AgentTab.swift:30-32`
- **LOW · NEW · `everyFallbackNameIsDispatchedOrClientSide` checks membership in the cross-version UNION** (both `compact` and `compress`), so it cannot catch a wrong compress spelling at a version; doc says "nine" while the set holds ten. · `M9SlashCommandTests.swift:625-635,699-718`
- **LOW · NEW · The `hasACPSteerOnIdle` arm of `disabledSlashCommandNames` is now unreachable** (`hasACPSteerOnIdle == hasACPSteer`; roster hides `steer` below the floor); its six-locale string can never render. · `RichChatViewModel.swift:1376`, `:1420`
- **LOW · PRE · `/queue` is offered on an idle-but-open session**; `_cmd_queue` on idle appends to a queue nothing drains. · `RichChatViewModel.swift:1373-1378` · `acp_adapter/commands.py:285-289`

#### Verified sound

- All four new flags' floors walked independently: `hasACPSteer`/`hasACPSteerOnIdle` = 0.13.0 (`server.py:170`/`:171`/`:812-820` @ `v2026.5.7`; nothing at `v2026.4.30`/`4.23`); `hasReasoningEffortMax` = 0.18.1, `hasReasoningEffortUltra` = 0.19.0; `hasCronRecoverableErrorResume` = 0.21.0 (all 32 tags; `cron/jobs.py:664-692` @ `v2026.8.31`).
- Four-test pattern present for each (`HermesP37RemediationTests.swift:33-63`; `HermesCapabilitiesTests.swift:939,957,984,994,1123,1180`; `:1353-1378`).
- P34's dropped roster re-derived from source: `cost` nowhere at any tag; `clear:58`, `sessions:148`, `codex-runtime:156`, `yolo:181`, `reload-skills:259`, `usage:277`, `quit/exit:302` @ `v2026.9.7`, line-exact; the ACP dict nine names `:44-66`, `_available_commands` `:69-74`, fall-through `:88-95`; earliest adapter `v2026.3.17:server.py:329-337` already carries `help model tools context reset compact version`.
- No other ACP method Scarf sends is ungated: `initialize`, `session/new|load|prompt|cancel|set_mode|set_model` (`ACPClient.swift:324,404,425,532,559,584,620`) all present from `v2026.3.17`.
- The roster snap-back has no iOS twin to miss; `KnownPlatforms.reconcile` (`HermesTool.swift:241-246`) wired at `PlatformsView.swift:72,87` and `ToolsView.swift:64,71`; snap target `cli` unfloored.
- `scripts/tests` skip policy real on both machine states (20/20; `HERMES_SRC=/nonexistent` → `FAILED (failures=3)`; with `SCARF_ALLOW_SKIP=1` → `OK (skipped=3)`); `ALIASES` third-shape close correct.
- README target table + gate consistent with `HERMES_TARGET_TAG`.
- `WebToolsBackendRoster` re-derived against `git ls-tree` (tavily window v2026.8.27/8.31/9.7; perplexity at 9.7; keenable at 8.19).
- Advertisement ordering and the client-side intercept table correct (`availableCommands:917-1001`; `clientSideSlashCommand:1231-1239` one case; both send paths call it identically).

#### Product decisions

1. Sub-floor `/steer`/`/queue` typed by hand: gate the chip and send as an ordinary prompt; additionally notify; or leave as the v1 caveat and only fix the working indicator?
2. A configured effort level above the host's floor: widen the picker, render blank, or show with a "not supported" affordance?
3. The unreachable idle-steer grey-out: keep as defence-in-depth, or retire the arm, the string and six translations?

## Concurrency and spawn discipline (C10), platform-setup forms, iOS twins

### HIGH

- **HIGH · PRE · `unzip`/`zip` in ScarfCore hold unbounded `waitUntilExit()` with an undrained stderr pipe and a `readToEnd` after the wait** — a chatty/corrupt archive hangs restore or backup forever with no timeout (C10), the exact shape P33 fixed in the app target. · `RemoteRestoreService.swift:544` (also `:354`), `RemoteBackupService.swift:520` · Fix: hoist `Process.waitDraining` into ScarfCore, convert all three with named timeouts.
- **HIGH · PRE · `HermesProxyService` gives the child a `Pipe()` for stdout it never drains, closes or reads** — 64 KB of output wedges the proxy. · `HermesProxyService.swift:86` · Fix: `FileHandle.nullDevice`.
- **HIGH · NEW · `HermesP35MCPTokenProbeTests` subscripts an array immediately after a non-guarding count `#expect`** — the test-host stability rule. · `HermesP35MCPTokenProbeTests.swift:106-107` · Fix: `try #require(servers.first)` or a guard.

### MED

- **MED · NEW · `try! #require(...)` traps the test host when the premise fails.** · `HermesP35SelectionAndFloorsTests.swift:41`, `:48` · Fix: make the func `throws`.
- **MED · PRE · `enforceArchiveBounds` fails OPEN**: `runToolCapturingOutput` reads stdout after the bounded poll and never drains stderr; a chatty `unzip -Zt` times out and the bomb caps are skipped. · `ProjectTemplateService.swift:342-344`, `:366-391` · Fix: `waitDraining`, and treat a failed listing as a refusal.
- **MED · PRE · `HermesFileService.runShellProbe` reads stdout after the wait and never drains `errPipe`** — noisy rc files block the env probe. · `HermesFileService.swift:2620-2633`
- **MED · NEW · `HealthViewModel.dashboardListenerPID` still hand-rolls the drain routine P33 hoisted from this very site.** · `HealthViewModel.swift:1205-1231`; helper `ProcessTimeout.swift:99`
- **MED · NEW · The P22 sweep's `HealthViewModel.swift` allowance (t-cd9fd829) is dead debt**: that wait runs inside `Task.detached` (`:1155-1163`); the "allowance is still REAL" check greps for the call, not its isolation. · `MainActorSpawnDisciplineP22Tests.swift:437-441`, `:520-530`
- **MED · NEW · `recoveryOffer` is "the single source of truth" in one direction only**: iOS pre-refuses a non-terminal one-shot whose time is past (`oneShotIsUnresumable`), the Mac does not, so the Mac gets a raw exit-1 ValueError. · `CronViewModel.swift:420-428` vs `IOSCronViewModel.swift:160-164` · `cron/jobs.py:1991-1996` @ v2026.9.7 · Fix: fold `oneShotIsUnresumable` into `recoveryOffer` as the third door.
- **MED · PRE · `SpotifyAuthFlow` never nils its two `readabilityHandler`s on EOF, and the spawn has no timeout** (C10). · `SpotifyAuthFlow.swift:94-107` (teardown only at `:123-124`)

### LOW

- **LOW · NEW · `ProvenConfig.exists` is read by no caller.** · `HermesFileService.swift:69`; `PlatformSetupHelpers.swift:207-222`
- **LOW · NEW · `alwaysAvailableCommands(capabilities:hasActiveSession:)` no longer reads `hasActiveSession`.** · `RichChatViewModel.swift:766-839`
- **LOW · PRE · `AppRelauncher.relaunch()` never closes the WRITE ends of its two pipes** (2 fds per relaunch). · `AppRelauncher.swift:91-95`
- **LOW · NEW · The P22 sweep's allowance loop maps name→path with a two-way ternary**, so a third allowance would be checked against the wrong file. · `MainActorSpawnDisciplineP22Tests.swift:520-524`
- **LOW · PRE · The sweep matches only `waitDraining(` / `.waitUntilExit(`**; a hand-rolled `isRunning` poll or `DispatchSemaphore.wait(` on the main actor would not be caught. · `:466`
- **LOW · NEW · `ConfigReadProofP33Tests` proves the refusal path for 3 of 15 forms, `HermesP37RemediationTests` for 2**; nothing sweeps all 15 `apply` bodies for a `snapshot.env` read outside the guard. · `ConfigReadProofP33Tests.swift:90-183`

#### Verified sound

- The P37 skip-apply-on-`envFailure` guard and its asymmetry argument hold across all 15 `apply` bodies: every config-reading form opens with `guard let cfg = snapshot.config?.<platform> else { return }` (Discord `:70`, HomeAssistant `:60`, Matrix `:57`, Mattermost `:51`, Ntfy `:52`, Slack `:53`, Telegram `:84`, WhatsApp `:66`, WhatsAppCloud `:55`) or a non-blanking `if let` (Signal `:64`); Email guards `rawConfigText` (`:99`). `HermesConfig.discord`/`.ntfy`/etc. are non-optional (`HermesConfig.swift:1814-1825`), so `snapshot.config?.X == nil` means refusal only.
- `loadForm`'s one-read consolidation correct for both selectors (`PlatformSetupHelpers.swift:207-222`); the refusal latch cannot be lost to the `guard !self.isSaving` early return (`:327-329`, `:370`).
- Reload and Save both `.disabled(viewModel.isBusy)` in all 15 setup views.
- `HermesCronJob.recoveryOffer` matches Hermes exactly at the tag (`:509-522`, `:1865-1878`, `:2012`, `:2054`, `:2066`); Mac/iOS refusal sentences and button gating twinned (`CronView.swift:595-640`, `IOSCronViewModel.swift:166-179`).
- The `/steer` floor is real (`server.py:170` @ `v2026.5.7`; absent at `v2026.4.30`; idle rewrite `:812-824` same tag); the nine-name dict matches; `_handle_slash_command` returns `None` for unknown (`:88-95`).
- `HermesConfigUnset` is one gate for both twins (`HermesCLIOutcome.swift:655-673`; `SettingsViewModel.swift:245-246`; `IOSSettingsViewModel.swift:177-192`); argv one positional; `unglyphed` strips the `✓` before the anchored `"Unset "` test.
- `Process.waitDraining` sound (`ProcessTimeout.swift:32-122`): readers before the wait, each closes only the handle it drained, bounded group wait, SIGTERM → poll → pid-guarded SIGKILL → poll; its three callers pass `[errPipe, outPipe]` and take `drained.first` as stderr.
- The P22 sweep's indent walk does work on the app target: the three `nonisolated` spawn sites are excused by their enclosing `nonisolated func`, and the `isolatedScanned == allowed.count` floor fails if the enumerator finds nothing.

#### Product decisions

1. Hoist `Process.waitDraining` into ScarfCore and convert `RemoteRestoreService`/`RemoteBackupService` now, or file — noting the restore path runs a user-supplied archive with no timeout at all?
2. Should a listing Scarf could not read become a REFUSAL for `enforceArchiveBounds`, or stay fail-open?
3. Keep the platform-specific `terminalRefusalMessage` wording, or give iOS the re-arm gesture?
