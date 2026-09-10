---
title: Hermes v0.21.1 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-21-1-compatibility-decisions
tags: [hermes, capability-gating, versioning, settings, hermes-v0-21-1]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/WebToolsBackendRoster.swift, scarf/scarf/Features/Settings/Views/Tabs/WebToolsTab.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: 238674747424f516c7b840a69371d1b0fb004fa7
created: 2026-09-08
updated: 2026-09-09
reviewed: 2026-09-09
reviewed_by: claude-fable-5-1
---
The decision record for the v0.21.1 ("v2026.9.7") parity cycle, Phases 0–7.
Tag map: v2026.7.30 = 0.19.1 (NOT 0.20.2 — corrected in the P16 section
below, which carries the full tag walk), v2026.8.19 = 0.20.5, v2026.8.27 = 0.20.6,
v2026.8.31 = 0.21.0, v2026.9.7 = 0.21.1.

The shape of this cycle: **a capability floor is neither monotonic nor readable
from a two-endpoint diff.** The audit report's floors were a starting point and
were wrong in five places; every correction came from walking a symbol across
every tag rather than diffing the endpoints. See
[[Hermes v0.21.1 Audit Findings]] for the source-grounded findings and the
deliberate NO-OPs.

## Observations
- [gotcha] A capability can be a WINDOW, not a floor: `plugins/web/tavily/` was deleted at v2026.8.31 (0.21.0) and re-added at v2026.9.7 (0.21.1, commit 428e084dcd), so `hasTavilyWebBackend` is `semver != 0.21.0`. A removal flag written as a floor silently hides a live surface on every later release #capability-gating
- [gotcha] Floors must be found by walking the symbol across EVERY tag over EVERY file location it has ever had. The v0.21.1 modularization moved most argparse blocks out of `hermes_cli/main.py` into `hermes_cli/subcommands/<verb>.py`, so `git show <old-tag>:<new-path>` fails and a naive check reads "absent" — that alone mis-floored four Phase-4 surfaces. `plugins/web/keenable/` likewise first appears at v2026.8.19 (0.20.5), not the v0.20.6 the report asserts #verification
- [decision] A surface is gated at its TRUE floor, never at the release being audited. Gating a v0.18 surface on `isV0211OrLater` hides something the host already has — precisely the degradation C1 exists to prevent (precedents: `hasKeenableWebBackend` corrected DOWN to 0.20.5, `hasTavilyWebBackend` modelled as a window) #capability-gating
- [decision] Where the signal lives in the data (a `state_meta` key, a JSON field, a `sqlite_master` row), gate on PRESENCE with no version floor at all — the FTS 8 KB fallback, the rebuild note, and the cron dispatch diagnostics all do, so a pre-target host mid-migration behaves correctly too #capability-gating
- [gotcha] `HermesConfig+YAML`'s `bool(key, default:)` returns `v == "true"` for a PRESENT key, so any other spelling (`no`, `off`, `0`, `False`) reads `false` — silently wrong for a key whose upstream default is TRUE. Five v0.21.1 keys plus `gateway_restart_notification` read through the `boolTrueDefault` helper instead: absent → true, only a member of {false,0,no,off} turns it off #config-parsing #settings

## Phase 0 — capability flags, drift script, web backends (A1 / A2 / A3 / D)

- [gotcha] `hermes_cli/providers.py` at v0.21.1 replaced the `ALIASES` dict LITERAL with a dict COMPREHENSION inverting a new `_ALIAS_GROUPS` {canonical: (alias,…)} literal, so an AST walk reading `node.value.keys` dies with AttributeError on `ast.DictComp`. `scripts/check-hermes-tables.py` handles both shapes #ops
- [fact] A bundled model-provider plugin's own id is frequently an ALIAS of the canonical id models.dev carries (`ai-gateway`→`vercel`, `kilocode`→`kilo`, `opencode-zen`→`opencode`), so any reachability check over `plugins/model-providers/` must resolve through ALIASES first or it reports three false alarms #verification
- [decision] `WebToolsTab` lives in the app target where no test bundle reaches it, so the backend roster was extracted to `ScarfCore/Services/WebToolsBackendRoster.swift` to give finding D's parity test a seam #testing

## Phase 1 — Settings: fast mode, telemetry, config keys (A4 / A5 / A11 / C9)

- [decision] `telemetry.shared_metrics.enabled` (collection, v0.20) and `.send`/`.endpoint` (transmission, v0.21.1) are two different opt-ins behind two flags — `hasSharedMetricsTelemetry` and `hasSharedMetricsSend`. Scarf's Advanced-tab "no remote sink" copy is FALSE from v0.21.1 on, so the footnote is now per host generation #settings
- [fact] `agent.service_tier` has FOUR meanings behind nine spellings: `_parse_service_tier_config` (cli.py:274-284) maps {"",normal,default,standard,off,none}→None, {fast,priority,on}→"priority", and (v0.21.1 only) auto/cold→themselves; anything else is warn-and-ignore. Read it through `HermesServiceTier.normalize`, never `== "fast"`. Scarf keeps writing `normal`/`fast` rather than the canonical `""`/`priority` so the picker round-trips byte-identically with the Bool toggle it replaced #settings
- [fact] `model.streaming` (v0.21.1) is NOT in `hermes_cli/config_defaults.py` — its default lives in its only reader, `agent/agent_init.py:1184`. Grepping config_defaults for a v0.21.1 key and finding nothing does not mean the key is fake. It forces NON-streaming provider requests session-wide and is orthogonal to `display.streaming` (terminal rendering only) #verification
- [gotcha] `delegation.compression_threshold_tokens` has a DEAD BAND: Hermes enables the cap only at >= 16000 and warns-and-ignores 1…15999, so Scarf's stepper steps by 16000 from 0 #settings
- [gotcha] `tool_loop_guardrails` is a TOP-LEVEL config block, not a child of `agent.`, even though `agent/agent_init.py` reads it off `_agent_cfg` #config-parsing
- [fact] A11 verified, no Scarf change: `sessions.auto_prune` flipping false→true (90-day retention) is safe because Scarf reads sessions live from state.db on every view, persists no session id across launches, and the ACP resume path already creates a new session when the id is gone #verification

## Phase 2 — gateway (A6 / B4 / B5)

- [gotcha] `hermes gateway status` at v2026.9.7 has a THIRD verdict, printed FIRST: `✓ Gateway is running via the default-profile multiplexer` + `Manage it from the default profile: …`, with **no PID** (`hermes_cli/gateway.py:6112-6115`). Any "is it loaded?" test that falls through to `pid != nil` badges a served satellite profile as dead. `gateway list` carries the same state as a `— served by the default multiplexer` clause where a self-hosted profile prints `— PID <n>` (`:1520-1522`) #gateway
- [decision] `a2a` and `raft` stay OUT of `KnownPlatforms.all` (verified at v2026.9.7): a2a is agent-to-agent infrastructure with `requires_env: []`, and raft's entire config surface is one env var (`RAFT_PROFILE`) with no token, allowlist or `enabled` key. `local`, `relay` (EXPERIMENTAL) and `wecom_callback` stay out as internal members with no adapter directory #gateway
- [gotcha] Scarf's `imessage` platform id is not a Hermes platform at ANY version — the adapter is `bluebubbles` (`gateway/platforms/bluebubbles.py`) and the setup form always wrote `BLUEBUBBLES_*`. The wrong id made the row's `bluebubbles:` config block invisible to the "Configured" check. Renamed rather than duplicated; `icon(for:)`, `PlatformsView` and `identifyingEnvVar` still resolve the legacy spelling #gateway
- [fact] Of the ten platforms added to the roster, only `dingtalk` has a DESTINATION allowlist (`allowed_chats`). sms/irc/photon gate by `allowed_users`, wecom/weixin by `allow_from`/`group_allow_from`, msgraph_webhook by `allowed_source_cidrs` (a network ACL), and bluebubbles/qqbot/api_server have no recipient list — so `GatewayAllowlistKind` maps none of them. Discord's `allowed_channels` IS real and the KNOWN GAP was closed #gateway
- [gotcha] `<platform>.gateway_restart_notification` defaults to **True** upstream (`gateway/config.py PlatformConfig`, both tags) while Scarf modelled it `false`: the toggle rendered OFF on a host that was pinging, and one save wrote the `false` the user never chose. `slash_command_notice_ttl_seconds` exists in no Hermes version and its field was deleted, not kept "for round-trip" #settings

