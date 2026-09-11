---
id: t-5c6de93d
title: Audit P28: cross-phase review remediation (round 2)
status: done
added: 2026-09-10
priority: high
---

## Description

Round-2 analogue of P17: remediate the cross-phase reviewer's findings on `fix/whole-surface-audit-r2` (HEAD 479886cf). Findings list (H1–H3, M1–M5, L1–L6) is in the phase scratchpad `xphase-findings.md`:

- H1 roster widen-for-current hatch unreachable (computeConfiguredPlatforms misses nested `platforms.<name>.` keys; no identifyingEnvVar arms for the eight newly-gated rows) + L6 first-paint hide.
- H2 iOS approvals.mode picker pins `manual` (option set `manual/auto/yolo` vs Hermes `manual/smart/off`; `options.first` primed for empty current); same-sheet `agent.max_turns` resolved-default prime.
- H3 Tools tab platform roster ungated + L4 dead `platforms` accessor.
- M1/M2 MCPLoginController shared OutputInbox drain race + stale post-spawn `process` assignment.
- M3/L5/L2 sessions trace redaction default must be ON; restore prior toggle on switch-away; `:394`→`:395` citation.
- M4/L3 literal `== "true"` boolish reads → `HermesYAML.boolishValue`.
- M5/L1 stale doc comments / capability doc lines.

Each finding verified against current Scarf code (and tagged Hermes source where a contract is cited) before fixing; NO-OP with evidence where the reviewer is wrong.

## Plan



## Artifacts

Branch `fix/whole-surface-audit-r2`. 8 commits (base 479886cf):

- `6a401176` fix(platforms): make the widen-for-current hatch reachable — **H1 + L6 + H3 + L4**
- `bfa41e1f` fix(ios-settings): stop the quick-edit sheet pinning modes nobody picked — **H2**
- `752bbb5b` fix(mcp-login): stop a retired run feeding the next run's verdict — **M1 + M2**
- `1b4506cb` fix(sessions): restore redaction as the default for a trace export — **M3 + L5 + L2**
- `a34839df` fix(config-reads): route the last literal boolish readers through the one helper — **M4 + L3**
- `8e8d124a` docs(comments): carry P23's re-floors into the consumer comments — **M5 + L1**
- `aab1d591` fix(platforms): count a flow-style `platforms: {ntfy: …}` entry too — fresh-eyes follow-up
- `4c8623f6` test(p28): assert the boolish rule directly, report the raw parse on failure

## Per finding

**H1 — CONFIRMED, fixed.** `computeConfiguredPlatforms` recognised only a top-level `<name>:` section or an `identifyingEnvVar` arm; verified that `NtfySetupViewModel.save` writes only `platforms.ntfy.extra.*` + `NTFY_TOPIC`, `SimpleXSetupViewModel` only `.env` (`configKV: [:]`), `WhatsAppCloudSetupViewModel` only `platforms.whatsapp_cloud.*`, and that `yuanbao`/`teams`/`google_chat`/`line`/`buzz` have NO Scarf form at all (configured via `hermes setup` → the same nested block). Now: nested `platforms.<name>` / `gateway.platforms.<name>` (exact key or prefix) counts, plus `ntfy`→`NTFY_TOPIC` and `simplex`→`SIMPLEX_WS_URL` arms. `whatsapp_cloud` deliberately gets no arm (its form writes no env key) — the nested check finds it. Pinned end-to-end by driving the real ntfy form with a recording CLI runner, rendering its own recorded `config set` keys back into YAML and feeding that to the real detector, then asserting the roster on `.empty` and on v0.14.

**H2 — CONFIRMED, fixed.** Re-verified `_VALID_MODES = ("manual","smart","off")` at `tools/approval_context.py:197` @ v2026.9.7. Option set now `HermesApprovalMode.options`; `resolved(capabilities:)` prepends the `""` host-default sentinel row labelled from the shared `HermesConfig.approvalModeHostDefaultLabel` (new static); priming moved into one pure `Kind.primedScalar` that never primes a concrete option over an absent value; `hasValidValue` rejects an empty enum selection unless `""` is an option; Save writes NOTHING when the control still holds what priming produced — which covers the `agent.max_turns` resolved-default prime the reviewer flagged in the same sheet, and `display.show_reasoning`, with one rule. Picker style `.segmented`→`.menu` (the sentinel label is a sentence). False comment at `SettingsView.swift:171-174` corrected; the Quick-edits row now names the host default instead of rendering a blank caption. iOS built with `-derivedDataPath`; 5 new iOS tests.