## Phase 3 — cron (C2 / C3 / C4 / A7 / A8 / A9)

- [decision] The three new job fields — `failure_deliver`, `last_dispatch`, `last_delivery_unverified` — are read through computed accessors over `HermesCronJob.extra`, NOT added to `CodingKeys`. Modeling them would make Scarf responsible for re-encoding them on every `withEnabled` rewrite, and two have shapes it cannot faithfully round-trip (`last_delivery_unverified` is a LIST in the writer but rendered scalar-tolerantly by the CLI). The generic passthrough keeps bytes verbatim while the UI gets every field #capability-gating
- [gotcha] `last_dispatch` is written **only for recurring, non-manual fires** (`cron/jobs.py:2969-2981`): a manual `cron run` and an expired one-shot never stamp one, so "no dispatch stamp" ≠ "never ran". `CronDispatchStamp` decodes to nil for an unknown `kind`, degrading to "no diagnostics" rather than a wrong badge #cron
- [gotcha] `hermes_cli/cron.py::_format_lateness` DROPS the minutes component once days are present — 97200s reads `1d 3h`. Scarf's `latenessDisplay` is a deliberate port of that quirk #cron
- [gotcha] The cron lifecycle guard's cloud-placeholder refusal reaches Scarf on **STDOUT, not stderr**: `lifecycle_guard.py` raises `GatewayLifecycleBlocked` (a `ValueError`), `tools/cronjob_tools.py::cronjob` turns it into a JSON `{"success": false, "error": …}`, and `cron_create` `print()`s `Failed to create job: <error>`. The audit report's "surface stderr verbatim" is really about combined output — and the sentence's REMEDY is its last clause, so a `prefix(200)` truncation cut off exactly the actionable half #cron #verification
- [decision] The A8 past-one-shot pre-check is gated on `isV0211OrLater`, mirroring the v0.20.6 terminal-job precedent: only a v0.21.1 host REJECTS it; an older one stores it, and refusing locally there would deny a write the host accepts #capability-gating
- [gotcha] Only the ISO-timestamp arm of `parse_schedule` can be in the past. An offset-less timestamp is resolved by Hermes in the CONFIGURED timezone, which Scarf cannot know, so it is refused only when past-grace in EVERY zone (`T + 12h`, at UTC−12). A cron expression with a named month (`0 9 * OCT *`) contains a `T`, so the ISO sniff must fail closed on it #cron
- [decision] `cron doctor`'s new `last delivery unverified (adapter acked without evidence)` issue gets its own severity (`problemIssues` / `unverifiedIssues`). An adapter that acked without a receipt is not a fault — counting it would badge every Slack/Matrix-delivering job permanently broken #cron
- [fact] `cron edit --failure-deliver ''` is Hermes's documented CLEAR gesture, so an emptied field is forwarded on edit and omitted on create #cron

## Phase 4 — skills / debug share / plugins compat / computer-use (B1 / B2 / B3 / C1 / C8)

- [gotcha] **Four of the five surfaces this phase reached for were NOT v0.21.1**: `skills search --json` is v0.17, `browse-sh` as a `--source` choice is v0.15, and the seven provider `--source` filters + `debug share -y` + `computer-use permissions status --json` are all v0.18. The modularization is what made them look new #verification #capability-gating
- [gotcha] `hermes skills search`'s table is `Name | Description | Source | Trust | Identifier` — **no `#` column**, unlike `skills browse`. `parseHubList` keys each data row off an integer in cell 1, so EVERY source-specific search in Scarf's history returned zero rows, silently. `--json` is both the fix and the only shape carrying the full `identifier` #skills
- [decision] `hermes debug share` gets `-y` behind Scarf's confirmation sheet plus a second button for `--local`. From v0.18 `_confirm_upload` exits 1 on a non-TTY without `--yes`, so the button could never have produced a URL; below v0.18 there is no gate AND no flag, so the argv must omit it. The consent that matters is the sheet — `-y` only asserts consent was collected #health
- [gotcha] `computer_use_status`'s permission booleans are **tri-state**: `None` means "could not ask", not "denied". A card that paints nil as ❌ tells a user to grant a permission they may already have, or one meaningless on their platform (`can_grant` is macOS-only) #health
- [fact] Both new JSON surfaces exit 1 as their FINDING path, not a failure — `plugins compat` (`sys.exit(1 if report else 0)`) and `computer-use permissions status`. Both parsers read stdout regardless of exit code and return nil (not empty) with no payload: "the command never answered" must never render as "you're fine" on a warning surface #verification

## Phase 5 — search / state.db (A10 / A10b / A12 / schema)

- [gotcha] **A10b is wrong in the report.** `fts_rebuild_progress` / `fts_rebuild_high_water` are NOT new in v0.21.1 and there is no one-time full FTS rebuild at first v0.21.1 open: `_migrate_bounded_tool_fts_triggers` swaps the triggers WITHOUT rebuilding (`hermes_state_schema.py:287-291`), and the two keys first appear at v2026.7.30 as part of the opt-in `sessions optimize-storage` backfill. Only `FTS_TOOL_CONTENT_PREFIX_CHARS` and `fts_tool_full_content_high_water` are genuinely v2026.9.7 (commit 57162d0cc1) #verification
- [gotcha] **A bounded scan must be bounded by rows READ, not rows returned.** `WHERE … LIKE … LIMIT n` lets SQLite hunt the whole tool history for the n-th match, and every candidate is a >8 KB (often multi-MB) payload — so a no-result search would be the expensive one. The candidate window is an inner `ORDER BY id DESC LIMIT 400` subquery: measured on a 1.6 GB fixture, ≈42 MB read ≈0.06–0.10 s, match or miss #performance
- [gotcha] `LocalSQLiteBackend.refresh(forceFresh: false)` keeping its handle (the gh#102 fix) collides with v0.21.1's `quarantine_zeroed_state_db`, which MOVES a corrupt state.db aside: an sqlite connection follows the INODE, so the backend served the quarantined file forever — no error, no empty result, data that quietly stops changing. Fixed with a `(st_dev, st_ino)` check on the steady-state path; `st_ino == 0` counts as UNKNOWN, or a network FS would reopen every tick. The WATCHER half was already correct #state-db
- [gotcha] The LIKE fallback is the FIRST caller to put RAW user text into a `SQLValue.text` param on the remote path; `SQLValueInliner`'s doc claimed every text param arrives pre-sanitized. The encoder is genuinely safe (quote-doubling + control chars as `char(n)` inside a quoted heredoc), but the comment was corrected rather than left to mislead the next caller #security

## Phase 6 — providers / image-gen / kanban / auth / MCP device flow (B6 / B7 / C5 / C6 / C7)

- [gotcha] **B7's "six unreachable providers" was four.** `gemini` is a STATIC `CANONICAL_PROVIDERS` slug reachable through models.dev's `google` via `models_catalog_static._PROVIDER_ALIASES`, and `custom` is Scarf's LocalModelProviders surface. Only `meta-ai`, `router`, `commandcode`, `commandcode-anthropic` were genuinely unreachable, and all four predate v0.21.1 #verification
- [fact] There are **TWO provider alias tables** and they differ. `hermes_cli/providers.py::ALIASES` (87, what Scarf mirrors and lane 1 gates) does NOT contain `google → gemini`; `models_catalog_static._PROVIDER_ALIASES` (picker-side) does. A reachability question must consult both, in both directions #verification
- [gotcha] `image_gen.model` is read by the **FAL pipeline only**; every other backend reads `image_gen.<provider>.model`. Scarf's picker had carried openai/google/krea/dall-e rows for releases — values `_resolve_model` warns on and discards. The list is now a verbatim mirror of `FAL_MODELS`, value-identical at both tags, so this was staleness, not a gated change #settings
- [gotcha] `hermes auth priority <provider> <target> <n>` uses **two index bases in one argv**: `target` resolves 1-based, `priority` is 0-based. Hermes also CLAMPS the destination and re-sorts afterwards, printing a `note:` when the effective position differs — a UI must report the CLI's verdict, not assert the position it asked for #capability-gating
- [gotcha] `hermes auth refresh` is not a general "clear this cooldown": it refuses anything outside `REFRESHABLE_OAUTH_PROVIDERS` without an oauth refresh_token. The gesture that works for api-key entries is the new optional target on `auth reset` #capability-gating
- [gotcha] The MCP device-code prompt goes to **STDERR**, not stdout as the report says (`tools/mcp_oauth_device.py::_authorize`), and the user code is not in the verification URL. A runner capturing only stdout shows an empty pane until the authorization expires #mcp
- [decision] `oauth.flow` is written by a nested-SCALAR patcher (`replaceOrInsertNestedScalar`), never an `identity_header`-style block writer: the `oauth:` block also holds `client_id`/`client_secret`/`scope`, which Scarf does not model, so a block writer is silent credential loss. Clearing the only child removes the `oauth:` header too, because an emptied mapping is a YAML null #dataloss
- [fact] `--completion-contract` exists on `kanban create` ONLY; `kanban edit` at v2026.9.7 takes `--result` plus step-handoff flags and nothing else, so the report's "create/edit" has no edit half #kanban

## Phase 8 — remediation of the whole-branch adversarial audit

- [gotcha] **A YAML scalar must be normalised before any typed comparison.** `parseNestedYAML` stores everything after `key: ` verbatim, so `false  # was true` and `"false"` are legal YAML for `false` that no literal comparison matches. On a TRUE-by-default key that read the user's explicit `false` as ON, and one Settings save wrote it back. `HermesYAML.normalizedScalar` (strip quotes, drop a whitespace-preceded `# comment`, trim) now fronts `bool`/`boolTrueDefault`/`boolOpt`/`int`/`intOpt`/`double`. A `#` NOT preceded by whitespace is part of the value, per YAML #config-parsing
- [gotcha] **A JSON payload must be read from stdout ALONE.** All three new `--json` parsers slice the payload out of the buffer ("first `[` … last `]`"), which is only safe on one stream: the combined runner appends stderr, so one warning line containing a bracket extends the slice past the payload and the decode fails. For `skills search` the failure is silent — it falls back to a table parser with no `#` column to key off. Split runners exist for every stream now (`runHermesCLISplit`, `ServerContext.runHermesSplit`, `SkillsViewModel.runHermesSplit`) #verification
- [gotcha] `image_gen.model` is the TOP-LEVEL key and **four** backends read it as a fallback under their own scoped key — fal, krea, openai and openai-codex, all through `plugins/image_gen/_common.py::resolve_static_model`, which simply ignores an id it does not know. Narrowing the picker to a verbatim `FAL_MODELS` mirror (Phase 6) stranded every krea/openai/codex user on the free-form field. `xai`/`deepinfra` read the scoped key only; `openrouter` takes any id verbatim #settings
- [gotcha] A job id is **not** guaranteed to contain a digit: an id-keyed `jobs.json` from an external tool contributes its KEY as the id (`cron/jobs.py:1271`), so `nightly-backup` is legal. The doctor parser's digit-requiring plausibility rule read such a header as traceback continuation and misattributed the job's issue #cron
- [gotcha] A nested-scalar patcher must decide on what follows the header's colon: nothing (or only a comment) is a block, a VALUE is an inline-flow mapping it cannot edit. Matching the bare `oauth:` alone inserted a SECOND header, and PyYAML keeps the last duplicate key — the user's `client_id`/`client_secret` stop existing as far as Hermes is concerned without a byte being deleted #dataloss
- [decision] A capability FLOOR is a property of the Hermes surface; a GATE is a product decision. `bluebubbles`'s adapter lands at 0.9.0, but the Scarf ROW predates this cycle, so gating it would remove a row users already see whenever the version probe hasn't answered — the floor is recorded in the table and deliberately not enforced. The nine genuinely new roster rows do carry theirs (`HermesToolPlatform.minimumVersion`) #capability-gating
- [decision] A pre-target host renders the CONTROL it rendered before, not a disabled variant of the new one: Fast Mode is the Bool toggle below v0.21.1 and the four-way picker at or above (`HermesServiceTier.editorStyle`). "Same values, different widget" is still a rendering change under C1 #capability-gating
- [gotcha] A `readabilityHandler` chunk can end mid-codepoint — `String(data:encoding:.utf8) ?? ""` then drops the WHOLE read, which for the MCP device flow can be the line carrying the user code. `IncrementalUTF8Decoder` holds only a genuinely incomplete trailing sequence (lead byte + too few continuations) and decodes anything else lossily so the pane never stalls. A `Process` runner also has to clear `terminationHandler` and bump a generation in `stop()`, or run A's SIGTERM marks run B failed #mcp
- [fact] `hermes skills uninstall --yes` DOES exist — first tagged v2026.8.19 = **0.20.5**, consumed as `skip_confirm` (`hermes_cli/skills_hub.py:1324`). Scarf's "it never existed" comment was stale; the piped `"y\n"` is now only sent below that floor #skills
- [convention] A test must fail when the feature is deleted. Three on this branch did not: one asserted a substring's absence, one re-parsed its own fixture constant, and one was satisfied by a reopen it existed to forbid. The gh#102 short-circuit is now pinned with a TEMP table on the backend's own connection — it survives exactly as long as the handle does #testing


## Relations
- extends [[Hermes v0.21 Compatibility Decisions]]
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.21.1 Audit Findings]]
- relates_to [[Hermes messages_fts contract: an 8 KB tool prefix and two rebuild markers]]


## Whole-surface remediation — P9 exit-code-as-truth (C5)