**H3 — CONFIRMED, fixed.** `ToolsViewModel` assigned `availablePlatforms = KnownPlatforms.all` and `ToolsView` rendered it straight into the `--platform` menu. Both surfaces now go through one new seam, `KnownPlatforms.visible(on:isConfigured:)`. Also found and fixed a second divergence the gate made load-bearing: Tools had its OWN `hasSuffix(":")` configured-ness scan (blind to `slack: {}` and to nested keys); it now calls `PlatformsViewModel.computeConfiguredPlatforms`, and a test asserts the two surfaces return the identical set for one file. Stale "always show these" comment replaced with the C5 reason.

**L4 — CONFIRMED, deleted.** `PlatformsViewModel.platforms` had no consumers; `ToolsViewModel.availablePlatforms` became the same trap after the filter moved to the view (its only remaining use was an unreachable off-roster-selection correction), so both are gone.

**L6 — CONFIRMED, fixed.** `hasLoadedConfiguredPlatforms`; until the read lands the filter treats every row as possibly configured (what Scarf rendered before the gate existed), so a configured sub-floor row is never hidden-then-shown.

**M1 — CONFIRMED, fixed**, with a correction to the reviewer's mechanism. Fresh `OutputInbox` per run captured by that run's reader; `readabilityHandler` cleared in the spawn's generation-mismatch branch; dead `OutputInbox.reset()` removed. The reviewer's *text*-leak path is NOT observable — the mismatch branch terminates the retired child before it writes (two test constructions asserting on leaked text passed against the broken code). The reachable harm is a premature `markEOF` on the new run's inbox, which collapses P21's EOF-then-exit ordering: the test asserts the invariant (`readabilityHandler` nil on the retired run's pipe) and *does* fail against the broken code — there, run B reports `succeeded == false` over its own `✓ Authenticated` line.

**M2 — CONFIRMED, fixed.** `guard !self.didFinish` before the post-spawn `process`/`stdoutPipe` publish. NOT independently unit-testable: the spawn continuation always resumes before a child process can exit, so the window cannot be opened from a test. It shares the branch the M1 test exercises; no dead test-only seam was left behind.

**M3 — CONFIRMED, fixed.** Re-verified the docstring at `hermes_cli/sessions_cmd.py:382-383` and the read at `:395`. Redaction default is now per-format in the VM (`exportFormatChanged(from:to:)`), capability-independent; decision 3 (OFF → `--no-redact`) stands. **L5** — the same function restores the user's prior non-trace choice instead of forcing OFF. **L2** — `:394`→`:395` fixed (and the docstring line cited).

**M4 / L3 — CONFIRMED, fixed.** `EmailSetupViewModel` → `HermesYAML.boolishValue(raw) ?? false`; verified Hermes's read is plain truthiness over the PyYAML-typed value (`plugins/platforms/email/adapter.py:354` @ v2026.9.7). `PluginsViewModel`'s `plugin.yaml` `tool_override` likewise (noting it is Scarf's own display read — Hermes gates on `plugins.entries.<id>.allow_tool_override` in config.yaml, `hermes_cli/plugins.py:568-578`; a manifest-level `tool_override` key is read by no Hermes module at the tag).

`grep -rn '== "true"' scarf/` judgements on the remaining hits:
- `HermesPeerCLI.swift:366` (`bool`'s String fallback) — **fixed** too: JSON carries real bools, but a Python-stringified `"True"` was read as false.
- `SettingEditorSheet.swift:211` (toggle priming) — **fixed**, routed through the helper.
- `SettingEditorSheet.swift:143` (`primed == "true"`) — **no change**: a round-trip of our OWN canonical "true"/"false" scalar from `primedScalar`, not a YAML read.
- `ConfigYAMLScalarQuotingTests.swift:157`, `SettingsEditorSentinelP28Tests.swift:101-102`, `BotModePhaseAB0Tests.swift:283`, `SectionAuditF5PlatformExtraKeyTests.swift:38/65/79`, and the P13/P17/P18/V0211 test doc comments — **no change**: test expectations and prose naming the bug class.

**M5 — CONFIRMED, fixed** (all ten, plus four neighbours in the same families the reviewer did not list): curator adopt/unmanaged v0.20→v0.19.1; curator ledger/purge/rollback v0.20.4→v0.20.3; `approvals suggest` v0.20→v0.19.1; `cron runs` v0.20→v0.19.0; personalities v0.20.4 (v2026.8.18)→v0.20.1 (v2026.8.13) in both files. Tag→version re-read from `pyproject.toml` at each tag.

**L1 — CONFIRMED, fixed, with a sharper claim than the reviewer's.** P24's "read by no Hermes version" is loose: `sse_read_timeout` DOES occur at the tag — Hermes hard-codes it (`"sse_read_timeout": 300.0` in `sse_client`'s kwargs, `tools/mcp_tool_transport.py:352` @ v2026.9.7; same literal in `tools/mcp_tool.py` at the v0.13 origin v2026.5.7). What does not exist is a CONFIG KEY an `mcp_servers` entry can set, which is what P24's removal turned on; the comment now says exactly that.

## Tests

- New: `scarfTests/HermesP28CrossPhaseRemediationTests.swift` (10 tests), `Scarf iOSTests/SettingsEditorSentinelP28Tests.swift` (5 tests).
- Revert-checks run for real, not reasoned: reverting the H1/L6 detector fails 5 of the 6 platform tests; reverting the per-format trace default fails 2; reverting only the restore-prior-choice half fails 1; reverting the email boolish read fails that test (4 spellings); reverting the MCP reader-unhook fails the login test with `succeeded != true`.
- ScarfCore `swift test`: 2590 tests / 172 suites, 4 issues, all in `ACPClientStartIdempotenceTests` (3 s internal timeout, load-sensitive) — green in isolation. Pre-existing.
- iOS `Scarf iOSTests`: 7/7 pass.
- Mac: the 10 suites nearest this diff (P28, ConfigYAMLScalarQuoting, AuditP21Verdict, MainActorSpawnDisciplineP22, AuditP25SurfaceCopy, SessionExportRemoteDestination, HermesFileServiceConfigParity, MCPOAuthAndTransportP24, HermesMCPOAuthFlow, HermesCLIExitCodeTruth) = **109/109 pass together**.
- The whole `scarfTests` target is not a usable signal on this machine: a run takes a Swift `Index out of range` crash in an unrelated suite, restarts, and cascades ~100 timing failures (10–12 s durations from contention). EVERY suite in that list passes in isolation with these changes (verified one by one). A base-commit comparison was attempted in a `git worktree` and is impossible: the SwiftTerm build plug-in needs interactive trust, so `xcodebuild` refuses to build there. Corroborating evidence that this pre-exists: the working tree carries an UNCOMMITTED (not mine, left by an earlier phase) `SettingsP20ConfigDefaultsTests.swift` change raising a deadline from 10 s to 120 s with the comment "under the full parallel `scarfTests` run those can take well over 10 s". Left untouched and unstaged.
- One flake of my own, chased down rather than ignored: the email round-trip failed for exactly one spelling (`on`) in a batch run while three other `xcodebuild` runs were contending for the machine; it did not reproduce in 3 isolated runs nor in a clean re-run of the same batch. `4c8623f6` asserts the boolish rule with no I/O in the way and reports the parsed raw value on failure so a recurrence is diagnosable.

## Fresh-eyes findings on my own diff

1. Nested detection missed a flow-style `platforms: {ntfy: …}`, where the parser holds `platforms.ntfy` as the key with nothing under it → added the exact-key arm (`aab1d591`).
2. Checked that `ToolsView` really is inside `ContextBoundRoot`'s `.hermesCapabilities` (`scarfApp.swift:495`), or its new `.empty` default would have hidden every gated row on the Tools tab permanently.
3. Checked the iOS `@State primedValue` cannot be consulted before `.task { primeFromCurrent() }` runs (Save is a toolbar button), and that the sentinel no-op falls out of the primed-equality rule rather than needing its own branch.
4. Confirmed the sub-floor export path (`formatsAvailable == false`) still passes `redact: false` with `.jsonl` — byte-identical argv for a pre-0.18.1 host (C1).
5. Removed the `hasLiveProcessForTesting` seam once M2's window proved untestable, rather than leave an unused test-only accessor — the same trap L4 named.

## C7

No managed tier staged or committed: `.memory/` and `tasks/` left dirty; all 8 commits touch only `scarf/` paths.