- [gotcha] **A `hermes` handler declared `-> None` exits 0 on every refusal it prints.** This is the general form of C5, and it hit six surfaces at once: `do_install` (`hermes_cli/skills_hub.py:645`, nine bare `return`s), `_cmd_export` (`sessions_cmd.py:295`), `cmd_mcp_login` (`mcp_config.py:709`, which DISCARDS `_reauth_oauth_server`'s bool), `_job_action` (`cron.py:635`) and `cmd_enable` (`plugins_cmd.py:1033`, which discards `_run_capability_consent`'s bool). The rule that survives: judge by the emitter's own SUCCESS line, and treat exit 0 with no success line as a FAILURE — never the reverse #verification #cli
- [gotcha] Two emitters print BOTH markers by design, so "any failure marker ⇒ failure" and "any success marker ⇒ success" are each wrong on their own. `cron run` prints the green `Triggered job:` (`cron.py:658`) and THEN `Ran now: failed.` (`:662`, `:677`); `plugins enable` prints `enabled. Takes effect on next session.` (`:1023`) and THEN runs the consent screen (`:1033`). Everywhere else the refusal arms `return` before the success line, so a success marker is proof and a failure phrase inside a report body must not flip it — hence a per-site `failureWins`, not a global precedence #cli
- [gotcha] `hermes sessions export -` has **no success line to judge**: `_write_output` (`sessions_cmd.py:78-80`) writes the payload and prints the `Exported …` summary ONLY for a real `--output` path. Its refusals go to STDOUT, so `Session '<id>' not found.` was the payload Scarf wrote into the user's `.jsonl`. The stdout path is judged by validating the payload shape instead (first non-blank line must parse as a JSON object — both stdout formats are JSON Lines), and only the first line inside a 64 KB window is decoded, because a real export can be hundreds of MB #verification #dataloss
- [gotcha] `plugins enable`'s non-TTY arm (`plugins_cmd.py:1092-1098`) is the arm Scarf **always** takes for a capability-declaring plugin: it prints `capabilities NOT granted (fail closed)` and grants nothing, while the plugin still lands on the allow-list. "Enabled" was true and misleading at the same time. Its actionable half is the line's LAST clause, so it gets a purpose-written sentence rather than a `prefix(200)` — the same trap the v0.21.1 cron lifecycle-guard message set #plugins
- [fact] `hermes security audit` is the INVERSE mistake and the exception to this whole group: its exit code is meaningful in THREE states, not two (`security_audit.py:311-312` returns `int(any(severity >= threshold))`), so **1 means findings, not a broken scan**; 2 is the only real failure (`:293` bad `--fail-on`, `:307` OSV `RuntimeError`). Contract and the `critical` default are unchanged since v2026.5.29 — the release the verb shipped in, and the floor of `hasHermesAudit` — so passing `--fail-on critical` explicitly pins the threshold without any pre-target risk #health #verification
- [decision] The markers live in one `HermesCLIMarkers` table (`ScarfCore/Services/HermesCLIOutcome.swift`) with the emitting `file:line` on every entry, judged by one `HermesCLIVerdict.judge`, rather than six ad-hoc `output.contains` scans. Every marker was walked over EVERY tag back to v2026.6.19 (v0.17) before being trusted; all are byte-identical, and the one that is not that old (`Ran now:`, v2026.7.1) simply never fires on an older host — which is what makes an output-judged verdict safe under C1 #capability-gating #verification


## Whole-surface remediation — P10 (YAML writers + parser)

Commit `bf1645b1` on `fix/whole-surface-audit`.

**The hazard, cited.** `gateway/config.py:776-791` at `v2026.9.7` wraps
`config_loader.load_yaml_layer(...)` in a bare `except Exception` that logs
*"Failed to process config.yaml — falling back to .env / gateway.json values."*
and **continues**. A PyYAML syntax error in a file Scarf wrote therefore never
fails loudly — it makes Hermes discard the **entire** config.yaml layer. Any
new config.yaml writer must be round-tripped through real PyYAML in a test
(`python3 -c 'import sys,yaml; yaml.safe_load(sys.stdin.read())'`), not merely
eyeballed.

**Durable gotchas learned here:**

- **Never assume 2/4 indent.** `GatewayConfigWriter` hardcoded it. A 4-space
  config is ordinary YAML; splicing an indent-2 key into it is a hard parse
  error, and matching keys only at indent 2 means the existing key is never
  found and a **duplicate** is appended (PyYAML resolves duplicates last-wins →
  the section's siblings are silently lost). Derive the key indent from the
  section's own first body line and the item indent from the block's own first
  bullet; use the body indent as the step (`step * 2`), not `+ 2`.
- **`"\r\n"` is ONE Swift `Character`.** `"a\r\nb".contains("\n")` is `false`.
  Any CR/LF guard must scan `unicodeScalars`. This silently defeated the first
  cut of the embedded-newline check.
- **`.whitespaces` does not contain `\r`.** `HermesYAML` trimmed with it, so in
  a CRLF config.yaml `slack:\r` failed the `key: value` separator scan and every
  section header was dropped with its whole subtree. Strip `\r` per line.
- **A section header is `<name>:` followed by ANYTHING.** `hasSuffix(":")`
  misses `slack: {}` — which is what Hermes itself emits for a
  preserved-but-empty section (`_strip_default_values` preserve_keys) — and
  `slack:  # comment`. Split at the first separator colon.
- **`ssl_verify` is bool OR path**, so it is the one MCP scalar that must NOT
  go through `yamlScalar`'s bool-quoting: a quoted `"true"` is a CA-bundle path
  named `true` to Hermes, i.e. a silent downgrade of cert verification. Every
  other path scalar (`client_cert`, `client_key`, `cwd`) must go through it.
- **Refusal is a required outcome for a line-oriented YAML editor.** Shapes it
  cannot rewrite (nested inline flow mapping, a value carrying a line break)
  must return "declined", distinct from "already correct" — otherwise the
  no-op path reports success while the file is wrong.
  `GatewayConfigWriter.WriteOutcome` is that seam; `setList`/`setMap` keep the
  String signature and return the input unchanged.
- **Block-scalar headers are not just `|` and `>`** — `|-`, `|+`, `>-`, `>+`,
  `|2`, `|2-` and `|  # comment` all open a block. Treating them as values made
  every deeper body line fold onto the header string.


## Whole-surface remediation — P11 (main-actor writes, gateway load coalescing)

- [gotcha] Measuring the elapsed time of a synchronous VM method proves NOTHING about main-actor blocking when the method kicks off `Task { … }` on a MainActor-isolated class: that body cannot start until the caller returns, so the call is fast whether or not the spawn inside it blocks. Both P11 timing tests were first written that way and passed with the `Task.detached` hop deleted — the same trap as the `@MainActor` detached-read note. #testing #concurrency
- [convention] The honest signal for "this spawn does not run on the main actor" is `Thread.isMainThread` recorded INSIDE the injected fake runner. Deterministic and load-independent; a wall-clock main-actor-latency budget (repeated `Task.yield()` after the kick-off) does distinguish the two, but flakes under the full parallel `scarfTests` run where other suites' main-actor work inflates it. #testing #concurrency
- [convention] `ServerContext` is a Sendable struct and `runHermes` is a concrete extension in the Mac target, so there is no protocol or subclass seam. `HermesCLIRunner` (`scarf/Core/Models/HermesCLIRunner.swift`) is the injectable `@Sendable ([String], TimeInterval) -> (output, exitCode)` alias plus `ServerContext.cliRunner`; a VM that must prove a C10 invariant takes it as an optional init parameter defaulting to `context.cliRunner`. #concurrency
- [decision] A config write is `run CLI` + `re-read config.yaml`, so the two halves must be atomic with respect to each other: `SettingsViewModel.writeChain` serialises every write (including `memory off` and `config migrate`). Without it two quick toggles commit a snapshot belonging to neither, and the control visibly snaps back. #settings
- [decision] Adopting `load(changeToken:force:)` on a VM whose load is a LIVE probe (`hermes gateway status` derives pids from the runtime snapshot; the gateway can die without rewriting `gateway_state.json`) requires `force: true` on section re-entry and on every post-mutation reload — coalescing is only safe for file-watcher ticks. `PlatformsViewModel`'s pattern coalesces re-entry too, which is fine there because its load reads files only. #gateway



## Whole-surface remediation — P12 (skills hub, MCP login, mcp test rows)

Commit `7e8e5c41` on `fix/whole-surface-audit`. All eight findings were real
and all eight are PRE-existing — every shape fixed here is byte-identical
back to `v2026.6.19` (v0.17), so nothing needed a capability flag.

- [convention] **A Rich-table fixture must be RENDERED, not drawn.** Copy the
  tag's own column specs + helpers into a scratch script and run them through
  the Hermes venv's Rich (`$(dirname $(realpath ~/.local/bin/hermes))/python3`
  — the system python3 has no `rich`) at **width 80**, the fallback a bare
  `Console()` takes on a pipe. The width is load-bearing: at 80 the browse
  Identifier column folds and the fold is the bug. Generators are preserved in
  `documents/audits/hermes-v0.21.1-p12-fixture-provenance.md` #testing #verification
- [gotcha] **Rich's two wrap modes need two different merge rules.** The browse
  Description column word-wraps, so continuation cells are space-joined; the
  Identifier column is `overflow="fold"` (`skills_hub.py:64-69`), a HARD
  character wrap, so its continuation cells must be CONCATENATED. Space-joining
  a folded browse.sh slug yields an identifier that installs nothing — and the
  slug's trailing `-XXXXXX` content hash is exactly what folds off the end #skills
- [gotcha] `hermes skills check` has never printed a version anywhere. It
  compares CONTENT HASHES (`skills_hub_install.py:300`) and renders
  `Name | Source | Status` with status ∈ {update_available, up_to_date,
  orphaned, unavailable, invalid_install}. Only `update_available` is
  actionable (`skills_hub.py:843`); the other three are faults a user fixes by
  hand, so counting them as updates makes the tab promise work it cannot do.
  `orphaned`/`invalid_install` postdate v0.17, where only the other three exist #skills
- [gotcha] `hermes_cli/colors.py::should_use_color()` is `sys.stdout.isatty()`,
  so for every piped Scarf run `color()` is the IDENTITY function — there is no
  ANSI in `mcp test` output at all, and a finding that says "with ANSI" is
  describing the TTY case. Conversely, when colour IS on, `f"{color(n):{w}s}"`
  pads the ESCAPED string, so column alignment can never be parsed on #verification #cli
- [decision] **`ssh -tt` is not available as a remote-stop fix.** Forcing a pty
  would flip `should_use_color()` on for the remote command and make Rich wrap
  at the pty's 80 columns — folding the very verification URL the MCP login
  sheet exists to show. That is a user-visible change on a remote host, which
  C1 forbids for a stop-path fix. A shell wrapper is impossible by construction:
  `SSHTransport.composedRemoteCommand` quotes every token through
  `remotePathArg`, so no caller can inject a shell operator. What is left is a
  best-effort `pkill -f` over the same transport, anchored with `$` on the
  server name (which matches the `hermes` process, not the `bash -lc` wrapper
  whose cmdline ends in a quote) and with every ERE metacharacter escaped #mcp #concurrency
- [gotcha] The MCP device prompt is ONE `print` of three lines
  (`mcp_oauth_device.py:125-126`), and a `readabilityHandler` chunk splits on a
  byte count — so `…\n  Code: WDJB-MJ` is a legal intermediate state and
  `WDJB-MJ` is a perfectly non-empty string. A streaming parser must (a) ignore
  everything after the LAST newline and (b) require the block's own last line,
  `Waiting for approval...`, as a completion sentinel. Without both, a caller
  that re-parses only while its result is nil latches a truncated code forever #mcp
- [gotcha] `enabled`, `tools.resources` and `tools.prompts` all go through
  `_parse_boolish` ({true,1,yes,on}/{false,0,no,off}, `mcp_tool_common.py:120-137`),
  and resources/prompts default to **True** when absent
  (`mcp_tool_registration.py:77`). Scarf defaulted both to false, so the editor
  showed two toggles off for every server that had never set them and one save
  wrote the `false` the user never chose — the same trap as
  `gateway_restart_notification`. Note `mcp list`'s own display uses a
  DIFFERENT, narrower set ({true,1,yes}, `mcp_config.py:575-577`); the gateway's
  behaviour is what a client must model, not the list renderer's #config-parsing #mcp



## Whole-surface remediation — P13 (config read correctness)

Commit `c95caedb` on `fix/whole-surface-audit`.

- [gotcha] **A default lives in whichever layer the reader can actually see.**
  `hermes_cli/config.py::_load_config_impl` (`:2197,2211`) starts from
  `deepcopy(DEFAULT_CONFIG)` and deep-merges the user's config.yaml over it, so
  for any key present in `config_defaults.py` the READER's own
  `.get(key, fallback)` arm is UNREACHABLE and the schema value is the answer.
  `openrouter.response_cache` is the trap: schema `True` (`:649`), reader
  `or_config.get("response_cache", False)` (`agent/auxiliary_client.py:860`).
  Citing the reader alone would have "confirmed" Scarf's wrong `false`. Where
  the schema has NO entry the reader's fallback IS the default — `model.streaming`,
  `matrix.auto_thread`, `display.busy_ack_enabled`, `telegram.require_mention`
  all work that way, so a key must be looked up in BOTH layers, in that order #config-parsing #verification
- [gotcha] **A default that CHANGED mid-window is not a default, it is a sentinel.**
  `platforms.telegram.extra.rich_messages` shipped `True` at v0.17.0
  (`config.py:2144`) and `False` from v0.18.0 (`:2367`) — one release later.
  Reading either as "the" default renders one host generation's toggle
  backwards, so the parse reports ABSENCE (`boolishOpt`) and
  `displayTelegramRichMessages(capabilities:)` resolves it, the
  `checkpoints.enabled` pattern. This is why the phase rule "verify at the
  target tag AND at the floor tag" exists: a two-endpoint check (v0.21.0 vs
  v0.21.1) sees a stable `False` and misses the flip entirely #config-parsing #capability-gating
- [gotcha] `platforms.telegram.extra.ignore_root_dm` is a **WINDOW ceiling**
  (0.15.0 <= v < 0.21.1), the mirror of `hasTavilyWebBackend`: reader at
  `gateway/platforms/telegram.py:4879` from v2026.5.28, moved by the v0.18
  plugin split to `plugins/platforms/telegram/adapter.py:9835` (last at
  v2026.8.31), and at v2026.9.7 a WHOLE-TREE grep finds it only in
  `scripts/release.py:798` and the docs. A ceiling gates the ROW and the WRITE
  but never the PARSE — the value round-trips on every host so a downgrade back
  into the window finds the user's setting intact #capability-gating
- [gotcha] **`boolTrueDefault` has a mirror image and Scarf was missing it.**
  `bool(_:default: false)` reads `yes`/`on`/`1` as OFF while Hermes's
  `_coerce_bool_extra` (`plugins/platforms/telegram/adapter.py:1176-1186`)
  reads them ON — the same class of bug as the true-default one, in the other
  direction. `boolish(_:default:)` / `boolishOpt` carry Hermes's actual sets
  (truthy {true,1,yes,on}, falsy {false,0,no,off}, else the default) #config-parsing
- [gotcha] A `??` chain over RAW values picks the first non-nil string and then
  compares it literally, which is not "first key present wins": Slack's
  `platforms.slack.require_mention: false` fell through to a true `extra:` one.
  `boolTrueDefaultAt([keys])` decides on the first key PRESENT, then reads it
  boolishly — Hermes's bridge is `extra.update(bridged)`, so top-level
  overwrites `extra:` (`gateway/config_loader.py`) #config-parsing
- [gotcha] `mattermost.reply_mode` is read from `config.extra` ONLY
  (`plugins/platforms/mattermost/adapter.py:120-121`) and is NOT in
  `gateway/config_loader.py`'s `_SHARED_KEYS` (`:197-215`), so the top-level
  spelling Scarf read is never bridged and never reaches the adapter. The
  `_SHARED_KEYS` tuple is the only list of top-level platform keys that ARE
  bridged — check a platform key against it before believing a top-level path #config-parsing
- [decision] `strEnum()` normalises closed-enum scalars through
  `normalizedScalar` but deliberately does NOT validate against a member set.
  `wal  # weak-fsync FS` is legal YAML for `wal` that no picker option matched
  (blank control, then a save over a value the user never saw); but snapping an
  UNKNOWN member back to the default would hide a value a newer host honours
  and overwrite it. Both pickers instead APPEND an unrecognised stored value #settings
- [gotcha] `approvals.mode` never accepted `auto` at any tag —
  `tools/approval_context.py:197` `_VALID_MODES = ("manual","smart","off")`,
  and from v0.18 the docstring names `'auto'` as *the* rejected example. Scarf's
  picker offered it, so choosing it wrote a scalar Hermes logged and discarded.
  A picker that drops an invalid member must also NORMALISE the selection
  (`HermesApprovalMode.normalize`) or a config still carrying it renders blank #settings
- [gotcha] `display.busy_input_mode: steer`'s floor is **v0.12.0**, and finding
  it needs the READER: `elif _bim == "steer":` at `cli.py:1946` (v2026.4.30).
  v2026.4.23's `"steer"` hits are the `/steer` SLASH COMMAND, and the
  `interrupt | queue | steer` comment lands at the same tag as the reader but a
  comment is not a reader. At v2026.9.7 the modularised line states the whole
  set: `_bim if _bim in ("queue","steer") else "interrupt"` (`cli.py:2592`) #verification
- [gotcha] There are TWO Hermes provider tables and Scarf mirrors both:
  `providers.py::ALIASES` (inference ROUTING) and
  `agent/models_dev.py::PROVIDER_TO_MODELS_DEV` (capability METADATA). They
  disagree ON PURPOSE — bare `openai` routes to `openrouter` but resolves
  metadata against models.dev's `openai` — so **catalog lookups must try the
  RAW spelling first and only consult the alias table when it misses**.
  Unconditional canonicalisation would have swapped an `openai` user's entire
  model list for OpenRouter's. `meta-ai`/`opencode-free` were missing because
  neither is an ALIASES entry at all #verification #settings
- [gotcha] **A table-diff scan that reads a Swift block with a `"a": "b"` regex
  is defeated by its own doc comment.** `check-hermes-tables.py`'s new
  `models-dev` lane stayed green after the real `"meta-ai": "meta"` line was
  deleted, because the comment above it QUOTES the entry. `swift_block()` now
  drops whole-line `//` comments (only whole-line, so a `"https://…"` doc URL in
  a value survives). Every lane reads through it #testing #ops
- [decision] `SQLValueInliner`'s non-finite doubles are chosen for BACKEND
  PARITY, not on their own merits: `%.17g` spells them `nan`/`inf`, which
  SQLite parses as IDENTIFIERS, so the remote backend failed "no such column:
  inf" where the local one bound the value happily. `sqlite3_bind_double`
  stores NaN as NULL and keeps ±Infinity, so the literals reproduce it exactly
  (`NULL`, `±9e999` — SQLite's own out-of-range float literal). Throwing would
  invert the same divergence rather than remove it #state-db
- [gotcha] `LocalSQLiteBackend`'s detected-schema flags are DERIVED state
  describing the file behind the current handle, not accumulated knowledge.
  `detectSchema()` only ever set them TRUE, so a `refresh()` onto a narrower
  state.db — a v0.21.1 quarantine-and-recreate, a restore, a Hermes DOWNGRADE —
  kept the previous file's answers and every widened SELECT failed "no such
  column". Cleared in `close()` AND at the top of `detectSchema()`, so a
  refresh whose reopen FAILS reports "no schema" rather than the last good
  file's #state-db


## Whole-surface remediation — P14 (Kanban dead gate surface, diagnostics, sessions rename)

- **The Kanban "hallucination gate" was never real.** `hallucination_gate_status` and
  `auto_blocked_reason` are emitted by NO Hermes version: a whole-tree `git grep` for both
  names across **all 38 tags** in `~/.hermes/hermes-agent` (through v2026.9.7) returns zero
  hits, and `_TASK_DICT_FIELDS` (`hermes_cli/kanban_output.py:18-24`) has never carried them.
  They were modelled in Scarf v2.8.0 from the v0.13 release notes. Deleted outright (Alan's
  call, 2026-09-09): the fields, `KanbanHallucinationGate`, the Reject button + `comment`
  +`archive` reject path, the dim/glyph, the inspector banner, the card sub-line, the
  board-VM optimistic-override side, and the iOS badge. The stall they were meant to show
  reaches the UI through `last_failure_error` (real, v0.21.1). Hermes's only equivalent
  signal is the `completion_blocked_hallucination` task_event (`kanban_db.py:2629`) —
  design from that payload if it's ever wanted again.
- **`goal_mode` / `goal_max_turns` are real COLUMNS but not a real WIRE surface.** They exist
  on the `tasks` table (`kanban_db.py:922-925`) and as `kanban create` flags
  (`kanban_parser.py:191-197`), but are absent from `_TASK_DICT_FIELDS`, so no `list --json`
  / `show --json` has ever emitted them. Only the `created` task_event payload carries
  `goal_mode` (`kanban_db.py:1359`). The Goal badge could never render; decode paths deleted.
  `HermesCapabilities.hasKanbanGoalMode` now has NO consumer.
- **Diagnostics: `hermes kanban diagnostics --json` is the ONLY emitter.** No task row, run
  row, or `show` envelope has ever had a `diagnostics` key (`_TASK_DICT_FIELDS`,
  `_SHOW_RUN_FIELDS`/`_RUNS_RUN_FIELDS` at `kanban_output.py:18-33`; `_cmd_show`'s envelope
  at `kanban.py:493-498`). Fleet mode returns `[{task_id, title, status, assignee,
  diagnostics:[…]}]` in ONE call (`kanban.py:676-678`) — mergeable by task id, so Scarf now
  fetches it once per board load and merges. **Verified floor: v2026.5.7 (v0.13.0)** — the
  `diagnostics` subcommand + `--json` + that exact JSON shape have existed unchanged since
  (`kanban.py:350-370` at v2026.5.7; `kanban_parser.py:251-256` at v2026.9.7), which is
  exactly `hasKanbanDiagnostics`, so no new flag was needed.
- **Scarf's diagnostic model was invented too.** The real wire shape is
  `Diagnostic.to_dict()` = `asdict` of `kanban_diagnostics.py:48-64`: `kind, severity, title,
  detail, actions, first_seen_at, last_seen_at, count, run_id, data` — Unix-int timestamps,
  `0` meaning unset. There is no `message` and no `detected_at`. Severity comes OFF THE WIRE
  (`warning|error|critical`); Scarf must not infer it from `kind`. The nine real kinds are
  `DIAGNOSTIC_KINDS` (`kanban_diagnostics.py`): hallucinated_cards, triage_aux_unavailable,
  prose_phantom_refs, repeated_failures, repeated_crashes, review_dependency_deadlock,
  stuck_in_blocked, block_unblock_cycling, stranded_in_ready. Scarf's previous seven
  (`heartbeat_stalled`, `retry_cap_hit`, `darwin_zombie_detected`, …) matched none of them.
- **`--max-retries` is a FAILURE limit, not an extra-attempt count.** `DEFAULT_FAILURE_LIMIT
  = 2` (`kanban_db_dispatch.py:33`); `record_failure` trips when `failures >=
  effective_limit` (`:1026-1034`). Hermes's own help says it: "`--max-retries 1` blocks on
  the first failure (no retries), `--max-retries 3` allows two retries"
  (`kanban_parser.py:176-181`). Scarf's create sheet said "0 = no retries. Defaults to 3."
- **`sessions rename` needs `--`.** `title` is `nargs="+"`
  (`hermes_cli/subcommands/sessions.py:210-213`), so a dash-leading title was eaten as an
  option and argparse exited 2. Fixed to `["sessions","rename","--",id,title]`; the title
  stays ONE argv element because `_cmd_rename` re-joins with single spaces
  (`sessions_cmd.py:681`).
- **Gotcha: `sessions.api_call_count` cannot be read at a fixed index.** `sessionColumns`
  appends the v0.7 block only when present and `api_call_count` after it, and the two PRAGMA
  probes are independent (Hermes adds columns without bumping SCHEMA_VERSION, C4). A host
  with `api_call_count` but no `reasoning_tokens` made the hardcoded `row.int(at: 20)` read
  past the row; `Row.int(at:)` is bounds-safe, so it silently reported 0. Resolve by column
  NAME via `row.columnIndex`, like `rewind_count` / `last_read_at` already did.
- Board diagnostics are throttled to one fetch per 30 s (thresholds in the rule engine are
  minutes-to-hours) so the 5 s board poll doesn't gain a third process spawn per tick.


## Whole-surface remediation — P15 (cron edit, doctor ids, timestamps)

Commit `7a51abea` on `fix/whole-surface-audit`.

- [gotcha] **`cron edit` cannot express "no skills" with `--skill`.**
  `hermes_cli/cron.py::cron_edit` (v2026.9.7 :606-618): `_normalize_skills`
  returns **None** for an empty or absent `--skill` list, and `final_skills`
  stays `None` unless `--clear-skills`, a non-empty replacement, or an
  add/remove pair is present — `None` reaches `update_job` as "field
  untouched". So "the user unticked every skill" and "the user didn't touch
  skills" were the SAME argv. An emptied set must be spelled
  `--clear-skills`; a non-empty one is better sent as an
  `--add-skill`/`--remove-skill` diff, which Hermes applies to the
  `existing_skills` it reads at edit time (:606) rather than to the form's
  snapshot #cron
- [fact] Floor walk for `--clear-skills` / `--add-skill` / `--remove-skill`:
  all three are `cron edit` arguments from **v0.3.0** —
  `hermes_cli/main.py:2854-2857` at tag `v2026.3.17`, absent at
  `v2026.3.12` (v0.2.0) — relocated to `hermes_cli/subcommands/cron.py:98-104`
  by the v0.17 modularisation (`v2026.6.19`) and unchanged at `v2026.9.7`.
  That is BELOW Scarf's minimum supported Hermes (v0.6.0), so the correct
  outcome of the floor walk was **no gate at all**. A floor below the
  project minimum is a legitimate answer; adding a flag for it would be
  ceremony, and the test that matters is the one pinning the builder as
  capability-free #capability-gating #verification
- [gotcha] **A cron job id is not a single token.** `cron/jobs.py::load_jobs`
  (v2026.9.7 :1271) adopts an id-keyed `jobs.json` map KEY verbatim
  (`{**v, "id": v.get("id") or k}`) and nothing sanitizes it, so
  `nightly backup` is a legal id. `cron doctor` prints its header as
  `  {id} {name}`, so splitting on the first space files the finding under a
  job that doesn't exist AND leaves the real one unwarned. The header must
  be resolved against the ids the client already holds, by longest
  token-boundary prefix — which also means the roster has to be snapshotted
  on the main actor before the parse hops off, and the parse re-run when the
  roster arrives after the doctor answer (the cold-launch order) #cron
- [gotcha] **`_ensure_aware` never reads a naive timestamp as UTC.**
  `cron/jobs.py:807-814` stamps it with the *system-local* zone of the
  process reading it and converts to the *configured Hermes* zone. Scarf can
  know neither (the system zone belongs to the SSH HOST, the configured zone
  isn't exposed), so every consumer of a naive `run_at` must carry the same
  ±12h conservative window `oneShotScheduleIsPastGrace` already had — the
  latest instant a naive value can denote is `T + 12h` at UTC−12.
  `oneShotIsUnresumable` did not, so it refused resumes the host accepts.
  An OFFSET-bearing value keeps the tight `ONESHOT_GRACE_SECONDS` (:96)
  comparison; the two arms are genuinely different problems #cron
- [gotcha] `hermes_cli/cron.py::_format_lateness` (v2026.9.7 :88-91) opens
  `seconds = max(0, int(seconds))` — Python `int()` TRUNCATES toward zero
  and the `max` CLAMPS. Scarf rounded and never clamped, so `59.7s` read
  `1m` where the CLI says `59s` and an early dispatch rendered `-1s late`.
  Note the Swift trap the port then needs: `Int(_: Double)` **crashes** on
  NaN/±inf, and `lateness_seconds` is untrusted JSON — Hermes's own
  `except (TypeError, ValueError): return "?"` arm is the admission that it
  is not trusted #cron
- [convention] A post-mutation refresh of a CAPABILITY-GATED diagnostic verb
  is gated on that verb having already ANSWERED on this host, not on a
  version flag the view holds: a pre-target host then provably gains no
  spawn it did not already make (C1), and the check needs no capability
  plumbing into the view model. The C1-critical half is testable without a
  CLI seam — on a fresh VM the refresh must leave both in-flight flags false #capability-gating #cron


## Whole-surface remediation — P16 (capabilities/roster hygiene)

**The tag map in this note's header was WRONG and is corrected here.** It
read `v2026.7.30 = 0.20.2`. Walking `pyproject.toml:5` across every tag:

| tag | version | | tag | version |
|---|---|---|---|---|
| v2026.7.1 | 0.18.0 | | v2026.8.16 | 0.20.2 |
| v2026.7.7 | 0.18.1 | | v2026.8.16.2 | 0.20.3 |
| v2026.7.7.2 | 0.18.2 | | v2026.8.18 | 0.20.4 |
| v2026.7.20 | **0.19.0** | | v2026.8.19 | 0.20.5 |
| v2026.7.30 | **0.19.1** | | v2026.8.27 | 0.20.6 |
| v2026.8.3 | 0.20.0 | | v2026.8.31 | 0.21.0 |
| v2026.8.13 | 0.20.1 | | v2026.9.7 | 0.21.1 |

`v2026.7.30` is a NUMBERED patch release, 0.19.1. The v0.20 audit read it
as an unnumbered pre-release ("between v0.19.0 and v0.20.0, so the next
guaranteed floor is v0.20") and floored seven surfaces a whole minor too
high, hiding them from every 0.19.1 host. Fixed via `isV0191OrLater`:
`hasApprovalSmartPolicy`, `hasBitwardenEncryptedCache`,
`hasCommandSecretSource`, `hasSharedMetricsTelemetry`,
`hasDatabaseJournalSettings`, `hasSTTUnifiedLanguage`,
`hasSTTLocalVADTuning`.

**The rule this makes explicit: read `pyproject.toml:5` AT the tag before
calling a tag "between releases".** Never infer a version from the date
tag's position between two other tags. Cheapest possible check:
`git -C ~/.hermes/hermes-agent show <tag>:pyproject.toml | sed -n 5p`.

Durable gotchas from this phase:

- **Not every config key is in `config_defaults.py`.** `secrets.command.*`
  is absent from that file on EVERY tag including v2026.9.7 — the secret
  source declares its own schema and reads its block directly
  (`agent/secret_sources/command.py:416,436`, registered at
  `agent/secret_sources/registry.py:179-181`). Absence from
  `config_defaults.py` is NOT evidence a key does not exist.
- **`hermes gateway list` has no `--json`** at any tag
  (`hermes_cli/subcommands/gateway.py:108` registers it with zero
  arguments). Its output is a text table with no platform column, so any
  per-profile platform data in a `gateway list` snapshot is invented.
- **`auth <verb> <provider> <target>` resolves `target` id → unique label
  → 1-based index**, in that order (`agent/credential_pool_admin.py:87`
  `resolve_target`; `:94` id, `:97` label, `:106` `raw.isdigit()`). A bare
  `"2"` therefore lands on a credential *labelled* `2` whenever one
  exists. Send the stable auth.json `id`. This ordering is byte-identical
  back to the pool's first tag (v2026.4.30), so no capability gate is
  needed — and `auth remove`'s own help says "by index, id, or label".
- **`screen_recording_capturable` is a second signal, not a restatement of
  the grant.** `tools/computer_use/doctor.py:204-207` makes
  granted-but-not-capturable a FAILING row that outranks the plain pass.
  Tri-state like the grants: `nil` = could not ask, never "cannot".
- **An `.empty` capabilities value means "the probe failed", not "old
  host".** Any gate that renders a *lossy* editor on the false branch must
  also consider the stored value — `HermesServiceTier.editorStyle` showed
  a bounded `auto`/`cold` as a Bool "off" and destroyed it on first tap.
  Widening branches that only the detected path can reach are dead code
  and a sign the gate is wrong.


## Whole-surface remediation — P17 (cross-phase review remediation)

Commit `ac61b5f7` on `fix/whole-surface-audit`.

- [gotcha] **The YAML boolean coercion lives in the LOADER, not the reader —
  so "is this key's reader boolish-tolerant?" is the wrong question.**
  `hermes_cli/config.py::_load_config_impl` hands config.yaml to
  `yaml.safe_load`, so `yes`/`on`/`no`/`off` are already Python bools and
  `1`/`0` are truthy/falsy ints before ANY per-key reader runs. That makes the
  boolish contract UNIVERSAL across every boolean key in config.yaml,
  whichever module reads it — there is no per-key verification to do, and no
  literal `== "true"` comparer can be correct. P13 fixed only the true-default
  direction and two keys; P17 folded in the remaining 39 and DELETED the
  literal `bool(_:default:)` reader so it cannot return. Verified against
  PyYAML that bare `y`/`n` are NOT bools (they stay strings), so those are
  paths/values, not booleans #config-parsing
- [gotcha] `ssl_verify` on an MCP server is the bool-OR-path scalar again, and
  its bool half is boolish for the same loader reason:
  `tools/mcp_tool_transport.py:410` (v2026.9.7) passes
  `config.get("ssl_verify", True)` straight into httpx's `verify=`. Reading
  only the literal `"false"` put the word `no` in the CA-path field, and the
  next save quoted it into a CA bundle literally NAMED `no` — the P10
  bare-bool writer rule defeated through the READER. A split control that
  collapses two widgets into one scalar has to hydrate with the same
  vocabulary it writes #config-parsing #mcp
- [gotcha] **`Task.cancel()` does not reach an inner `Task.detached`.**
  `Task { … await Task.detached { … }.value }` reads exactly like a
  cancellable load and is not one: every `Task.isCancelled` check inside the
  detached body is dead, so a superseded load runs all its probes anyway.
  Detaching the WHOLE body and hopping back with `await MainActor.run { … }`
  gives real cancellation and still satisfies C10. The honest test is
  behavioural — park the first probe on a semaphore, issue the superseding
  load, then count the second probe #concurrency #gateway
- [gotcha] Scarf reads `cron/jobs.json` **directly**, so none of
  `cron/jobs.py`'s read-time normalisation applies to that path — `list_jobs`
  → `_normalize_job_record` → `_apply_skill_fields` only runs for `cron list`.
  A legacy job carries the singular `skill` and no `skills`, so the skill-edit
  diff saw an empty existing set, emitted no `--remove-skill`, and `cron edit`
  (which computes its own `existing_skills` via `_normalize_skill_list`) kept
  the skill the user had just unticked. Mirror the rules exactly: `skills`
  present WINS even when empty, `skills: null` is `None` and falls back to
  `skill`, a bare STRING `skills` is a one-element list (decoding it strictly
  throws and blanks the WHOLE board) #cron #state-db
- [convention] A legacy alias key read in a decoder gets its OWN `CodingKey`
  type, never a new case on the model's `CodingKeys`: `CodingKeys.allCases` is
  what decides which keys get swept into `extra` and re-emitted verbatim, so
  listing it there silently STRIPS the alias from every file Scarf writes back
  #conventions
- [convention] A test that re-states the production call site's own verdict
  rules (markers, `failureWins`) proves nothing — reverting the call site
  leaves it green. Drive the real entry point instead; `PluginsViewModel` took
  the `HermesCLIRunner` injection P11 introduced for exactly this #testing
- [convention] An optional test lane (PyYAML round-trip) that no-ops when its
  dependency is missing must SAY so. One `@Test` wrapping
  `#expect(dependencyAvailable)` in `withKnownIssue(…, isIntermittent: true)`
  is green when the lane ran and prints a named known issue when it did not,
  without ever failing a machine that lacks it #testing
- [decision] NO-OP on finding 8 (cron-doctor roster branch ordering). Verified
  against the emitter: `cron_doctor` (`hermes_cli/cron.py:517-536`) prints
  exactly one header shape, `  {id} {name}` at indent 2, and issues at indent
  4. The roster branch requires an EXACT known job id at a token boundary,
  which is strictly stronger evidence than the shape heuristic that follows
  it, so reordering changes nothing; `File` / `Traceback` fail
  `isPlausibleJobID` too. Pinned with a traceback fixture instead of a reorder
  #cron #verification
