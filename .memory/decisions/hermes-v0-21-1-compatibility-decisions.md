---
title: Hermes v0.21.1 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-21-1-compatibility-decisions
tags: [hermes, capability-gating, versioning, settings, hermes-v0-21-1]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/WebToolsBackendRoster.swift, scarf/scarf/Features/Settings/Views/Tabs/WebToolsTab.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-08
updated: 2026-09-14
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
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



## Round-2 product decisions (Alan, 2026-09-10) — binding for P18–P27

Decisions on the seven product calls in `documents/hermes-v0.21.1-whole-surface-audit-round2.md`:

1. **iOS kanban card body → plain `Text`** (P25). Parity with the Mac inspector; closes the `javascript:` link vector. No Markdown on either platform for worker-authored bodies.
2. **Skills "Reload" → relabel "Re-scan skills"** (P21/P25). Keep the `hermes skills audit` call; label, tooltip and doc comment say it re-runs the security scanner. No gateway slash-command wiring.
3. **Trace export "Redact secrets" → honour it**: when the toggle is OFF on the `trace` format, pass `--no-redact`; when ON pass nothing (trace redacts by default). Toggle keeps one meaning across formats (P25).
4. **TTS/STT pickers list every provider registered at target** (gemini/kittentts TTS; elevenlabs/deepinfra STT), each floor-gated where its registration postdates the supported minimum; an unrecognised stored value is still appended per the existing `strEnum` picker convention (P20).
5. **`approvals.mode` absent → resolve by host version and render a distinct "Host default (smart)" / "Host default (manual)" row**; an undetected host renders "Host default (unknown)". Picking any explicit mode writes it; the host-default row writes nothing (P20).
6. **Roster gating: gate `whatsapp_cloud` at its v0.17 floor and audit the rest of the roster** for the same inconsistency; the existing "a pre-existing row stays ungated" exception (bluebubbles) stands (P23).
7. **Version parser fails closed**: an unrecognised `hermes --version` shape (e.g. a date-only `v2026.9.7`, or a major component outside the plausible 0–9 range) yields NO capabilities, per C1 (P23).



## Whole-surface remediation — P18 (incomplete-fix residue from P9–P17)

Commit `74cd8321` on `fix/whole-surface-audit-r2`.

- [gotcha] **`cron edit`'s clear gestures are not symmetric, and the guard
  that decides is not in the same file as the flag.** `--repeat` is
  `type=int` in argparse, so the clear is `--repeat 0` and NOT `--repeat ""`
  (which argparse rejects outright): `normalize_repeat_value` folds `<= 0` to
  `None` = forever (`cron/jobs.py:591-617`), reached through
  `_update_run_fields`'s `if a["repeat"] is not None` — `0` passes that guard,
  `None` does not. `--prompt` is a plain string whose guard is `if prompt is
  not None`, so `--prompt ""` IS the clear. `--name` is the counter-example:
  `_update_core_fields` has `if a["name"] is not None and a["name"].strip()`,
  documented as "blank name is a no-op, not a clear" — so omitting an empty
  name is CORRECT and the same reflex applied to it would be a bug. Read the
  per-field guard in `tools/cronjob_tools.py`, never generalise from a sibling
  field #cron
- [gotcha] **Clearing the prompt can be refused, and that is fine.**
  `update_job` runs `job_payload_is_empty` on the MERGED record
  (`cron/jobs.py:428-436`, armed at :1949): a job left with no prompt, no
  script and no skills raises `EMPTY_PAYLOAD_ERROR`. Scarf sends the clear and
  lets Hermes's sentence surface rather than pre-judging which job kinds may
  be cleared — a client-side copy of that predicate would drift the moment
  `_PAYLOAD_FIELDS` grows #cron
- [convention] **An "empty field is a gesture" fix needs the SEEDED value, not
  just the form value.** `""` alone cannot distinguish "the user deleted the
  content" from "the field was always blank", and firing the clear on the
  latter turns every unrelated save into a write. Pass the editor's seed
  (`job.prompt`, `job.repeatEditValue`) alongside the form value and compare —
  the same shape `existingSkills` already had #cron #conventions
- [gotcha] **A re-parse beats a re-run when only the CLIENT's input changed.**
  The cold-launch doctor race was gated on `hasLoadedDoctorFindings`, which is
  set at the END of the doctor run — false at exactly the moment the race
  needs it. Retaining the verb's raw stdout and re-parsing it against the
  roster that lands second fixes the ordering with NO spawn, which also means
  nothing to capability-gate (C1 is satisfied by construction rather than by a
  flag). Keep the re-RUN too, gated as before: an external `jobs.json` edit
  makes the findings genuinely stale, not merely mis-keyed #cron
  #capability-gating
- [gotcha] **An `if isLoadingX { return }` in-flight guard silently DROPS a
  post-mutation refresh.** The in-flight probe was started before the thing
  the caller just changed, so returning early leaves the exact staleness the
  refresh exists to fix. Coalesce instead: set a `pending` flag when the
  dropped call was a `force`, and re-issue once on completion. The
  companion change is that the refresh's own gate becomes
  `hasLoadedX || isLoadingX` — a probe in flight is a probe this host already
  received, so it adds no spawn a pre-target host would not have made #cron
- [gotcha] **`resume_job` does not pass `last_run_at` to `compute_next_run`**
  (`cron/jobs.py:1991` → :1096 default `None`), so
  `_recoverable_oneshot_run_at`'s "already run, never eligible again" arm
  never fires on the resume path. `rearm_oneshot` (:2036-2055) clears
  `repeat.completed`, `run_claim` and `fire_claim` but NOT `last_run_at`, so a
  re-armed one-shot legitimately carries one. The refusal Hermes actually
  raises is `_reject_terminal_activation` on a TERMINAL record — which is
  where a genuinely spent one-shot ends up, because `_advance_after_run`
  retires every `kind == "once"` with no next run via `_complete_job_record`.
  Model the state, not the timestamp #cron
- [convention] **A "nothing was written" verdict has more than one arm, and
  cancellation is one of them.** `FleetApplyExecutor.cronFieldStatus` reported
  `.applied` for a CANCELLED pass (`cancelledRemaining` was not even an input)
  and for `created > 0 && failed > 0`. `status` is what `appliedCount` counts
  and what the row badge paints, so it must be the pessimistic half of the
  pair — the counts live in `message`. Cancellation landing between TARGETS
  already reported `.skipped "cancelled before apply"`; landing between cron
  creates must not read differently #conventions
- [gotcha] **P17's "no literal `== \"true\"` reader remains" was asserted in a
  comment 78 lines above a surviving one.** A comment is not a guarantee; the
  guarantee is having ONE helper. `HermesYAML.boolishValue` is now that helper
  (truthy `{1,true,yes,on}` / falsy `{0,false,no,off}` = `_TRUTHY_STRINGS` /
  `_FALSY_STRINGS`, `gateway/config.py:25-26`, normalised the way `_bool_token`
  does with `str(value).strip().lower()`), and both survivors route through it:
  `checkpoints.enabled` — where the literal reader was especially wrong,
  because that key is an ABSENCE SENTINEL and `yes` reading as "off" is the
  one direction the sentinel exists to prevent — and
  `ProfileRoutesYAML.parseMultiplex`, whose `_coerce_bool(value, False)`
  (`gateway/config.py:733`) is the same vocabulary #config-parsing
- [fact] **Every kanban `--json` shape is a CLOSED field tuple.**
  `_TASK_DICT_FIELDS` / `_SHOW_RUN_FIELDS` / `_RUNS_RUN_FIELDS` /
  `_ATTACHMENT_FIELDS` (`hermes_cli/kanban_output.py:18-33`) are the whole
  wire, applied through the single serialisers `_task_to_dict` (:85) and
  `_obj_dict` (:81); `kanban create/list/show --json` all go through
  `_task_to_dict`. Walked across every tag: before the v0.17 output-module
  split it was a dict literal in `kanban.py`, and none of `idempotency_key`,
  `last_heartbeat_at`, `max_runtime_seconds`, `current_run_id`, `task_id`,
  `claim_lock`, `claim_expires`, `failure_count` or `parent_results` has EVER
  been in it. `parent_results` exists only as `kanban_db.parent_results`
  (:4060) feeding the worker's context text (`_ctx_parent_results` :3692).
  **A kanban DB column is not evidence of a wire key** — check the tuple #kanban
- [convention] A dead-decode deletion is pinned by a DRIFT-ALARM test, not a
  regression test: the fixture is the emitted field set plus the deleted keys,
  and it asserts (a) the unknown keys are tolerated on decode and (b) the
  encode round-trip does not re-emit them. That fails the day someone adds the
  property back without a citation, which is the actual thing worth catching
  #testing #kanban



## Whole-surface remediation — P19 (YAML writer hardening)

Commit `c7a50524` on `fix/whole-surface-audit-r2`.

- [gotcha] **Foundation's UTF-8 decoder silently EATS a leading BOM, so the
  BOM hazard is unreachable through Scarf — and unfixable at the writer.**
  Both `String(data:encoding: .utf8)` and `String(contentsOfFile:encoding:)`
  strip U+FEFF, and every text read in the app goes through the former
  (`ServerContext.readTextThrowing:426`, `GuardedTextFile:291`,
  `HermesFileService.readFileResult:2845`). So no matcher, parser or writer
  ever sees one, and the audit's duplicate-first-section consequence cannot
  be reached through a Scarf READ. **Reconciled with what P10/P19 actually
  shipped (audit pass 2026-09-10):** the "already lost with or without a fix"
  half is WRONG — `GatewayConfigWriter.normalizedRoundTrip` strips a leading
  U+FEFF once and RE-PREFIXES it on the way out (same shape as its per-line
  CRLF restore), so a BOM'd config.yaml survives the write byte-for-byte, and
  the hazard IS fixed at the writer rather than being unfixable there. The
  branch is defensive against a future hand-rolled `Data` decode, not dead
  weight. A BOM finding derived from the PURE functions therefore
  has to be reachability-checked against the decode boundary before it is
  called a bug; the honest artifact is a test that pins the decoder's
  behaviour, so a future hand-rolled `Data` decode surfaces there instead of
  as a mystery duplicate section #config-parsing #verification
- [gotcha] **PyYAML's float resolver requires a `.` in the MANTISSA, so
  `1e3` AND `1e+3` are strings — only `1.0e+3` is a float.** A
  "quote anything that looks numeric" rule written from memory quotes both
  and churns every config it touches. The implicit-resolver table has to be
  mirrored from `yaml/resolver.py` and then CHECKED both directions: the
  spelling must misparse bare (or the test proves nothing) and round-trip
  quoted. Same trap in the other direction for bare `y`/`n`, which are NOT
  bools #config-parsing
- [gotcha] **Quoting a scalar removes YAML's bool coercion, and something was
  depending on it.** `reasoning_overrides: off` only ever meant "disabled"
  because bare `off` loads as Python `False` and `parse_reasoning_effort`
  does `str(False).lower()` → `"false"` (`hermes_constants.py:876-889` at
  `v2026.9.7`). Quoted, it loads as `"off"`, which is in NEITHER of that
  function's sets — so a quoting widening silently turned "disabled" into
  "host default". Before widening a writer's quoting, grep for every value
  vocabulary that reaches a `str(...)`-coercing reader and check which
  members survive the change; `false`/`disabled` do, `off` does not and must
  be canonicalised #config-parsing
- [gotcha] **Only a LEADING `{` / `[` breaks a plain YAML key.** Verified
  against PyYAML 6: `a,b`, `a}b`, `a]b`, `a{b`, `a[b` all load as plain
  keys; `{a}` and `[x]` raise `ConstructorError`, a tab anywhere raises
  `ScannerError`. A fail-closed gate that rejects the whole flow-indicator
  set is an over-refusal, and because this gate runs BEFORE the mutation it
  makes an ordinary config permanently uneditable rather than merely
  conservative. Pin the non-refusal as well as the refusal #config-parsing
- [convention] **A structural post-write verifier cannot see damage that
  leaves the structure intact; only named expected rows can.** `entryNames`
  reads indent 0/2 and `unpatchableReason` skips `#` lines, so an `env:` key
  of `#note` — which turns the whole mapping into `None` — changed neither.
  The seam that actually closes it is `patchMCPServerField(expecting:)`:
  build the emitted rows with the SAME helper the mutator uses
  (`HermesFileService.subMapRows`) and hand them to the read-back. "The file
  still looks like a file" is not the question; "the rows I wrote are in it"
  is #verification #mcp
- [convention] **Two writers, one quoting routine.** P10's HIGH was not a
  missing rule but a rule applied in one of two files: `GatewayConfigWriter`
  quoted its map keys and `HermesFileService.replaceOrInsertSubMap` did not.
  Scalar-level emission now lives in `ScarfCore/Parsing/YAMLScalar.swift`
  and line-terminator restoration in `YAMLLineEndings.swift` (lifted out of
  `HermesBotProfileYAML`, which had already solved per-line preservation
  while `GatewayConfigWriter` was still flipping whole files to CRLF). Before
  adding a refusal for a shape another writer already handles, grep for the
  shape #conventions
- [convention] **A quote-escaping writer needs its reader un-escaping in the
  SAME commit, and the test for it is idempotence, not equality.** The
  single-quote writers double an embedded `'`; `stripYAMLQuotes` and
  `normalizedScalar` did not un-double, so `#it's` → `'#it''s'` → read back
  `#it''s` → `'#it''''s'` and the on-disk value genuinely changed on the
  second save. A single save→read comparison passes that bug; save→read→save
  catches it. (`normalizedScalar` also needed the doubling-aware
  `closingQuoteIndex` — `firstIndex(of:)` stops at the first half of `''`.)
  #config-parsing #testing
- [decision] Comments inside a rewritten block are re-emitted directly under
  the key, not back between the bullets they sat between: a bullet's
  identity is its VALUE and the values are exactly what the edit replaces,
  so there is no honest "where it was" to restore to. The first save of a
  config with interleaved comments reflows the block once and is stable
  after — pinned by an idempotence assertion, which is the property that
  matters. Deleting them was never an option #conventions


## Whole-surface remediation — P20 (config-read defaults, platform read paths)

Commits `37497c16`, `f82ccb60` on `fix/whole-surface-audit-r2`.

- [convention] **A mid-window default flip is found by a TABLE, not by two
  endpoint reads — and the table must fail closed.** P13 established the
  sentinel rule; P20 needed it for four keys and the only reliable way to
  find them was extracting `DEFAULT_CONFIG` at all 32 `v2026.*` tags with an
  AST walk (`hermes_cli/config_defaults.py`, falling back to
  `hermes_cli/config.py` at tags before v0.19.1). `ast.literal_eval` is NOT
  enough: the dict carries `24 * 7` BinOps and, at v2026.9.7, `_aux(...)`
  CALLS. A custom evaluator that folds arithmetic and marks anything else
  UNRESOLVED, then exits non-zero if a requested path landed on one, is what
  makes the table trustworthy — silently skipping an unevaluable subtree would
  have read as `<absent>` and invented a flip. The script is worth rebuilding
  per cycle; the shape is what matters #verification #config-parsing
- [gotcha] **The round-2 audit's own flip citation was two releases wrong.**
  It put `display.show_reasoning`'s False→True at v2026.7.20 (0.19.0); the
  table says v2026.7.7 (**0.18.1**), with v2026.7.1 (0.18.0) the last `False`.
  C2 applies to the audit report as much as to release notes — a finding's
  *claim* can be right while its *citation* is wrong, and the floor is what
  the capability flag encodes, so the citation is the load-bearing half
  #verification #capability-gating
- [gotcha] **A 0 sentinel is only available when 0 is not a setting.**
  `approvals.timeout` can take the 0 sentinel (Scarf's stepper floor is 5, so
  Scarf can never write it; a hand-edited 0 IS honoured upstream and is
  knowingly ambiguous, the `displayMaxTurns` precedent).
  `agent.gateway_notify_interval` CANNOT: `0` means "no still-working
  notices" and its stepper range starts at 0, so that key needed a true
  `Int?`. Check the stepper's own floor before reaching for the cheaper
  sentinel #config-parsing #settings
- [gotcha] **`platform_section` REPLACES the bridge source; it does not
  out-rank it key-by-key.** `gateway/config_loader.py:171-180` @ v2026.9.7
  picks ONE section for a platform's `_SHARED_KEYS` — a top-level `<name>:`
  block wins outright — so with a top-level `slack:` present, a
  `platforms.slack.require_mention` is never bridged and never reaches the
  adapter AT ALL. P13's "first key present wins" list was therefore still
  wrong in shape, not just in order: the precedence is (1) the chosen bridge
  source, then (2) `platforms.<p>.extra`, then (3)
  `gateway.platforms.<p>.extra` (merge order from `:136-147`). Detect "is a
  dict" the way PyYAML does — a bare `slack:` with no children is `None` and
  NOT a dict, which in a flat parse is exactly "no `slack.*` key exists"
  #config-parsing #gateway
- [gotcha] **`_SHARED_KEYS` membership is the test for a top-level platform
  key, and it has a mirror: a key that is NOT a member is dead at the top
  level.** `reply_in_thread` IS a member, so reading it from `extra:` alone
  showed the half the bridge overwrites. `reply_to_mode` is NOT, and
  `merge_platform_sections` never merges a bare top-level `<plat>:` block into
  `platforms_data` (which is what `PlatformConfig.from_dict` reads it from,
  `gateway/config.py:437`), so top-level `slack.reply_to_mode` is read by no
  Hermes version — the mattermost bug P13 fixed, third instance. Check the
  plugin's own `apply_yaml_config_fn` hook too before declaring a key dead:
  slack's (`adapter.py:6449`) enumerates exactly what it translates
  #config-parsing #gateway
- [gotcha] **`display.busy_ack_enabled` is the ONE exception to P17's
  universal boolish contract, and the reason is the env bridge.**
  `gateway/run.py:1816-1820` exports it as `str(section[cfg_key])` and
  `run_busy.py:727` compares `!= "true"`. PyYAML has already typed the
  scalar, so `true`/`yes`/`on` → Python `True` → `"true"` → enabled, but `1`
  → the INT 1 → `"1"` → **DISABLED**, while every other boolean key in the
  file reads `1` as on. P17's "the coercion is in the LOADER so it's
  universal" holds for readers that see the Python object; a key whose value
  is stringified into an env var on the way is a different contract. Grep the
  env bridges before trusting the universal rule #config-parsing #gateway
- [gotcha] **`pick` selects on PRESENCE, `data.get(...) is None` selects on
  VALUE, and the two live eleven lines apart.**
  `gateway/config.py:668-670`'s `pick` is `data[key] if key in data else
  nested_gateway.get(key)` — so a present-but-null TOP-LEVEL
  `multiplex_profile_allowlist` shadows the nested key AND means serve-all
  (`_normalize_multiplex_profile_allowlist(None)` → `None`). But `:708-710`
  resolves `multiplex_profiles` with `if multiplex_profiles is None:` — so a
  null top-level key there falls THROUGH. Sibling keys in the same
  constructor, opposite null semantics; read each one's own line. Expressing
  the first needed `[String]??` in the resolver so "present with a nil value"
  is distinguishable from "absent" #config-parsing #gateway
- [gotcha] **An explicitly quoted `key: ''` is not null.** A bare `key:` never
  reaches `parseNestedYAML`'s `values` at all (an empty value opens a section),
  so the only way to observe `""` is `key: ''`, which PyYAML loads as the
  empty STRING — not `None`. A null predicate that folds in `isEmpty`
  therefore turns a malformed value (which Hermes warns about and fails closed
  on) into "absent". Null is `null` / `~` only #config-parsing
- [gotcha] **A "write to the key in effect" fix needs the in-effect test to be
  the SAME predicate the explanatory UI uses.** `multiplexIsTopLevel` already
  existed to tell the user "edit it at the top level"; once
  `setMultiplexProfiles` writes the spelling in effect, that same flag picks
  the key — and the banner's button stops being a dead end, so the
  can't-help-you branch can be deleted rather than kept. Extracting the choice
  as a pure `static func` is what makes it testable without shelling through
  `setSetting` (the `CronViewModel.repeatEditArguments` shape) #settings #testing
- [decision] **A "host default" picker row writes NOTHING; a "provider
  default" row writes an empty scalar.** They look identical and are not:
  `approvals.mode: ''` is a value `_normalize_approval_mode` warns about and
  reads as `manual`, so selecting "Host default" would pin the very mode the
  row exists to avoid claiming — the setter no-ops and getting back out needs
  `hermes config unset` (a separate, `hasConfigUnset`-gated affordance).
  `agent.reasoning_effort: ''` IS equivalent to absent
  (`parse_reasoning_effort` returns `None` for both), so that row stays
  writable and is the user's way back out of a pin. Ask what the empty scalar
  means to the reader before deciding which of the two a row is #settings
- [decision] An UNDETECTED host does not get a guessed default for a value
  with real consequences: `displayApprovalMode` returns `nil` and the row
  reads "Host default (unknown)", rather than resolving to either mode. For
  the numeric resolvers the existing convention stands (fall to the OLDER
  value, `displayGatewayTurnLeaseTimeout`), because over-stating a wait is
  benign where mis-stating an approval posture is not #capability-gating #settings
- [gotcha] **A provider roster's floor is the tag its frozenset first
  appears, and that is not automatically the tag the provider arrived.**
  `BUILTIN_TTS_PROVIDERS` first exists at v2026.4.23 (v0.11.0) already
  containing `gemini` and `kittentts`, which reads like an artefact of the
  constant being introduced — the check that makes v0.11.0 a REAL floor is
  that neither name occurs anywhere in `tools/tts_tool.py` at v2026.4.16
  (v0.10.0). Hermes keeps two copies of each roster in sync with a test of its
  own (`agent/tts_registry.py::_BUILTIN_NAMES` vs
  `tools/tts_command_provider.py::BUILTIN_TTS_PROVIDERS`; same for STT via
  `agent/transcription_registry.py` and `tools/transcription_common.py`), so
  either is citable #verification #capability-gating
- [decision] A roster mirror stops at the names Scarf can actually express:
  `stt.xai` is a genuine built-in since v0.15.0 but Scarf has no `stt.xai.*`
  fields, and `local_command` is a mechanism rather than a pickable name.
  Offering a pin with no settings behind it is half a feature — file the gap
  (`t-7b6c5a7f`) instead of shipping the row #settings


## Whole-surface remediation — P21 (output-verdict correctness)

Commit `4995e7c0` on `fix/whole-surface-audit-r2`.

- [gotcha] **`stripANSI` stripped nothing, for two releases.** The pattern was
  a RAW string, `#"\u{1B}\[…"#` — `\u{1B}` is a *Swift* escape and ICU's regex
  dialect has no `\u{…}` form, so the literal six characters reached the engine
  and matched nothing. Any `#"…"#` regex containing a Unicode escape is broken
  by construction; the escape has to be interpolated by the Swift lexer
  (`"\u{1B}\\[…"`). Nothing failed loudly because a piped `hermes` emits no
  ANSI (`colors.py::should_use_color()` is `isatty()`) — the bug only bites
  under `FORCE_COLOR`, i.e. exactly the case the function exists for
  #verification #cli
- [gotcha] **A fix that makes a verdict output-dependent makes every latent
  drain race load-bearing.** P9 turned `mcp login` from exit-code-judged into
  output-judged; the pre-existing termination handler nil'd the reader's
  `readabilityHandler` and judged immediately, so a `✓ Authenticated` line
  written just before exit could be judged missing — a SUCCESS reported as a
  failure, and P12's EOF `decoder.flush()` unreachable whenever termination
  won. The rule: **EOF and the exit status are two independent signals and the
  verdict belongs to whichever arrives LAST.** Leave the reader installed on
  termination; add a grace deadline (2 s) so a pipe still held by a grandchild
  cannot hang the sheet forever #mcp #concurrency #verification
- [gotcha] **`Task { @MainActor … }` hops from a pipe queue are NOT ordered
  relative to one another**, so appending each decoded chunk inside its own hop
  can interleave the output text. Sequence where the text is PRODUCED (a
  lock-guarded inbox on the reader side) and let the main actor drain it; then
  hop ordering stops mattering and the drain flag rides along with the text
  #concurrency
- [convention] **A drain-race test must control the interleaving, not race
  it.** A fake `hermes` that backgrounds its last write into a SUBSHELL
  (`( sleep 0.3; printf … ) & exit 0`) makes the parent exit strictly BEFORE
  the final chunk — the failing order, every time. For "EOF alone must not
  decide", block the child on a gate FILE the test creates: it cannot exit
  before the assertion runs at any machine load. Both need a `Process` factory
  injected into the controller — the P11 `HermesCLIRunner` seam does not reach
  a streaming controller #testing #concurrency
- [gotcha] **A "success count" printed after a loop counts ATTEMPTS.**
  `do_update`'s `Updated {len(updates) - len(skipped_local)} skill(s).`
  (`skills_hub.py:871`) is emitted whatever each nested `do_install` did — and
  `do_install` is itself `-> None`, so a blocked scan prints its refusal and
  returns at exit 0. The honest per-skill signal is the callee's own
  `Installed:` line (`:720`); `Updating:` (`:834`) is printed BEFORE the call
  and proves only intent. When only an attempt line exists, the UI must say
  "attempted", never "updated" #skills #verification
- [gotcha] **The discarded-consent-bool bug is three call sites, not one.**
  `_run_capability_consent`'s return is thrown away by `cmd_enable` (:1033),
  `cmd_install` (:764) AND `cmd_update` (:822). `update` prints its success
  lines AFTER the consent screen, so like `enable` it needs `failureWins: true`;
  `install` reports through `HermesPluginInstallOutcome`, so it needs the
  marker on the PARSER instead. The consent call arrives at v2026.8.13, so an
  older host never prints the line and is judged as before (C1) #plugins
- [gotcha] **A bare-substring success marker can be quoted into existence by
  untrusted content.** `do_install` runs `_print_tier1_advisory` (:704), which
  prints SKILL.md-derived findings BEFORE `install_from_quarantine` can raise
  (:714-720) — so a skill whose own text contains `Installed: …` read as a
  successful install of a refused skill (with `failureWins: false`, a success
  marker wins). Every emitter that prints its success line at column 0 now
  matches ANCHORED (`hasPrefix` after ANSI-strip, trim and a leading status
  glyph); the `plugins` markers stay substrings because there the marker is a
  mid-sentence clause. `failureWins` stays per-site — anchoring is orthogonal
  to it #verification #cli
- [gotcha] `hermes pairing list` prints two HINT lines inside the pending
  section (`pairing.py:38-39`), and they have a row's shape: `Approve with:
  hermes pairing approve …` parsed as platform `Approve` / code `with:`, giving
  the user two phantom pending pairings with live Approve buttons. They arrive
  at v2026.8.3 (absent below, so the filter is a no-op there). The approved row
  is the mirror trap: `user_name` is `a.get("user_name") or ""` (`:48`, same
  since v2026.6.19), so a nameless user is a TWO-token row that a
  `parts.count >= 3` guard dropped — invisible in the list and impossible to
  revoke #gateway #config-parsing
- [fact] `hermes security audit`'s exit code answers ONE question — "was
  anything at or above `--fail-on`?" — so with Scarf's `critical` threshold
  exit 0 also covers a report full of high/moderate/low advisories. The
  distinguishing signal is `_render_human`'s own head (`No known vulnerabilities
  found across …` :255 vs `Found N known vulnerability finding(s) across …`
  :257) plus its `  {severity.ljust(8)}  {name}=={version}  {osv-id}` rows
  (:264) — all byte-identical back to v2026.5.29, the verb's first release and
  the `hasHermesAudit` floor #health #verification
- [decision] `HermesCLIMarkers.pluginsDisableFailure` lost `"was removed."`
  A floor walk over every `v2026.*` tag carrying `hermes_cli/plugins_cmd.py`
  (v2026.3.23 … v2026.9.7) puts the string's first appearance at v2026.8.19,
  at :1424/:1439 — both inside `cmd_enable` (:1405), far above `cmd_disable`
  (:1710) — and at v2026.9.7 it lives in `_refuse_legacy_relay`, defined inside
  and called only from `cmd_enable`. A dead marker on a failure list is not
  inert: it can only ever turn a real success into a reported failure #plugins
- [convention] The capability-refusal sentence is now VERB-NEUTRAL. One
  consent screen serves install/enable/update, so a message opening
  "Enabled, but…" is wrong at two of the three call sites — the user-facing
  wording has to be as shared as the emitter it quotes #plugins



## Whole-surface remediation — P22 (main-actor and spawn discipline, C10)

Commit `6ce74848` on `fix/whole-surface-audit-r2`.

- [convention] **A per-surface C10 sweep needs a shared choreography, not 14
  hand-written `Task.detached` blocks.** The 15 platform-setup forms had the
  same load (`.env` + config.yaml read) and the same save (`.env` write + one
  `hermes config set` spawn per key) inline on the main actor; the fix is one
  `PlatformSetupForm` protocol (context, an optional `HermesCLIRunner` seam,
  `isLoading`/`isSaving`) whose extension owns `loadSnapshot` and
  `commitSave`. Single-sourcing it is what lets the two invariants the
  detachment INTRODUCES be stated once #concurrency #platforms
- [gotcha] **Detaching a form's load re-opens GW-F6 through the other door.**
  Until the read lands the form renders its pre-load BLANKS, and
  `PlatformSetupHelpers.saveForm` treats a blank field as an `unset` — so a
  Save clicked in that window comments live credentials out of `.env`. Every
  off-main load therefore needs a save guard (`guard !isBusy`) AND a disabled
  Save button, plus the mirror guard (a load landing on a save must not
  commit) #platforms #concurrency
- [fact] `hermes config set` takes exactly ONE key/value pair at v2026.9.7 —
  `hermes_cli/config.py::_cmd_config_set` reads `args.key` / `args.value` and
  `_CONFIG_SUBCOMMANDS` maps the single verb; there is no batch form and no
  `--from-file`. A multi-key form save is irreducibly N spawns, which is why
  it cannot run on the main actor rather than something to collapse #cli
- [gotcha] **A "fetch at most once per interval" throttle whose stamp is set
  only on SUCCESS is not a throttle.** The kanban diagnostics stamp lived
  inside `if let diags = try? await service.diagnostics()`, so a host where the
  command fails never satisfied the interval again and respawned it on every
  5 s board tick. Stamp the ATTEMPT #kanban #concurrency
- [gotcha] `isLoading` cannot be cleared under the same generation guard that
  decides whether to COMMIT. A mutation bumps `loadGeneration` without starting
  a load, so the superseded load returned early and left the spinner up until
  the post-mutation reload — and any test waiting on `isLoading == false` was
  really waiting on that reload. Two tokens: `loadGeneration` owns the data, a
  separate `inFlightLoadGeneration` owns the spinner #gateway #concurrency
- [decision] `HermesGatewayListService.fetch` takes an OPTIONAL runner that is
  `nil` in production. It judges `gateway list`'s stdout alone via its own
  transport call; routing production through `runHermes` would merge stderr,
  and a stderr line has a profile row's shape (it would parse as a phantom
  profile). The seam exists so the third probe of a gateway load is observable
  at all — before it, no test could see it #gateway #testing
- [gotcha] **`Process` cannot be subclassed to record where `run()` was
  called** — `NSTask` is abstract, and overriding `run()` makes Foundation
  demand `setLaunchPath:` and the rest of the primitives at runtime
  (`NSInvalidArgumentException`). For a controller with a `ProcessFactory`
  seam the honest signal is ORDER instead: `run()` launches synchronously, so
  a process still `isRunning == false` when `start()` returns cannot have been
  launched on the main actor — the main actor has not suspended yet. Give the
  child a blocking body so "not launched" cannot be confused with "already
  exited" #testing #concurrency
- [gotcha] **Half-isolating a Swift-5-mode `@Observable` class is what created
  the hole.** `SkillsViewModel` had `@MainActor` on some methods and nothing on
  others, and the unannotated ones mutated UI state. Annotating only the
  offenders does not even compile against the existing tests (ScarfCore's test
  target builds in Swift 6, where a nonisolated `sending` closure would have to
  SEND the view model into each call). The whole type gets `@MainActor`; the
  off-main work is already in `nonisolated static` helpers called from explicit
  `Task.detached`, and a `static let` they read needs `nonisolated`
  #concurrency #skills
- [convention] `Process.waitUntilExit(timeout:)` (written at `Core/Models/ProcessTimeout.swift`;
  **hoisted to `ScarfCore/Models/ProcessTimeout.swift` in round-4 P43** — the app-target copy is gone)
  is the one place the C10 "every subprocess has a timeout" poll lives for
  ad-hoc spawns outside the transport. It returns `false` after an overrun AND
  reaps the child, so a caller can never leave a runaway behind — the `lsof` in
  `HealthViewModel.dashboardListenerPID` had a bare `waitUntilExit()` on the
  main actor. A long-running server spawn (the dashboard itself) legitimately
  has none, because nothing WAITS on it #health #concurrency



## Whole-surface remediation — P23 (capability floors and gates)

Commit `7644b37d` on `fix/whole-surface-audit-r2`.

- [gotcha] **A capability flag can be INVERTED, and the doc comment is where
  the lie hides.** `hasCompressCommand` claimed "`/compact` was renamed
  `/compress` at v0.20". The truth is the other way round and older than the
  supported window: `CommandDef("compress", …)` is canonical at
  `hermes_cli/commands.py:57`, tag **v2026.3.17 (0.3.0)**, and
  `aliases=("compact",)` only appears at `:92`, tag **v2026.7.7 (0.18.1)**. So
  the flag's FALSE branch sent the spelling no 0.12–0.18.0 host routes to
  compression — and on the TUI gateway `/compact` is `_TUI_EXTRA`'s "Toggle
  compact display mode" (`tui_gateway/server.py:3845` @v2026.4.30), i.e. the
  user's compress gesture silently flipped a display mode. The general rule:
  when a flag picks between two SPELLINGS rather than showing/hiding a
  surface, walk BOTH spellings — a floor walk on only the new one confirms the
  flag and misses the inversion. The second spelling existing as an ALIAS is
  the tell that there was never a rename #capability-gating #verification
- [fact] Inside Scarf the same surface disagreed with itself:
  `RichChatInputBar`'s compress sheet already sent `/compress` unconditionally
  while the slash MENU switched on the flag. Two call sites for one command
  name and only one of them gated is itself evidence the gate is wrong #chat
- [gotcha] **The `isV020OrLater` cluster was never walked** — P16 fixed only
  the seven flags it attributed to the v2026.7.30 mis-read, and the five flags
  filed directly under the v0.20 MARK were never checked at all. Four of the
  five were too high: `cron runs` is `hermes_cli/subcommands/cron.py:159` at
  **v2026.7.20 = 0.19.0**; `curator adopt` / `list-unmanaged`
  (`curator.py:344`, `:748`) and `hermes_cli/approvals_suggest.py` at
  **v2026.7.30 = 0.19.1**; `sessions export --format` with its five choices at
  `main.py:13546`, **v2026.7.7 = 0.18.1**. Fixing a mis-read tag map means
  re-walking EVERY flag that cites a version near it, not only the ones the
  original finding named #capability-gating
- [gotcha] The same held a patch level down: the "v0.20.4" MARK group was
  mostly 0.20.1 and 0.20.3. `hermes_cli/personality.py` and
  `cron/jobs.py:482 _has_pause_marker` both first exist at **v2026.8.13 =
  0.20.1**; `curator ledger`/`purge`/`rollback` and `skills trust`/`untrust`/
  `update --force` all land together at **v2026.8.16.2 = 0.20.3** and are all
  absent at v2026.8.16 = 0.20.2. A MARK group's NAME is not evidence for its
  members' floors — `git ls-tree` the file or grep the subparser at the tag #capability-gating
- [decision] **A floor below Scarf's v0.6.0 supported minimum is no floor at
  all** (the P15 `--clear-skills` rule), and it applies to REMOVING flags too,
  not only to declining to add one. `hasSessionsRename` (v0.16) and
  `hasCompressCommand` (v0.20) are both gone: `sessions rename` is
  `hermes_cli/main.py:2373` at **v2026.3.12 (0.2.0)**, the oldest tag in the
  repo, so the flag's only effect was hiding the rename context-menu item from
  every 0.12–0.15 host that has the verb. What survives instead is a test
  pinning the consumer as capability-free across the whole supported window,
  including `.empty` #capability-gating
- [decision] **`HermesCapabilities.parseLine` fails CLOSED on an unrecognised
  shape** (Alan's round-2 decision 7): a major component outside `0...9`
  yields `.empty`. `Hermes Agent v2026.9.7` — what a wrapper or shim on PATH
  emits — used to parse as `SemVer(2026, 9, 7)` and satisfy EVERY floor in the
  file, write and argv gates included (`hasCronCreatePaused`,
  `hasConfigDottedKeyEscape`, `hasCronFailureDeliver`). `.empty` is already
  the failed-probe value, so no caller needs a new case, and the three
  `parse()` consumers outside the cache all degrade safely on `semver == nil`
  (Health retries with `--version`). The cost accepted: a legitimate future
  versioning scheme degrades to "no capabilities" rather than "everything" #capability-gating #verification
- [decision] **Roster gating rule, settled** (decision 6): a row added in a
  Scarf parity cycle WITH a known floor carries it; a row that predates this
  audit cycle with no parity-cycle attribution does not (`bluebubbles`, plus
  the original core roster). `photon` carried `photonPlatformFloor` while
  `whatsapp_cloud` — the same v2026.6.19 adapter — did not, and the whole
  `-- v0.1x additions` set was ungated the same way. Floors walked with
  `git ls-tree -r` over `gateway/platforms/<n>.py` and
  `plugins/platforms/<n>/` at all 32 tags: teams + yuanbao v2026.4.30 (0.12.0),
  google_chat v2026.5.7 (0.13.0), line + simplex v2026.5.16 (0.14.0), ntfy
  v2026.5.28 (0.15.0), whatsapp_cloud v2026.6.19 (0.17.0), **buzz v2026.7.30 =
  0.19.1** (filed under "v0.20" by the same mis-read). Each floor is now a
  shared `static let …PlatformFloor` so the roster row and its `has…Platform`
  flag cannot drift #capability-gating #gateway
- [convention] **Gating a row users already see needs the widen-for-current
  hatch.** Hiding an UNCONFIGURED channel the host has no adapter for is the
  point; hiding one the user has ALREADY configured hides their own config
  behind a failed probe (`.empty` means the probe failed, not "old host" —
  P16's `editorStyle` lesson). `HermesToolPlatform.isVisible(on:isConfigured:)`
  is that seam, and it is what made the decision safe to apply to eight
  pre-existing rows instead of one #capability-gating #gateway
- [convention] The same hatch closed the Web Tools hole:
  `WebToolsBackendRoster.editorStyle` renders the SPLIT editor on an
  undetected host whose config already names `web.search_backend` /
  `web.extract_backend`, because the combined `web.backend` row neither shows
  nor writes those keys — it showed "Automatic" and every pick wrote a key the
  override shadows. The widening branch is unreachable for any config Scarf
  itself could have written on a pre-v0.13 host, which is what keeps C1 #settings
- [gotcha] A re-floor's blast radius is the CONSUMERS' doc comments, not just
  the flag: nine files said "v0.20+ / pre-0.20 hosts" about surfaces that turn
  out to be 0.18.1–0.19.1. A floor change that leaves those behind re-creates
  exactly the stale-citation class C2 exists to prevent #verification


## Whole-surface remediation — P24 (MCP OAuth paths, transport, boolish type gate)

Commit `e4bf9653` on `fix/whole-surface-audit-r2`. Task `t-00d04dcc`.

- [architecture] **Hermes does NOT name an MCP server's OAuth files after the
  server.** `HermesTokenStorage` sanitises first —
  `re.sub(r"[^\w\-]","_",name).strip("_")[:128] or "default"`
  (`tools/mcp_oauth.py:104-106` @ v2026.9.7) — so `github.com` is
  `github_com.json`, and four files hang off that one basename: `.json`
  (tokens), `.client.json` (DCR registration), `.meta.json` (discovered
  metadata), `.cimd-off` (CIMD refused). `remove_oauth_tokens` (`:690-693` →
  `remove`, `:391-394`) deletes ALL FOUR. The port lives in
  `ScarfCore/Services/HermesMCPOAuthPaths.swift`; anything reading or clearing
  MCP OAuth state goes through it #mcp #oauth
- [gotcha] **Porting a Python `re.sub` to Swift: iterate unicode SCALARS, not
  `Character`s, and capture the expectations from CPython.** Python's `\w` in
  `str` mode is Unicode-aware (CPython `SRE_UNI_IS_WORD` = `Py_UNICODE_ISALNUM
  || '_'`, i.e. general categories `L* ∪ N* ∪ _` — so `Character.isLetter ||
  isNumber` is close but not that set, use `generalCategory`), and both the
  substitution and the `[:128]` slice count CODE POINTS. `cafe` + U+0301 is one
  Swift `Character`: Python replaces the combining mark (Mn is not `\w`) and
  then strips the trailing `_`, giving `cafe`, where a grapheme-cluster port
  keeps `café` — a different filename from the one on disk. Decide the
  grapheme question explicitly for every ported regex #verification
- [gotcha] **A clear-the-credential path must not be built from an
  unsanitised, user-chosen name.** The sanitiser is what keeps a server called
  `../../.ssh/id_rsa` from naming a file outside `mcp-tokens/`, so the legacy
  raw-name fallback (kept for C1, since pre-v0.8.0 Hermes stored raw) is
  dropped whenever the name carries a path separator. Detect broadly, DELETE
  narrowly #mcp #security
- [decision] **A sidecar an older Hermes never wrote needs no capability
  gate when the removal primitive already tolerates absence.** Both transports'
  `removeFile` is `rm -f`-shaped (`LocalTransport.swift:207-214` guards on
  `fileExists`; `SSHTransport.swift:636` runs literal `rm -f`), so unlinking
  `.cimd-off` on a v0.16 host is a no-op indistinguishable from the pre-target
  behaviour. Gate the SURFACE, not an idempotent unlink #capability-gating
- [architecture] **`_parse_boolish`'s word sets are only half of it; the other
  half is a TYPE gate that INVERTS the answer.** Hermes matches
  {true,1,yes,on}/{false,0,no,off} only when `isinstance(value, str)`
  (`tools/mcp_tool_common.py:124-137`). PyYAML types a BARE `0` as an `int`, so
  Hermes warns and returns the per-key DEFAULT: `enabled: 0` is an ENABLED
  server, `supports_parallel_tool_calls: 1` is OFF, `tools.resources: 0` is ON.
  QUOTED (`"0"`) is a `str` and does match — so the gate must run on the raw
  scalar BEFORE any unquote. Any future reader of a Hermes bool-ish key needs
  both halves #config #mcp
- [convention] `YAMLScalar.resolvesToBool` is split out of
  `resolvesToNonString` for exactly that: a WRITER only needs "would PyYAML
  retype this" (quote it either way), a READER of a bool-ish key needs "retyped
  to a bool specifically". `ssl_verify` is the documented exception — it never
  reaches `_parse_boolish`, it goes to httpx, and a CA-bundle path is a legal
  value, so it stays a `String?` to the UI #config
- [gotcha] **An audit finding can be understated as well as wrong.** The
  device-prompt CRLF finding said `.whitespaces` does not strip `\r`; true, but
  trimming alone would not have fixed it, because Swift treats `\r\n` as a
  SINGLE grapheme cluster and `split(separator: "\n")` therefore does not see a
  CRLF break AT ALL — the whole stream arrived as one line. Normalise `\r\n`
  before any line split. Third appearance of this cluster trap (P10's `\r`,
  P19's `containsLineBreak`, now here) #parsing
- [decision] **`sse_read_timeout` is dead config.** Walked all 32 `v2026.*`
  tags: the key exists only as a hard-coded `300.0` literal
  (`tools/mcp_tool.py:1323` → `mcp_tool_transport.py:352` after the v0.21.1
  modularisation), with no `config.get("sse_read_timeout")` at any tag and
  Hermes's own suite pinning it (`tests/tools/test_mcp_sse_transport.py:109`).
  Editor field and writers removed; the PARSE is kept so an existing key is
  never rewritten — and note the removed writer's nil arm actively DELETED the
  key from the user's file, which is the worse half of a dead-knob bug
  #mcp #config
- [gotcha] The MCP transport discriminator is `== "sse"`, EXACT case
  (`tools/mcp_tool_transport.py:412`) — `transport: SSE` runs down the
  Streamable-HTTP arm on the host. Scarf's old `.lowercased()` compare was
  wrong in both directions: it accepted `SSE` and REJECTED `"sse"` / `'sse'`,
  which PyYAML loads as the same string as bare `sse`. Compare unquoted, then
  exactly #mcp
- [gotcha] **`pkill` needs `-u` or it is everyone's.** `-u` is an
  effective-uid restriction on both platforms Scarf reaches (macOS `pkill(1)`
  `-u euid`; Linux procps `-u, --euid`), so one argv works on either — but the
  uid must be PROBED (`id -u` over the same transport), never guessed from the
  SSH username, because `~/.ssh/config` `User` can rewrite it. If the probe
  fails, ABANDON the reap rather than run it unscoped #concurrency
- [gotcha] **`SSHTransport.remotePathArg` double-quotes UNCONDITIONALLY**
  (`SSHTransport.swift:303-322`), so a `bash -lc` wrapper's command line ends
  with a literal `"` after the last argument while the process it execs does
  not. Any `pkill -f … $`-anchored pattern therefore already excludes the
  wrapper — the round-2 finding that it "matches as well" is FALSE. This is a
  property of another file, so it is pinned by a test that runs the pattern
  against the real composed wrapper string with the real `grep -E` (not
  `NSRegularExpression`, which is not POSIX ERE) #verification
- [gotcha] A fix to a misread contract usually has an EXISTING test encoding
  the misread: `boolishHelperMirrorsHermesWordSets` asserted bare `1` → true
  and bare `0` → false. Finding it is part of the fix; quietly deleting the
  assertion is not #verification


## Whole-surface remediation — P25 (surface completeness and copy)

Commits `eac1efa3`, `5dbc2f0e`, `2b6e2960` on `fix/whole-surface-audit-r2`.

- [gotcha] **`sessions export --format trace` and `--no-redact` have DIFFERENT
  floors, three releases apart.** `trace` has been a `--format` choice since
  v0.18.1 (`hermes_cli/main.py:13546` at v2026.7.7, moved to
  `subcommands/sessions.py:75` by v2026.9.7), but `--no-redact` is registered
  for the first time at v2026.9.7 (`subcommands/sessions.py:83`) — a walk of
  all 32 `v2026.*` tags. `_export_trace` *read* `getattr(args, "no_redact",
  False)` as far back as v2026.8.31, so the code looks older than it is: with
  no option registered the getattr always saw `False`, meaning a 0.21.0 host
  redacts every trace unconditionally AND exits 2 on the flag. Reading the
  consumer is not reading the floor — the floor is in argparse #sessions
- [gotcha] **The redaction flags are per-format, not global.** `--redact` is
  consumed only by `_cmd_export`'s `_redact` closure
  (`hermes_cli/sessions_cmd.py:306-309`), which the jsonl/md/html renderers
  call and `_export_trace` never does. So `--redact --format trace` is a silent
  no-op and the opt-OUT `--no-redact` is the only lever a trace has. A single
  UI toggle spanning formats has to invert for `trace` (ON ⇒ send nothing)
  #sessions
- [gotcha] **"Export everything" is not a flag on every export format.** With
  neither `--session-id` nor a filter, `_export_trace` quietly means "the last
  thing I did" — `list_sessions_rich(limit=1, order_by_last_active=True)`
  (`sessions_cmd.py:383-388`) — while bare `jsonl` genuinely means
  `db.export_all()` (`:327`). Trace's only multi-session shape needs a filter
  AND writes a DIRECTORY of `<id>.trace.jsonl` files (`:425-440`), so it can
  never stream to one save-panel file. A bulk-export UI must check the
  no-argument branch of EACH format's emitter, not just the verb's argparse
  #sessions
- [decision] **`hermes skills audit` is a security scan, not a reload.**
  `do_audit` re-runs `scan_skill` per installed skill and prints the report
  (`hermes_cli/skills_hub.py:879-904`); the only reload Hermes has is the
  `/reload-skills` slash command inside a live chat session
  (`gateway/slash_commands.py:1038-1048`), which has NO CLI form — so no Scarf
  button can reload a running gateway. Scarf's button keeps the `audit` argv
  and says "Re-scan skills" everywhere (label, tooltip, a11y label, banner,
  doc comment). No iOS twin of that button exists #skills
- [convention] **A "both settings can be on" contradiction is a UI fix, not a
  warning.** Where Hermes gives one input precedence (`--clear-skills` beats
  `--add-skill`, `hermes_cli/cron.py:612-618`), the losing control is DISABLED
  with a caption rather than left settable and discarded at save time
- [convention] **A roster-driven editor block must key on roster ∪ current
  value.** Cron's Skills block was `if !availableSkills.isEmpty`, so on a host
  with an empty roster a job's existing skills could be neither edited nor
  cleared. Rows are now the roster plus any value the record already carries —
  the same shape the `strEnum` pickers use for an unrecognised stored value
- [gotcha] **`RelativeDateTimeFormatter.localizedString` already ends in
  "ago".** Two kanban-card arms appended their own, so every non-running card
  read "3 min. ago ago" — in the footer AND in the accessibility label that
  reuses the same string. A string built by composing a formatter's output
  needs a pure, `now`-injectable function so a test can pin it in any locale;
  the test asserts against the same formatter rather than literal English
- [decision] **Consumer-less capability flags stay.** `hasKanbanGoalMode` lost
  its last consumer in P14 and P18 already annotated it `**No consumer yet**`
  per the file's own convention — the same convention `hasInsightsCommand` and
  `hasDashboardCommand` live under. Deleting one of them would discard a
  source-verified floor (a tag walk to rediscover) and make the file
  inconsistent, so P25 left it in place rather than deleting it. **Reconciles with P23 (which DELETED `hasSessionsRename` and `hasCompressCommand`) and with the v0.21.1 cycle's own deletion of `hasComputerUseDoctorJSON`/`hasGatewayMultiplexerStatus`:** the discriminator is the FLOOR, not the consumer count. A flag whose floor is at or below Scarf's v0.6.0 supported minimum encodes nothing (P15's `--clear-skills` rule) and goes; a flag whose surface is correctly decided by OUTPUT rather than by version goes; a flag carrying a real, source-verified floor above the minimum with no consumer YET stays, annotated `**No consumer yet**` (`hasKanbanGoalMode`, `hasInsightsCommand`, `hasDashboardCommand`). "An unread flag is drift bait" is not the rule — an unread flag with no floor to encode is
- [gotcha] **A fix that changes an argv shape will break the test that pinned
  the old shape, and that test may read as a legitimate failure.**
  `SessionExportRemoteDestinationTests`' "redact with trace over stdout" pinned
  `--redact` for trace. Re-pin it with a comment saying WHY the old
  expectation was wrong, in the same commit series — and note that the Mac
  target's suites are genuinely flaky under full parallel load (the ACP
  `session/cancel` and `BotAgentViewModel` suites failed in the full run and
  passed in isolation in a tenth of the time), so every failure needs an
  isolated rerun before it is called a regression


## Whole-surface remediation — P26 (citation and doc-comment sweep, C2)

- [gotcha] **The Hermes repo is FLAT.** `hermes_constants.py`, `cli.py`, `pyproject.toml`, `cron/`, `gateway/`, `tools/`, `hermes_cli/`, `plugins/`, `agent/` all sit at the repo root — there is no `hermes/` package prefix. A `git show <tag>:hermes/hermes_constants.py` fails with "path does not exist", which reads like a deleted file and is really a wrong path. `git ls-tree -r --name-only <tag> | grep <basename>` settles it in one call. Note `kanban_db.py` lives under `hermes_cli/`, not the root. #verification
- [gotcha] **In zsh, `H="git -C $HOME/repo"; $H show …` does not word-split** — unquoted parameter expansion keeps it one word and the shell reports `no such file or directory: git -C /Users/…`. That error names a path that clearly exists, so it reads like a missing checkout. Use `cd <repo> && git …` per call. #tooling
- [convention] **A citation sweep is only worth anything if every replacement line is READ, not computed.** Of ~20 findings in this phase, four of my own first-pass corrections were wrong in the same way the originals were: I wrote `kanban add --max-retries` (the subcommand is `create`), `_cmd_diagnostics` at `:629` (it is `:627`), `PlatformConfig`'s `extra:` read at `:437` (that line is `reply_to_mode`; the read is `:419`), and "no darwin zombie detection in Hermes" (`reap_worker_zombies` exists at `hermes_cli/kanban_db_dispatch.py:190` — internal, no wire surface). Quote the line into the artifact before writing the comment; an adversarial re-read of the DIFF, not of the finding, is what caught all four. #verification
- [gotcha] **A past-EOF citation is the cheapest drift alarm there is, and the sweep should start by measuring every cited file.** `gateway/config.py` is 840 lines and carried cites at `:1190`, `:1345`, `:1356`, `:1413`, `:1719`, `:1809`; `plugins/platforms/slack/adapter.py` is 6508 and was cited at `:9058`; `hermes_cli/gateway.py` is 6202 and was cited at `:8958`; `cron/jobs.py` is 3172 and was cited at `:3019` and `:3210`; `gateway/run.py` is 5475 and was cited at `:23923`. One `git show <tag>:<path> | wc -l` per distinct file triages the whole list before any line-by-line work. #verification
- [gotcha] **Config-key precedence moved OUT of `gateway/config.py` into `gateway/config_loader.py`, and that is why every profile-routes cite rotted at once.** The top-level-vs-`gateway.` decision is now a declarative table, `_TOPLEVEL_BRIDGE` (`config_loader.py:70-86`), resolved by `_bridge_lookup` (`:89-108`) whose FOUR modes answer differently: `"presence"`/`"gwdata"` pick the top-level key if the key is PRESENT, `"none"` picks it only if the value is non-None, `"nested"` reads the nested form only. `profile_routes` is `"none"`, `multiplex_profile_allowlist` is `"presence"`. Quoting `config.py:745`'s `data.get("profile_routes")` alone makes it look top-level-ONLY; the nested fallback is upstream in the bridge. Same split for the platform `extra:` bridge: `_SHARED_KEYS` (`:197-213`) → `_bridged_keys` (`:224-236`) → `extra.update(bridged)` (`:283`). #settings #gateway
- [fact] **`checkpoints.enabled` never flipped inside the supported window.** `cli.py` reads `cp_cfg.get("enabled", False)` at v2026.3.30:1163 (0.6.0, the floor), v2026.8.31:5501 and v2026.9.7:2755 — all `False`. Only `max_snapshots` moved, 50 → 20 at v0.13.0 (v2026.9.7:2756 = 20). So `enabled` is an **absent-vs-explicit-false** sentinel (the display layer owns the host default), NOT the "default changed mid-window" sentinel P13 named — two different reasons for the same `Bool?`, and conflating them put a false flip claim in the parser. The "v2 flipped True → False" line in `config_defaults.py`'s comment block is the checkpoint engine's own pre-history, not a Hermes release. #config
- [gotcha] **`--tenant ""` is not "untagged".** `list_tasks` appends `AND tenant = ?` for every non-`None` value (`hermes_cli/kanban_db.py:1472-1479`), so the empty string matches only rows whose tenant IS the empty string. There is no `--tenant` spelling that selects NULL; all-tenants is the flag OMITTED. #kanban
- [gotcha] **Hermes raises where Scarf degrades, and the comment must say which.** A `skills` value that is neither a list nor a string falls through `_normalize_skill_list` to `list(skills)` (`cron/jobs.py:391`), which raises TypeError on a number/bool (and silently returns the KEYS of a mapping), unguarded out through `_apply_skill_fields:403` → `_normalize_job_record:456` → `list_jobs:1851` — so `hermes cron list` fails outright on such a record. Scarf degrades to skill-less ON PURPOSE (read-only viewer; one hand-edited row must not blank the board). Writing that as "Hermes treats it as skill-less" turned a deliberate divergence into a false parity claim. The general rule: when Scarf is more forgiving than Hermes, the comment must name the divergence, not launder it into a mirror. #conventions
- [gotcha] **A defensive clamp's comment must say WHAT it defends against.** `latenessDisplay`'s `max(0, …)` was documented as guarding an early catch-up dispatch; Hermes clamps at the WRITER (`lateness = max(0.0, (now - d.next_run_dt).total_seconds())`, `cron/jobs.py:2972`) before stamping `lateness_seconds`, so no Hermes-authored record is ever negative and the only real threat is a hand-edited `jobs.json`. Same shape as the `is_job_runnable` cite that named `_evaluate_due_job` and a "roster filter" as call sites when neither calls it (real: the claim gate `jobs.py:2509` and the scheduler scan `cron/scheduler_provider.py:261`). #cron
- [convention] **One separator rule per YAML concern, exported rather than re-derived.** `HermesYAML.plainKeySeparatorIndex` (first colon followed by whitespace or EOL) is now `public` so the parser, `GatewayConfigWriter.flowPairSeparatorIndex`'s block sibling, and `PlatformsViewModel.computeConfiguredPlatforms` share it. The VM had been splitting at `firstIndex(of: ":")` while its own comment claimed the separator rule — so `slack:dev: {}` registered a configured `slack` section the file never had. A comment that states an invariant the code next to it does not hold is the most expensive kind of stale comment, because the next reader trusts the comment. #parsing
- [convention] **Every provider-ID lookup resolves raw-then-canonical-alias, with no exceptions.** `overlayMetadata(for:)` was the one path doing a raw-only dictionary hit, so `grok-oauth` (alias → `xai-oauth`, which IS an overlay key) returned nil and `CredentialPoolsView.keyless` reported an OAuth-only provider as key-based. `providerByID` and `validateModel` already had the fallback. Raw FIRST matters: `canonicalProviderID("openai")` is `openrouter`, so a canonical-first lookup would answer differently for an id that is itself an overlay key. #models
- [fact] `"openai-api": "openai"` is Hermes's OWN `PROVIDER_TO_MODELS_DEV` entry (`agent/models_dev.py:110`), not a Scarf extension — the table has grown since the entry was added and a "Hermes has no entry for this" claim is the kind that rots silently, because nothing fails when it becomes false. #models
- [gotcha] **`-only-testing:<Suite>/<swiftTestingFunction>` can select NOTHING and still print `** TEST SUCCEEDED **`.** A revert-proof check run that way passed against deliberately broken code. Run the whole SUITE for the revert check, and confirm the output actually names the test. #testing
- [decision] A doc comment whose subject is a function must live ON that function. `displayCheckpointsEnabled`'s entire per-tag floor walk had drifted up above `displayTelegramRichMessages`, leaving the checkpoints resolver undocumented and the telegram one carrying two lead paragraphs — invisible to the compiler, and the kind of thing only a diff-shaped read finds. #conventions


## Whole-surface remediation — P27 (`scripts/check-hermes-tables.py` hardening)

- [decision] **A table-diff lane has exactly two honest outcomes for a missing input: SKIP or ERROR — never "empty, therefore nothing to compare."** `parse_models_dev_map` returned `{}` both when `agent/models_dev.py` was absent (benign: pre-v0.21 tag) and when `PROVIDER_TO_MODELS_DEV` was present but no longer an `ast.Dict` (a shape change — the exact v0.21.1 `ALIASES` dict-comprehension trap, one table over). Those are now distinct: absent FILE → `None` → SKIP; present-but-unparseable, renamed, or zero-literal-entries → `sys.exit`. The discriminator is the same one Scarf uses everywhere for absent-vs-unreadable. #ops
- [decision] **A skipped lane is not a pass.** Lanes 3/4 need `~/.hermes/models_dev_cache.json`; they used to WARN and the script still printed `OK` and exited 0, so on any fresh machine two of five lanes were silently off behind a green verdict. Skips now print `SKIPPED lane N: <reason>` and exit **2**; the verdict line carries `lanes=N/5`, so `lanes=5/5` is the only result that means the tables were actually checked. `--allow-skip` accepts a partial run — it is an escape hatch for a deliberately-partial host, not a way to clear a release gate. #ops
- [decision] **The script reads Hermes at a TAG by default (`git -C <checkout> show <tag>:<path>`), not the working tree.** A doc comment saying "check the checkout out at the target tag first" is not a guard: the round-2 reviewer's tree was `v2026.9.7-385-g9e6c4100cb` and the script printed OK regardless. `--worktree` opts back in for local work and prints `git describe --dirty` so the run is at least self-describing. Generalizes: any script that judges Scarf against Hermes should take the revision as an argument and read through `git show`, never through the checkout's mutable state. #ops
- [decision] `HERMES_TARGET_TAG` in `scripts/check-hermes-tables.py` is the ONE machine-readable place this repo records the Hermes tag Scarf targets, and the `--tag` default. Nothing else was usable: `HermesCapabilities.swift` records per-flag floors but no single current target, README.md's "Current target" line was stale by two releases (said v0.20.4 while the target was v0.21.1), and the memory/wiki record is a managed tier a script must not grep. Bump it with the capability floors. #ops
- [fact] Listing a directory at a tag is `git ls-tree --name-only <tag>:<dir>` (entries come back bare, directories with a trailing `/` to strip) — the lane-4 plugin walk needed it, and there is no `git show` equivalent. #ops
- [convention] `scripts/tests/` now exists: stdlib `unittest`, run `python3 -m unittest discover -s scripts/tests -t .` from the repo root. The repo's Python scripts had no harness at all before. A hyphenated script is imported via `importlib.util.spec_from_file_location`, and a `scripts/tests/__init__.py` is REQUIRED or discovery refuses the directory as "not importable". Two traps the suite needed: the verdict accumulators are module-level lists, so `main()` clears them (a second call in one process otherwise inherits the first's findings); and the tag-vs-worktree test fixture must deliberately DIVERGE its working tree from the tagged commit, or a test that passes proves nothing about which one was read. #testing

## Whole-surface remediation — P28 (cross-phase review remediation, round 2)

Commits `6a401176`, `bfa41e1f`, `752bbb5b`, `1b4506cb`, `a34839df`, `8e8d124a`,
`aab1d591` on `fix/whole-surface-audit-r2`.

- [gotcha] **A widen-for-current escape hatch is only as real as the predicate
  that feeds it.** P23 gated eight platform rows and relied on
  `isVisible(on:isConfigured:)` to keep a row the user had configured visible
  below its floor — but `isConfigured` came from a detector that recognised only
  a TOP-LEVEL `<name>:` section or a hand-maintained `identifyingEnvVar` arm,
  and every newly-gated row's own Scarf form writes `platforms.<name>.…` nested
  keys or `.env` keys with no arm. So the hatch was structurally unreachable for
  exactly the rows it existed for, and the unit test passed because it called
  `isVisible(isConfigured: true)` directly instead of the production argument.
  **A gate whose escape hatch takes a computed predicate must be tested through
  that predicate, from a fixture the PRODUCING code wrote** — drive the real
  setup form, capture the keys it hands `hermes config set`, render them back
  into YAML, and feed that to the real detector #testing #capability-gating
- [gotcha] **"Not loaded yet" and "nothing found" are the same empty `Set` and
  must not render the same way.** Any async-loaded fact that GATES a surface
  needs a companion "has been read" flag, or the first paint shows the
  not-found rendering and pops. Err toward what the surface rendered before the
  gate existed (treat every row as possibly configured until the read lands) —
  that direction can only ever show a row briefly, never hide the user's own
  config #ui #capability-gating
- [decision] One roster-visibility seam for every surface:
  `KnownPlatforms.visible(on:isConfigured:)`. Two surfaces (Platforms list,
  Tools platform picker) were answering the same question with different rules
  and different configured-ness detectors; the Tools picker shells
  `hermes tools enable --platform <name>`, so its ungated copy offered adapters
  the host does not have (C5). Two ungated `KnownPlatforms.all` accessors with
  no consumers were deleted in the same pass: **an ungated roster accessor left
  in place is the next caller's bug** #capability-gating
- [gotcha] **A sentinel read is worthless without a sentinel WRITE path, and an
  editor that primes a value has already decided to write it.** iOS's quick-edit
  sheet primed `options.first` for an empty (= absent) `approvals.mode` and
  `hasValidValue` was unconditionally true for a picker, so opening the sheet on
  a stock v0.19+ host and tapping Save pinned `manual` over the `smart` the host
  was running. Same shape for `agent.max_turns`, which primes a RESOLVED
  default. The general rule, cheaper than per-key guards: **remember what
  priming produced and write nothing when the control still holds it** — every
  absence-sentinel key then gets the no-pin guarantee for free. Keep priming in
  ONE pure function so the value Save compares against cannot drift from the
  value the control was given #settings #capability-gating
- [gotcha] **Moving a spawn off the main actor moves the moment its handles
  become visible, and every "retire the previous run" path keys off those
  handles.** With `proc.run()` in a detached task, `self.process`/`self.stdoutPipe`
  publish only after the spawn resumes, so a `start()` (or `stop()`) landing in
  that window unhooks NOTHING: the retired run's `readabilityHandler` stays
  live, and a reader that writes into shared state with no generation check then
  feeds the replacement run. The fix is two-sided — give each run its OWN buffer
  (so a stale reader writes where nothing drains) AND unhook the reader in the
  spawn's generation-mismatch branch, which is the only place that window can be
  closed. Also skip the post-spawn handle publish when the run already FINISHED,
  or a fast-exiting child hands the next `stop()` a dead process to reap
  #concurrency #mcp
- [gotcha] The observable symptom of that race is NOT a text leak — the
  mismatch branch terminates the retired child before it can write much — it is
  a premature `markEOF` on the new run's buffer, which collapses P21's
  "judge only after EOF AND exit" into "judge at exit" and reports a successful
  login as failed. Two attempts to pin it by asserting on leaked TEXT passed
  against the broken code; asserting on the INVARIANT (`readabilityHandler` is
  readable — the retired run's must be nil) failed against it immediately.
  **When a race's symptom is timing-dependent, assert the invariant the fix
  establishes, not the symptom it prevents** #testing #concurrency
- [gotcha] **A per-format flag needs a per-format DEFAULT.** `sessions export`'s
  redaction is opt-IN for every streamed format and opt-OUT for `trace`
  (`_export_trace`: redaction ON by default because traces leave the machine —
  `hermes_cli/sessions_cmd.py:382-383`, applied at `:395` @ v2026.9.7). Giving
  `trace` the inverted FLAG while leaving the toggle's default OFF made Scarf's
  default trace export actively emit `--no-redact` — strictly less redaction
  than the prior release. Carry the default in the view model keyed on the
  selected format, remember the user's other-format choice across the switch,
  and keep the rule capability-INDEPENDENT (below the floor the host redacts
  unconditionally, so ON is the truth there too) #sessions #privacy
- [gotcha] A capability doc comment can outlive the knob it describes:
  `hasMCPSSETransport` still advertised an `sse_read_timeout` config key that
  P24 had removed from Scarf in the same branch, because no Hermes version reads
  one — the value is hard-coded (`"sse_read_timeout": 300.0`,
  `tools/mcp_tool_transport.py:352` @ v2026.9.7, same literal in
  `tools/mcp_tool.py` at the v0.13 origin v2026.5.7). **When a phase removes a
  surface because the contract does not exist, the flag's own doc comment is
  part of the removal** (C2) #capability-gating
- [note] Re-flooring a capability flag is a two-file job at minimum: P23 moved
  six floors and P26 swept the citations, yet ten CONSUMER comments (view
  models, views, parsers) still named the old version. Grep the old version
  string repo-wide, not just the flag's own file #conventions
- [note] The whole `scarfTests` target under full parallelism is not a reliable
  signal on this machine: a run can take a Swift `Index out of range` crash in
  an unrelated suite, restart, and cascade ~100 timing failures (10–12 s test
  durations from contention). Every suite passes in isolation. A fresh `git
  worktree` cannot be used to get a base-commit comparison either — the SwiftTerm
  build plug-in needs interactive trust, so `xcodebuild` refuses to build there
  #testing
- [gotcha] **A poll-until-not-loading test must assert that the load FINISHED,
  not just that the deadline passed.** With several `xcodebuild` runs contending,
  a platform-setup form's `loadSnapshot` was measured taking **842 s** for nine
  temp-home round-trips; the 120 s deadline expired and the assertion then read
  the field's UNSET DEFAULT, which looks exactly like the bug the test exists to
  catch. Pair every such wait with a `guard !vm.isLoading else { Issue.record(…) }`
  so starvation reports itself, and assert the pure rule separately from the
  round-trip that exercises it #testing


## Whole-surface remediation — P29 (round 3: the regressions the branch itself introduced)

Round 3 reviewed P18–P28 and found that several phases had broken things while fixing others.
The durable lessons:

- **"The CLI command table says X" is not evidence about the CHAT composer.** Scarf's composer
  speaks ACP, whose slash set is a separate, smaller dict (`acp_adapter/server.py::_SLASH_COMMANDS`,
  `acp_adapter/commands.py` from v2026.9.7). `hermes_cli/commands.py` is the CLI/TUI table and says
  nothing about it — P23 deleted a compress gate on the strength of the wrong file and broke
  thirteen of the sixteen supported releases. **Before removing a gate, confirm which Hermes
  surface the Scarf code actually talks to, and walk THAT file.** (ACP: `compact` ≤ v2026.7.20 /
  0.19.0, `compress` ≥ v2026.7.30 / 0.19.1, no alias either way; an unknown ACP slash command
  is not an error, it falls through to the LLM and silently burns a turn, so there is no runtime
  signal that the spelling is wrong.)
- **A doc comment asserting "I walked all 32 tags" is a claim, not a proof — and two of them were
  false this round.** `hasSessionsExportNoRedact` was floored at v0.21.1 on a walk that missed
  `hermes_cli/main.py:13567` @ v2026.7.7 (0.18.1), and the TESTS encoded the false claim instead of
  catching it. `hasGeminiKittenTTS` cited a constant (`BUILTIN_TTS_PROVIDERS`) that postdates its
  own floor by a release. **When a flag's doc names a walk, re-run the grep at the floor tag and at
  the tag below it before trusting it; a floor whose cited symbol postdates it cannot be
  re-verified from the comment (C2).**
- **A flag whose floor moves must move the tests that pin it — in the same commit.** Re-flooring
  `hasSessionsExportNoRedact` made an existing `#expect(!caps.…)` fail, which is the correct signal
  and is why it is worth re-running the suite after every re-floor.
- **Gate an absence sentinel's WRITE, not just its read and priming.** P28 taught the iOS quick-edit
  sheet to prime the "Host default" row and pinned the priming; nothing exercised Save, so selecting
  that row over a STORED mode wrote `approvals.mode: ''`. That is not an unset —
  `_coerce_config_set_value` keeps the empty string for a str-typed key
  (`hermes_cli/config.py:3306-3312`) and `_normalize_approval_mode("")` resolves it to `manual`
  (`tools/approval_context.py:197-214`) while Scarf's reader drops it and renders "Host default"
  again. **The host-default row writes nothing; clearing a set key needs `config unset`.**
- **When the write/no-write rule lives in a SwiftUI `View` over `@State`, extract it to a pure
  static and test that.** Both iOS sentinel bugs shipped green because `save()` was unreachable
  from a test. Same move for `SkillsViewModel.forceUpdateVerdict`. Pair it with a source-scan test
  asserting the one write site sits behind the guard, so a second path cannot appear silently.
- **Fix a verdict in pairs.** P21 replaced `finishUpdateAll`'s exit-code verdict and left its twin
  `finishForceUpdate` judging by exit code — on the one action that DESTROYS the user's local edits.
  `do_update` and the `do_install(force=True)` it nests are both `-> None`, so
  `Installation blocked:` comes back at exit 0. **Grep for sibling finishers of the same CLI verb.**
- **An exit-0 failure marker set must contain only markers the emitter controls, and only failures
  it can actually reach at exit 0.** `plugins update`'s set carried a bare `Error:` with
  `failureWins: true`, while `cmd_update` prints a post-pull scan report and the raw `git pull`
  output — plugin-authored text. Every other refusal goes through `_fail` → `sys.exit(1)`, so the
  exit code already had them. **Anchoring is the cure on the success side; on the failure side the
  cure is usually DELETION, because the exit code already covers it.**
- **Discriminate in Hermes's own ORDER, not just with Hermes's own comparison.** P24 got the
  `transport == "sse"` comparison exact-case right and still read it FIRST; Hermes gates on `url`
  first (`tools/mcp_tool_health.py:27`, and the status payload at
  `tools/mcp_tool_discovery.py:484`), so a url-less `transport: sse` entry is `stdio` upstream.
- **PyYAML's bool resolver is narrower than a liberal "boolish" helper.** `no`/`off`/`false` (and
  their case variants) load as bools; **`0` and `1` load as INTS**. For a key Hermes reads with
  `isinstance(mode, bool)` that distinction is load-bearing — `approvals.mode: 0` is `manual`
  upstream, not `off`. `HermesYAML.boolishValue` is still the right helper, with the numeric
  spellings carved out and the reason recorded. Always round-trip the spelling list through the
  real PyYAML before encoding it.
- **A "guard" arm added to one of two twin emitters is half a fix.** `YAMLScalar.quoteIfNeeded` has
  had a tab arm all along and `HermesFileService.yamlScalar` did not, so one emitted row quoted its
  KEY for a tab and not its VALUE. A structural verifier cannot catch it: the expected rows come
  from the same emitter, so the literal match succeeds on a file PyYAML rejects.
- **A bounded wait that ends in an unbounded one is unbounded.** `waitUntilExit(timeout:)` polled to
  the deadline then did `terminate(); waitUntilExit()`. Escalate SIGTERM → bounded poll → SIGKILL →
  bounded poll, never a bare wait — and test the overrun arm with a child that IGNORES the signal
  (`sh -c 'trap "" TERM; sleep 30'`); `sleep 30` alone obeys SIGTERM and proves nothing. Guard the
  pid before `kill`: `kill(0, …)` signals Scarf's own process group.
- **`static let` + launch warm-up is not protection from a main-actor read.** A `static let`
  initialiser is a `swift_once`: a main-actor reader arriving mid-warm-up BLOCKS on it. P22 detached
  the load and left `detectSignalCLI()` inside the main-actor apply closure, where it could block on
  `enrichedShellEnv`'s 5 s + 3 s zsh probes. Such a probe needs `nonisolated` and its own detached
  hop, not a warm-up it might lose the race to.
- **A test named for an invariant must assert that invariant, at the CONSUMER.** `sessionsRenameIsUngated`
  asserted an unrelated flag and `detected`; re-adding the gate would have left it green. When the
  ungating lives in a view, the pin belongs in the target that can read the view — a source scan for
  "no `if`/`capabilit` between the `.contextMenu {` and the item" is a legitimate pin.
- **"Each floor is now a shared constant" must be true of ALL of them.** Four of the twelve gated
  roster rows still carried inline `.init(major:…)` literals after the phase that recorded that rule.
  Grep for the anti-pattern, not just for the pattern.
- Stale-citation rot keeps recurring because a later phase's edits shift the offsets a previous
  phase cited. The rule from P28 stands and needs applying EVERY round: grep the old version string
  and the old offsets repo-wide, not just in the flag's own file.



## Round 3 — merge and what the branch taught about itself (2026-09-10)

Merged to `main` as `3e64448e` (`merge(whole-surface-audit-r2)`, 34 commits, P18–P29). Round-3 report: `documents/hermes-v0.21.1-whole-surface-audit-round3.md`; follow-ups P30–P36 (`t-f1f8fe74`, `t-4d0b9fe4`, `t-700f9255`, `t-eff9696b`, `t-069033ec`, `t-602f6b7b`, `t-628227d4`).

- [gotcha] **Which Hermes surface does this Scarf call actually reach?** P23 fixed `/compress` against `hermes_cli/commands.py` — the CLI/TUI table — but the composer talks to `acp_adapter`, whose `_SLASH_COMMANDS` spells it `compact` through v2026.7.20 (0.19.0) and `compress` from v2026.7.30 (0.19.1) with no alias in either direction. A verified citation against the wrong emitter is worse than none: it *looks* like C2 compliance. Before floor-walking a command, find the dispatcher Scarf's transport reaches (ACP vs CLI vs gateway slash) and walk that #verification #capability-gating
- [gotcha] **Four phase agents called failures "pre-existing" without checking main.** Two parity tests were red because of P20's own computed key (P21 said pre-existing), and a P11 test that trapped on `spans[1]` under load took the whole `scarfTests` host down (three crash reports), which P28 and P29 read as "the target is not a usable signal". The rule that survives: a failure is pre-existing only when it reproduces on a `main` worktree (`-skipPackagePluginValidation`, scratch `-derivedDataPath`), and a Swift Testing subscript after a failed count `#expect` must be a `guard` — a trap in one test cascades into every suite still running #testing
- [gotcha] A `-only-testing:<Suite>/<swiftTestingFunc>` filter that matches nothing still prints `** TEST SUCCEEDED **`; a revert check has to run the whole suite and confirm the test count is non-zero #testing
- [convention] Round-3 pre-merge scope was exactly "regressions this branch introduced" (NEW in a reviewer's report); everything PRE or needing a product call was filed, not fixed — merging a branch with known self-inflicted HIGHs is worse than one more phase, but widening pre-merge scope to pre-existing findings never terminates #process
- [decision] The ten product decisions in the round-3 report are open; Alan decides before P30–P36 are scoped #process


## Round-3 product decisions (Alan, 2026-09-10) — binding for P30–P36

Decisions on the ten product calls in `documents/hermes-v0.21.1-whole-surface-audit-round3.md`:

1. **Cron recovery mirrors Hermes's split** (P30): plain Resume for recoverable-error recurring jobs; "Resume & Run Now" only for `once` jobs. A recurring job that went terminal via `completed` gets no button, only a "no future occurrences — edit the schedule" hint. No invented re-arm gesture.
2. **Partly-refused `skills update`** (P31): suppress `is already installed at` from the failure set on the update path only; quote the first real refusal.
3. **Refused `pairing approve`/`revoke`** (P31): judge by the success marker; on refusal keep the row and show a dismissable sticky error quoting Hermes's line verbatim, including the lockout's "clears in ~N minute(s)".
4. **ACP slash roster: full reconciliation** (P34): drop `clear`/`cost`/`reload-skills`/`exit`/`yolo`/`sessions`/`codex-runtime` from the ACP menu; add `reset`/`context`/`version`, each floor-walked in `acp_adapter/`; correct the `hasYOLOSlashCommand` doc.
5. **`max`/`ultra` reasoning-effort floors re-floored to the cited tags** (0.18.1 / 0.19.0) (P35): a permissive rendering change on hosts that accept the value is not a C1 degradation.
6. **Control characters in user-typed YAML scalars are refused** with a visible editor validation error (like `duplicateKey`); everything else routes through `YAMLScalar.quoteIfNeeded` (P32).
7. **`.env` overrides `GATEWAY_MULTIPLEX_PROFILES` / `SLACK_REQUIRE_MENTION` are deferred**: filed as a task, no Settings change this cycle (P32).
8. **Post-load selection reconciliation: snap back** (P35): when the roster narrows after the detached read, clear `selected`/`selectedPlatform` so no sub-floor form is writable.
9. **Forms vs Settings posture: document why they differ** (P33/P35): platform-setup forms are "set up this platform" gestures that write the whole block explicitly; Settings edits single keys and treats absence as a sentinel. Memory note + doc comment, no behaviour change.
10. **"Host default" approvals row wired to `hermes config unset` behind `hasConfigUnset` on both platforms** (P35); below the floor the row stays inert with a hint.


## Whole-surface remediation — P30 (cron recovery semantics, `t-f1f8fe74`)

**What was wrong.** Hermes splits cron recovery three ways and Scarf split it two. `HermesCronJob.isTerminal` (`effectiveState in {completed, error}`) was used as the single gate for every affordance, so:

1. **"Resume & Run Now" was offered for every paused job** (`CronView.swift:596` `if hasCronResumeRunNow, !job.enabled || job.isTerminal`, `BotRoutinesView.swift:129-136`). `rearm_oneshot` re-checks the JOB's own schedule inside `apply` and raises `_REARM_RECURRING_ERROR` — "Cannot re-arm recurring jobs: re-arm is one-shot-only; use plain resume or cron run." — for anything but `once` (`cron/jobs.py:2040-2042`, `:2065-2066` @ `v2026.9.7`), which `cron_resume` turns into exit 1 (`hermes_cli/cron.py:691-695`). Every click on a `0 9 * * *` job was a guaranteed failure.
2. **A recurring job in `state = "error"` had no recovery path**, though `hermes cron resume` genuinely recovers it: `_reject_terminal_activation` exempts `_is_recoverable_error_job` (`cron/jobs.py:1865-1878`, predicate at `:504-522`). Scarf blocked Resume client-side and pointed at the dead-end re-arm above — so every affordance was a dead end. iOS, whose `oneShotIsUnresumable` returns early for any non-`once` schedule, let the CLI decide — so the two platforms disagreed.

**What shipped.**

- `HermesCronJob.isRecoverableErrorJob` — the port of `_is_recoverable_error_job`.
- `HermesCronJob.isRearmableOneShot` — the port of `rearm_oneshot`'s own-schedule guard.
- `CronRecoveryOffer` (new, ScarfCore/Models) + `HermesCronJob.recoveryOffer(hostRefusesTerminalJobs:hostRecoversErrorRecurring:)` — ONE function both platforms' view models delegate to (`CronViewModel.recoveryOffer(for:)`, `BotRoutinesViewModel.recoveryOffer(for:)`, `IOSCronViewModel.recoveryOffer(for:)`), so the Mac detail pane, the Bots routines list and the iOS toggle cannot make different offers again.
- `HermesCapabilities.hasCronRecoverableErrorResume = isV021OrLater`, mirrored onto both VMs by `CronView`, `BotsView` and (new) `CronListView` on iOS, `.onChange` included for the async version probe.
- Decision 1's third arm: a recurring job that reached `completed` gets no button, only "No future occurrences — edit the schedule to run it again."
- LOW: `"Resumed — running now"` → `"Re-armed — will run at the next scheduler tick"` (`rearm_oneshot` only sets `next_run_at`, `cron/jobs.py:2055`, `:2072-2075`; unlike `runNow` this path never follows up with `cron tick`).
- LOW: `HermesCronJob.isTruthyPauseMarker` — Hermes's `_has_pause_marker` is `bool(job.get("paused_at"))` (`:479`), so `""` / `0` / `false` / `[]` / `{}` are NOT markers. Scarf read any non-`null` as one, rendering "paused" for a disabled-but-unmarked job the host would still describe as `scheduled`.

**Floors (walked, not asserted).** All 32 `v2026.*` tags dumped to scratch and grepped:
- `_is_recoverable_error_job` — first tag `v2026.8.31` (0.21.0), last tag without it `v2026.8.27` (0.20.6). At v2026.8.27 the same `update_job` block reads `is_terminal_job(job) and (…)` with no exemption (`:2272-2278`, `:2369-2375`). → `isV021OrLater`.
- `rearm_oneshot` and its `_REARM_RECURRING_ERROR` guard — the function first exists at `v2026.8.27` (0.20.6) and the own-schedule guard is present inside it at that very first tag (`:2467-2471` parsed-schedule arm, and the job-schedule arm inside the loop). So re-arm has NEVER accepted a recurring job on any host that has re-arm, and the restriction needs **no flag** — `hasCronResumeRunNow`'s existing v0.20.6 floor already bounds it.

**NO-OPs, deliberate.**
- `refusesTerminalJobLocally` was NOT loosened. `trigger_job` uses the BARE `is_terminal_job` (`cron/jobs.py:2012`) with no exemption, so Run Now stays refused for a recoverable-error job. The resume gate and the run gate are now deliberately different predicates, with a test (`runNowStaysRefusedForARecoverableErrorJob`) pinning that.
- `HermesKanbanTask` still does not decode `project_id` / `provider_override` (`hermes_cli/kanban_output.py:20,22`). No consumer needs either today, and P18's lesson was that decoded-but-dead keys get deleted. Filed as `t-dafcc4a5`, which also flags `KanbanTenantResolver.swift:7`'s "Hermes Kanban has no `project_id` column" comment as needing re-verification against the tagged schema.

**Tests watched fail before the fix.**
- `HermesCronRecoveryP30Tests.falsyPausedAtIsNotAPauseMarker` — run as a standalone probe against the unmodified model: 5 failures, one per falsy value.
- `CronRecoveryOfferP30Tests` with `recoveryOffer` temporarily rewritten to the pre-P30 Mac rule: `aPausedRecurringJobIsNeverOfferedRearm`, `aRecurringErrorJobIsResumableOnAV021Host`, `aCompletedRecurringJobGetsOnlyTheHint` all fail.
- `macAndIOSMakeTheSameOfferForEveryJobShape` with the iOS VM ALSO temporarily rewritten to its pre-P30 rule (refuse only a terminal one-shot, never offer re-arm): fails on many cells. Two copies of one function pass a parity test trivially — the failure had to be manufactured from the two real old rules to be worth anything.
- `CronViewModelErrorClassificationTests.resumingATerminalJobIsRefusedLocallyOnV0206Hosts` failed on the real change: its fixture is a `0 9 * * *` job in `completed`, i.e. exactly the case that must NOT name "Resume & Run Now". Split into a one-shot case (still names re-arm) and a recurring case (quotes the hint).

**Lessons.**
- **One `isTerminal` is not one gate.** Hermes checks terminality at three call sites with three different predicates; a client that collapses them will always be wrong in at least one direction. When porting a guard, port the CALL SITE's predicate, not the family name.
- **A guard can be checked twice with only one copy mattering.** `rearm_oneshot` tests `kind != "once"` on the parsed `run_at` first — which is always `once` on the `--run-now` path — and again on the job's own schedule inside `apply`. Reading only the top of the function gives the wrong answer.
- **A cross-platform parity test written after unification is a tautology.** It only earns its keep once you have seen it fail against both real old rules; otherwise it is a checkbox test dressed as an alarm.
- **`git show "$t:cron/jobs.py"` inside a shell loop silently ate the `:c`** in this environment, so a tag walk returned all-zeros and looked like "the symbol never existed". Put the path in its own variable (`git show "$t:$P"`) and always sanity-check the walk against the tag you already know has the symbol.


## Whole-surface remediation — P31 (pairing/skills verdicts, argv residue, `t-4d0b9fe4`)

Commits `45ec3777` (verdicts + `--`) and `7abf07c1` (citation + drain) on `fix/whole-surface-audit-r3`.

**What was wrong.** Two `pairing` verbs judged by exit code, and one failure set that could never quote the real reason.

1. **A refused `pairing revoke` deleted the row.** `_cmd_revoke` (`hermes_cli/pairing.py:84-90` @ `v2026.9.7`) is a plain `-> None` reached through a `-> None` `pairing_command` (`:3-19`): `User <id> not found in approved list for <platform>.` (`:90`) exits 0 exactly like `Revoked access for user <id> on <platform>.` (`:88`). Scarf removed the row on `exitCode == 0`, so the refusal was invisible until the follow-up `load(force: true)` put the row back. The comment above that arm — "Only drop the row when the CLI agreed" — described a fix the exit code cannot deliver.
2. **A refused `pairing approve` reported nothing at all.** Same shape: expired/unknown code (`:80`) and rate-limit lockout (`:76-78`) both exit 0, and Scarf set `actionFailed = false` and posted no message. Click Approve, see nothing, row stays.
3. **`parseUpdateReport.failureDetail` was poisoned on every real update** (the P21 regression). `do_update` calls `do_install(..., force=True)` (`skills_hub.py:868`); `do_install` prints `Warning: '<name>' is already installed at <path>` (`:682`) **unconditionally** whenever the lock has an entry — always true for an update — and only THEN checks `if not force` (`:683`). That string was in the shared `skillsInstallFailure` set and `failureDetail` takes the FIRST match, so "Update attempted — …" quoted the warning instead of `Installation blocked:`, and a succeeding update carried a quotable "reason" too. The P21 fixtures omitted the warning line entirely, i.e. asserted on output the emitter cannot produce.

**What shipped.**

- `HermesPairingVerdict.approve/revoke` in `ScarfCore/Services/HermesCLIOutcome.swift` — thin wrappers over `HermesCLIVerdict.judge` with `successAnchored: true` (the emitter indents its lines two spaces, which `significantLines` already trims) and `fallbackDetail: false` (every refusal is followed by a next-step hint, so the last line is chatter).
- Round-3 decision 3: on refusal the row is KEPT and Hermes's line is quoted verbatim into a new `pairingError` sticky banner in `GatewayView`'s pairing section, dismissable via `dismissPairingError()`. The lockout's `Lockout clears in ~N minute(s).` (`:77`) is a SECOND printed line, so `withLockoutCountdown` appends it — quoting only the marker line loses the entire remediation.
- Pairing feedback no longer touches `actionMessage`/`actionFailed` (found in this phase's own fresh-eyes pass): those belong to the service start/stop/restart row, and setting `actionFailed` from a pairing action repainted a stale "Gateway start requested" in red.
- Round-3 decision 2: `HermesCLIMarkers.skillsUpdateFailure` = `skillsInstallFailure` minus `is already installed at` and minus `Use --force to reinstall.` (`:684`, unreachable under `force=True`). The install set keeps both — a plain `skills install` of an already-installed skill genuinely IS refused by that pair. The two sets are deliberately no longer one list.
- Five argv sites gained `--`: `plugins update|remove|enable|disable <name>`, `skills update <name> --force`, `pairing approve|revoke <platform> <id>`.
- LOW: `HermesPluginList`'s `_plugin_status` and `cmd_list` "quotes" re-anchored at v2026.9.7 (`plugins_cmd.py:1290-1293`, `:1324-1331`) — both were paraphrases of the v2026.8.31 shape presented as verbatim Python (C2).
- LOW: `HealthViewModel.dashboardListenerPID` drains its pipe on a background queue concurrently with the wait instead of after it.

**Floors (walked, not asserted).** `hermes_cli/pairing.py` exists at all 32 `v2026.*` tags and both success markers are byte-identical at every one (`Approved! User …` v2026.3.12:74 … v2026.9.7:68; `Revoked access for user …` :86 … :88). The approve refusal gained a prefix at **v2026.8.3** (`Code '<code>' not found or expired…` → `Pairing request or code '<code>' not found or expired…`), so the marker is the tail both spellings share. The lockout branch first exists at **v2026.5.7** and is absent below it, so that marker simply never fires there. No capability flag: the judgement is identical on every supported host (C1).

**Tests watched fail before the fix.**
- `HermesCLIVerdictP31Tests` with the parser reverted to `skillsInstallFailure`: `aBlockedUpdateQuotesTheBlockNotTheAlwaysPrintedWarning` and `aSucceedingUpdateHasNoFailureDetailDespiteTheWarning` fail.
- The same suite with `HermesPairingVerdict` short-circuited to `succeeded: exitCode == 0`: 10 issues across five pairing tests.
- `GatewayPairingVerdictP31Tests` with the VM reverted to the exit-code arm: 7 issues, including `approvedUsers.contains { $0.id == user.id }` — the row-deletion itself.

**Lessons.**
- **A row-restoring reload will pass your test for you.** The first version of `aRefusedRevokeKeepsTheRowAndQuotesHermes` waited on `pairingError != nil`, which pre-fix never arrives — so the gated reload's own 10 s timeout expired first, put the row back, and the deletion assertion PASSED against the broken code. Wait on a signal BOTH the old and the new arm produce (`isBusy == false`) and give the gate a timeout longer than the poll. A gate only removes a race if the wait it guards cannot outlive it.
- **`--` goes last, but flags go before it.** `skills update` was the first site in this codebase where the positional is followed by a flag: `skills update -- <name> --force` exits 2 with `unrecognized arguments: --force`, because argparse reads everything after the first `--` as positional. Verified by replicating the tagged parser in a throwaway `python3 -` rather than by reasoning about it.
- **The zsh `:h` trap from P30 is real and silent.** `git show "$t:hermes_cli/pairing.py"` inside a loop became `.ermes_cli/pairing.py`; always `P=<path>; git show "$t:$P"`.
- **A verdict fix invites a presentation bug.** Routing a new failure into an existing `actionFailed` flag looked like reuse and was actually a second surface's state being flipped from the first surface's code path. A new feedback channel needs its own storage when its lifetime (sticky until dismissed) differs from the old one's.


## Whole-surface remediation — P32 (the last two YAML quoting routines, `t-700f9255`)

**What was wrong.** P19 unified two of Scarf's four quoting routines; the other two stayed, and both claimed to mirror the rule they no longer matched.

1. **`ProfileRoutesWriter.quoted`** (`:211-235`, emitted at `:106/108/116`) — its own comment said it "mirrors `GatewayConfigWriter`'s rule", which since P19 is `YAMLScalar.quoteIfNeeded`. It had no `]`/`}`/`` ` ``/`=`-leading case, no `\t` case, no line-break arm, and `Double(raw) != nil` instead of PyYAML's resolver table. Route Name is free text (`ProfileRoutesSection.swift:330`) and `normalizedRoute()` only `.whitespaces`-trims it, so a name opening with `}` made PyYAML raise and Hermes discarded the ENTIRE config.yaml layer through the bare `except Exception` at `gateway/config.py:773-792` (`yaml.safe_load` at `gateway/config_loader.py:346`) @ `v2026.9.7`. `quotedID` (`:205-207`) hand-rolled `"'\(raw)'"` with the `''` doubling — but no line-break or control guard at all.
2. **`HermesBotProfileYAML.quoted`** (`:867-893`) — doc block: "for ANY input string this returns a single line of valid YAML that PyYAML loads back as that exact string." Leading `]`/`}`/`` ` `` raise, `<<`/`=` are `ConstructorError`, `.inf`/`.nan`/dates/`0b101`/`12_000` retype. Reached by `display_name`, profile `description`, and the bot block's `title`/`description`/`color`/`shape`/`group`. Consequence is the file's own "total metadata loss": `_load_yaml_dict` catches and returns `None` (`hermes_cli/profiles.py:471-480`), `read_profile_meta` hands back empty defaults (`:609-618`), the bot leaves the roster.

**What shipped** (round-3 decisions 6 and 7).

- Both routines **deleted**, not wrapped. Name/platform/profile and every bot scalar go through `YAMLScalar.quoteIfNeeded`; `ProfileRoutesWriter.quotedID` is now a four-line POLICY over it (ids stay quoted even when safe bare, via the new `YAMLScalar.singleQuoted`, which keeps the `''` doubling the hand-rolled version had).
- `YAMLScalar.quoteIfNeeded` gained a control-character arm: a raw C0/C1 control is refused by PyYAML's READER in EVERY quoting style ("unacceptable character #x0001: special characters are not allowed"), single quotes included — so it routes to `doubleQuoted`, which now escapes `\xNN`/`\uNNNN`. **A TAB is deliberately not in that set**: it is legal raw inside both quote styles and illegal only in a plain scalar, which `quoteIfNeeded` already quotes.
- `HermesFileService.unquote` learned `\t`/`\xNN`/`\uNNNN` in the SAME commit (P19's writer-and-reader rule), pinned by an idempotence test, with a malformed-escape passthrough test.
- Decision 6, refuse not reshape: `YAMLScalar.containsControlCharacter(_:allowingLineBreaks:)` plus `HermesProfileRoute.controlCharacterFieldLabel` and `BotDraft.controlCharacterFieldLabel`, wired into both editors' `canSave` and a visible message in the `MCPServerEditorViewModel.duplicateKey` shape.
- LOW L8: `HermesYAML.parseNestedYAML` is now last-wins for the whole re-opened MAPPING (`values`/`maps` as well as `lists`), so a sibling that appears only in the first block no longer renders a value the host does not have.

**NO-OPs, deliberate.**
- **A line break is NOT refused in a bot's Role/`description`** — that field is deliberately multi-line (`BotsViewModel.swift:185-192`), Hermes round-trips real newlines through `yaml.safe_dump`, and `doubleQuoted` represents them losslessly. In Name/Color/Shape a pasted newline is already flattened by `BotDraft.singleLine`, so there is nothing left to refuse there either. Decision 6 is applied to what would actually reach the YAML, not to the raw keystroke.
- Decision 7: the `.env` overrides (`GATEWAY_MULTIPLEX_PROFILES`, `SLACK_REQUIRE_MENTION`) are untouched — `t-1eaf1579`.
- `HermesFileService.yamlScalar` remains a third emission routine; the round-3 M1 tab gap in it was already closed on this branch, and folding it into `YAMLScalar` is a bigger change than this task's HIGHs.

**Lessons.**
- **"Mirrors X's rule" in a comment ages into a lie the moment X is unified.** Both routines named the rule they had diverged from, and both read as compliant. When a shared primitive is extracted, grep for the routines that CLAIM it and delete them in the same pass — P19 extracted `YAMLScalar` and left two files saying they matched it.
- **Deleting a bespoke routine deletes its knowledge unless you move the knowledge first.** `requiresDoubleQuoting`'s doc block held the only written account of the `---`/`...` mid-scalar hazard; it now lives on `YAMLScalar.doubleQuoted`.
- **A control character is not one class.** A tab is legal raw inside both quote styles and fatal in a plain scalar; every other C0/C1 control is fatal in all three. A single "escape all controls" rule would have churned every tab-bearing value into `\t` and needed a reader change for no gain — probe PyYAML per class rather than per family.
- **An always-quote policy is not a quoting rule.** `quotedID` looked like a fourth routine and was really one policy line on top of one; expressing it as `emitted == raw ? singleQuoted(raw) : emitted` keeps the count at one and fixes the `'` doubling for free.



## Whole-surface remediation — P33 (proving the config.yaml read, `saveDirectYAML` on `writeChain`, `t-eff9696b`)

Commits `0e64b7fe` (proven config read), `30616b14` (`saveDirectYAML` on the chain), `871ced40` (the last three ad-hoc spawns + dead code) on `fix/whole-surface-audit-r3`.

**What was wrong.** P22 detached the 15 platform setup forms and proved the `.env` half of their load (`HermesEnvService.loadProven`). The config.yaml half stayed tolerant: `HermesFileService.loadConfig()` returns `.empty` for a file that is there and unreadable exactly as it does for one that is absent, and `EmailSetupViewModel` read `readText(path) ?? ""` for the same reason. So the hole P22 existed to close was still wide open through the other door — a blipped read renders a blank form over live values and `PlatformSetupHelpers.saveForm` publishes those blanks.

`whatsapp_cloud` is the worst case because it is CONFIG-ONLY: access token, app secret and verify token all live in config.yaml, so one failed read plus one Save issued ten `hermes config set` pairs including `extra.access_token ""` and `enabled false`, with no message. `SignalSetupViewModel` and `EmailSetupViewModel` are the same shape with the credentials split across both files.

Separately, `SettingsViewModel.saveDirectYAML` never joined `writeChain` although `runConfigMigrate` does — and the three direct-YAML writers (`agent.reasoning_overrides`, `model_catalog.excluded_providers`, `profile_routes`) are the most damaging thing that can interleave, because each is a read-modify-write of the WHOLE file.

**What shipped.**

- `HermesFileService.loadConfigProven()` + `ProvenConfig` + `HermesFileService.LoadRefusal` — config.yaml's twin of `loadProven()`, built on `GuardedTextFile.load`.
- `FormSnapshot.configFailure` / `loadFailure`, filled from ONE proven read that serves both `config` and `rawConfigText` (they used to be two separate round-trips of the same file that could disagree).
- `PlatformSetupForm.loadRefusal` (a new protocol requirement, one stored property on each of the 15 VMs) — latched by `loadSnapshot` when EITHER half is unproven, and `commitSave` refuses while it is set, re-stating the reason rather than failing silently.
- On a refused config read `snapshot.config` / `rawConfigText` stay `nil`, so a form's `apply` leaves its fields alone instead of resetting them to defaults over values it could not read (`EmailSetupViewModel`'s `skipAttachments` was the concrete case).
- Round-3 decision 9 written into `PlatformSetupForm`'s doc comment and into a memory note (`decisions/setup-forms-write-the-resolved-default-settings-treats`). No behaviour change on that point.
- `saveDirectYAML` now claims `writeChain` in the same shape as `runConfigMigrate`; the body moved to `performDirectYAMLSave`. The guarded lock underneath protects the BYTES from a second PROCESS; the chain is what orders THIS process's own writes against each other, so the two are not redundant.
- `Process.waitDraining(timeout:pipes:)` — `HealthViewModel.dashboardListenerPID`'s concurrent-drain + bounded-wait shape hoisted, and the last three ad-hoc spawns adopted it: `ProjectTemplateService` (`unzip`, 120 s), `ProjectTemplateExporter` (`zip`, 120 s), `AppRelauncher` (`open -n`, 20 s). It owns the READ ends' lifetime — each reading handle is closed by the reader that drained it, because closing a `FileHandle` another thread is blocked reading raises, which is exactly what a caller-side close after a drain overrun would do.
- Dead `SessionsViewModel.runHermes` (zero callers, MainActor-isolated) deleted.

**Why NOT `loadConfigResult()`**, which the finding named. It maps a plain `readFileResult`, so (a) an ABSENT config.yaml and an unreadable one are both `.failure` — refusing to save on the former makes first-run setup impossible — and (b) it judges on ONE read, so a single dropped SSH round-trip reads as damage. `GuardedTextFile.load` already settles both: absence is proved by a failed read AND a failed `stat`, and damage is declared only after a RETRY. That is the same primitive `loadProven()` uses, so the two halves of a form's load are now proved by one rule instead of two.

**Tests watched fail before the fix** (`scarfTests/ConfigReadProofP33Tests`, 6 tests; the three source files stashed and the suite re-run — 5 of 6 failed with 12 issues):
- `whatsAppCloudRefusesToSaveAfterAnUnprovenConfigRead` (5 issues: no failure surfaced, and the ten `config set` pairs including `extra.access_token` went out).
- `signalRefusesToSaveAfterAnUnprovenConfigRead`, `emailRefusesToSaveAfterAnUnprovenConfigRead` (same shape).
- `aDirectYAMLSaveWaitsForAnEnqueuedToggle` and `aToggleIssuedDuringADirectYAMLSaveLandsAfterIt`.
- `aFormOnAnAbsentConfigYamlStillSaves` passes on BOTH sides deliberately: it is the guard against over-fixing absence into a refusal, not a regression alarm.

**NO-OPs, deliberate.**
- **The 15 "Reload" buttons are already `.disabled(viewModel.isBusy)`** — all fifteen views checked line by line. The round-3 LOW is stale; nothing to change.
- **`MCPLoginController.finish()`'s `readabilityHandler` LOW is a false positive.** `finish` is reachable only from `pump`, and `pump` only calls it once `sawEOF` — which is set in the handler's own empty-data branch, immediately after that branch has already done `handle.readabilityHandler = nil`. So the handler is always cleared before `finish` runs, and `finish` seeing a nil `stdoutPipe` (the fast-exit race, where the spawn continuation had not published it yet) is harmless in every path.
- `GatewayBehaviorViewModel`'s runner seam and `!isBusy` guard belong to `t-fc76a90d`, untouched.
- `AppRelauncher.relaunch()` is bounded but still waits ON the main actor; the hop needs `ProfilesViewModel.switchAndRelaunch`'s `MainActor.run` block restructured, so it is filed as `t-b15ba4c3` rather than widened into here.

**Lessons.**
- **Proving one file is the per-writer disease moved to the read side.** `GuardedTextFile` exists because the guard kept getting applied to whichever WRITER someone audited; P22 applied the read proof to whichever FILE it audited. A surface that reads N files and publishes a rewrite must prove all N — the count is the audit unit, not the file that was in the finding.
- **A `Result`-returning read is not a proof.** `loadConfigResult()` looks like the fix and is not one: proof needs the absent/unreadable discriminator AND a retry, and a `Result` over one read has neither. The finding named it; taking the named symbol would have shipped a first-run regression.
- **A refused read must return `nil`, not a default.** Handing `apply` an `.empty` config on a refused read still resets the form — just to Hermes's defaults instead of to blanks. The refusal has to reach the field assignment, not only the save bar.
- **A test that passes on both sides can still be worth writing when it is the anti-regression clamp** — `aFormOnAnAbsentConfigYamlStillSaves` exists precisely because the obvious fix (`loadConfigResult`) breaks it. Say so in the suite comment so it is not mistaken for a checkbox test.
- **`Self.` in a default argument of a `Process` extension does not compile** ("covariant 'Self' type cannot be referenced from a default argument expression") — spell the concrete type.


## Whole-surface remediation — P34 (ACP slash-command roster, `t-069033ec`, commit 99412912)

**What was wrong.** `RichChatViewModel.alwaysAvailableCommands` was assembled from Hermes's CLI/gateway command catalog, not from the surface Scarf's chat transport reaches. Seven rows — `clear`, `cost`, `reload-skills`, `exit`, plus capability-gated `yolo`, `sessions`, `codex-runtime` — are names the ACP adapter has never dispatched at any tag; three real ACP commands (`reset`, `context`, `version`) were missing. Over ACP an unknown name is not an error: `_handle_slash_command` returns `None` and the text falls through to the LLM (`acp_adapter/commands.py:88-95` @ v2026.9.7), so each dead row silently burned a turn. `hasYOLOSlashCommand`'s doc comment said "Available in ACP", which was false at every tag (C2).

**Citations (32-tag walk of `acp_adapter/`).** The whole ACP slash surface is nine names and has been since v2026.3.17 (0.3.0), the first tag that ships an adapter at all (v2026.3.12 / 0.2.0 has none): `_SLASH_COMMANDS` at `acp_adapter/server.py:453-463` @ v2026.7.20 → `SlashCommandsMixin._COMMANDS` at `acp_adapter/commands.py:44-66` @ v2026.9.7, advertised verbatim by `_available_commands()` (`:69-74`). `help model tools context reset version` at every tag; `steer`/`queue` from v2026.5.7 (0.13.0); the compress spelling flips `compact`→`compress` at v2026.7.30 (0.19.1). The dropped names: `cost` has never existed anywhere in Hermes (CLI verb is `usage`, `hermes_cli/commands.py:277` @ v2026.9.7); `clear` (`:58`) and `exit` (`:302-303`, alias of `quit`) are `cli_only`; `reload-skills` (`:259-260`), `sessions` (`:148`), `codex-runtime` (`:156-158`) and `yolo` (`:181`) are CLI/gateway CommandDefs the adapter does not wire.

**What shipped.** Roster is now `/new` (client-side) + `help model tools context reset compact|compress version`; `/steer` and `/queue` continue to come from `nonInterruptiveCommands`. `sessionRequiredCommandNames` reconciled to match. `reset`/`context`/`version` take NO capability flag — they are below the v0.6.0 support floor, so C1 does not apply. `hasACPCompressSpelling` untouched. The three v0.14 flags' doc comments corrected to say CLI/gateway-only with the file's "No consumer" note. Five new tests in `M9SlashCommandTests` (roster equality at v0.21.1; never-dispatched sweep at four versions incl. `.empty`; `reset`/`context`/`version` on every host; every fallback name is dispatched-or-client-side; advertisement-supersedes-fallback ordering), all watched fail first. `v014ConfigCommandsRespectCapabilityGate` asserted the bug and was replaced by `v014ConfigCommandsAreNotInTheACPMenu`; two `SlashMenuLogicTests` that pinned `/clear`/`/yolo` re-pointed at `/reset`/`/context`/`/version`.

**Client-side check (required before dropping any name).** Only `/new` is client-side — `clientSideSlashCommand(for:)` (`RichChatViewModel.swift:1229`) has exactly one case, and the two send paths (`ChatViewModel.swift:1213`, iOS `ChatView.swift:1622`) are its only callers. There is no `/clear` that clears the local transcript and no `/sessions` that opens a sheet; every dropped name really was going to the wire. The new test asserts this both ways.

**Advertisement ordering.** Scarf DOES consume `available_commands_update` (`handleACPEvent` → `acpCommands`), and `availableCommands` dedupes fallback names against it, so the fallback only matters before the advertisement arrives — the `session/load` / cold-start case it exists for. Covered by `advertisedCommandsSupersedeTheFallbackRoster`.

**NO-OPs.** (1) The three v0.14 flags were KEPT rather than deleted despite having no consumer: `HermesCapabilities.swift` already states the convention three times verbatim ("Kept because the floor is source-verified and rediscovering it costs a tag walk" — `hasSubgoal`, `hasGrokOAuthProvider`, `hasNovitaProvider`), and deleting one of three identically-situated flags would be the inconsistent choice. Their four-test coverage in `HermesCapabilitiesTests` stands. (2) The `ScarfDesign` `SlashMenu` mockup still lists `/clear` and `/cost` — a static design-gallery preview, not the live menu; filed as a task.

**Lesson.** "Which dispatcher does this surface reach?" is the first question, and the answer for the composer is `acp_adapter/` — but the second question is "does Scarf reach a dispatcher at all?". `/new` looked like the same class of dead row and is in fact the one legitimately client-side entry. Check the intercept table before deleting.


## Whole-surface remediation — P35 (floors, selection, `config unset`, residue, `t-602f6b7b`)

Commits `b08b2eea` (max/ultra re-floor), `1a41f79f` (selection snap-back), `037a22e2` (Host default → `config unset`), `7e541c29` (one `mcp-tokens/` listing + `sse_read_timeout` residue), `a4bfad1c` (`ALIASES` fall-through, script-test skip policy, three citations), `533de6e0` (self-audit remediation) on `fix/whole-surface-audit-r3`.

- [gotcha] **Two levels added to the same Hermes tuple can have DIFFERENT floors, and one flag for both is a floor claim about the earlier one.** `VALID_REASONING_EFFORTS` gains `max` at v2026.7.7 (**0.18.1**, `hermes_constants.py:794`) and `ultra` one release later at v2026.7.20 (**0.19.0**, `:835-837`, where the tuple wraps to two lines); v2026.7.1 (0.18.0) has neither and v2026.7.7.2 (0.18.2) has only `max`. `HermesReasoningEffort` gated both on `isV020OrLater` behind a doc asserting "the v0.20 additions (#62650)" — a release-note claim, never walked (C2). When a flag covers a SET, walk each member: the floor is per-member until proven otherwise #capability-gating #verification
- [gotcha] **A selection binding that can only SET from the visible list can never CLEAR itself.** Both roster surfaces render every row until the detached read lands (so a configured sub-floor row is not hidden for the first paint), and nothing reconciled `selected`/`selectedPlatform` against the narrowed roster — so a row clicked in that window stayed selected, with `PlatformsView`'s detail pane switching on the NAME with no visibility check and `ToolsViewModel.toggleTool` passing it to `hermes tools enable … --platform <name>` (C5). One pure `KnownPlatforms.reconcile(selection:against:)` beside `visible(on:isConfigured:)`, driven from each view's `.onChange(of: visiblePlatforms.map(\.name))` — which fires both when the read lands and when capabilities arrive. Snap target is `cli`: unfloored, always configured, already both surfaces' initial selection #capability-gating #settings
- [decision] **A "host default" picker row is not inert — it is `hermes config unset <key>`, gated on `hasConfigUnset` (0.19.0).** The P20 rule that such a row writes NOTHING stands for `config set`; the way OUT of an explicit key is `unset`, and leaving the row a no-op reads as a bug on both platforms. Below the floor the row shells nothing and shows `HermesConfigUnset.belowFloorHint(key:)`, which names the host-side edit — Scarf never shells a verb the host lacks (C5). argv `config unset <key>`, one positional, no flags, byte-equivalent at the floor and the target tag (`hermes_cli/subcommands/config.py:51-55` @ v2026.7.20, `:33-34` @ v2026.9.7) #settings #capability-gating
- [gotcha] **`hermes config unset` has an exit-0 refusal, so it must be judged by OUTPUT — and that is true of every `unsetSetting` call site, not just the approvals row.** `unset_config_value`'s managed-install arm calls `managed_error(...)`, which PRINTS `Cannot unset configuration values: …` to stderr and `return`s (`hermes_cli/config.py:3550-3552` @ v2026.9.7, `:8870-8872` @ v2026.7.20) — Python makes that exit 0, so six existing clears (`browser.cloud_provider`, `stt.provider`, two `auxiliary.*.max_concurrency`, two `database.*`) banner'd "Saved <key>" over a key still on disk. Success is the emitter's own `✓ Unset <key> from <path>`, anchored; the other two refusals (`_exit_if_key_managed`, `Config key not set:`) do `sys.exit(1)`. `config set` is the opposite — every refusal exits non-zero — so the exit-code rule stays there and the verdict is a per-verb opt-in (`enqueueConfigWrite(verdict:)`) #verification #settings
- [gotcha] **Ask whether a probe's question can be answered for the whole roster at once.** `loadMCPServers` asked `fileExists` once per candidate basename per server — and `basenames(for:)` returns TWO spellings whenever the name needs sanitizing — so a dozen MCP servers cost up to two dozen serialized SSH round trips in one load. One `listDirectory` of `mcp-tokens/` answers all of them (bare entry names on both transports), and an unreadable directory is an empty set, i.e. the same "no token" the per-path probe gave. The cost was invisible until something could COUNT it: a `HermesFileService(context:transport:)` test seam plus a counting transport decorator #performance #testing
- [gotcha] **"Kept for round-trip fidelity" is only true if something would otherwise rewrite the line.** `HermesMCPServer.sseReadTimeout` was parsed and threaded through two initializers on that reasoning; both writers are line-level patchers over the user's own YAML, so the key survived regardless, and no supported Hermes reads it (`_sse_transport` hard-codes `"sse_read_timeout": 300.0`). Check whether the writer is whole-file or line-level before keeping a field to protect a key #conventions
- [convention] **A skipped TEST is the same lie as a skipped LANE.** P27 made `check-hermes-tables.py` exit 2 on a skipped lane unless `--allow-skip`; its own suite still sat behind `@unittest.skipUnless(_target_tag_available())`, so a machine with no hermes-agent checkout printed OK having exercised none of the five lanes. The missing checkout (and a missing models.dev cache) now FAILS, with `SCARF_ALLOW_SKIP=1` as the test-runner spelling of the flag. Same phase closed lane 1's `ALIASES` fall-through — a shape that is neither the dict literal nor the `_ALIAS_GROUPS` comprehension used to leave `aliases` empty and let `if not aliases: aliases = alias_groups` substitute a DIFFERENT table's contents #testing #verification
- [gotcha] **Inserting a symbol between a doc block and its declaration orphans the doc** — P29 fixed exactly this for the compress helpers and the P35 self-audit caught itself doing it to `saveFailureMessage`. Also caught in the same pass: `arguments.contains("unset")` as the "is this a clear" test, which a `config set model.default unset` would satisfy (now positional). The fresh-eyes pass on one's OWN diff is where both were found, not the test run #conventions

**NO-OPs, deliberate.**
- **Decision 9 (forms vs Settings posture) was already shipped by P33** — `PlatformSetupHelpers.swift:273-277` carries the doc and `decisions/setup-forms-write-the-resolved-default-settings-treats` the note. Nothing to do; verified rather than assumed.
- `PowerSettingsWriter.setReasoningOverrides`/`setExcludedProviders` keep their `isV020OrLater` guard: the `agent.reasoning_overrides` DICT and `model_catalog.excluded_providers` LIST are genuinely v0.20 surfaces. Only the effort VOCABULARY re-floored.
- `valueToWrite` on iOS is untouched. The clear gesture is a separate pure `clearAction` that precedes and returns before the write path, so P29's "the sentinel row writes no scalar" pin still holds unchanged.


**P35 test results.** ScarfCore 2654 (the known `ACPClientStartIdempotenceTests` load flake under full parallel load; 5/5 green in isolation — t-f3820038). Mac `scarfTests` **1052/1052 serial**. iOS `SettingsEditorClearP35Tests` 5/5. `scripts/tests` 18/18, and 3 FAILURES on a machine with no hermes-agent checkout (3 skips + exit 0 with `SCARF_ALLOW_SKIP=1`), which is the point of that change. `check-hermes-tables.py --tag v2026.9.7` → `OK … lanes=5/5`.

- [gotcha] **`AllConfigWritersParityTests` is a real gate and it caught P35 twice.** Moving `unsetSetting`'s inline `["config", "unset", key]` argv into `HermesConfigUnset.argv(key:)` dropped `SettingsViewModel` from 9 non-literal key sites to 8 AND made `HermesCLIOutcome.swift` a config writer that was not in the manifest. Both are the manifest working as designed — a shared argv builder is exactly the shape that can smuggle a key past the read-parity gate — so the answer is registration (1 site, no keys of its own, every caller registered), never a looser scan. Extracting an argv builder means re-balancing that manifest in the same commit #testing #conventions
- [gotcha] **`scarfUITests/SectionSweepUITests.testEverySectionRenders` is RED and pre-existing** — `Activity rendered with an error.banner on screen: Warning` (`ActivityView.swift:97`). Proven by a detached worktree at `99412912` with a scratch `-derivedDataPath`: identical failure. It fails in isolation too, so it is not a load flake. Filed as `t-a9ef75f0` (likely Activity reporting "no state.db in the sweep's isolated home" as a WARNING where the absent/unreadable discriminator says empty state). `ConfigJourneyUITests.testModelPresetCreateAndDeleteWritesPresetStore` failed only in the full run and passes in isolation — load-sensitive, same task #testing


## Whole-surface remediation — P36 (round-3 citation sweep + README target, `t-628227d4`)

Commits `3e68bdad` (citations) and `ca6ae1e8` (README + script test) on `fix/whole-surface-audit-r3`.

**What was wrong.** Two sets of C2 violations, no behaviour involved.

1. **Seven citations the round-3 report named** pointed at line numbers the tagged file does not have, or at files that have never existed: `gateway/run.py:23923` (5475 lines), `gateway/profiles.py:987` (no such path at any tag), `model_switch.py:2007`, `tui_gateway/methods_profiles.py:780-863` (651 lines) and `:789-791`, `profiles.py:980-986`, `tools/tts_tool.py:2100-2170` (682 lines), `xai_retirement.py:110`.
2. **Eleven more that P30–P35 introduced this round**, almost all off-by-one or range-start errors of the kind that survive review because the number *looks* plausible: `cron/jobs.py:504-522` (that is `is_terminal_job`'s def line, not `_is_recoverable_error_job`'s), `:2369-2375` (starts mid-condition), the in-loop re-arm guard cited as `:2469` when it is `:2490-2494`, `hermes_cli/config.py:3550-3552` / `:3581` and their v2026.7.20 twins `:8922` / `:8874-8886` / `:8915-8917`, `subcommands/config.py:51-55` in a 68-line file, and `gateway/profile_routing.py:96-101` (docstring, not the `!=`).

**What shipped.** All 24 re-anchored against the tagged blob, plus three pre-existing siblings of the named items that carried the identical wrong number a few lines away (`HermesBotIdentity.swift:55`, `ProfileRoutesWriter.swift:111`, `BotModePhaseAB0Tests.swift`'s source header). One rationale corrected while re-anchoring it: `_coerce_route_id` (`gateway/profile_routing.py:90-110`, applied `:138-140` @ v2026.9.7) DOES rescue a plain unquoted int at load, so "an unquoted 123 never matches" was false — quoting earns its keep on floats/bools, which Hermes only warns about.

README moved from v0.20.4 (v2026.8.18) to v0.21.1 (v2026.9.7): badge, range line, "Current target", and four new table rows (v0.20.5, v0.20.6, v0.21.0 "Pantheon", v0.21.1). The `/compress` credit moved off the v0.20.0 row onto v0.19.x, where the ACP adapter's rename actually happened.

**Tests.** New `scripts/tests/test_readme_hermes_target.py` (2 tests) ties the README's "Current target" line to `HERMES_TARGET_TAG` in `scripts/check-hermes-tables.py` and requires the row marked "current target" to be that release. Watched `test_current_target_line_names_the_scripts_tag` fail before the edit (`'v2026.9.7' not found in … v0.20.4 "Herald" (v2026.8.18)`). ScarfCore 2654 tests, only the known `ACPClientStartIdempotenceTests` load flake (t-f3820038, green in isolation); `scripts/tests` 20/20; `check-hermes-tables.py` OK lanes=5/5.

**NO-OPs, deliberate.** `hasYOLOSlashCommand`'s "Available in ACP" doc was already fixed by P34 — verified and skipped. `gateway/config.py:773-792` was left alone: the try/except it spans is `:775-790`, so the range is generous rather than wrong. No Scarf version bump and no release notes (release-prep owns those). Citations outside the two named sets were left for the larger sweep.

**Lessons.**
- **The repo had no tie between its human-readable target and its machine-readable one**, so the README drifted three releases. A four-line unittest is enough to make that class of staleness impossible; every fact the repo states twice wants one.
- **A citation drifts by one line more often than by a thousand**, and a plausible-looking number is the hard case: `config.py:3581` vs `:3582` reads fine and is wrong. The only defence is opening the blob — and prose like "prints and RETURNS" pins the exact range, so read the sentence before picking the lines.
- **A wrong citation and a wrong rationale travel together.** Re-anchoring `profile_routing.py` surfaced that Hermes had grown a coercion that made the stated reason obsolete; if the line number had been right nobody would have re-read the function.
- **Named citations have unnamed siblings.** The same wrong number appeared 2–3 more times in nearby files because it was copy-pasted; grep the stale string across the repo before calling a citation fixed.
- **`git show "$T:$P"` needs its path in a variable in zsh** (the P30 lesson, hit again): `git show "$T:gateway/run.py"` silently ate the `:g` and reported a 0-line file.


## Whole-surface remediation — P37 (cross-phase review of P30–P36, `t-0ee45214`)

Commits `43781219` (citations), `d2d6f904` (`/steer` floor + one YAML decoder), `63d78f37` (`config unset` gate), `7d5aa818` (refused read), `c4626b94` + `f9be1120` (effort vocabulary, main-actor sweep), `3d49415e` + `867f1462` (localization + copy), plus the self-audit remediation commit, on `fix/whole-surface-audit-r3`. All 14 findings fixed.

**What was wrong, by class.**

1. **P36's cron re-anchorings never landed in two of the three files, and one replacement was wrong.** `HermesCapabilities.swift:1347` cited `_is_recoverable_error_job` at `cron/jobs.py:504-522` "defined there" meaning at `v2026.8.31` — but `:509-522` is its range at **v2026.9.7**; at v2026.8.31 it is `:664-692` (`is_terminal_job` at `:659`). The v2026.8.27 `update_job` blocks were cited `:2272-2278` / `:2369-2375`, both starting mid-condition: the real `if is_terminal_job(job) and (…)` / `raise` pairs are `:2270-2278` and `:2367-2375`. Each blob opened before writing.
2. **`/steer` was a dead ACP row below v0.13.** `RichChatViewModel`'s roster gated `queue` on `hasACPQueue` and let `steer` fall through `default: return true`, on a comment saying it "works on v0.11+ during an active turn" — a CLI/TUI fact. Walked: `steer` first at **v2026.5.7** (0.13.0), `acp_adapter/server.py:170`, the line ABOVE `queue` (`:171`); `acp_adapter/` at v2026.4.30 has no `steer` anywhere. Over ACP an unknown name is not an error (`commands.py:88-95` @ v2026.9.7), so each click burned a turn. New `hasACPSteer` with the four-test pattern, and `hasACPSteerOnIdle` then EXPRESSED as it (the idle fallback shipped at the same tag, `server.py:812-820`) rather than restating the floor — **the flag was RETIRED outright in round 4** (decision 14, P44): expressing one floor twice is exactly what left the idle-steer grey-out arm unreachable, so both the flag and the arm are gone. **Two existing tests asserted the bug** and now assert the floor (`availableCommandsExposesSteerButHidesV013OnV012`, `SlashMenuLogicTests.availableCommandsHidesQueueOnPreV013`) — P34's exact pattern, one row late.
3. **Three YAML unquote routines, two of them wrong.** P32 moved `ProfileRoutesWriter` onto `YAMLScalar.quoteIfNeeded` and left the reader on `HermesYAML.stripYAMLQuotes`, which returns a double-quoted BODY verbatim — so a route name with a backslash came back doubled and grew one `\` per save. Collapsed into ONE `YAMLScalar.unquote` carrying PyYAML's whole table, with `HermesFileService.unquote` / `HermesBotProfileYAML.unquote` as forwarders. That also closed the hex hole: `HermesFileService`'s copy had no `allSatisfy(\.isHexDigit)`, so `\x+9` decoded to a TAB.
4. **Six `unsetSetting` rows shelled a verb below its floor.** P35 gated only `setApprovalMode`. The gate now lives INSIDE `unsetSetting(_:capabilities:)` with `capabilities` REQUIRED, so the compiler asks before anything can be cleared.
5. **A refused `.env` read blanked the form.** `loadSnapshot` latched the refusal and then called `apply(snapshot)` anyway; on `envFailure` the snapshot's `env` is `[:]`, so every `env["…"] ?? ""` overwrote a live credential on screen.
6. **`AuxiliaryReasoningEffort` was a second effort vocabulary** behind a doc still crediting "v0.20.0" for `max`/`ultra` after P35 walked them to 0.18.1 / 0.19.0. Retired; the picker reads `HermesReasoningEffort.levels(capabilities:)`. The narrowing is MOOT rather than missing — `hasAuxiliaryReasoningEffort` is itself 0.19.0, the tag that added `ultra` — and the doc now says so with the tags.
7. **`doubleQuoted`'s comment said a tab stays raw** while the `< 0x20` arm spelled it `\x09`. Now `\t`, which is also PyYAML's own spelling (`yaml.safe_dump("a\tb")` → `"a\\tb"`, probed).
8, 10, 12, 13, 14. `/clear` dropped from a doc; 40 bare `skills_hub.py` citations qualified as `hermes_cli/skills_hub.py` (a sibling `tools/skills_hub.py` exists at the same tag, so the bare path was genuinely ambiguous); the hex guard; route-editor copy matched to `BotEditorSheet`'s "a tab or a control character" — it named a subset of what the editor rejects.
9. Nine catalogue keys, `CronRecoveryOffer`'s two hints moved onto `String(localized:)`.
11. **`parseNestedYAML`'s last-wins purge fired on EVERY section header** while its comment said a fresh one was a no-op. It was not: a flat dotted key (`gateway.enabled: true`, which PyYAML keeps ALONGSIDE a `gateway:` mapping) matches the `gateway.` descendant prefix, so the first opening of `gateway:` deleted it.

**Tests watched fail before the fix** (all by reverting the fix in place, then restoring): 8 issues across `aSignedHexBodyIsNotAValidEscape`, `afreshSectionHeaderDoesNotPurgeAFlatDottedSibling`, `profileRoutesRoundTripEveryHostileScalar`, `availableCommandsHidesBothSteerAndQueueOnV012`; `aTabIsEscapedAsBackslashTNotAsAHexByte` on its own revert; 17 issues across `noClearRowShellsConfigUnsetBelowTheFloor` (all six rows) and `theSharedHelperIsTheGate`; `telegramKeepsAPrimedTokenAfterARefusedEnvRead` (2); `theAuxiliaryTabHasNoSecondVocabulary`; the C10 sweep against a planted probe type.

**P37 test results.** ScarfCore 2667. Mac `scarfTests` 1061/1061 serial. iOS (`scarf mobile`) builds. Known load flakes, each green in isolation: `ACPClientStartIdempotenceTests` (t-f3820038) and, once, `M0bTransportTests.localTransportRunProcessDrainsLargeStdoutAndStderr` (a 10 s drain timeout under full parallel load).

**NO-OPs, deliberate.**
- `HermesYAML.stripYAMLQuotes` was NOT folded into the shared decoder. It reads arbitrary HERMES-written config values, where widening the rule would change the meaning of every unrelated `\` in the file. The shared decoder is for the blocks Scarf both reads AND writes. `ProfileRoutesYAML`'s `multiplex_profiles` read also stays on `normalizedScalar`: no token that resolves to a bool or to null carries an escape, so the full decoder would answer identically while widening the rule for a value Hermes also writes.
- The `DispatchGroup.wait` / `DispatchSemaphore.wait` family was left out of the C10 sweep's primitive set. Nine sites, most legitimately off-main; extending the scan needs a triage pass first (noted in `t-cd9fd829`).

**The self-audit found three defects in this phase's own diff, and it found them after the tests were green.**
- [gotcha] **A guard on the UNION of two refusals suppresses the proven half.** P37's first fix skipped `apply` on `loadFailure`, which is `envFailure ?? configFailure` — so a form whose `.env` read succeeded and whose config.yaml did not rendered nothing at all, and a FIRST load showed an empty form over a credential it had just read successfully: finding 5's own failure mode through the other door. The halves are not symmetric and the guard belongs on `envFailure` alone: `config`/`rawConfigText` are `nil` on a refusal and every form's `apply` already opens with `guard let cfg = snapshot.config?.<platform> else { return }`, so the config half declines itself; `env` is `[:]`, which is indistinguishable from "nothing is set yet" #verification
- [gotcha] **Tracking "headers opened" is not tracking "paths written".** The P37 purge guard recorded only SECTION HEADERS in `openedPaths`, but the inline-flow-list branch writes `lists[path]` and `continue`s — so `toolsets: [hermes-cli]` followed by `toolsets:\n  - browser` read as a first open, the purge was skipped, and the two lists CONCATENATED where PyYAML is last-wins. Renamed to `writtenPaths` and recorded at every branch that assigns at `path`, which is what "this key appears twice" actually means. A guard added to narrow a purge has to be keyed on the same event the purge is about #yaml #verification
- [gotcha] **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes an `@MainActor`-seeking scan test a no-op.** The full lesson, with the hit-count rule and the indent-based enclosing-declaration walk, is in `conventions/a-source-scan-test-must-be-calibrated-against-the-target-s`. The corrected sweep immediately found a second real violation, `HealthViewModel.dashboardListenerPID`'s `lsof` wait (`t-cd9fd829`) #concurrency #testing

**Other lessons.**
- **`swift build` is not a check for a ScarfCore TEST edit.** It builds only the library; a Mac `-only-testing` run compiles only the Mac test target. A `#expect(x, someString)` that needs a `Comment` got committed and broke `ScarfCoreTests` between two green-looking runs. For a ScarfCore test edit the check is the full `swift test`.
- **"Leave the new strings untranslated, translations are a separate pass" is not a judgement call here — the repo has a gate.** `LocalizationCatalogTests.everyTranslatableKeyIsLocalized` requires all six shipped locales for every key that is real UI prose, with exactly three allowed holes. All nine new keys were offenders and needed real de/es/fr/ja/pt-BR/zh-Hans values, each keeping its `%@` order so no positional specifiers are needed.
- **Probe PyYAML rather than quoting a reviewer about it.** The self-audit reported that PyYAML "always" writes U+0085/U+2028/U+2029 as `\N`/`\L`/`\P`, which would have made a Hermes-dumped bot description unreadable. Under `allow_unicode=True` — what `utils.atomic_yaml_write` passes (`utils.py:271` @ v2026.9.7) — it emits them RAW inside single quotes. The four mnemonics are still decoded (PyYAML's READER accepts them, so a hand-edited file can carry them) but the comment says what the writer actually does.
- **A citation the review calls wrong can be wrong in a way the review did not name.** Finding 1 flagged `:504-522`; opening the blob showed `:509-522` is the v2026.9.7 range and the doc's "there" meant v2026.8.31, where it is `:664-692`. The fix was a different number than either the code or the finding had.


## Whole-surface remediation — P38 (round-4 NEW findings fixed pre-merge, `t-79143f86`)

Round 4 audited the branch's OWN work (P30–P37) and found 25 defects it had introduced. All 25 are fixed here, in six commits (`ea65ff90`, `fa4d1414`, `87f0ca40`, `43b594bd`, `e9055e55`, `6db90fe2`). Nothing marked a pending product decision was implemented.

**What was wrong, by surface.**

*Cron (P30 residue).* P30 unified the recovery offer and then contradicted it in four places. (1) The dead-end hint said "edit the schedule to run it again" — an edit Hermes REFUSES on a `completed` job: `_apply_schedule_update` writes `next_run_at` for any record whose `state != "paused"` (`cron/jobs.py:1899-1910` @ v2026.9.7) and the second `_reject_terminal_activation` (`:1965`) raises on exactly that. (2) The Mac row context menu read `job.enabled` raw — a FOURTH offer site P30 never unified. (3) iOS's `setEnabled` consulted `oneShotIsUnresumable` BEFORE the shared offer, and that predicate is true for every terminal one-shot, so `terminalRefusalMessage`'s `offer.canRearm` branch was dead code: iOS said "duplicate it" where the Mac said "Resume & Run Now". (4) `friendlyCronFailure` named "Resume & Run Now" for every terminal refusal, recurring included.

*Settings/YAML (P32/P35/P37 residue).* `parseNestedYAML`'s last-wins purge removed the earlier block's DESCENDANTS but not its own `values[path]`/`maps[path]`, so `sharedPlatformScalar`'s `maps[section]?[key]` fallback still read the FIRST `slack:` block. The descendant sweep also ate a flat dotted sibling on a RE-open (P37 had fixed only the first-open case). The "nothing stored → no-op" guard existed only in `setApprovalMode`; six other clear rows got a red "Couldn't clear" for a key already absent. `BotDraft.controlCharacterFieldLabel` omitted `groups`/`legacyGroup`, both emitted through `quoteIfNeeded`.

*CLI verdicts (P31/P33/P35/P37 residue).* Two doc comments written this branch claimed "every `config set` refusal `sys.exit(1)`s" — false. `HealthViewModel.dashboardListenerPID` still hand-rolled the drain routine `Process.waitDraining` had been hoisted OUT of it in P33. Three citations were wrong.

*Capabilities/chat (P34/P37 residue).* Five stale doc comments and one unread function parameter; one test that checked against a cross-version union it could never fail against.

**What shipped.**

- `CronRecoveryOffer.noFutureOccurrencesHint` → "This job has no runs left — duplicate it to schedule a new one.", plus a `noFutureOccurrencesHint(repeatTimes:)` overload that names the exhausted limit (`_advance_after_run` retires a recurring job as `completed` at `repeat.completed >= times`, `:2192-2215` — the common way a recurring job dies). New `pastDeadlineOneShotHint`. Three new catalogue keys in all six locales; the old key removed.
- `HermesCronJob.isPastDeadlineOneShot(now:)` — the non-terminal half of `oneShotIsUnresumable`, which is now literally `kind == "once" && (isTerminal || isPastDeadlineOneShot)`.
- `recoveryOffer`'s THIRD door, gated on the new `HermesCapabilities.hasCronPastOneShotResumeRefusal` (`isV0181OrLater`). Mac, Bots and iOS all inherit it, which also closes C10 reviewer M6 (the Mac had no pre-refusal here and got `resume_job`'s raw exit-1 ValueError). The flag is mirrored at all four sites with `.onChange`, as P30's two are.
- `CronRecoveryOffer.refusesResume` — the predicate BOTH platforms' gates key on. Deliberately excludes `.none`, so iOS's idempotent `setEnabled(enabled: true)` on a healthy job still round-trips.
- `CronViewModel.resumeRefusalMessage` / `IOSCronViewModel.resumeRefusalMessage` — one entry point per platform for both refused shapes, with a test asserting they name the same affordance.
- `friendlyCronFailure(_:offer:)`; `runAndReload(_:success:job:)` threads the job at all five cron call sites.
- `parseNestedYAML`: purge `values[path]`/`maps[path]` too, and exempt `dottedLiteralPaths` (a path whose LEAF key literally contains a `.`) from the descendant sweep.
- `unsetSetting(_:capabilities:isStored:)` — `isStored` REQUIRED, for the same reason `capabilities` became required in P37.
- `dashboardListenerPID` → `lsof.waitDraining(...)`, `nonisolated`; `t-cd9fd829` closed; the `HealthViewModel.swift` allowance removed from the P22 sweep.
- The P22 sweep grew three things: an `isRunning`-spin matcher (the BODY decides — an `await Task.sleep` loop is correctly not a finding), a `DispatchSemaphore`/`DispatchGroup` `.wait(` matcher, and `allowed` as `[String: (path:, task:)]`. Its "allowance is still REAL" check is now isolation-based (did the sweep reach it?) rather than substring-based.
- `HermesP38SourceSweepTests` — `try! #require` repo-wide, subscript-after-count-expect scoped to the 17 phase suites, and every `*SetupViewModel` reading `snapshot.env` under the shared `envFailure` guard.
- 19 `try! #require` sites fixed across 5 files.

**Floors (walked, not asserted).**
- `resume_job`'s `"Cannot resume: one-shot time … is in the past"` — grepped across all 32 `v2026.*` tags: first tag `v2026.7.7` (0.18.1), last without it `v2026.7.1` (0.18.0). → `isV0181OrLater`.
- `pairing approve`'s refusal prefix — `v2026.7.20:95` has the bare `Code '<c>' not found…`; `v2026.7.30:100` has `Pairing request or code '<c>' not found…`. The branch (and the memory note) said v2026.8.3.
- `max` at `hermes_constants.py:794` @ v2026.7.7 (0.18.1); `ultra` at `:835-837` @ v2026.7.20 (0.19.0).
- `steer`/`queue` at `acp_adapter/server.py:170-171` @ v2026.5.7, absent at v2026.4.30.

**NO-OPs, deliberate.**
- No Duplicate button on the cron dead-end hint (pending product decision) — copy only.
- No output verdict for `config set`, though its managed-install exit-0 arm is now DOCUMENTED at both doc sites (`hermes_cli/config.py:3450-3452`, `managed_error` `:453-455`). Pending product decision, tracked as `t-ba727c07` ("Audit P39").
- The subscript-after-count sweep is scoped to the phase suites, not repo-wide: a full run reports ~100 pre-existing sites. Filed as `t-f43f0af5`.

**Tests watched fail before the fix.** `HermesCronRecoveryP38Tests` against a reverted offer (11 issues); `M5FeatureVMTests.p38*` against the pre-P38 iOS gate (6 issues / 3 tests); `CronRecoveryP38Tests` against the pre-P38 Mac wording, gate and menu (9 issues / 3 tests); `HermesP38YAMLPurgeTests` against the pre-P38 purge (6 issues / 4 tests); `HermesP38ClearRowNoOpTests` + `HermesP38BotGroupControlCharacterTests` against the removed guard and group checks (13 issues / 5 tests); `noNewSynchronousWaitRunsOnTheMainActor` with `nonisolated` reverted; `everyFallbackNameIsDispatchedOrClientSide` with the compress row hardcoded (8 issues, invisible to the old union); and each of the three P38 source sweeps against its own reverted fix.

**Lessons.**

- [gotcha] **A remedy in a hint is a claim about Hermes and needs the same citation as a verb.** "Edit the schedule to run it again" read as harmless UI copy and was actually a guaranteed exit 1: `update_job` re-arms `_reject_terminal_activation` AFTER `_apply_schedule_update` has written `next_run_at`, so the very edit being suggested is what trips the guard. Copy that names an action is an argv claim #verification #cron
- [gotcha] **A pre-check placed AHEAD of a shared decision silently deletes branches of it.** iOS's `oneShotIsUnresumable` ran before `recoveryOffer` and returned true for every terminal one-shot, so the offer's `canRearm` arm was unreachable — and the cross-platform parity test still passed, because it compared the two `recoveryOffer` calls and never went through either VM's actual GATE. Unify by making the shared function the FIRST thing each gate consults, and test the gate, not the helper #testing #cron
- [gotcha] **`!canResume` is not "refused".** The healthy-running-job offer (`.none`) also has no resume door, so the obvious gate would have broken `setEnabled`'s documented idempotence. A tri-state needs its own named predicate (`refusesResume`), not a negation #swift
- [gotcha] **A cross-version UNION can never fail.** `acpDispatchedNames` held both `compact` and `compress`, so a roster offering the wrong spelling at a version passed. Any "is this name valid" set built across tags has to be a FUNCTION of the version #testing #verification
- [gotcha] **An allowlist entry validated by substring outlives the debt.** The P22 sweep checked `src.contains("waitDraining(")` to prove an allowance was still real — but the fix for that allowance was `nonisolated`, which leaves the substring. Validate an allowance by re-running the SWEEP against it, not by looking for the shape it allows #testing
- [gotcha] **A multi-line declaration signature defeats an indent-walking source scan.** The walk landed on the signature's closing `) throws -> String {` and refused to look at the `private nonisolated static func` line that opened it, because it was not strictly LESS indented — two already-`nonisolated` helpers were reported as C10 offenders. Keep walking at the same indent until a line that actually starts a declaration #testing
- [gotcha] **A marker built from two adjacent f-string literals is invisible to grep and identical when printed.** The cron lockout sentence is one string at v2026.9.7 and two at `v2026.8.31:91-93`; grepping the tag walk says "absent" while the emitted line is byte-identical. Floor-walk a MARKER by what it prints, never by whether the source holds it contiguously #verification
- [gotcha] **Last-wins over a mapping is not last-wins over a key prefix.** PyYAML replaces a duplicated `gateway:` mapping outright but keeps a flat dotted `gateway.enabled: true` as an INDEPENDENT top-level key — `{"gateway": {"port": 2}, "gateway.enabled": true}`. A purge keyed on the `gateway.` prefix eats the sibling; the flat key has to be tracked as such #yaml
- [convention] A sweep that fails on day one is a sweep somebody disables. Scope a newly-added source rule to the code the phase owns, file the backlog as a task, and assert the scope list still resolves so it cannot rot #testing
- [fact] The `main`-worktree rule paid for itself again: the full parallel `scarfTests` host was red in 25 tests on the branch and **34 on a `main` worktree under the same load** — a strict superset, including `HermesP28CrossPhaseRemediationTests` and `SettingsP20ConfigDefaultsTests`, which were GREEN on the branch. The load-sensitive set is now five suites, not four: add `SessionDeletedSignalTests`, `ChatViewModelMismatchChooseModelTests` and `PermissionApprovalEditShapeTests` to the list the phase preamble names (all 47 of their tests pass in isolation) #testing


## Round 4 — merge of P30–P38 and what this branch taught (2026-09-11)

Branch `fix/whole-surface-audit-r3` (P30–P38, 34 commits) merged to `main` with `merge(whole-surface-audit-r3)`. Round-4 report: `documents/hermes-v0.21.1-whole-surface-audit-round4.md`; follow-ups P39–P44 (`t-ba727c07`, `t-1559ec68`, `t-f3ffabf9`, `t-8e9ddad0`, `t-e23f78e6`, `t-83c1e3b5`) with sixteen product decisions open for Alan.

- [gotcha] **The exit-0 refusal is a family, not a case.** `is_managed()` makes `config set`, `config unset` and `save_config` print-and-return at exit 0 (`hermes_cli/config.py:3450-3452`, `:3549-3551`, `:2315-2318` @ v2026.9.7), and `save_config`'s callers (`plugins enable/disable`, `mcp remove`, `skills trust`) print their own success line afterwards. Judging one `-> None` handler per phase (P9, P21, P31, P35) never converges; enumerate every handler Scarf shells from the tagged source once and judge them all #verification
- [gotcha] **A fix in the app target does not reach its ScarfCore twin.** P33's `Process.waitDraining` fixed three app spawns while `RemoteRestoreService`/`RemoteBackupService` keep the identical unbounded wait and cannot see the helper; P32 unified three YAML emitters and left `HermesFileService.yamlScalar` with the same control-character hole. When a fix names a primitive, grep BOTH targets for the shape before calling it done #process
- [gotcha] **A hint can be a dead end as surely as a button.** P30's "edit the schedule" copy named the one gesture Hermes refuses on a `completed` job (`_apply_schedule_update` writes `next_run_at`, `update_job` raises at `cron/jobs.py:1965`). Copy that names a remedy has to be walked like a button #cron
- [gotcha] **The false claim written while fixing its twin.** P35/P37 fixed `config unset`'s exit-0 arm and wrote "every `config set` refusal `sys.exit(1)`s" into two doc comments — false at every tag from v2026.3.28. A doc comment that asserts the sibling is safe is a claim that needs its own citation #verification
- [gotcha] **A sweep that adds a path prefix is not a walk.** P37 qualified `skills_hub.py` citations without opening the blob; seven line numbers in two clusters stayed wrong. The same rule as "walked all tags": open the tagged file for every number you touch #verification
- [convention] **The test-host stability rule needs a scan.** Two P35 tests violated it (`servers[0]` after a count expect; `try! #require`); P38 added a source sweep over the phase suites and found ~100 pre-existing sites repo-wide (`t-f43f0af5`). A rule that lives only in memory is re-broken by the next phase #testing
- [gotcha] **A grep across tags can say "absent" for text that is emitted byte-identically** when the source splits an f-string across adjacent literals (the pairing lockout line below v2026.9.7, `v2026.8.31:91-93`). When a marker "disappears" at older tags, read the print site before concluding #verification
- [fact] The Hermes checkout used for tag walks is `~/.hermes/hermes-agent` (fetch done; never touch its working tree). The compatibility-target note's older pointer to `~/Developer/ScarfBox/Vendor/hermes-agent` is stale and sent the round-4 memory auditor to the wrong path #operations
- [fact] Load-sensitive Mac suites under the full parallel run are five, not four: `ACPClientStartIdempotenceTests`, `ChatViewModelStartLifecycleTests`, `ScarfMiniAppBridgeTests`, the ACP `session/cancel` suites, `M0bTransportTests` — all green in isolation and on a serial `-parallel-testing-enabled NO` run, which is the usable signal #testing
- [decision] The sixteen product decisions in the round-4 report are open; Alan decides before P39–P44 are scoped #process



## Round-4 product decisions (Alan, 2026-09-11) — binding for P39–P44

Decisions on the sixteen product calls in `documents/hermes-v0.21.1-whole-surface-audit-round4.md`:

1. **Managed hosts: both** (P39). A shared `is managed by` refusal marker in every config-mutating verdict with `failureWins`, AND a connect-time probe of `$HERMES_HOME/.managed` (`get_managed_system`, `hermes_cli/config.py:276-290` @ v2026.9.7) that renders write surfaces read-only behind one banner. Env-var-only (`HERMES_MANAGED`) hosts fall through to the marker.
2. **Gateway verdicts claim the real state** ("Gateway started/stopped"); Stop on a profile with nothing running is a success with a neutral "nothing was running" note (P40).
3. **`plugins update` disabled by the security scan is a third state**: "Updated, then disabled by the security scan", quoting Hermes's reason line (P40).
4. **`config migrate` button is hidden**; the pane points at running it in a terminal on the host (P40). No piped defaults.
5. **Duplicate button** for a `completed` recurring job: an ordinary create pre-filled from the record (P42).
6. **iOS gets re-arm**: `cron resume --run-now` wired into `IOSCronViewModel` through the shared offer (P42).
7. **`--flag=value` at every user-text option site** in cron and kanban builders; no input refused (P42).
8. **Fleet-copied monitor jobs are skipped and surfaced** like `no_agent` jobs (P42).
9. **Control-character refusal extended** to the MCP entry editor and the reasoning-override pattern field; `HermesFileService.yamlScalar` forwards to `YAMLScalar.quoteIfNeeded` (P41).
10. **The three Scarf-written blocks move onto `YAMLScalar.unquote`** via per-key opt-in inside `parseNestedYAML` (P41).
11. **Bot model-pin clears gated on `hasConfigUnset` and output-judged** through `HermesConfigUnset` (P39).
12. **Typed sub-floor `/steer`/`/queue`: gate the chip, send as a plain prompt with a normal working indicator, and show a one-line notice** (P44).
13. **Effort level above the host's floor: widen the picker AND show a "not supported on this host" affordance** (P44) — not the bare widening the reviewer recommended.
14. **Retire the unreachable idle-steer arm** and its six-locale string (P44).
15. **`Process.waitDraining` hoisted into ScarfCore now**; `RemoteRestoreService`/`RemoteBackupService` converted with named timeouts (P43).
16. **`enforceArchiveBounds` refuses** when the listing cannot be read (P43).

## Whole-surface remediation — P39 (managed-install refusals, `t-ba727c07` + `t-32794e9f`)

Commits `8f92f236` (the fix) and `5b81476b` (the fresh-eyes pass on its own diff) on
`fix/whole-surface-audit-r4`. Round-4 decisions 1 (BOTH halves) and 11.

Full detail: [[A managed Hermes install refuses every config write at exit 0 — one marker, five verbs, one probe]].

- [gotcha] **Enumerating the arms is what makes the verdict safe, not just complete.** `config set` has NINE refusal arms (`config.py:3445-3527`); only two (`is_managed()` at `:3450-3452` and the `.env` branch's `_env_write_blocked`) can land at exit 0. The other seven all `sys.exit`, so the exit code covers them — which is exactly why the marker list can stay short and anchored instead of trying to quote arbitrary `ValueError` text. The enumeration told us *which* arms need markers, not just *that* some do #verification
- [gotcha] **`memory off` was a fourth `save_config` door nobody had filed.** It was found by walking `enqueueConfigWrite`'s callers when the `verdict` parameter became required, not by any finding. Making a wrong default REQUIRED is how the remaining doors announce themselves — the same move P37 made with `capabilities` and P38 with `isStored` #verification
- [gotcha] **A test fake that returns `("", 0)` is a refusal now.** Six existing suites passed `output: ""` for `config set` because the exit code was the whole verdict. Under an output verdict that is the C5 "exit 0 with no success line" case. Fixtures for an output-judged verb must print the emitter's own line #testing
- [fact] **The `hasConfigUnset` gate on the bot path is MOOT, and that is pinned rather than commented.** `hasBotMode` is v0.20.3 and `hasConfigUnset` is v0.19.0, so no host reaches a bot's config surface without the verb. The guard is in `BotAgentConfigService.unsetValue` anyway (P37's reason), and `BotAgentUnsetP39Tests.theConfigUnsetFloorIsMootUnderBotModeButStillStructural` asserts the implication so the day it stops holding is a test failure #capability-gating
- [done] **`t-32794e9f` folded in.** `config check` (`_cmd_config_check`, `config.py:3693-3720`) is read-only — no `is_managed()` arm, no mutation — so its exit code is sufficient and `runConfigCheck` is unchanged. `config migrate` (`_cmd_config_migrate`, `:3653`) DOES reach `save_config` and refuses at exit 0, but round-4 decision 4 hides the button entirely and P40 owns that.
- [todo] **Left for others**: the `mcp remove` verdict (P40 owns it; `managedRefusal` is in `HermesCLIMarkers` waiting for it), gating the project-skills trust bar on the verb's v2026.8.16.2 floor (`t-74df283e`), and extending the read-only lock past Settings to the other config-mutating panes (`t-8f55df7d`).

**P39 test results.** ScarfCore **2718** (4 known `ACPClientStartIdempotenceTests` load flakes under
full parallel load; 5/5 green in isolation — t-f3820038). Mac `scarfTests` **1092/1092 serial**.
`scarf mobile` builds. **46 new tests in six suites across THREE files** (the suite name is not the
file name here): `HermesConfigSetP39Tests.swift` carries `HermesConfigSetP39Tests` (25) and
`BotAgentUnsetP39Tests` (3); `HermesManagedInstallP39Tests.swift` carries
`HermesManagedInstallP39Tests` (8); the Mac's `HermesManagedRefusalP39Tests.swift` carries
`HermesManagedRefusalP39Tests` (7), `BotAgentClearPinP39Tests` (4) and
`QuickCommandFailureAttributionP39Tests` (2). Each watched fail against its reverted fix.

## P39b — the round-4 review of P39's own two commits (`1f384a84`)

Nine findings from an independent audit of `8f92f236` + `5b81476b`. All nine fixed in one commit.

- [gotcha] **An unanchored refusal marker is unsafe on any emitter that ECHOES user text.**
  `set_config_value` prints `✓ Set {key} = {value} in {config_path}` (`hermes_cli/config.py:3521` @
  v2026.9.7) — the user's VALUE is on the success line. As bare substrings, `is managed by` /
  `Cannot set` matched that echo, and because these verdicts run `failureWins: true` a completed
  write was reported as a refusal: QuickCommands free text and all fifteen platform-setup forms.
  `HermesCLIVerdict.judge` grew `anchoredFailureMarkers`, the `failureAnchored` twin of
  `successAnchored`. The rule that falls out: **anchor the failure side wherever the success line
  quotes anything the user typed** #verification
- [fact] **One anchor covers every managed refusal: `Cannot `.** Every refusal line on these paths is
  at column 0 and opens with it — `format_managed_message` (`:445-450`, under `set_config_value`
  `:3450`, `unset_config_value` `:3549` AND `save_config` `:2316`, i.e. under plugins
  enable/disable/update, skills trust and memory off), `_env_write_blocked`'s managed-scope line
  (`:2560-2565`) and `_exit_if_key_managed` (`:3363-3371`). `managedRefusalAnchored = ["Cannot "]`
  subsumes the per-verb `Cannot set` / `Cannot unset` / `Cannot save configuration` spellings. The
  three plugins sets keep their mid-sentence markers as substrings and ride the anchored list
  alongside — which is what stops a `git pull` message or a post-update scan report
  (`plugins_cmd.py:829`, `:844`) from flipping a real update #capability-gating
- [decision] **A refused `.env` mirror is a PARTIAL write, not a failure** (Alan). The tenth exit-0
  arm: config.yaml is written (`:3508`), then a `terminal.*` key's env twin goes through
  `save_env_value` (`:3511`) → `_env_write_blocked` (`:2574-2578`), whose managed-SCOPE arm refuses
  and returns, and `:3521` prints `✓ Set …` anyway; `unset_config_value` has it through
  `remove_env_value` (`:3574-3576`). `HermesConfigMirror` tells it apart from the
  `_is_env_config_key` branch (`:3461-3468`, where the `.env` write was the ONLY write and stays a
  failure) **by the file Hermes names on its own success line**, and `HermesCLIOutcome.warning`
  carries the banner sentence
- [fact] **The `.managed` marker's CONTENTS are only read from v0.20.5 (v2026.8.19).** Walked every
  tag: v2026.7.30 adds `_IGNORED_MANAGED_VALUES` but applies it to `HERMES_MANAGED` only; its marker
  half is still `if managed_marker.exists(): return "NixOS"`, byte-identical from v2026.3.12 through
  v2026.8.18. So below the floor a marker holding `brew` means MANAGED, system `"NixOS"` verbatim —
  the opposite of the v0.20.5+ answer. `hasManagedMarkerContents` is threaded into the probe on both
  platforms; a failed version probe answers `.empty`, i.e. below the floor, i.e. err toward the lock
  #capability-gating
- [gotcha] **`.disabled` reaches every descendant, so a pane-wide lock takes the READS with it.**
  P39's tab-wide lock disabled Config Diagnostics' "Check" (`_cmd_config_check` mutates nothing,
  `:3693-3720`), "Backup Now", the Raw Config disclosure (a `Text`, not an editor — the comment
  claiming otherwise was wrong), ScarfMon's "Copy as JSON", and text selection in every output
  panel. A managed host has MORE reason to read its own config, not less. The lock is now
  `selectedTab.locksWholeTabWhenManaged` plus, inside `AdvancedTab`, the write controls alone —
  `config migrate` DOES reach `save_config` (`:3653`) and stays locked #ux
- [done] **iOS took the verdicts and not the probe.** `IOSSettingsViewModel` consumes
  `HermesManagedInstallCache`, renders the same banner word for word, and refuses a write up front
  rather than shelling one whose only outcome is Hermes's exit-0 refusal
- [gotcha] **`LocalizationCatalogTests` gates the catalogue INTERNALLY only.** Nothing proves a
  `String(localized:)` in the sources HAS an entry — which is how P39 shipped two user-facing strings
  with no catalogue row at all. Three keys added with six translations each; the general
  source→catalogue gate is `t-3bcd1d7f`
- [todo] **Smaller three**: `transportProbe` got its absent / empty / named-system / chmod-000 tests
  (unreadable-but-present ⇒ managed, `:285-286`) and is now one `fileExists` + one read against one
  transport (was three round-trips); the probe has a named `probeTimeout` that falls OPEN without
  caching; the `BotAgentUnsetP39Tests` doc citation names its file

**P39b test results.** ScarfCore **2747** (same 4 known flakes). Mac `scarfTests` **1099/1099
serial**. `scarf` and `scarf mobile` both build. New: `HermesAnchoredRefusalP39bTests` (11),
`HermesConfigMirrorP39bTests` (5), `HermesManagedMarkerFloorP39bTests` (11),
`HermesTransportProbeP39bTests` (6), `IOSManagedHostP39bTests` (4) — all in
`HermesManagedRefusalP39bTests.swift` (ScarfCore) — plus `HermesManagedLockP39bTests` (7) in the Mac
file of the same name.

### P39c — the second review of P39 (`d4e4f6cf`)

Six findings from a re-audit of `1f384a84` (P39b's commit). All six fixed in one commit.

- [gotcha] **A one-anchor marker is only as safe as the noisiest emitter that uses it.** P39b's
  `managedRefusalAnchored = ["Cannot "]` was safe against the *success* line it was written for, but
  `plugins update` echoes text Hermes does not author — the raw `git pull` output (`cmd_update`
  prints `[dim]{out}[/dim]`, `plugins_cmd.py:829`) and a post-pull scan report (`:844`) — and
  `significantLines` TRIMS leading whitespace, so git's own indented `Cannot open …` arrived at
  column 0 and matched under `failureWins`. The fix is to anchor on the FULL action prefix. The
  enumeration that makes that safe: grep `managed_error(` **and** `format_managed_message(` across
  `hermes_cli/` at the tag and list every `action` string actually passed —
  `save configuration` (`config.py:2317`), `set configuration values` (`:3451`),
  `unset configuration values` (`:3550`), `{set|remove} {key}` (`:2557`, via `save_env_value`
  `:2577` / `remove_env_value` `:2612`) and `_exit_if_key_managed`'s `{set|unset} '{key}'` (`:3369`
  from `:3460`/`:3552`) — so the set is `["Cannot save configuration", "Cannot set",
  "Cannot unset", "Cannot remove"]`, byte-stable back to v2026.4.3. The actions Scarf never shells
  are named and excluded (`edit configuration` `:2957`; gateway's `:5580`/`:5919`/`:5945`;
  `update Hermes Agent`; `run setup wizard`), and `gatewayServiceFailureAnchored` took its own
  `Cannot restart gateway as a service` (`gateway.py:6047`) rather than riding a bare anchor
  #capability-gating
- [gotcha] **A scoped lock has to be re-walked every time the scope changes.** P39b exempted
  `.advanced` and asserted "every OTHER tab locks wholesale" — which pinned the bug on `.secrets`,
  whose "Check Status" is a pure read (`cmd_status`, `hermes_cli/secrets_cli.py:248-282`: one
  `load_config()` and `find_bws(install_if_missing=False)`, no writer) with a `.textSelection`
  panel under it. The eleven-tab walk found one more of the class, `.security` (selectable proposal
  patterns plus the two `ReadOnlyRow`s that are the only view of what the managed layer PINNED).
  The other nine — Agent, Aux Models, Browser, Display, General, Memory, Terminal, Voice, Web Tools
  — carry no copy / export / check / open-in-Finder / text-selection affordance at all, and a
  source sweep now fails if one appears inside a wholesale lock #ux
- [gotcha] **A lock scoped by "does Hermes refuse it" must exclude what Hermes never sees.**
  `usageAnalyticsSection` is Scarf's own swift-stats `UserDefaults` toggle — its own doc says it
  never touches `HermesConfig` — and it sat inside `AdvancedTab`'s `Group{…}.disabled(isManagedHost)`,
  making the one setting a managed host CAN change the one it could not #ux
- [fact] **`.env` refused ≠ nothing else was written.** `HermesConfigMirror`'s doc claimed the
  `_is_env_config_key` arm's `.env` write "was the ONLY write". True of `set_config_value`, but
  `save_provider_env_credential` (`credential_lifecycle.py:167-193` @ v2026.9.7) DISCARDS
  `save_env_value`'s bool (`:186`) and still runs `_scrub_config_yaml_mirrors` (`:190`), which
  rewrites config.yaml through `atomic_yaml_write` (`:142`) — around `save_config`'s `is_managed()`
  guard. Doc-only: that path is the Desktop credential API, not a verb Scarf shells, and the
  discriminator errs toward failure on it
- [gotcha] **`#expect(x == false)` on a cache is not a proof of "not cached" when the empty
  answer is also false.** The fall-open test asserted `cached(for:).isManaged == false`, which an
  empty cache satisfies. Rewritten to release the blocked probe and ASK AGAIN, expecting the real
  answer — the only shape that distinguishes "nothing memoized" from "`.notManaged` memoized"
  #testing
- [done] **`HermesCLIMarkers.managedRefusal` deleted.** The unanchored `is managed by` had no call
  site in either target after P39b; the three doc references that still pointed at it are corrected
  and a scan test fails if it returns.

**P39c test results.** ScarfCore **2782** (same 4 known `ACPClientStartIdempotenceTests` load
flakes; 5/5 in isolation). New: `HermesManagedRefusalP39cTests` (8 tests / 18 cases, ScarfCore) and
`HermesManagedLockP39cTests` (6, Mac). Re-run green: `HermesManagedLockP39bTests` 7,
`HermesManagedRefusalP39Tests` 7, `HermesP38SourceSweepTests` 3, `LocalizationCatalogTests` 10,
`GatewayAndPluginsVerdictP40Tests` 7. `scarf` builds. The narrowed anchors and the rewritten
fall-open test were both watched failing against the reverted fix.



## P40 — gateway/mcp/plugins verdicts and the OAuth drain (`t-1559ec68`, `t-bd119897`)

Commits `ef79ccd4` (the drain), `455a0a89` (config migrate hidden), `07d8f3d1` (the five
output verdicts) and the fresh-eyes follow-up on `fix/whole-surface-audit-r4`. Round-4
decisions 2, 3 and 4.

- [gotcha] **Changing a helper's RETURN TYPE is how the un-filed call sites announce themselves.**
  The finding named five `gateway start|stop|restart` sites. Making `HermesFileService.stopHermes()`
  return `HermesCLIOutcome` instead of `Bool` compiled fine — but grepping the verb afterwards
  found TWO MORE the finding never listed: `PlatformsViewModel.restartGateway`
  (`PlatformsViewModel.swift:248`) and `MCPServersViewModel.restartGateway`
  (`:513`), both through `HermesFileService.restartGateway()`, both exit-code-judged. Same move as
  P37's required `capabilities`, P38's `isStored` and P39's required `verdict`. A source-sweep test
  now fails on any hand-built `["gateway", "<verb>"]` argv #verification
- [gotcha] **`gateway restart` on systemd prints NO success line from `systemd_restart` itself.**
  The `✓ {User|System} service restarted (PID n)` line comes from
  `_wait_for_systemd_service_restart` (`hermes_cli/gateway.py:1218` @ v2026.9.7), several frames
  below. Judging `systemd_restart`'s own body would have reported every Linux restart as a failure.
  The other half of the same lesson: the s6 dispatch
  (`_dispatch_via_service_manager_if_s6`, `:5608-5629` → `service_manager.py:529-566`) prints
  **nothing at all** on success, so on an s6 container host a real start/stop/restart is reported
  "could not confirm". That is the C5 answer and it is documented in the verdict rather than
  papered over — the reload that follows corrects the banner #verification
- [decision] **"Nothing was running" must not launder a real refusal** (fresh-eyes). Decision 2
  turns `✗ No gateway running for this profile` into a success-with-note, and the first cut keyed
  that on the marker alone. `_refuse_from_inside_gateway` (`:5776-5781`) can print its own refusal
  into the same output, so the flip is now gated on NO failure marker having matched
- [gotcha] **An anchored marker is not a claim about WHY.** `managedRefusalAnchored = ["Cannot "]`
  catches `⚠ Cannot restart gateway as a service — linger is not enabled.` (`:6047`), which has
  nothing to do with a managed install — it is a column-0 exit-0 refusal and that is all the anchor
  asserts. Reusing it there is correct and is called out in the marker's doc so nobody "fixes" it
- [gotcha] **`rich` wraps at 80 columns when stdout is not a TTY**, so a marker inside a long
  `console.print` sentence can start mid-line. `pluginsUpdateSecurityDisabled`
  (`plugins_cmd.py:849`) is therefore a SUBSTRING while the success side
  (`✓ Plugin <name> updated.`, `:828`) is matched as a whole shape — column-0 `Plugin ` prefix AND
  one of the two tails. The bare `"updated."` it replaces matched the raw `git pull` body (`:829`):
  a commit message reading "docs updated." was a false success #verification
- [done] **`config migrate` has no button** (decision 4). `_cmd_config_migrate` (`config.py:3653`)
  reaches a bare `input()` with no `EOFError` guard (`:1289-1297`; `cli_output.py:29-37`), so with
  no stdin it dies after applying migrations and before stamping `_config_version` (`:1374-1378`).
  `runConfigMigrate` was deleted with it; a sweep test pins that nothing shells the verb
- [todo] **Not done here**: the `DrainedProcessRun` hoist over the five streamed-process
  controllers (`t-51a29de2`, after P43, which owns `SpotifyAuthFlow` and `HermesProxyService`).
  P40 hoisted only `OutputInbox` → `ScarfCore.ProcessOutputInbox` and ported the rest, because
  `OAuthFlowController` has live stdin and a prompt, `MCPLoginController` has a remote `pkill`
  reap, and `HermesProxyService` has no verdict at all — a shared type today would be a rewrite

**P40 test results.** ScarfCore **2774/2774** (clean; the `ACPClientStartIdempotenceTests` load
flake appeared in one run of four and was 5/5 green in isolation — `t-f3820038`). Mac `scarfTests`
**1110/1110 serial**. `scarf` builds. **38 new tests in three suites**:
`HermesCLIVerdictP40Tests` (27, ScarfCore), `GatewayAndPluginsVerdictP40Tests` (7, Mac) and
`OAuthFlowDrainP40Tests` (4, Mac); plus three migrated off the retired
`HermesFileService.mcpTestReportsFailure`. Each watched fail against its reverted fix — the OAuth
drain test fails on three expectations when the termination handler judges eagerly again.

### P40b — the review of P40's four commits (`3055fb07`)

Thirteen findings from an independent audit of `ef79ccd4` + `455a0a89` + `07d8f3d1` + `4dcfa161`.
All thirteen fixed in one commit.

- [gotcha] **The exit-0 family lesson has a second half: walk the helper the handler CALLS, not just
  the handlers on the verb.** P40 judged `launchd_start`'s own body and read its
  `_launchd_bootstrap_and_kickstart` degradation (`hermes_cli/gateway.py:3926-3928`, `:3938-3939` @
  v2026.9.7) as "no success line ⇒ failed". One frame down, `_launchd_degrade_or_raise` (`:3626-3630`)
  calls `_launchd_fallback_to_detached` (`:3607-3618`), which `Popen`s the gateway
  (`_spawn_detached_gateway`, `:3583-3604`) and prints `✓ Started gateway as a background process
  instead` (`:3614`) — a REAL start, present since v2026.6.19. Every macOS host whose launchd domain
  is unmanageable (macOS 26+, issue #23387) was reported "Start failed" while its gateway was
  running. The same helper is reached from `launchd_restart`'s two arms (`:4068`, `:4079`), so the
  marker joined BOTH verbs; `launchd_stop` never reaches it (it swallows the unmanageable-domain
  error and ends on `✓ Service stopped`, `:3978`) #verification
- [gotcha] **"Could not confirm" is not a failure, and a destructive fallback must be able to tell.**
  `_dispatch_via_service_manager_if_s6` (`:5608-5629`) prints NOTHING on the success path, so on an
  s6 container host `stopHermes()` judged "could not confirm", fell through to `pgrep` +
  `kill -TERM`, and `s6-supervise` read the bare SIGTERM as a crash and restarted the gateway ~1s
  later — Hermes documents that exact hazard in the sibling helper's docstring (`:5631-5634`). Stop
  looked like it worked and then undid itself. `HermesCLIOutcome` grew
  `Confidence { confirmed, unconfirmed, failed }`: `judge` answers `.unconfirmed` for exit 0 with no
  success line AND no matched refusal, `.failed` only on a positive signal, and the kill fallback is
  gated on `.failed`. **The general rule: a `!succeeded` guard in front of anything irreversible is
  a bug whenever silence is one of the answers** #capability-gating
- [decision] **The analytics facade takes the third token** (round-4 decision 5). `UsageEvent.Outcome`
  gained `unconfirmed` alongside `succeeded`/`failed`, with `init(_ confidence:)` next to the
  untouched `init(succeeded:)`, so no other event's vocabulary moved. **Series break:** before this,
  a could-not-confirm gateway action was recorded as `failed`, so `hermes_control_action` rows with
  `outcome=failed` from earlier builds mix real refusals with silent s6 dispatches — compare
  `succeeded` across the boundary, not `failed`. A restart folds its two halves through
  `HermesCLIOutcome.Confidence.combined` (failed if either half failed, confirmed only if both did)
- [gotcha] **A `-> None` handler can also end in a call that never returns.** `_cmd_restart`'s
  last-resort arm (`:6062-6066`) prints `Starting gateway...` and then `run_gateway(verbose=0)`,
  which runs the gateway in the FOREGROUND — the run ends at Scarf's own CLI timeout.
  `_restart_all` (`:6003-6016`) has the same shape. Neither "restarted" nor "failed" is true, so
  `gatewayForegroundStarting` maps it to `.unconfirmed` carrying its own note. Per the product call,
  nothing claims "restarted" without a confirmation line
- [fact] **`gateway restart` on Windows has no restart line at all.** `gateway_windows.restart()`
  (`hermes_cli/gateway_windows.py:1380-1399`) is `stop()`, an absence wait, then `start()` (`:1225`),
  so the run ends on `✓ Gateway started via {via} (PID: …)` (`:971`) or `✓ Gateway already running
  (PID: …)` (`:698`). P40 had both on the START verb only ⇒ every Windows restart was "could not
  confirm"
- [gotcha] **Keying a third state on the LAST line of a block misses the arms that stop earlier.**
  `_rescan_after_update` (`plugins_cmd.py:832-851`) prints `⚠ Security scan flagged the updated
  plugin: {reason}` for EVERY not-allowed verdict (`:843`) and only disables when the verdict is
  `dangerous` (`:845-851`). P40 keyed decision 3's third state on `has been disabled.`, so a
  `suspicious` verdict — flagged, still enabled — was reported as a flat "Updated" and the user never
  learned the scan had found anything. The warning is keyed on the flagged line now; the disable line
  only selects between "…then disabled by the security scan" and "…but the security scan flagged it"
- [gotcha] **A source sweep that names a directory nobody checked is a sweep that reads nothing.**
  Both P40 sweeps walked `scarf/ScarfGo`; the iOS target has been `scarf/Scarf iOS` for releases, and
  `FileManager.enumerator` returns `nil` for a missing root, which the code `continue`d past
  silently. They also matched `"gateway", "start"` verbatim, which a removed space dodges. Now:
  every listed root must exist (the sweep fails otherwise), every line is matched with whitespace
  STRIPPED, the `["gateway", verb]` variable form is caught too, and a `> 10_000` line-count premise
  assertion makes "read nothing" impossible. `HermesCLIOutcome.swift` is exempted by name and a
  positive assertion pins that the sanctioned `argv` still lives there, so the exemption is not a
  hole #testing
- [gotcha] **A hint is walked like a button, INCLUDING on the hosts the button was hidden for.**
  Decision 4 replaced the Migrate button with "run `hermes config migrate` in a terminal" — which on
  a managed install is a dead end: `_cmd_config_migrate` (`config.py:3653`) reaches `save_config`,
  whose first act is the `is_managed()` refusal (`:2315-2318`). A managed host gets its own line
  (six locales) saying the migration comes with the next managed update #ux
- [fact] **The OAuth flow's markers are anchored where Hermes prints at column 0.** The argv is
  `auth add <provider> --type oauth --no-browser`, which routes through `auth_command`
  (`auth_commands.py:766`) → `auth_add_command` (`:333`) → `_add_credential` (`:361`) →
  `_anthropic_oauth_login` (`:181-186`) → `run_hermes_oauth_login_pure`, whose three refusals are
  bare column-0 `print()`s (`agent/anthropic_credentials.py:546`, `:560`, `:563`). `did not return
  credentials` stays a SUBSTRING because the `SystemExit` sentence leads with the provider name
  (`auth_commands.py:185`). Two markers retired: `HTTP Error` only ever arrives interpolated into
  `Token exchange failed: {exc}` (urllib's `HTTPError` str), and `OAuth login failed` has exactly one
  emitter at the tag — `setup_tts.py:105`, the TTS wizard, not on this argv. The old
  `localizedCaseInsensitiveContains` over the whole blob matched a provider error page echoed into
  the log
- [decision] **`COLUMNS` is set wide in both spawn seams.** `rich` wraps `console.print` at its
  80-column non-TTY default, which can split `✓ Plugin <long name> updated.` (`:828`) across two
  lines and break a whole-shape match. `LocalTransport.wideColumns = "400"` is the one constant;
  `subprocessEnvironment` sets it locally (an explicit value in the environment wins) and
  `SSHTransport.composedRemoteCommand` puts it in the remote assignment prefix beside `HERMES_HOME=`,
  because ssh does not forward the client's environment
- [todo] **Doc-only, walked and left**: the s6 `--all` partial failure (`:5653-5655` prints a per-
  profile `✗ Could not {action} …` ALONGSIDE the `✓ … under s6` summary, which a verdict without
  `failureWins` would read as a flat success) is unreachable because Scarf never passes `--all`, and
  is named in the verdict so the day an `--all` surface appears the gap is known. `HermesMCPAdd`'s
  `--` doc was narrowed to what `--args`' `nargs=REMAINDER` (`subcommands/mcp.py:34-36`) actually
  proves, and its claim that "a leading-dash server name is rejected upstream by the name validator"
  was FALSE — `validate_mcp_server_entry` (`mcp_security.py:89-145`) never looks at `name`; argparse
  itself is the gate (exit 2), and Scarf has no readable refusal of its own

**P40b test results.** ScarfCore **2802/2802** (clean; no `ACPClientStartIdempotenceTests` flake this
run). Mac `scarfTests` **1127/1127 serial**. New: `HermesGatewayVerdictP40bTests` (20 cases, ScarfCore) and
`GatewayAndPluginsVerdictP40bTests` (11, Mac). Re-run green: `GatewayAndPluginsVerdictP40Tests` 7,
`HermesP38SourceSweepTests` 3, `LocalizationCatalogTests` 10, `MainActorSpawnDisciplineP22Tests` 16,
`OAuthFlowDrainP40Tests` 4, `AuditP21VerdictTests` 9, the four Analytics suites, both Health suites.
`scarf` builds. Two existing transport assertions were updated for the new `COLUMNS=` prefix
(`M0bTransportTests`, `BotModePhaseBP0Tests`). Every fix was watched failing against its reverted
form.



## P41 — the YAML emitter, the two editor refusals, and the decoders (`t-f3ffabf9`)


### P41b — the review of P41's own four commits (`9f23018f`)

Six findings from an independent audit of `2fb7cc08` + `d4a3ab4d` + `402442a1` + `151cdd3e`.
All six fixed in one commit. The reviewer fuzzed 3 597 inputs through PyYAML first: the emitter
P41 landed on is sound. What was not sound was everything that READS it back, and the scope of
the two refusals.

- [gotcha] **A quote scanner that knows one style's escape and not the other's DELETES rows,
  and the deletion is silent until the next save makes it permanent.**
  `HermesYAML.closingQuoteIndex` skipped the doubled `''` for single quotes and nothing at all
  for double ones — but `YAMLScalar.doubleQuoted` is exactly the style the writers reach for when
  a key carries a control character, and it escapes an embedded quote as `\"`. The span closed at
  the escape, `rest.hasPrefix(":")` then failed, and `parseNestedYAML` hit `continue` — dropping
  the whole row. Under `agent.reasoning_overrides` that row vanished from the editor, and because
  `setReasoningOverrides` rewrites the block from what the editor holds, the next save deleted it
  from the file. The reviewer's fixture is one line: `"gpt\x01\"x": high` beside `plain: low`
  reads back as `plain` alone. P41's own round-trip test had `quote"inside` in its arguments and
  passed, because without a control character `quoteIfNeeded` SINGLE-quotes it — the escape arm
  is only reachable when both hazards are in the same token #yaml
- [convention] **One block-style key scanner, and the way to prove it is to make the second
  caller ask for it by name.** `HermesFileService`'s MCP entry reader had its own
  `trimmed.firstIndex(of: ":")`, so an env or header name containing a colon was WRITTEN
  correctly (`'A: B': v`, via `quoteIfNeeded`) and read back as the key `'A` with the value
  `B': v` — and the next save persisted that. The scan `parseNestedYAML` already did inline is
  now `HermesYAML.blockKeySpan`, returning the key's RAW span (quotes included) and the text
  after the separator; both callers go through it. The reader also inherits the separator RULE it
  disagreed with before — a colon with a non-space successor belongs to the key
  (`llama3:8b: high`) #yaml
- [gotcha] **A refusal must run on the value the WRITER emits — P41's own fresh-eyes lesson,
  missed one field over.** The identity-header NAME was checked raw although `save` writes it
  trimmed, so a surrounding TAB was refused although `.whitespaces` strips it before it reaches
  the file. The VALUE is correctly raw: nothing trims that one #ux
- [gotcha] **And it must be gated on the same DELTA the write is.** The identity-header block ran
  on `identityHeaderEnabled` while the write runs on `identityHeaderValue != server.identityHeader`,
  so an entry whose config.yaml already carried a control character in `identity_header.name` was
  permanently uneditable — the over-refusal every sibling scalar in that method is written to
  avoid. Both halves now read `resolvedIdentityHeader`, the property `save` itself uses, which is
  what stops the check and the write drifting apart again (the same move `resolvedSSLVerify`
  already was) #ux
- [gotcha] **A trim on the wrong side of the quotes is a type gate all over again.**
  `HermesApprovalMode.normalize` trimmed the RAW scalar, i.e. OUTSIDE the quotes, so
  `mode: " off"` kept its leading space through `normalizedScalar` and landed on `manual` while
  Hermes's `mode.strip().lower()` (`tools/approval_context.py:207` @ `v2026.9.7`) answers `off` —
  PyYAML hands the string arm the scalar's CONTENT, and the strip happens there. Unsafe
  direction, exactly like P41's quoted-scalar finding one line above it. The trim moves after
  `normalizedScalar`; the bare arm is untouched because it was already trimmed #config-parsing
- [fact] **PyYAML refuses a mapping key past 1024 characters, measured on the EMITTED token.**
  `yaml/scanner.py:283-291` (`self.index - key.index > 1024`, the comment at `:91`) — so quoting
  spends two characters of the budget rather than buying headroom, and there is no quoting style
  that gets a longer key in. Past it the document raises `ScannerError`, `load_config` discards
  the WHOLE config.yaml layer and falls back to `.env` (`gateway/config.py:775-791` @
  `v2026.9.7`), and every unrelated setting in the file silently reverts. Unlike the
  control-character refusal beside it this is a PARSE guard, not a visibility one.
  `YAMLScalar.exceedsSimpleKeyLimit` is the rule; the MCP editor refuses an env/header name and
  `ReasoningOverridesSection` refuses a pattern, each with a localized message in six locales.
  Boundary verified against PyYAML 6.0.3 locally and pinned in a test that runs the real
  interpreter: bare 1024 loads and 1025 does not; `'…'` with 1022 inside loads and 1023 does not
  #yaml
- [todo] **The same escape gap survives in `GatewayConfigWriter`'s three flow scanners**
  (`parseOrderedFlowPairs` `:618`, `flowPairSeparatorIndex` `:660`, and `:881`) — filed as
  `t-38ae4f26`, deliberately out of P41b's scope, which was named at `HermesYAML` /
  `HermesFileService`. The MCP server NAME is a map key too but Scarf never emits it: the add
  path shells `hermes mcp add`, so Hermes writes that key itself.

**P41b test results.** ScarfCore **2830** (the 4 known `ACPClientStartIdempotenceTests` load
flakes; 5/5 green in isolation — `t-f3820038`). Mac: the touched suites green serially. `scarf`
builds. **25 new tests in two suites**: `HermesP41bYAMLTests` (9, ScarfCore) and
`HermesP41bRefusalTests` (16, Mac — six of them over-refusal clamps, one running real PyYAML on
the length boundary). Each was watched failing against its reverted fix: 12 issues and 19.


Commits `2fb7cc08` (the emitter), `d4a3ab4d` (decision 9 + the LOW trim), `402442a1`
(decision 10 + the quoted `approvals.mode`) and `151cdd3e` (the fresh-eyes pass) on
`fix/whole-surface-audit-r4`. Round-4 decisions 9 and 10.

Full detail: [[A YAML reader is opted in per KEY, and only for what Scarf writes]].

### P41c — the re-audit of P41b's own commit (`a2280ab6`)

Five findings from an independent re-audit of `9f23018f`. All five dispatched in one commit.

- [gotcha] **A length guard measured in Swift `String.count` is measured in the WRONG unit.**
  PyYAML's `self.index - key.index > 1024` (`yaml/scanner.py:283-291`) counts PYTHON
  characters — unicode code points — while Swift's `.count` counts grapheme CLUSTERS.
  `YAMLScalar.exceedsSimpleKeyLimit` used `.count`, so 600 × `e` + U+0301 read as 600 and
  spent 1200: the guard passed, PyYAML raised, and Hermes discarded the whole config.yaml
  layer (`gateway/config.py:775-791` @ `v2026.9.7`) — precisely the failure the guard exists
  to prevent. An emoji ZWJ family is the same shape at 7 scalars per Character. The measure
  is `unicodeScalars.count`; both fixtures are pinned and both sides of both boundaries now
  run through the real interpreter. Confirmed against PyYAML 6.0.3: 512 combining pairs
  (1024 scalars) load and 513 do not; 146 ZWJ families (1022) load and 147 (1029) do not
  #yaml
- [gotcha] **A `withKnownIssue` that wraps the ASSERTIONS and not just the probe turns the
  whole lane decorative.** `pyYAMLAgreesOnWhereTheLimitFalls` had all four boundary
  `#expect`s inside `withKnownIssue(…, isIntermittent: true)` alongside the availability
  check, so a disagreement with PyYAML was recorded as a known issue and the test could not
  fail. The correct shape is the one `HermesP41MCPScalarTests.pyYAMLRoundTripLaneIsPresent`
  already used: a separate named test wraps ONLY the probe (so absence is reported, not
  vacuous), and the boundary test asserts unguarded and returns early when the interpreter
  is genuinely missing. Proved failable by flipping the 1024 boundary — TEST FAILED — then
  restored. The general rule: a guard belongs around the thing that can be ABSENT, never
  around the thing that can be WRONG #testing
- [fact] **PyYAML's parser demands a space after the value indicator once the key is not
  plain.** `'a':b` and `"a":b` raise `ParserError`; `'a': b` and `'a':` load (6.0.3).
  `HermesYAML.blockKeySpan` accepted `'key':value`, i.e. read a row Hermes cannot load at
  all. The quoted arm now requires the colon to end the span or be followed by space/tab
  (tab accepted for symmetry with the plain arm — PyYAML refuses a tab there too, but as a
  scanner-wide rule about tabs, and no Scarf writer emits one). No writer is affected: every
  emitter (`HermesFileService:2117`, `GatewayConfigWriter.setMapLF`) writes `<key>: <value>`
  #yaml
- [ux] **Refusal copy must not quote a number the user cannot count.** "longer than 1024
  characters" was wrong twice over: the budget is the EMITTED token (quoting spends two of
  it) and it is counted in scalars, so a combining mark or a ZWJ sequence spends more than
  it shows. Reworded in six locales across all three strings — editor save, add-path hint,
  its a11y label — to say the key is too long for Hermes to read once Scarf quotes it
- [decision] **The MCP server NAME on the add path gets NO length pre-check, and the reason
  is the EMITTER, not the rule.** `hermes mcp add` writes the name through PyYAML's own
  emitter (`hermes_cli/mcp_config.py:_save_mcp_server` → `hermes_cli/config.py:2307`
  `save_config` → `utils.py:262` `atomic_yaml_write` = `yaml.dump` @ `v2026.9.7`), and the
  emitter never produces a simple key it could not read back: past its line width it emits
  the EXPLICIT `? key` / `: value` form, which carries no simple-key limit at all. An 1100
  character name is neither refused by Hermes (`hermes_cli/mcp_security.py:89` has no length
  rule) nor written unreadable — the document reloads with every sibling intact. Scarf's
  refusal exists because SCARF emits env/header names and reasoning-override patterns as
  simple keys ITSELF; refusing a key Hermes writes correctly would be P19's over-refusal.
  Pinned through real PyYAML in `anOverLongServerNameSurvivesHermesOwnEmitter`. Open gap
  noted, not in scope: Scarf's own readers do not understand the `? key` form, so such an
  entry would not appear in Scarf's MCP list — a display gap, not data loss, since the
  editor patches per entry #yaml

**P41c test results.** ScarfCore **2844**, all green (no `ACPClientStartIdempotenceTests`
flake this run). Mac serial, green: `HermesP41bRefusalTests` **18**, `HermesP41MCPScalarTests`
8, `HermesP41ControlCharacterRefusalTests` 15, `MCPYAMLMapKeyP19Tests` 14,
`HermesP17AppRemediationTests` 6, `HermesP38SourceSweepTests` 3, `LocalizationCatalogTests`
10. `scarf` builds. Two new Mac tests plus expanded fixtures in two existing suites; each fix
watched failing against its reverted form.

Commit `a2280ab6` on `fix/whole-surface-audit-r4`.

- [gotcha] **The routine P32 left standing was the one that was wrong, and the verifier
  could not see it.** `HermesFileService.yamlScalar`'s double-quoted arm escaped exactly
  `\\` and `\"`, so every other C0/C1 control, DEL, NEL and U+2028/9 went out RAW inside
  the quotes — PyYAML's READER refuses those in every quoting style, and Hermes discards
  the whole config.yaml layer (`gateway/config.py:775-791` @ `v2026.9.7`).
  `patchMCPServerField(expecting:)` passes it because the expected rows come from the
  same `subMapRows` that emitted the damage: P19's "a structural verifier cannot see
  damage that leaves the structure intact", now applied to a scalar the verifier itself
  emits. Deleted, forwarded to `YAMLScalar.quoteIfNeeded`. `ssl_verify`'s bool carve-out
  is unmoved because it lives at the CALL SITE, not in the emitter #yaml
- [convention] **When a shared emitter absorbs a bespoke one, the tests that pinned the
  bespoke SPELLING become tests of the RULE.** `quoteIfNeeded` single-quotes where the
  deleted routine double-quoted, and emits `''` for empty where it emitted `""`; both
  round-trip through `YAMLScalar.unquote` and PyYAML.
  `MCPYAMLMapKeyP19Tests.yamlScalarQuotesImplicitlyTypedValues` asserted the byte-exact
  double-quoted form — i.e. it pinned the copy P41 deletes — and now asserts "quoted, and
  PyYAML reads the string back" #testing
- [fact] **The emitter sweep's answer: exactly ONE hand-rolled YAML scalar emitter is
  left in the repo**, `ProjectSlashCommandService.yamlScalar`
  (`ScarfCore/Services/ProjectSlashCommandService.swift:308`, emitted `:284/:286/:289/:294`
  into `.hermes/commands/*.md` frontmatter) — escapes only `"`, no control/tab/line-break
  arm, no implicit-resolver arm. Filed as `t-f46dfedb`; out of scope because decisions 9
  and 10 are scoped to config.yaml. Everything else the greps (`"\""`,
  `.replacingOccurrences(of: "\\"`, `quoted(`) turned up across both targets and
  `Scarf iOS` is SHELL or SQL quoting — `HermesEnvService.formatLine`,
  `TestConnectionProbe`, `HermesProfileScope.shellQuotePath`, `RemoteSQLiteBackend`,
  `BotsRosterScan.quote`, `SQLValueInliner` — and `Scarf iOS` emits no YAML at all
- [decision] **Decision 9's refusals are scoped to what the save WRITES, not to what the
  field holds.** `MCPServerEditorViewModel.controlCharacterFieldLabel` checks env/headers
  (per transport) and the tool filters unconditionally because those are rewritten every
  save, and the v0.15/v0.20.4 scalars only when they differ from the loaded value — an
  unchanged field is not written, so refusing it would make an entry whose config.yaml
  already carries a control character permanently uneditable (P19's over-refusal lesson).
  Same reason the reasoning-override refusal covers only the NEW pattern and not the
  existing rows a re-save rewrites: `quoteIfNeeded` represents a control losslessly, so
  refusing there would make the section uneditable to fix the row that carries it #ux
- [gotcha] **The fresh-eyes finding: a refusal has to be checked in the form the writer
  emits.** The first cut checked env/header KEYS and the tool-filter drafts as typed, but
  `save` trims every key and every filter item, and `.whitespaces` contains the TAB — so a
  surrounding tab was refused although it never reaches the file. Keys and filter items
  are checked trimmed now; VALUES raw, because nothing trims those
- [gotcha] **A TYPE gate on a YAML scalar runs on the RAW text, and QUOTING is half of
  it.** `HermesApprovalMode.normalize` ran on an already-unquoted scalar, so a quoted
  `approvals.mode: "no"` / `"false"` rendered "Never ask" while
  `_normalize_approval_mode` (`tools/approval_context.py:198-214`, `_VALID_MODES` `:195`
  @ `v2026.9.7`) returns `manual` — PyYAML types the scalar first, and a quoted spelling
  is a `str`, not a `bool`. Unsafe direction. The re-derived table, tested row by row:
  BARE `yes`/`true`/`on` → manual, `no`/`false`/`off` → **off**, `0`/`1` (ints, neither
  `isinstance` arm) → manual; QUOTED — all eight are `str`, only `"off"` is in
  `_VALID_MODES`, so `"off"` → off and the other SEVEN → manual. The bool arm is gated on
  `YAMLScalar.resolvesToBool` before quote-stripping, as
  `HermesFileService.boolishOptional` does, which also retires the hand-carved `0`/`1`
  exclusion — PyYAML's resolver excludes ints on its own. `HermesConfig` carries
  `approvalModeRawScalar` (a REQUIRED init argument, the P37/P38/P39 move) beside the
  normalised one; absence still keys on the normalised field so `mode: ""` reads as
  before. iOS and the Bots surface read this through the same ScarfCore model — no twin
  #config-parsing
- [decision] **Decision 10 shipped for TWO of its three blocks, deliberately.**
  `agent.reasoning_overrides` (keys AND values) and `model_catalog.excluded_providers` are
  opted into `YAMLScalar.unquote` inside `parseNestedYAML`.
  `gateway.multiplex_profile_allowlist` is NOT: the finding called it Scarf-written and it
  is not one — a repo-wide grep finds only reads (`HermesConfig+YAML.swift:1014-1056`,
  `SettingsViewModel.swift:1107-1122`); the only nearby write is the sibling BOOL
  `multiplex_profiles` through `hermes config set`, and `GatewayConfigWriter.saveList`'s
  one caller passes `GatewayAllowlistKind.yamlKey`, i.e. `allowed_channels` /
  `allowed_chats` / `allowed_rooms`. Opting a Hermes-written list into the wider escape
  table is precisely what `YAMLScalar.unquote`'s own doc refuses. Recorded in the opt-in's
  doc, in a test, and in `t-6e9a0985` (which also asks whether the platform allowlists
  should join, and whether the read-only multiplex WARNING is a dead end in the shape
  P40b fixed for the migrate hint)
- [done] **The "one decoder" claim is now true and cites its writers** rather than
  asserting. The LOW: `setReasoningOverrides` trimmed the key for the emptiness test and
  wrote it untrimmed, so a pattern pasted with a trailing space went in quoted and never
  matched a model — `setExcludedProviders` had trimmed all along.
- [done] **The `parseNestedYAML` flat-dotted-sibling LOW was already closed by P38**
  (`fa4d1414`, item 8, `dottedLiteralPaths`); pinned by
  `HermesP38YAMLPurgeTests.aFlatDottedSiblingSurvivesTheReopen` and
  `.aFlatDottedSiblingSurvivesTheFirstOpen`. Nothing to do.

**P41 test results.** ScarfCore **2810** (the 4 known `ACPClientStartIdempotenceTests`
load flakes; 5/5 green in isolation — `t-f3820038`). Mac: the 21 touched suites green
serially (138 + 21 + 23 across three filtered runs). `scarf` and `scarf mobile` both
build. **30 new tests / 123 cases in three suites**: `HermesP41MCPScalarTests` (8/60,
Mac — five real writers × the reviewer's failing classes, round-tripped through real
PyYAML 6.0.3 with a `withKnownIssue` lane so an absent PyYAML reports rather than passes
vacuously), `HermesP41ControlCharacterRefusalTests` (15/42, Mac — five of them
over-refusal clamps) and `HermesP41YAMLDecoderTests` (8/21, ScarfCore). Each watched
failing against its reverted form: 28 issues for the emitter, 83 for the refusals, 18 for
the decoders.


### P40c — the review of P40b's own commit `3055fb07` (fixed in `5fe72ef7`)

Six findings from a third audit, plus two the fresh-eyes pass found in the fix itself. All fixed in
one commit (`5fe72ef7`).

- [gotcha] **A third state whose only production shape is a TIMEOUT cannot be gated on exit 0.**
  P40b's `.unconfirmed` foreground-restart arm required `verdict.confidence != .failed`, which
  `HermesCLIVerdict.judge` only ever answers on an exit-0 run — but `_cmd_restart`'s no-service arm
  (`hermes_cli/gateway.py:6062-6066` @ v2026.9.7) prints `Starting gateway...` and then calls
  `run_gateway`, which NEVER RETURNS. The run can only end at Scarf's own timer, i.e. at
  `TransportError.timeout` → `runHermesCLI`'s `(-1, …)`. The arm was unreachable in production from
  the day it shipped, and its test asserted the unreachability as if it were the semantics. The arm
  is keyed on the OUTPUT now — `Starting gateway...` with no matched refusal — so it covers the
  exit-0 and the timeout shape alike #capability-gating
- [gotcha] **`TransportError.timeout` carried `partialStdout` and nothing read it.**
  `diagnosticStderr` has no `.timeout` case (correctly: it is *stderr*, and seven callers render it
  as such, one passing it to a `stderr:` parameter), so the bytes the child printed before the kill
  were discarded at `HermesFileService.runHermesCLI`. A new `TransportError.partialStdoutText` is
  asked for BY NAME on the one path that hands its output to a verdict; the timeout message stays as
  the last line so `fallbackDetail` still quotes something. Both transports capture the partial the
  same way (`LocalTransport.swift:306`, `SSHTransport.swift:1130` — the latter after a
  `waitUntilExit()` so the read cannot race the kill)
- [gotcha] **`Gateway already running` is TWO different lines, one of them a refusal.** Windows's
  `✓ Gateway already running (PID: {n})` (`gateway_windows.py:698`) is a success;
  `gateway/run.py:4769`'s `❌ Gateway already running (PID {n}).` —
  `_start_gateway_replace_existing_instance`, which returns False and ABORTS startup — is a refusal,
  and it arrives on exactly the path the foreground arm covers. P40b's bare substring covered both
  and the only thing saving it was that `❌` is not in `HermesCLIVerdict`'s glyph set, so the anchor
  missed by one character. Now the success marker carries `(PID: ` (colon) and the colon-less
  spelling is a REFUSAL marker, so a run that ends in run.py's refusal reads `.failed` with Hermes's
  own sentence in the banner instead of "started in the foreground, could not confirm"
- [gotcha] **A `!succeeded` banner launders the third state straight back into "failed".** Four
  panes still branched on the bool after P40b split the verdict three ways, so an s6 Stop (silent on
  success, `gateway.py:5608-5629`) and a foreground restart both showed the red "Gateway stop
  failed". `GatewayActionBanner.unconfirmed(_:detail:)` (three strings × six locales) is the neutral
  arm for `GatewayViewModel`, `HealthViewModel.controlMessage`, `PlatformsViewModel.restartBanner`
  and `MCPServersViewModel.restartBanner`; `actionFailed`/`isFailure` stay false and the
  settle-reload each site already schedules is what tells the real state. The MCP pane's unconfirmed
  arm deliberately does NOT clear the "restart needed" banner. `scarfApp`'s menu-bar path has no
  banner at all — it only records `outcome.confidence` to Analytics, which P40b already made
  three-valued #ux
- [gotcha] **`.unconfirmed` may only ever mean SILENCE — so every exit-0 refusal on the verb has to
  have a marker.** Adding the third arm turned `_no_backend_exit`'s `("start", "container")` entry
  (`gateway.py:5860-5866`: `Service start is not applicable inside a Docker container.`, printed at
  column 0, **exit 0**) from a reported failure into a neutral "could not confirm" — Hermes had said
  no in as many words. Marker added. The corollary is a rule: **widening a verdict's neutral arm is
  a reason to re-walk the verb's refusals, because every one you lack a marker for now reads as
  silence** #verification
- [gotcha] **A per-line source sweep is dodged by a newline, and a bare token by a longer
  identifier.** P40b's two sweeps matched each line's whitespace-stripped text, so
  `["gateway",\n "start"]` walked past, interpolation (`"gateway \(verb)"`) was invisible, and the
  `"verb"` token matched `verbose`. Matching is on the whole FILE blob now, through three regexes
  (literal pair, `[A-Za-z_]*[Vv]erb\b`, and `"gateway\(`), and the `config migrate` sweep got the
  same treatment — minus a concatenated `"config migrate"` matcher, which would hit decision 4's own
  hint copy #testing
- [decision] **`wideColumns` stays off the LOCAL streaming/ACP spawns and the DOC narrows to say
  so.** `streamLines`, `streamRawBytes` and `makeProcess` inherit the app environment; routing them
  through `subprocessEnvironment` for `COLUMNS` alone would also move PATH (the enricher always
  overrides it) and every other shell-harvested key onto the ACP session — a real behaviour change
  for a setting nothing on those paths reads (log tails, raw bytes, newline-framed JSON-RPC). The
  remote ACP spawn DOES carry it, because it shares `SSHTransport.composedRemoteCommand`'s prefix;
  harmless

**P40c test results.** ScarfCore **2821/2821** clean. Mac `scarfTests` **1162/1162 serial**.
`scarf` builds. **New: `HermesGatewayVerdictP40cTests` (10, ScarfCore) and
`GatewayAndPluginsVerdictP40cTests` (11, Mac)**; `HermesGatewayVerdictP40bTests`'s
`aForegroundRestartThatFailedToSpawnIsStillAFailure` corrected to the real semantics and split in
two, and P40's `aSilentExitZeroStartIsReportedAsAFailure` renamed to
`aContainerRefusalAtExitZeroIsReportedAsAFailure` (its fixture was never silent). Each fix watched
failing against its reverted form.

## Whole-surface remediation — P42 (cron/kanban residue, `t-8e9ddad0` + `t-dafcc4a5`)

Round-4 decisions 5, 6, 7 and 8, plus the MED on `friendlyCronFailure` and the section's LOWs. Seven commits on `fix/whole-surface-audit-r4` (`5e1550b6`, `f188a5e5`, `a133d79d`, `8de6c5f1`, `f442eb62`, `c5dd78eb`, `4275fbfb`).

**What was wrong.**

*Decision 7 — the dash-leading value.* Several phases had carefully put `--` before every positional in the cron and kanban builders. That work protected exactly half the argv: `--` ends the OPTIONS, so a user-typed OPTION value beginning with `-` still made argparse exit 2 on the whole verb. `--name/--deliver/--prompt/--workdir/--failure-deliver/--script/--repeat/--skill/--add-skill/--remove-skill/--schedule` in cron, `--author/--result/--summary/--metadata` in kanban, and every option in `KanbanCreateRequest.argv` / `KanbanListFilter.argv` / the fleet copier. Proven against CPython, not reasoned about: `parse_args(["--name", "-nightly", "--", sched])` → `error: argument --name: expected one argument`.

*Decision 5 — the hint with no button.* Every hint `CronRecoveryOffer` can produce tells the user to duplicate the job. There was no Duplicate anywhere in the app.

*Decision 6 — iOS's pointer.* P38 made iOS consult the shared offer first, which made `terminalRefusalMessage`'s `canRearm` branch reachable; all it did when reached was tell the user to go to the Mac.

*The MED.* `friendlyCronFailure(_:offer:)`'s no-offer arm defaulted to `?? true` and named "Resume & Run Now" — for a recurring job, a guaranteed exit 1.

*Decision 8 — the silent monitor copy.* `cronCreateArgs(copying:)` forwarded neither `--monitor-script` nor `--monitor-url`, so a fleet-copied monitor job became an ordinary agent job that ran, and billed, on every tick under a green "created".

*The tenant premise.* `KanbanTenantResolver`'s founding comment opened "Hermes Kanban has no `project_id` column". False at the target tag.

**What shipped.**

- `HermesCLIOption` (ScarfCore/Parsing) — `joined(flag, value)` is the ONE place the single-token `--flag=value` spelling is decided, with the validity boundary in its doc: plain `store`/`append` options only, never an `nargs='+'` one (kanban's `--ids`), never a positional. `contains/index/value/values` read an argv back in either spelling so the existing argv tests assert what an option CARRIES rather than its neighbour's index.
- The same family, enumerated rather than taken one at a time: `kanban complete` AND `kanban archive` append `nargs` positional ids and had no `--` while `unblock` did. Both fixed, both given a `static …Argv` builder next to `listArgv`/`promoteArgv`/`diagnosticsArgv`.
- `CronJobEditor.Mode.duplicate(job)` — an ordinary create, pre-filled. Raised from the cron detail pane beside the hint, the row context menu (unconditional — a create is accepted for any record), and the Bots routines list, which presents the SAME shared editor so the `[bot:<name>] ` prefix and the delegation wrapper round-trip verbatim. `HermesCronJob.settingsACreateFormCannotCarry` names what the FORM cannot express (`--model`/`--provider`/`--reasoning-effort`/`--monitor-script`/`--monitor-url`/`--continuity`) rather than dropping it silently.
- `HermesCronJob.duplicatedAsNewJob(id:)` for iOS, whose create is a JSON write and so loses nothing: config carried (including `extra`), run state dropped, `repeat`'s limit kept and its `completed` count reset.
- `IOSCronViewModel.resumeAndRunNow(id:)`, gated on the shared `offer.canRearm`, **with no JSON fallback** — a re-arm rewrites a terminal record's schedule, claims and repeat counter (`cron/jobs.py:2036-2075`), the exact state `_reject_terminal_activation` exists to stop a client inventing.
- `CronCopySet.monitor` — the monitor partition at the SAME seam `scriptOnly` uses, so the preview the user approves and the set the executor acts on stay identical. `--continuity` is a downgrade note, not a refusal, counted on the success arm.
- `HermesKanbanTask.projectId` / `.providerOverride` decoded; a `Provider:` chip beside the existing `Model:` one, gated on the new `hasKanbanProviderOverride`.

**Floors (walked, not asserted).**
- `provider_override` in `_TASK_DICT_FIELDS` — grepped across all `v2026.*` tags: first and only tag with it is `v2026.9.7` (0.21.1); `v2026.8.31` (0.21.0) has `model_override` and not it. → `isV0211OrLater`. The DECODE stays ungated and tolerant; only the chip is gated.
- Every option converted to `=` was re-opened at `v2026.9.7` and confirmed a bare `add_argument` with no `nargs`: `hermes_cli/subcommands/cron.py:25-31,32-49,51-62,63-88,91-128` and `hermes_cli/kanban_parser.py:59,64,81,263-316,335-339,444`.

**NO-OPs, deliberate.**
- Decision 7 was applied to the CRON and KANBAN builders only, as the decision says. The same shape is live at ten other sites — `WebhooksViewModel` (`--prompt/--events/--description/--skills/--deliver/--deliver-chat-id/--secret`), `BotsService` (`--clone-from/--description`), `SkillsViewModel` (`--category/--name`), `CredentialPoolsViewModel` + `OAuthFlowController` (`--label`), `SessionsViewModel` (`--session-id`), `HermesPeerCLI` (`--idempotency-key`), `CuratorService` (`--skill`), `HermesMCPAdd`. Filed rather than widened.
- The Mac's create FORM was not grown a `--model`/monitor/continuity field. Naming the gap is this phase's answer; widening the form is a feature.
- `CronScheduleArgument.swift:6`'s tag and `exportAllExcludesTrace`'s `:385-389` cite were both already correct — fixed by an earlier phase, re-verified here, not re-touched.

**Tests watched fail before the fix.** `HermesCLIOptionP42Tests.kanbanCreateCarriesEveryUserTextValueInOneToken` against a `--body` reverted to two tokens (2 issues). `CronRecoveryP42Tests`'s three no-offer assertions are the pre-P42 default inverted, and the two suites that PINNED that default — `CronRecoveryP38Tests.noOfferKeepsTheOldWording` and `CronViewModelErrorClassificationTests.terminalRefusalsGetAFriendlyMessage` — failed on the real change and were rewritten to the new contract. `M5FeatureVMTests.p42*` fail without `resumeAndRunNow` existing at all.

**Lessons.**

- [gotcha] **`--` protects positionals only.** Several phases of careful `--` placement left every free-text OPTION value a live argparse exit 2, because `--` ends the options and argparse tests an option's VALUE for option-ness before consuming it. The two guards are independent and a surface needs both #cli #argv
- [gotcha] **A default of "we cannot rule it out" is a guess.** `friendlyCronFailure`'s `offer?.canRearm ?? true` was written as caution and behaved as a claim: with no record in hand it named a button Hermes refuses for the commonest terminal shape. When a fact is unknown, assert the subset that is true for every case — not the optimistic case #verification
- [gotcha] **A fix at the executor is a fix in one of two places.** The monitor skip belonged in `copyableCronJobs`, which is documented as the single source of truth for "which jobs" and is what the PREVIEW counts; adding it only to the executor loop would have left the user approving a number the pass would not deliver #process
- [gotcha] **A false premise outlives the code it justified.** "Hermes Kanban has no `project_id` column" justified the tenant surrogate, went stale, and was still load-bearing prose three releases later. The surrogate is still right — `project_id` references Hermes's own `projects.db` and a non-resolving id is silently DROPPED at create (`kanban_db.py:1124-1127`) — but the stated reason had to be replaced with the real one, in the code and in the two memory notes that had copied it #verification
- [convention] **`argv.contains("--flag")` pins nothing and breaks on a spelling change.** Assert the VALUE through an argv inspector; assert the literal token only in the test whose subject IS the spelling #testing

### P42b — the round-4 review of P42's seven commits (`b30c3983`)

Five findings from an independent audit of `5e1550b6`…`4275fbfb`. All five fixed in one commit.

- [gotcha] **Grepping a CONSTANT dates the file it lives in, not the key it names.** P42 floored
  `hasKanbanProviderOverride` at v0.21.1 because `_TASK_DICT_FIELDS` — the name it grepped — first
  exists at `v2026.9.7`. That tag is where the task dict MOVED
  (`hermes_cli/kanban.py::_task_to_dict` → `hermes_cli/kanban_output.py::_TASK_DICT_FIELDS`); the
  key is two releases older. Opening `hermes_cli/kanban.py` at every `v2026.*` tag:
  `"provider_override": t.provider_override` enters `_task_to_dict` at **`v2026.7.30:80`**
  (`pyproject.toml` = `0.19.1`) and is present at `v2026.8.31:80` — the tag the doc AND the test
  both cited as proof of absence — while `v2026.7.20` (0.19.0) has no occurrence of the name in the
  file. `cmd_list` prints `[_task_to_dict(t) for t in tasks]` at `v2026.7.30:1594`, so storing and
  emitting begin at the same tag. Floor is `isV0191OrLater`. **The rule: a tag walk means opening
  the file at each tag; a walk that greps one identifier proves only when that IDENTIFIER was
  born.** #capability-gating #verification
- [fact] **`project_id` gets no flag, and that is the answer, not an omission.** Walked the same
  way: `"project_id": t.project_id` enters `_task_to_dict` at `v2026.7.1:72` (0.18.0) and is absent
  at `v2026.6.19`. But nothing in Scarf RENDERS it — it is decode-only and `decodeIfPresent`, so a
  pre-v0.18 row answers `nil`, which is exactly what an unlinked task answers. A flag would gate
  nothing. Add one the day a surface reads it #capability-gating
- [gotcha] **The same missing field is a refusal on one platform and a ghost on the other.** The
  duplicate sheet seeded `schedule.editValue`, i.e. the raw `run_at`, for a spent one-shot. On the
  Mac that is a guaranteed exit 1 — `cron create` → `_next_run_or_reject_past_oneshot`
  (`cron/jobs.py:1758` → `:1669-1680` → `:1663-1666` @ `v2026.9.7`). On iOS, where create is a
  `jobs.json` rewrite with no CLI in the path, the copy LANDS and is "scheduled" forever, because
  the misfire backstop refuses to resurrect a one-shot past `ONESHOT_GRACE_SECONDS`
  (`cron/scheduler_provider.py:274-279`). **Where Hermes owns the file, the CLI's refusal is also
  Scarf's only validation — so a platform that writes the file directly has to reimplement the
  refusal at its form.** `duplicateSeedSchedule(now:)` blanks the seed; `duplicatedAsNewJob` drops
  the dead `run_at` and its `display` from the record; `CronEditorView.isValid` refuses a `once`
  with no usable time #ux #verification
- [fact] **iOS's duplicate was already going through the editor**, so the C3-adjacent "iOS writes
  `jobs.json` directly" question did not have to be reopened: the duplicate is seeded into
  `CronEditorView` and saved through `IOSCronViewModel.upsert`/`saveJobs`, the same path every iOS
  cron create has always used. The gate belongs in that editor, and that is where it went
- [gotcha] **A "what the form can't carry" list is host-shaped as well as record-shaped.**
  `settingsACreateFormCannotCarry` named only the fields with no widget, while both call sites were
  already blanking `workdir`/`noAgent`/`failureDeliver` below their floors (v0.12 / v0.13 /
  v0.21.1) before calling `createJob`. A `--workdir` job duplicated onto a pre-v0.12 host reported a
  faithful copy. It takes `caps` now #capability-gating
- [fact] **There is no `--context-from` on `cron create`/`edit` at `v2026.9.7` at all.**
  `hermes_cli/subcommands/cron.py:76-84` and `:115-120` expose `--continuity`/`--no-continuity`
  only, which `_apply_continuity` implements purely as "ensure/remove `self` in `context_from`"
  (`tools/cronjob_job_args.py:313-323`); the only setters for a cross-job ref are the agent's
  `cronjob` tool and the web dashboard. So the fleet copier SURFACES the loss and does not forward
  it — and could not usefully forward it anyway: `_validate_context_from_refs` (`:326-337`) rejects
  any non-`self` ref the TARGET profile's `get_job` cannot find, and every id in the list is the
  source host's. `crossJobContextRefs` splits the field from `hasRunToRunContinuity` #cli
- [gotcha] **"Wait and retry" is a remedy that has to be walked like a button.** The live-claim
  arm's copy says "a run is in progress; try again after it finishes", and that only holds because
  `_claim_is_live` (`cron/jobs.py:2031-2037` @ `v2026.9.7`) is true ONLY for a well-formed claim
  aged within `[0, ttl)` — run claim ≥ 1800s (`ONESHOT_RUN_CLAIM_TTL_SECONDS`, `:154`,
  applied as a FLOOR by `max(timeout * 3, 1800)`, `:174` — corrected by P42c; the 600 is
  `_DEFAULT_CRON_INACTIVITY_TIMEOUT`, `:161`), fire claim 300s (`:891`) — and counts a
  future-dated or malformed claim as STALE so it can never wedge a job. A claim therefore cannot
  outlive its run. `_REARM_RECURRING_ERROR` (`:2040-2042`, raised at `:2054` and `:2066`) got the
  other arm. Both used to fall through to the generic `prefix(200)` truncation of raw CLI text

**P42b test results.** ScarfCore **2857/2857** (no ACP flake in this run). Mac `scarfTests`
**1196/1196 serial**. `scarf` and `scarf mobile` both build. **16 new tests in four suites**:
`HermesKanbanProviderFloorP42bTests` (4), `CronDuplicateSeedP42bTests` (5) and
`CronCopyGapsP42bTests` (4) in `ScarfCoreTests/HermesCronKanbanP42bTests.swift`;
`CronRearmRefusalP42bTests` (3) in `scarfTests/CronRecoveryP42bTests.swift`. Seven catalogue keys in
all six locales.


## Whole-surface remediation — P43 (C10 residue, `t-e23f78e6`)

Commits `65e26ec7`, `088ca1e6`, `4a3e4932`, `66319415` (test determinism) and
`9c5d29a1` (fresh eyes) on `fix/whole-surface-audit-r4`. Round-4 decisions 15
and 16.

Full detail: [[Process.waitDraining lives in ScarfCore — the two halves of a piped spawn, and the poll-interval trap]].

- [decision] **Decision 15 done: `Process.waitDraining` moved DOWN, not copied.** It was
  written in the app target (P33, hoisted out of `HealthViewModel.dashboardListenerPID`), but
  every remaining unbounded wait was in ScarfCore — and a package cannot import its client. One
  definition, `ScarfCore/Models/ProcessTimeout.swift`, `#if !os(iOS)`; the app-target copy is
  deleted and `AppRelauncher` gained an `import ScarfCore`. Named budgets:
  `RemoteRestoreService.unzipTimeout` 900 s, `.remoteExtractTimeout` 300 s (the transfer is
  already done when that wait begins), `RemoteBackupService.zipTimeout` 900 s — each an
  injectable parameter defaulting to its own constant #c10
- [gotcha] **A bounded poll is not the second half of C10, and P43's five findings were all
  the same shape.** `run` → bounded poll → `readToEnd()` still deadlocks a child past the 64 KB
  buffer; it merely ends in a timeout rather than a hang, so the caller reports failure for a
  child that was working. `enforceArchiveBounds` is the worst case: the stall ran the budget
  out and the caller's `try?` turned that into "no bomb caps at all", for exactly the input
  that would want them skipped #c10
- [decision] **Decision 16 done, and wider than the finding.** `enforceArchiveBounds` refuses
  when the listing cannot be read — and "cannot be read" is three arms, not one: the spawn
  failed, it outstayed its budget, or it came back unparseable. The helper also throws on a
  non-zero exit now; it used to return the empty stdout of a failed `unzip -Zt`, which parsed
  into no fields and so checked nothing — the same fail-open one frame lower. Four sentences
  localized into the six shipped locales
- [gotcha] **`unzip -Zt` prints `1 file,` for a single-entry archive, not `files,`.** The old
  field walk knew only the plural. Harmless while the guard failed open (the cap was skipped);
  the moment it became a refusal it would have rejected a legitimate one-file template.
  `parseArchiveListing` takes both spellings and a test runs the real `unzip` on a real
  one-entry zip. **The lesson: flipping a fail-open to a refusal re-reads every parse failure
  as a verdict, so the parser's blind spots become user-visible on that flip, not before**
- [gotcha] **`waitUntilExit(timeout:)` sleeps `pollInterval` (0.05 s) before re-checking**, so
  a budget under that is really "50 ms or one poll turn, whichever is later". An overrun test
  passing `timeout: 0.001` needs a child whose work outlasts 50 ms — a 6 MB unzip finishes
  inside it, a 24 MB one does not. Cost one flaky full-suite run to find #testing
- [fact] **The Spotify deadline is Hermes's own number.** `_spotify_wait_for_callback` waits
  180 s (`hermes_cli/auth_spotify.py:154`, passed at `:420` @ v2026.9.7) and the token
  exchange adds 20 s (`:433`), so a healthy run always ends by itself; Scarf's 240 s ceiling is
  reached only when the child cannot report at all. The flow also never unhooked its
  `readabilityHandler`s on EOF — `cancel()` did, and a SUCCESSFUL run never calls `cancel()`
- [gotcha] **Folding two `[weak self]` closures into one local `func` is a retain cycle.** A
  local func captures `self` strongly, and this one is stored on a pipe `self` owns. Caught in
  P43's own fresh-eyes pass (`9c5d29a1`), together with three C10 budgets accidentally filed
  inside a `#if canImport(os)` block that exists to guard the LOGGER
- [done] **t-b15ba4c3 closed.** `AppRelauncher.relaunch()` is `nonisolated`; P33 bounded its
  `open(1)` wait at 20 s but left it ON the main actor, so a wedged `lsd` froze the window for
  the whole budget. `ProfilesViewModel.switchAndRelaunch` calls it from its detached task. That
  emptied the P22 sweep's allowance list — and an empty list makes its
  `isolatedScanned == allowed.count` floor 0 == 0, true however broken the matcher is. The
  matcher is a named function now with a calibration test that plants each shape and each
  near-miss. P38 item 23 HAD already added the `isRunning` poll and the semaphore/group block
- [todo] **Left for others (`t-10eb7c17`)**: the repo-wide grep's remaining sites, all PRE and
  outside P43's named scope — `LocalTransport:324`/`:331` and `SSHTransport:1122`/`:1133` (a
  bare `waitUntilExit()` after `terminate()`, and an unbounded `else` arm), the four streaming
  spawns that read stderr after the wait with nothing draining it during the run
  (`LocalTransport:390`/`:454`, `SSHTransport:782`/`:854`), and `TestConnectionProbe:182-202`,
  where a verbose ssh trace over 64 KB is the EXPECTED case and wedges the probe into a false
  "Timed out after 20s"

**P43 test results.** ScarfCore **2864/2864** (clean in one full run of three; the other two
showed only the known `ACPClientStartIdempotenceTests` load flake — t-f3820038 — 5/5 green in
isolation). Mac suites run serially: `SpawnDisciplineP43Tests` 9, `ProjectTemplateBoundsP43Tests`
8, `MainActorSpawnDisciplineP22Tests` 17 (was 16), `HermesP38SourceSweepTests` 3,
`LocalizationCatalogTests` 10, `ConfigReadProofP33Tests` 6, plus `ProjectTemplateServiceTests` 6,
`ProjectTemplateInstallerTests` 8, `ProfilesViewModelParsingTests` 7,
`RemoteProfileExportPipelineTests` 7. **24 new tests in three suites**:
`ProcessDrainP43Tests` (7, ScarfCore), `ProjectTemplateBoundsP43Tests` (8) and
`SpawnDisciplineP43Tests` (9). `scarf` and `scarf mobile` both build.


### P42c — the re-audit of P41b's and P42b's commits (`a2280ab6`, `b30c3983`)

Four findings; all four dispatched in one commit, `71e8bad9` on `fix/whole-surface-audit-r4`.

- [gotcha] **A DERIVED field that the producer PREFERS over what it derives from is not a
  display detail — it is a shadow.** Hermes's `_schedule_display_for_job`
  (`cron/jobs.py:438-446` @ `v2026.9.7`) returns the stored TOP-LEVEL `schedule_display`
  whenever it is non-empty and only then falls back to `schedule.display` / `value` / `expr`
  / `run_at`; `_normalize_job_record` stamps the result onto every record Hermes reads
  (`:470`). Scarf never modelled the key, so it rides in `extra` and `encode` re-emits it
  verbatim. P42b blanked `schedule.run_at` and `schedule.display` on the iOS duplicate and
  stopped there, so the copy still announced the source's 2020 label to every reader,
  `cron list` included. New `HermesCronJob.droppingDerivedScheduleDisplay`, applied
  UNCONDITIONALLY in `duplicatedAsNewJob`: a field whose producer re-grants it on the very
  next read can only ever cost a derivation to drop, so there is nothing to weigh
  #config-parsing
- [gotcha] **The duplicate was the visible half; the ORDINARY edit had the same bug, because
  they share one writer.** `CronEditorView.buildJob` (`Scarf iOS/Cron/CronListView.swift`)
  is behind both the iOS duplicate sheet and an ordinary iOS edit, and it forwarded
  `existing?.extra` unconditionally — so re-timing a LIVE job from the phone left the
  previous time's label in front of the new one. It now drops the key whenever the built
  schedule differs from the stored one (`existing?.schedule != schedule`, which covers a kind
  switch, a new `run_at`, a new expression and an edited `display` alike) and keeps it when
  nothing moved. The general shape: when a finding names a special path (duplicate, import,
  restore), find the WRITER that path goes through and ask what else goes through it
- [fact] **The one-shot run-claim TTL is ≥1800s, not ≥600s.** `ONESHOT_RUN_CLAIM_TTL_SECONDS
  = 1800` (`cron/jobs.py:154`) is a FLOOR, not a fallback: `_oneshot_run_claim_ttl_seconds`
  returns it outright for `HERMES_CRON_TIMEOUT=0` (`:173`) and otherwise
  `max(timeout * 3, 1800)` (`:174`). The 600 four lines below the constant is
  `_DEFAULT_CRON_INACTIVITY_TIMEOUT` (`:161`) — an INACTIVITY limit that feeds the
  multiplication, not the TTL. P42b's doc and test both quoted the neighbour. Corrected in
  `CronViewModel`'s `rearm_oneshot` arm and `CronRecoveryP42bTests`; no locale changed,
  because the copy states no duration ("try again after it finishes") — the wrong number only
  made the honesty argument weaker than it actually is
- [convention] **An iOS-only catalog key must be registered the same commit it is added.**
  Xcode's extractor runs from the macOS scheme and PRUNES any key it cannot see there, and
  the iOS scheme never writes back — so `"Pick a future time — a one-shot more than %lld s in
  the past can never fire."` and `"Duplicate cron job"` (both `Scarf iOS/Cron/CronListView
  .swift`, `:329` / `:171`) were one macOS extraction from deletion. Both added to
  `LocalizationCatalogTests.iosOnlyKeys`. The sweep that found them is the one to repeat: diff
  the catalog's keys against the phase's base commit, then match each new key's non-format
  literal chunks against every `.swift` file under `scarf/scarf`, `Scarf iOS`, `ScarfCore` and
  `ScarfGo` — 46 keys since `5be08f2e`, exactly these two iOS-only
- [gotcha] **"For symmetry with the other arm" is a reason to check the other arm, not to
  copy it.** P41b accepted a TAB after the value indicator in `blockKeySpan`'s quoted arm
  "for symmetry with the plain arm"; the plain arm (`plainKeySeparatorIndex`) was wrong too.
  PyYAML's SCANNER refuses a tab there in every shape — verified 6.0.3: `'q':\tv`,
  `"q":\tv`, `plain:\tv`, a bare `'q':\t`, `plain:\t` and `'q'\t: v` are all ScannerError
  ("found character '\t' that cannot start any token"), while `'q' : v` and `plain: v` load.
  So a tab-separated line is not a row Hermes can load, it is a document Hermes discards
  whole (`gateway/config.py:775-791`). Both arms now require a SPACE (or end of line) on both
  sides of the colon, and `pyYAMLRefusesEveryTabSeparatedRow` compares Scarf's verdict to the
  real interpreter's in BOTH directions — six refusals and five acceptances — so the rule
  cannot drift into over-refusal either. The tightening reached four doc comments that still
  said "colon followed by whitespace" #yaml

**P42c test results.** New `CronScheduleDisplayP42cTests` (6, ScarfCore): a decoded real
record for the duplicate half, and a P38-style SOURCE sweep for `buildJob`, which is `private`
to a SwiftUI view in the iOS target — a target neither test host builds, so the shape in the
source is the only available alarm. `HermesP41bYAMLTests` +2 tests, +9 parameterized cases.
Each fix watched failing against its reverted form. ScarfCore **2871**, green but for the known
`ACPClientStartIdempotenceTests` flake (5/5 in isolation). Mac serial: `HermesP38SourceSweepTests`
3, `LocalizationCatalogTests` 10, `CronRearmRefusalP42bTests` 3, `CronRecoveryP42Tests` 11,
`HermesP41bRefusalTests` 18. `scarf` and `scarf mobile` both build.

**A trap worth naming:** the phase brief asked for `-only-testing:scarfTests/CronRecoveryP42bTests`.
That is the FILE name; the suite inside it is `CronRearmRefusalP42bTests`. The filter matched
nothing and xcodebuild printed **TEST SUCCEEDED** anyway — addendum lesson 8, met in the wild.
Always read the Swift Testing "Test run with N tests" line, never the exit status.


### P43b — the review of P43's five commits (`204e1284`, plus the eleven files swept into `a1e333cc`)

Ten findings from an independent audit of `65e26ec7` + `088ca1e6` + `4a3e4932` + `66319415` +
`9c5d29a1`. All ten fixed.

- [gotcha] **A bounded wait placed AFTER the pump is not a ceiling on anything.**
  `RemoteRestoreService.pushTarball` installed no reader on `outPipe`/`errPipe` until the whole
  tarball was through the pipe, so a remote `tar -x` that reports a problem per member filled its
  64 KB stderr buffer, stopped reading stdin, and the parent blocked in `writer.write()` — BEFORE
  the `remoteExtractTimeout` wait that was supposed to rescue it. `checkCancellation` only ran
  between chunks that had stopped coming. **The general rule: the drain must be installed before
  the parent's LAST write to the child, not before its first read.** `Process.waitDraining` split
  into `startDraining(pipes:) -> ProcessPipeDrain` + `waitDraining(timeout:drain:)` for exactly
  this shape #c10
- [gotcha] **You cannot rescue a blocked `write()` from outside the thread that is blocked.** The
  first draft of the fix carried a stall timer that SIGKILLed the child; the reproduction still
  wedged past three minutes. A shell child has grandchildren that INHERITED the pipe's read end, so
  killing the one pid Scarf may signal does not close it — and signalling the process GROUP is not
  available, because Foundation's children share Scarf's group and `kill(-pid, …)` would take Scarf
  with it. The pump is `O_NONBLOCK` now: `EAGAIN` is where the stall ceiling
  (`RemoteRestoreService.pumpStallTimeout`, 120 s of NO progress — not a transfer budget) and
  `Task.checkCancellation()` get their turn, and `EPIPE` is a return value rather than a signal
  (`F_SETNOSIGPIPE` per-fd, no global disposition touched) #c10
- [fact] **Measured: it is the READ ends of a `Pipe` that leak, never the write ends.** 50 `/bin/echo`
  spawns holding their `Pipe`s: read ends left open took `/dev/fd` from 4 to 104 (2 per spawn);
  write ends left open kept it at 4, because Foundation closes the parent's copy as part of the
  spawn. The "each spawn leaks 4 fds"/"every relaunch leaked two fds" rationales in
  `ProjectTemplateService` and `AppRelauncher` were false. The closes are KEPT — on the
  launch-failure path `run()` never spawned and they are the real release — with the rationale
  corrected, and `SpawnDisciplineP43Tests.onlyReadEndsLeak` measures it rather than asserting it
- [gotcha] **A temp dir handed to the caller on success is the caller's ONLY on success.**
  `inspect()` created `scarf-restore-<uuid>` before unzipping and removed it on no throwing path,
  so a `.scarfbackup` refused at the unzip left however much had landed behind, once per attempt.
  `defer` + a `handedToCaller` flag
- [gotcha] **The P40 EOF-latch lesson had a third site.** `SpotifyAuthFlow` judged inside
  `terminationHandler`, reading `tail(output)` while the last stderr chunk was still in flight —
  and `hermes auth spotify` writes the line that explains a failure immediately before it exits.
  Two `ProcessOutputInbox`es (one per pipe, EOF latched per pipe), a `pump()` that judges only once
  BOTH EOFs and the exit status are in, and a 2 s `scheduleDrainDeadline` for the case where a
  grandchild holds a write end open. Its `cancel()` was a bare `terminate()` with no escalation on
  the one path that exists because the child would not stop, and closed the READ ends while a
  `readabilityHandler` could still be on them; it now escalates through `waitUntilExit(timeout:)`
  on a detached task (never the main actor) and lets the reader close what it drained
- [gotcha] **A sweep floor of `scanned == allowed.count` proves nothing once `allowed` is empty.**
  `0 == 0` passes however badly the enumeration is broken. `MainActorSpawnDisciplineP22Tests` now
  counts the `.swift` files it actually opened, per root (`> 20` each, `> 450` total against a real
  559), `try #require`s each enumerator instead of `continue`ing past a `nil`, and a separate
  `sweepRootsExist` test pins the three roots #testing
- [gotcha] **A refusal is a disposal path.** `TemplateInstallerViewModel.openRemoteURL` downloads to
  its own temp file; a refused inspect stranded it forever — the common case now that an unreadable
  listing IS the answer. `openLocalFile(_:source:removeArchiveWhenDone:)`, true only for the
  download, never for a file the user picked
- [testing] **A deterministic drain test is a child that PROVABLY cannot exit, not a big one.**
  `unzipArchiveIsBounded` was a 24 MB zip against a 1 ms budget — a bet that unpacking outlasts one
  50 ms poll turn. It is a FIFO nobody writes to now: `open(2)` blocks in the kernel until a writer
  appears, and none ever does. (`zip` skips FIFOs, so the backup side keeps its own shape.)
  `enforceArchiveBounds` gained its missing happy path and both cap paths — a legitimate four-file
  template, a 5001-entry zip, and a one-member 300 MB-of-zeros bomb that compresses to ~300 KB so
  the archive-size cap cannot be what refuses it #testing
- [fact] `ProjectTemplateExporter.zipTimeout` is `nonisolated static let` — the `AppRelauncher`
  defect, second instance: a main-actor-isolated static read from the `nonisolated` `zipDirectory`

**P43b test results.** ScarfCore `ProcessDrainP43Tests` 11/11; Mac
`SpawnDisciplineP43Tests` + `ProjectTemplateBoundsP43Tests` + `MainActorSpawnDisciplineP22Tests` +
`HermesP38SourceSweepTests` + `ProjectTemplateServiceTests` 52/52 serial; `scarf` builds with no new
warnings. A full ScarfCore `swift test` run under a load average of 176 (the concurrent P44 agent)
reported timeout-shaped failures in `M0bTransportTests`, `ACPClientStartIdempotenceTests`,
`M4ACPIOSTests` and P43's own chatty-child test; every one of them passed in isolation.


### P43c — the second review of P43 (`f2a27cdf`)

Five findings from a re-audit of `204e1284`. All five addressed in one commit.

- [gotcha] **A non-blocking loop that naps a fixed interval is slower than the blocking call it
  replaced, by three orders of magnitude.** P43b made the tarball pump `O_NONBLOCK` — correctly: a
  blocked `write()` into a child cannot be rescued from outside — and then waited at `EAGAIN` with
  `Task.sleep(20 ms)`. A pipe drains in microseconds, so the parent moved ONE pipe-full per tick
  whatever the link could do: 4138 MB/s blocking against 2.8 MB/s asleep on a 64 MB payload, i.e.
  most of a day added to a 16 GB Hermes home. `poll(2)` for `POLLOUT` is the wait that has both
  properties — it wakes on the byte AND it is capped, at
  `min(remaining stall budget, pumpPollSlice)` (200 ms), which is where `Task.checkCancellation()`
  still gets its turn. **The rule: when you replace a blocking call to regain control, the
  replacement must still block on the same EVENT — a timer is not the event** #c10
- [gotcha] **`Task.detached` does not move a block off the cooperative pool — it IS the cooperative
  pool.** `waitDraining` is a `Thread.sleep` poll loop, and `streamTarball` called it from `async`
  code: up to `remoteExtractTimeout` (300 s) parked on a pool that is one thread per core and
  cannot grow. The new `Process.waitDrainingAsync` runs the reap on a dedicated thread
  (`Thread.detachNewThread`) and suspends the caller on a continuation;
  `RemoteRestoreService.unzipArchive` and `RemoteBackupService.zipDirectory` became `async` so
  their `async` callers stop blocking too. `SpotifyAuthFlow.reapDetached`'s `Task.detached` was the
  cited precedent and is the shape to NOT copy — it was right for its own purpose (getting off the
  MAIN actor) and wrong for this one #c10
- [gotcha] **A fixed-width queue full of blocking reads re-enters the pipe deadlock from outside.**
  `ProcessPipeDrain`'s readers sat on `DispatchQueue.global(qos: .utility)`, each blocked in
  `readDataToEndOfFile` until its child closed the write end. With several piped spawns in flight —
  a full `swift test` is exactly that — every thread of that queue is parked and the NEXT spawn's
  drain is never scheduled, so the child it was meant to unblock fills its 64 KB stderr buffer and
  wedges. One thread per reader instead. It removed the long-standing
  `ProcessDrainP43Tests.pumpSurvivesAChattyChild` flake (which reproduces on `204e1284` itself, so
  it was never P43c's) and took a full ScarfCore `swift test` from 31.7 s to 25 s #c10
- [gotcha] **"Idempotent" means holding the lock across the WAIT, not across the read and the
  write.** `ProcessPipeDrain.collect(grace:)` checked the latch under one lock and set it under
  another, so two callers could both find it empty, both wait, and each return whatever had
  arrived by its own deadline — with the late answer overwriting the early one. One `NSLock` held
  across the whole call; an `NSLock` and not an unfair lock precisely BECAUSE it is held across a
  blocking wait
- [gotcha] **Every give-up arm was discarding the explanation it had just collected.**
  `_ = proc.waitDraining(…)` in `abandon()`, and then `EPIPE`, the stall ceiling and the
  extract-timeout arm all reported the mechanical consequence — "Broken pipe" — for a run whose
  stderr said `tar: /nope: Cannot open`. A give-up arm fires precisely when the child has stopped
  cooperating, and a child stops cooperating by saying why: `abandon()` returns the drain and each
  arm appends `outputTail` (last four non-blank lines). `drainCollectGrace` is 5 s rather than the
  1 s default for the same reason — it was a one-second grace that first lost `tar`'s message
  under load
- [testing] **Wall-clock throughput is not a testable property on a machine running 2900 other
  tests.** The throughput floor the finding asked for was written three ways and thrown away three
  times: 64 MB into `cat > /dev/null` (the pipe is only intermittently full there, so the sleeping
  pump measures 3-16 MB/s and part of that range passes any honest bound); 32 MB into a reader that
  takes one pipe-full and pauses, which DOES pin the sleeping pump to the tick but whose polling
  floor is the reader's pace and inflates 5x under parallel load; and the same normalised against a
  blocking-`write` baseline measured in the same test, where the ratios overlap outright — 8.6x for
  the sleep in isolation against 6.6x for `poll` under load. What ships is the MECHANISM: the wait
  ends when the reader takes a byte (5 ms against a 200 ms budget, a 40x margin) and is capped when
  no byte comes. It fails against the sleep for the same reason the throughput test did, and it
  does not move with load #testing
- [gotcha] **`-only-testing` needs the PARENT path for a nested suite.**
  `scarfTests/AnalyticsFeatureUsageEventsTests` is the FILE name and matches nothing (silently —
  the run prints no test count at all); the suite is declared inside
  `extension AnalyticsConnectionEventsTests`, so the path is
  `scarfTests/AnalyticsConnectionEventsTests/AnalyticsFeatureUsageEventsTests` and runs 16 tests.
  This is the P42b file-vs-suite lesson with a second level. `scarfTests` is a
  `PBXFileSystemSynchronizedRootGroup`, so `project.pbxproj` lists no files and grepping it cannot
  tell you whether a suite is live — the sources are the only roster. (The P43b note does NOT in
  fact claim this suite is dead; the only mention anywhere is `t-6ba8c1ce`, which correctly calls
  it a parallel-load flake that passes in isolation) #testing
- [todo] **The app target has five more sync waits under `Task.detached`** —
  `ProjectTemplateService` (×2), `ProjectTemplateExporter`, `AppRelauncher` (a 20 s budget),
  `HealthViewModel`, and `HermesFileService.runShellProbe`. P43c scoped itself to ScarfCore; filed
  as `t-12d04477`, which also asks for the sweep's second root and for the `Task.detached { … }`
  closure shape the declaration-scoped matcher does not see

**P43c test results.** ScarfCore **2905** in 205 suites, green — the only residue across five full
runs is the known `ACPClientStartIdempotenceTests` load flake (5/5 in isolation, t-f3820038), and
`M0bTransportTests` / `M4ACPIOSTests` did not flake at all this round. Mac serial:
`SpawnDisciplineP43Tests` 13, `ProjectTemplateBoundsP43Tests` 13,
`MainActorSpawnDisciplineP22Tests` 18, `HermesP38SourceSweepTests` 3, `HermesMCPOAuthFlowTests` 10.
`scarf` builds with no new warnings. **9 new tests**: `ProcessAsyncWaitP43cTests` (5, new file),
`ProcessDrainP43Tests` +3, `SpawnDisciplineP43Tests` +1. Each was watched failing against its
reverted fix.



## Whole-surface remediation — P44 (chat/settings residue, `t-83c1e3b5` + `t-6fa3fc84`)

Commits `a1e333cc`, `80d3522d`, `fdc2c981`, `0898bf07` on `fix/whole-surface-audit-r4`.
Round-4 decisions 12, 13 and 14, plus three of the surface's LOWs.

- [gotcha] **Gating the MENU is only half the gate.** P37 hid `/steer` and `/queue` below
  their v0.13 floor and the finding stopped there — but the user can still TYPE either name,
  and over ACP an unknown name is not an error: `_handle_slash_command` returns `None` for a
  name outside `_COMMANDS` and the raw text goes to the LLM (`acp_adapter/commands.py:88-95`
  @ v2026.9.7). So a pre-v0.13 host got "Queued — runs after current turn.", the queue chip,
  and `isNonInterruptiveSlash` suppressing the working indicator, over a real turn the model
  was answering. The rule that falls out: **whenever a capability gate hides a row, ask what
  the typed path does** — the two must share one predicate, not two derivations of it
  (`nonInterruptiveSlashIsDispatched`, asked by `availableCommands` AND by both send paths)
  #capability-gating
- [decision] **Decision 12 notices rather than refuses.** Below the floor Scarf sends the
  text as an ordinary prompt with the normal working indicator and says so in one localized
  line. It does not refuse the send (the LLM may still answer usefully) and it does not offer
  a remedy, because there is none on that host short of upgrading Hermes
- [gotcha] **A `Picker` whose selection matches no tag renders BLANK, and a blank picker is a
  write waiting to happen.** A 0.18.x host with `ultra` in config.yaml showed an empty control
  and the first unrelated save on that tab wrote whatever the user nudged it to.
  `ReasoningOverridesSection` had the fix in a private `effortOptions(current:)`; the two
  top-level pickers did not. One `levels(capabilities:selected:)` now serves all three #ux
- [fact] **What Hermes does with an unknown effort is "nothing", walked at four tags.**
  `parse_reasoning_effort` returns `None` for anything outside `VALID_REASONING_EFFORTS` and
  the disable aliases and the caller then uses the default — `hermes_constants.py:876-889` @
  v2026.9.7, `:797-812` @ v2026.7.1, `:797-820` @ v2026.7.7, `:840-864` @ v2026.7.20. Not an
  error, not a clamp to the nearest tier: the model provider's own default, which is exactly
  what the picker's empty "Provider default" row already means. That is what decision 13's
  affordance says, because "not supported" alone would not tell the user what they have
- [done] **Decision 14 retired the flag, not just the arm.** `hasACPSteerOnIdle` was
  `hasACPSteer` expressed a second time (the idle fallback shipped in `/steer`'s own commit,
  `acp_adapter/server.py:812-820` @ v2026.5.7) and its only reader was an arm the P37 roster
  gate had already made unreachable. Its replacement is the LOW it was sitting on: `/queue`
  greys out on an idle-but-open session, because `_cmd_queue` appends unconditionally
  (`commands.py:285-289`) and the only drain is the tail of a running turn (`server.py:908-915`),
  so on idle the prompt runs two turns later — and that arm is gated on `hasACPQueue`, i.e. on
  the row existing, so it cannot become the next dead arm
- [gotcha] **A form that reads through Hermes's precedence and writes through a hard-coded
  spelling shows the user a value it cannot change.** `t-6fa3fc84`: `platform_section`
  (`gateway/config_loader.py:171-180`) bridges a platform's `_SHARED_KEYS` from ONE section
  and a top-level `<name>:` block REPLACES the nested one as that source. The read side has
  modelled it since P20; the write side had not. Both halves now call one type
  (`HermesPlatformSharedKeys`), and the write fix lands at the single `config set` site
  (`PlatformSetupHelpers.saveForm`) so the forms keep their literal keys — which is what keeps
  them visible to `AllConfigWritersParityTests`
- [decision] **The allowlist is the honest half of that fix.** Only slack and telegram are
  rewritten, because only their READERS resolve the bridge. Moving the other writes without
  their reads would trade half the bug for the other half — the value would reach Hermes and
  stop reaching the form, so the form would then contradict a setting that IS live. Filed as
  `t-d02dd23e`, with a test that pins `bridgeResolvedPlatforms` equal to
  `HermesConfig+YAML`'s `sharedPlatform*` call sites so a converted reader fails until its
  writer is let in
- [done] **Three of the phase's LOWs were already fixed by earlier phases**: `hasACPQueue`'s
  citation (`HermesCapabilities.swift:194-203`), `hasGoals`' doc vs the
  `nonInterruptiveCommands` NOTE (`:183-192`), and `nonInterruptiveCommands`' own v2026.5.7
  floor + gate pointers (`RichChatViewModel.swift:653-672`). Re-read against the tag and left
  alone

**P44 test results.** ScarfCore **2897** (the known `ACPClientStartIdempotenceTests` /
`M1ACPTests` / `M4ACPIOSTests` / `M0bTransportTests` 20 s load-flake family under the full
parallel pass; 74/74 green rerun in isolation). Mac suites run serially, all green:
`LocalizationCatalogTests` 10, `AllConfigWritersParityTests` 5, `HermesP38SourceSweepTests` 3,
`HermesP37ConfigUnsetFloorTests` 3, `HermesP37RefusedReadTests` 4,
`HermesP37EffortVocabularyTests` 2, `ConfigReadProofP33Tests` 6,
`GwF4OutcomeMessageChannelTests` 9, `HermesP28CrossPhaseRemediationTests` 10,
`HermesManagedRefusalP39Tests` 7. `scarf` and `scarf mobile` both build. **22 new tests in
four suites** in one file (`HermesP44Tests.swift`, ScarfCore): `TypedSubFloorSlashP44Tests` (5),
`IdleSlashGreyOutP44Tests` (5), `ReasoningEffortWideningP44Tests` (5),
`HermesPlatformSharedKeyWriteP44Tests` (7). `Localizable.xcstrings` +82 lines, 0 deletions.

**P44 process note.** `a1e333cc` accidentally carries P43's files as well as its own: the P43
agent had staged work in the shared index, and a `git commit` after `git add <my paths>`
commits the whole index, not the paths just added. Nothing was lost and every P43 change is on
the branch, but its authorship sits in a P44 commit. The lesson for a concurrent-agent branch
is `git commit -- <paths>` (or `git stash`-free `git commit -o <paths>`), not `git add` then
`git commit`.


### P44b — the round-4 review of P44's four commits (`40e8ab1f`)

Seven findings from an independent audit of `a1e333cc` + `80d3522d` + `fdc2c981` + `0898bf07`.
All seven fixed in one commit.

- [gotcha] **An affordance built on the PICKER's vocabulary accuses the host of the values the
  picker deliberately never offers.** `unsupportedLevelNotice` asked
  `levels(capabilities:).contains(selected)`, and `levels` is the OFFER list — it excludes
  `disableAliases = ["disabled","false","off"]` by construction. So `agent.reasoning_effort:
  disabled`, which `parse_reasoning_effort` maps to `{"enabled": False}`
  (`hermes_constants.py:884-885` @ v2026.9.7) — reasoning off, exactly as asked — rendered "isn't
  supported on this Hermes". The fix is a second, capability-shaped question,
  `HermesReasoningEffort.disablingSpellings(capabilities:)`, because the aliases have a FLOOR that
  nobody had walked #capability-gating
- [fact] **The disable-alias floor is v0.18.1 — the same tag `max` arrived on, and it was walked
  tag by tag.** `{"none","false","disabled"}` first appears at **v2026.7.7** (`:816`) and is
  byte-identical through `v2026.9.7` (`:885`). At **v2026.7.1** (0.18.0) and every tag before it
  the signature is `parse_reasoning_effort(effort: str)`, the body disables on `"none"` ALONE
  (`:809`), and the leading `if not effort` swallows a YAML `False` — so below the floor all three
  spellings are values the host IGNORES and the notice is the right answer there. New flag
  `hasReasoningDisableAliases`
- [fact] **`off` is not in Hermes's alias set and is still not a Scarf bug.** It disables only
  through YAML's bool coercion (bare `off` → PyYAML `False` → `str(False).lower()` → `"false"`),
  which is why the writer canonicalises it to `none` on the way out. A flat parse cannot tell
  quoted `"off"` (ignored) from bare `off` (disabled), so the affordance errs toward not accusing
  the host, and `isValid` keeps accepting it so a hand-edited row is never REJECTED
- [gotcha] **"Uses the provider's own default" was a parser-level claim, and the consumers say
  otherwise.** `parse_reasoning_effort` returning `None` is where P44 stopped. Walking on:
  `resolve_reasoning_config` logs `Unknown reasoning_effort '%s', using default (medium)`
  (`hermes_constants.py:975-976`) and returns `None`; `agent_runtime_helpers.py:2145-2147` stores
  that `None` on `agent.reasoning_config`; and `agent/transports/chat_completions.py:420-422`
  substitutes `medium` EXPLICITLY (`… else "medium"`), as does the iteration summary
  (`agent/chat_completion_helpers.py:2020`). Only `agent/anthropic_adapter.py:570` omits the
  parameter and leaves it to the model. **Hermes's own default, not the provider's** — six
  locales, and the P44 test that asserted the old wording now asserts the absence of the word
  "provider" #verification
- [gotcha] **A greyed MENU row is not a gate; the keyboard is the other door.** `/queue` greys out
  on an idle session since P44, but typing it still painted "Queued — runs after current turn."
  `_queue_prompt` appends unconditionally (`acp_adapter/commands.py:33-36` — P44 cited
  `:285-290`, which is `_cmd_queue`, the CALLER), the only drain is the tail of a running turn
  (`server.py:908-915`), and a dispatched slash command returns `end_turn` at `server.py:793-799`,
  BEFORE it. Both send paths now gate the mirror on the working state and send the ARGUMENT as an
  ordinary prompt through the shared `idleQueueFallbackText` — leaving the `/queue` prefix on the
  wire would hand it straight back to `_cmd_queue` and make the notice a lie. An empty argument is
  left to Hermes's own `Usage: /queue <prompt>` #ux
- [gotcha] **`addUserMessage` RAISES `isAgentWorking`, so "is a turn in flight" must be snapshotted
  before the local echo.** Read after the echo — which is where both slash switches sit — the flag
  is unconditionally true and the idle arm could never fire. Mac additionally subtracts
  `localEchoAlreadyAdded` (its two callers, autostart's queued prompt and the project-wizard
  kickoff, are fresh sessions that echoed a moment earlier). Any future "was the session busy?"
  question on a send path has this trap #gotcha
- [gotcha] **`{}` is a dict.** `bridgeSourcePrefix` asked `maps[section]?.isEmpty == false`, so a
  top-level `slack: {}` — which PyYAML loads as `{}` and `platform_section` takes as THE bridge
  source (`gateway/config_loader.py:175`) — read as absent, and both the read and the write side
  resolved to `platforms.slack`, whose shared keys are then never bridged. The parse was never the
  problem: `parseNestedYAML` records `maps["slack"] = [:]` for any inline flow map
  (`HermesYAML.swift:343-354`) and records NOTHING for a bare `slack:` header. `maps[section] !=
  nil` is therefore `isinstance(section, dict)` exactly, empty case included, with the bare header
  still losing #verification
- [done] **The two bare literals and the stale flag name.** `disabledSlashCommandReason` had BOTH
  sentences unlocalized (the finding named one); `UnsupportedEffortNote`'s accessibility label was
  the third. Four catalogue keys, six translations each. `hasACPSteerOnIdle` gets a one-line
  retirement note atop the hand-authored `scarf/docs/v2.8/WS-2-goals-and-queue-plan.md` rather
  than a rewrite of history, and this note's own P36 paragraph no longer describes the flag as
  current
- [todo] **Left standing, deliberately.** The user's bubble still shows the literal `/queue …`
  while the wire carries the bare argument — the same divergence project-scoped expansion has had
  since v2.5, and the notice is what explains it.

**P44b test results.** ScarfCore **2927** (the four known `ACPClientStartIdempotenceTests` load
flakes under full parallel load; 5/5 green in isolation — t-f3820038). Mac suites serial, by name
and with non-zero counts: `HermesP38SourceSweepTests` 3, `LocalizationCatalogTests` 10,
`HermesP37EffortVocabularyTests` 2, `AllConfigWritersParityTests` 5,
`ChatViewModelSendDedupTests` 2, `ChatViewModelStartLifecycleTests` 14. `M9SlashCommandTests` (48)
and `HermesP37RemediationTests` (13) are ScarfCore suites, not `scarfTests` — a
`-only-testing:scarfTests/M9SlashCommandTests` filter matched NOTHING and still printed TEST
SUCCEEDED, which is the addendum's rule catching a real miss. All P44 + P44b suites: **44 tests in
8 suites**. Both schemes build. **22 new tests in four suites** in
`HermesP44bTests.swift` (ScarfCore).


## Round 4 — memory audit (2026-09-11)

A tier-wide pass over `.memory/` against `fix/whole-surface-audit-r4` at `40e8ab1f`.
`memory_health` went from **82 flagged → 27** (high 54→7 at the time of the sweep, then 0 after the
re-stamp of the moved notes; the residue is 13 `outsideTaxonomy` refiles and 5 genuinely ungrounded
notes). All sixteen round-4 product decisions above were checked against the phase section AND the
commit that shipped them; every one already carried its `(P##)` pointer and every pointer is
correct (decision 11's is `8f92f236`/`5b81476b`, pinned by
`BotAgentUnsetP39Tests.theConfigUnsetFloorIsMootUnderBotModeButStillStructural`).

**Added** (three notes, each `source_paths`-anchored except the git one, which is workflow):
- [[Judging a Hermes verb by its output: the exit-0 refusal FAMILY and the anchored-prefix rule]] —
  `scarf/architecture/judging-a-hermes-verb-by-its-output-the-exit-0-refusal`
- [[COLUMNS=400 rides the judged spawns only — rich wraps at 80 and splits a marker line]] —
  `scarf/architecture/columns-400-rides-the-judged-spawns-only-rich-wraps-at-80`
- [[Concurrent agents on one working tree: commit with `git commit -- <paths>`, never `git add` then `git commit`]] —
  `scarf/conventions/concurrent-agents-on-one-working-tree-commit-with-git`

The other two round-4 gotchas were folded into notes that already owned the subject rather than
forked: the `-only-testing` nested-suite / file-vs-suite trap into
`scarf/conventions/fast-test-iteration-commands-swift-test-vs-xcodebuild` (already there from P43c),
and "a tag walk means OPENING the file at each tag" into
`scarf/architecture/hermes-capability-gating-pattern`.

**Corrected in place** — `scarf/architecture/the-acp-adapter-s-slash-roster-is-nine-names-and-has-been`
(P44b's idle-`/queue`-is-an-ordinary-prompt arm, and `hasACPSteerOnIdle` recorded as RETIRED);
`scarf/architecture/a-platform-s-shared-keys-are-bridged-from-one-section-so` (the `slack: {}`
empty-block bridge win, `maps[section] != nil`); `scarf/decisions/setup-forms-write-the-resolved-default-settings-treats`
(setup forms owe the bridged spelling); `scarf/architecture/kanban-board-architecture-v2-7-5`
(`provider_override` re-floored to `isV0191OrLater`, `project_id` deliberately unflagged);
`scarf/decisions/bot-mode-phase-b-decisions` (the P39 model-pin clear);
`scarf/conventions/a-source-scan-test-must-be-calibrated-against-the-target-s` (both P22-sweep
allowances are CLOSED, so the floor is `0 == 0` and the calibration test is what keeps it honest);
`scarf/architecture/prefer-task-over-onappear-for-view-load-fetches-behind-switch-based-navigation`
(`SettingsView`'s `.onAppear` moved to line 166).

**Stale pointers fixed** — the `~/Developer/ScarfBox/Vendor/hermes-agent` checkout path in
`scarf/project/hermes-version-targeting-strategy` (now `~/.hermes/hermes-agent`), plus dated
annotations on the two historical mentions in
`scarf/architecture/hermes-has-no-project-concept-infer-working-dirs-from` and
`scarf/decisions/aggregator-providers-must-skip-the-model-provider-mismatch`; and this note's own
`Core/Models/ProcessTimeout.swift` citation, which moved to `ScarfCore/Models/` in P43. Checked and
found ALREADY correct at HEAD: `hasACPSteerOnIdle`, `managedRefusal`, `runConfigMigrate`,
`mcpTestReportsFailure`, `ProvenConfig.exists`, `HermesFileService.yamlScalar`-as-emitter, the
"no `project_id` column" premise, "Resume & Run Now" as a default hint, and `scarf/ScarfGo` as a
directory — every surviving mention is historical narrative in this note, correctly tensed.

**Broken relations repaired** — `[[Hermes v0.20.0 Audit Findings]]` (a note that was never written)
dropped from `scarf/decisions/hermes-v0-20-compatibility-decisions`, and `[[t-aud32]]` (a TASK id,
not a note) de-linked in `scarf/decisions/hermes-v0-17-compatibility-decisions`.

**Refiled into the six folders** — `features/Kanban Board Architecture` and
`features/Project Templates` → `architecture/`; `integration/Hermes Version Compatibility Target`
and `integration/Hermes Version Targeting Strategy` → `project/`; the v0.18.0 / v0.21.0 / v0.21.1
audit-findings notes → `decisions/`, beside the compatibility-decisions notes they evidence;
`integration/hermes-has-no-project-concept…` → `architecture/`.

- [todo] **Refile queue, 13 notes, left for Alan's call** — the untouched `design/` (2),
  `features/` (4), `integration/` (5), `overview/` (1) and `profile/` (1) notes are still outside
  the six canonical folders. This round moved only the notes it audited; mass-moving the rest is a
  structural decision, not an audit one #memory
- [todo] **Five notes stay `needsGrounding` honestly** — `hermes-has-no-project-concept…`,
  `hermes-system-prompt-tier-order…`, `Wiki Maintenance Workflow`,
  `decoding-bridged-swift-error-codes…` and `hermes-upstream-submission-pattern…` describe Hermes-side
  or workflow facts with no Scarf file to anchor to. They were content-reviewed, not grounded #memory


## P45 — the cross-phase remediation of the round-4 audit (`5d0c682b`, `93d2237b`)

Seventeen findings from a cross-phase review of P39–P44, plus two memory corrections. All
fixed on `fix/whole-surface-audit-r4`; the branch's last full serial pass is recorded below.

The eleven files P43's work was swept into `a1e333cc` under (see the P43b/P44 process note):
`ProcessTimeout.swift`, `RemoteRestoreService.swift`, `AppRelauncher.swift`,
`ProjectTemplateExporter.swift`, `ProjectTemplateService.swift`, `SpotifyAuthFlow.swift`,
`TemplateInstallerViewModel.swift`, `ProcessDrainP43Tests.swift`,
`ProjectTemplateBoundsP43Tests.swift`, `SpawnDisciplineP43Tests.swift`,
`MainActorSpawnDisciplineP22Tests.swift`. The other seven files in that commit are P44's own.

### The lessons

- [gotcha] **A sweep whose scope is a hand-kept list of filenames rots silently, and a
  self-check on that list only catches DELETIONS.** The P38 test-host stability sweep's
  `phaseSuiteFiles` stopped at P39 — every suite P40–P44 wrote, and every ScarfCore package
  test file, went unscanned for five phases — while its `scanned == phaseSuiteFiles`
  expectation reported a healthy green, because that assertion asks "does every name still
  exist?", never "is every file that should be here here?". A scope must be a PATTERN plus a
  population floor: the pattern finds new files by construction, the floor fails when the
  pattern stops matching, and the old names ride along as a deletion floor. Widened, it found
  two real out-of-bounds sites that had been on the branch the whole time.
- [gotcha] **Compare the string the way the CONSUMER compares it.**
  `parse_reasoning_effort` runs `str(effort).strip().lower()` before every comparison
  (`hermes_constants.py:884` @ `v2026.9.7`, `:807` @ `v2026.7.1`). Scarf compared the raw
  stored value, so `Max` in config.yaml widened the picker to a duplicate row beside `max`
  and `" high "` drew an "isn't supported" notice for a value the host accepts. Normalise for
  the DECISION, keep the raw string for DISPLAY — the row has to match what is on disk.
- [gotcha] **A marker matched as a bare substring is only as safe as the noisiest emitter on
  that verb's path — including the emitters that print text Hermes did not write.** P39c
  learned this for the success side of `plugins update`; the DISABLE side kept the bare
  `has been disabled.` over the same `git pull` echo (`plugins_cmd.py:829`) and scan report
  (`:844`). Matched as the shape `Plugin <…> has been disabled.` now. Note `contains`, not
  `hasSuffix`: the emitter continues the sentence with "Review the findings, …" (`:848-851`),
  so the clause is never at end of line.
- [gotcha] **A test that naps and then asserts is asserting about the clock.** Four `settle()`
  helpers slept a flat 300 ms after polling for a call; `M5FeatureVMTests` slept 50 ms and
  then indexed `entries[0]`; `ProcessDrainP43Tests` asserted a 0.15 s floor against a 0.2 s
  `poll` budget the kernel rounds to its own tick. Every one of them had an observable to wait
  on instead — `SettingsViewModel.writeChain` (the `Task` the write is serialised through,
  whose last act is the banner under test), a poll of `readNewLines()` to the expected count,
  a zero-timeout `poll` for `POLLOUT`. Where the assertion is "nothing ran" there IS no
  observable: poll to a short deadline and let the caller's emptiness assertion fail.
- [convention] **A name that lies about an invariant is cheaper to PIN than to rename.** Six
  failure lists (`configSetFailure`, `configUnsetFailure`, `skillsTrustFailure`,
  `memoryOffFailure`, `mcpRemoveFailure`, and `mcpTestFailure`) are spelled as if unanchored
  while `gatewayServiceFailureAnchored` says so. Forty commits of audit docs cite the current
  names, so instead of a rename there is now a source sweep asserting that any list built on
  `managedRefusalAnchored` reaches `HermesCLIVerdict.judge` only at the
  `anchoredFailureMarkers:` label (or through an explicit `hasPrefix` match, which is what
  that label does internally).
- [decision] **"Provider default" was never the provider's.** P44b's walk of the consumers
  ends at the chat-completions transport substituting `medium` EXPLICITLY
  (`agent/transports/chat_completions.py:420-422` @ `v2026.9.7`); only the Anthropic adapter
  leaves the choice to the model (`agent/anthropic_adapter.py:570`). The image-gen row is the
  same shape — an empty `image_gen.model` falls through to the PLUGIN's own default
  (`plugins/image_gen/_common.py:70-90`). The sentinel row reads **"Hermes default"** on all
  four surfaces (`AgentTab`, `AuxiliaryTab`, iOS `SettingsView`, and the `UnsupportedEffortNote`
  doc), one shared catalog key, six locales.
- [decision] **`HermesPluginsUpdateVerdict` stays bespoke.** `judge`'s third outcome is
  `.unconfirmed` — the shape where a verb can finish printing nothing the client recognises.
  `cmd_update` (`plugins_cmd.py:794-830`) has no such arm: every path ends in a refusal or one
  of the two `✓ Plugin <name> …` lines. What it has instead is a third SUCCESS state
  (updated-but-flagged / updated-then-disabled) that `judge` has no vocabulary for. Fold it in
  only when that warning shape becomes general. The reasoning is now a doc line on the type.
- [decision] **Round-4 decision 1's env-var-only fall-through has an end-to-end test.**
  `get_managed_system` reads two signals and Scarf can only see one; a host managed solely by
  `HERMES_MANAGED` renders writable by design. The test pins where that lands: no `.managed`
  marker ⇒ the probe says not managed, the pane shows no pre-emptive banner, the write RUNS,
  and the exit-0 refusal is caught by the OUTPUT verdict. Nothing reports a save over a write
  that did not happen.
- [gotcha] **`.help(…)` takes a `LocalizedStringKey`, so a literal with no catalog entry is a
  silent English leak.** The Kanban provider-override badge shipped its help text without its
  entry. A repo-wide sweep of `.help("…")` literals finds **19 more** in the same state
  (`VoiceTab`, `DisplayTab` ×3, `AgentTab` ×2, `AdvancedTab` ×5, `HealthView`,
  `CredentialPoolsView`, `MCPServerDetailView`, `KanbanInspectorPane:257`, `SkillsView`,
  `GatewayView`, `SidebarProjectsWell`) — a mechanical pass worth filing, not a P45 splice.

### What shipped

`5d0c682b` — the widened stability sweep and the determinism fixes (findings 1, 2, 3, 10, 11,
12, and the reachable half of 17). `93d2237b` — the verdict/normalisation/label fixes and the
new suites (findings 4, 5, 6, 7, 8, 9, 13, 14, 15, 16).

**Tests.** ScarfCore `swift test`: **2939 tests in 212 suites**, the only failures the known
`ACPClientStartIdempotenceTests` load flake (4 issues, all a 3 s `waitFor` under the full
parallel run; the suite passes in isolation). Mac full serial `-only-testing:scarfTests`:
**1229 tests in 163 suites, 0 failures**, 123 s — the branch's last full pass. `scarf` and
`scarf mobile` both build.

**Catalog.** The 52 keys this branch added are re-sorted into collation position — zero content
changes, verified by a JSON compare of the file before and after the reordering, and the diff
against `main` drops from 2405 changed lines to 2261.


## P46 — pre-merge remediation of the round-5 audit (`9ca4d384` … `b44dfefd`)

Seventeen findings from a round-5 review of the NEW work on
`fix/whole-surface-audit-r4`, i.e. of P39–P45's own diff. Six commits; the
branch's last full passes are recorded at the end.

### The lessons

- [gotcha] **An allowlist is scoped to whatever the READER resolves, and the
  reader's unit here is the `(platform, key)` PAIR, not the platform.** P44's
  `bridgeResolvedPlatforms` was `[slack, telegram]`, and `slack` resolves the
  shared-key bridge for `require_mention` but NOT for
  `gateway_restart_notification`, whose reader is a flat
  `boolTrueDefault("slack.gateway_restart_notification")`
  (`HermesConfig+YAML.swift:695`). So the honest-half allowlist that existed to
  stop half-fixes performed one: `GatewayBehaviorViewModel`'s toggle was
  rewritten to `platforms.slack.…` on every nested-only config and became
  write-only. `bridgeResolvedKeys` is now the three pairs the
  `sharedPlatform*` call sites actually read, and the parity test scans both
  arguments of each call rather than the first #capability-gating
- [gotcha] **A `config set` batch is not one write, so resolving against the
  PRE-save file can be invalidated by the batch itself.**
  `TelegramSetupViewModel` sends bare `telegram.require_mention` (shared)
  beside bare `telegram.reactions` and `telegram.disable_topic_auto_rename`
  (not shared, untouched). With no top-level `telegram:` on disk the shared key
  moved nested while `reactions` CREATED the top-level block — which
  `platform_section` then bridges from (`gateway/config_loader.py:171-180` @
  `v2026.9.7`), missing `require_mention`. Resolve against the file as the
  batch will LEAVE it: any bare `<platform>.<anything>` in the batch pins the
  prefix to `<platform>` #verification
- [gotcha] **Two questions need two comparisons.** P45's "compare the string
  the way the CONSUMER compares it" was right about the NOTICE and wrong about
  the ROW. A `Picker`'s tags and its selection are the RAW stored string, so
  asking membership of the normalised form left `Max` and `" high "` with no
  tag — the blank control decision 13 exists to prevent, reintroduced by the
  fix for the duplicate row. The row widens on RAW membership; the notice and
  the disable-alias check stay normalised. The normalised form is still what
  answers "is this empty": a whitespace-only value is Hermes's own absent-key
  case (`str(effort).strip()`, `hermes_constants.py:884`), so it is the
  sentinel — no row and no notice #ux
- [gotcha] **A sweep scoped by NAME is blind to a phase that edits an
  ordinarily-named file.** P45 replaced P38's hand-kept list with the
  `…P<n>…Tests.swift` pattern, which finds new PHASE suites by construction —
  and P45 itself fixed sites in `M5FeatureVMTests.swift`, which no sweep read.
  A scope has to be able to answer "what did this change touch?", which is a
  PATH question: the scope is now the name pattern OR
  `git diff --name-only <branch base>..HEAD -- '*Tests.swift'`, checked in as a
  list and pinned against `git` (not against itself) by
  `theBranchScopeMatchesGit`. Widened, the subscript-after-count rule found
  seven real sites, all in `M5FeatureVMTests.swift` #conventions
- [convention] **Two sibling stability rules, over the same scope.**
  `try? #require` is `try! #require`'s quiet twin — the requirement is
  DISCARDED and the test continues with nil, so the failure surfaces as an
  optional-chained `== true` far below with no statement of what was missing,
  or holds vacuously (nine sites, six files). And a FIXED sleep of 500 ms or
  more is P45's "a test that naps and then asserts is asserting about the
  clock" made mechanical; two sites survive, each with a written reason and a
  stale-allowance check, because their sleep is the FIXTURE or a deliberate
  "nothing happened" window with nothing to poll
- [gotcha] **`hermes tools enable|disable` is the FOURTH door onto
  `save_config`'s exit-0 refusal, and it has four exit-0 refusals of its own.**
  Walked at `v2026.9.7`: every refusal `tools_disable_enable_command` prints is
  a `_print_error` followed by a bare `return`/`continue` — `Unknown platform
  '…'` (`hermes_cli/tools_config_mcp.py:247`), `Unknown toolset '…'` (`:262`),
  `Toolset '…' is not available on platform '…'` (`:268`), `MCP server '…' not
  found in config` (`:278`) — and the write is `save_config`, whose managed arm
  prints and returns (`hermes_cli/config.py:2316-2318`). The success line
  `✓ Enabled: <names>` (`:284-285`) is printed from a `successful` list
  computed BEFORE the save could refuse, so a managed host prints both. New
  `HermesToolsToggle`, anchored on both sides, `failureWins: true` #capability-gating
- [gotcha] **A verdict computed and then thrown away is not a verdict.**
  `BotAgentViewModel.perform` filtered `clearModelPin`'s results through
  `isBenignUnset` — which judges by OUTPUT, P39's whole point — and then asked
  `results.first(where: { $0.exitCode != 0 })`, re-opening the hole one line
  later. `perform` takes a verdict now, the way `enqueueConfigWrite` does
- [gotcha] **The other half of P44b's `/queue` finding was `/steer`, and the
  cost was Stop.** `_rewrite_prompt_for_interrupt` (`acp_adapter/server.py:667-689`)
  runs at `:789`, BEFORE the slash dispatch at `:792-793`: on an idle session
  with a non-empty argument it returns `(steer_text, steer_text)` (`:686`), the
  prefix is gone, and the text runs as a real turn. Scarf painted "Guidance
  queued — applies after the next tool call.", suppressed the working
  indicator, and — because `turnGeneration`/`inFlightPromptSessionId` are only
  set on the interruptive branch — **Stop could not cancel it**. Same shape as
  `/queue`, minus the wire change: Hermes strips the prefix itself. The fallback
  shipped with `/steer` (`server.py:812-824` @ `v2026.5.7`) #ux
- [gotcha] **Caching a VERDICT caches every input to it, including the one that
  was missing.** `HermesManagedInstallCache` memoized
  `HermesManagedInstall(system:)`, which is a function of the marker AND of
  `hasManagedMarkerContents` — false for an UNDETECTED host as much as for a
  pre-v0.20.5 one. One missed `hermes --version` at connect time locked the
  below-floor reading in for the process ("any marker ⇒ NixOS",
  `hermes_cli/config.py:327-330` @ `v2026.6.19`), and a Homebrew host whose
  `.managed` says `brew` stayed read-only until relaunch. Cache the INPUT the
  round trip bought (the raw marker) and re-derive per call
- [gotcha] **A per-key opt-in has to be threaded down every arm, and YAML has
  two shapes for everything.** Decision 10's `unquote` opt-in reached the block
  arms of `parseNestedYAML` and not the FLOW arms, so one key decoded two ways
  depending on whether the host's config.yaml used `[…]` or `- …`. Expected
  values verified against PyYAML 6.0.3
- [gotcha] **Hermes cannot refuse a write it never sees.** `saveDirectYAML`
  splices config.yaml through `GuardedTextFile`, so unlike `config set` there
  is no exit-0 refusal downstream to catch a managed host — the pre-emptive
  `managedBannerText` bounce is the only guard that exists on that door
- [gotcha] **Two jobs with one name break `cron run` for BOTH.**
  `resolve_job_ref` falls back from id to a case-folded NAME match and raises
  `AmbiguousJobReference` on a collision (`cron/jobs.py:1831-1846` @
  `v2026.9.7`), so all three Duplicate seeds — Mac editor, iOS
  `duplicatedAsNewJob`, Bots Routines — broke the ORIGINAL as soon as the copy
  was saved unedited. `(copy)`, then `(copy 2)` …, case-folded like the
  resolver, with a bot routine's `[bot:…] ` prefix preserved
- [gotcha] **A happy path with no `await` in it holds a cooperative thread for
  its whole length.** `streamTarball`'s only suspension was the `EAGAIN` arm,
  which a remote reading as fast as we write never reaches — so a
  multi-gigabyte push never yielded. `Task.yield()` every 8 MB. Beside it,
  `write(2)` returning 0 for a non-zero count accepted nothing and set no
  errno, and fell into a throw that would have reported a stale one
- [convention] **A sweep's TITLE is a claim, and it has to be narrowed to what
  the matcher proves.** `ProcessAsyncWaitP43cTests` said "no async function in
  ScarfCore blocks a cooperative thread" while `LocalTransport.runProcess` and
  `SSHTransport.runLocal` — synchronous, a 100 ms spin and an unbounded
  `group.wait()`, both called from `async` code — were on the branch, and its
  calibration floor (a count of what the matcher finds) blessed them by
  construction. Narrowed; the shapes filed with their lines under `t-10eb7c17`
- [gotcha] **`stdout + stderr` with no separator can hide a refusal.**
  `runHermesCLI` welded them, and a stdout with no trailing newline glued the
  exit-0 refusal onto the end of a success line — where every anchored marker,
  which asks whether a LINE starts with it, cannot see it
- [gotcha] **P39's twin, on the surface nobody re-grepped.** iOS chat's model
  preflight hand-rolled a `config set` shell string — no `--`, judged by exit
  code — while `IOSSettingsViewModel` two directories away had used
  `HermesConfigSet.argv`/`.judge` since P39. Routing it through them also made
  it VISIBLE to `AllConfigWritersParityTests`, which discovered it as a new
  config writer. The floor that stops the next one is a calibrated source scan
  over both targets plus iOS, with the calibration written as its own test
  (a diagnostic that quotes the verb is not an invocation)

### The product decisions

- [decision] **Widen the row on RAW membership, keep the notice normalised**
  (P46 finding 2) — and treat a whitespace-only stored value as the sentinel
  rather than as a value needing a tag.
- [decision] **`AuxiliaryTab`'s "Default" is a deliberate distinction, not an
  inconsistency with "Hermes default".** Walked: an empty
  `agent.reasoning_effort` RESOLVES to Hermes's own `medium`
  (`agent/transports/chat_completions.py:420-422`), while an empty
  `auxiliary.<task>.reasoning_effort` resolves to NOTHING —
  `_get_task_extra_body` returns early on `effort is None or effort == ""`
  (`agent/auxiliary_client.py:5700-5702`), no `reasoning` key reaches the aux
  call's `extra_body`, and `_get_auxiliary_task_config` (`:5583-5605`) never
  reads `agent.*`. The first draft of this comment claimed it inherits the
  global row; the fresh-eyes pass caught it.
- [decision] **The shared-key rewrite MOVES rather than MIGRATES, and that is
  filed rather than smuggled.** `hermes config` has no delete for an arbitrary
  key, so clearing the stale shadow at the source spelling means hand-editing
  config.yaml through a different write door — `t-f3d7bdd2`.

### Citations re-anchored

`resolve_reasoning_config` is `hermes_constants.py:957-980`, the warning at
`:978-979` (was `:957-979` / `:975-976`). The `/steer`+`/queue` floor is
`HermesACPAgent._SLASH_COMMANDS`, `acp_adapter/server.py:163-173` @
`v2026.5.7` — `steer` at `:170`, `queue` at `:171` — with a note that the
roster has since moved to `acp_adapter/commands.py` (`:55`, `:60` @
`v2026.9.7`). `_write_user_config` is `hermes_cli/config.py:3506` (was
`:3508`, three sites). `unset_config_value`'s success line is `:3582` (was
`:3583`).

**P46 test results.** ScarfCore `swift test`: **2975 tests in 219 suites**, the
only failures the known `ACPClientStartIdempotenceTests` load flake under the
full parallel run (5/5 green in isolation — `t-f3820038`). Mac full serial
`-only-testing:scarfTests`: **1247 tests in 167 suites, 0 failures**, 121 s.
`scarf` and `scarf mobile` both build; no new warnings in the touched files.
**39 new tests in 9 suites** across two files (`HermesP46Tests.swift` in
ScarfCore and in `scarfTests`), plus the three widened/new sweep rules in
`HermesP38SourceSweepTests`. `Localizable.xcstrings` +205 lines, 0 deletions,
inserted in collation position.

**Two branch tests asserted the behaviour P46 changed** and were corrected
rather than exempted: `AllConfigWritersParityTests` (iOS `ChatView` registered
as the config writer it always was) and
`CronRecoveryP42Tests.theIOSDuplicateCarriesConfigAndDropsTheRun`
(`copy.name == spent.name` was the collision itself).

**Tasks filed / updated.** `t-f3d7bdd2` (new — the stale shadow);
`t-f43f0af5` (the remaining subscript-after-count sites recounted at the
widened scope: **90 in 35 files**, listed per file, plus the two new sibling
rules); `t-10eb7c17` (the two synchronous transport waits with their lines, and
why the P43c sweep cannot see them).



## Round 5 — merge of P39–P46 and what this branch taught (2026-09-11)

Branch `fix/whole-surface-audit-r4` (P39–P46, 46 code commits plus three of Alan's per-tier Memophant commits at its base) merged to `main` with `merge(whole-surface-audit-r4)`. Round-5 report: `documents/hermes-v0.21.1-whole-surface-audit-round5.md`; follow-ups P47–P51 (`t-a498595f`, `t-86311c5a`, `t-89264409`, `t-a397264c`, `t-f406c932`) with seventeen product decisions open for Alan.

- [gotcha] **Ask which axis the consumer keys on.** P44 scoped the shared-key rewrite by platform (readers resolve by platform+key); P45 scoped the stability sweep by file name (the worst offenders had no phase name); P45 normalised the picker's membership test (the control binds the raw tag). Each fix was right for the case in hand and wrong one axis over #process
- [gotcha] **The exit-0 family is enumerated by grepping `runHermesCLI(` callers, not by verb.** Round 5 found `plugins install --enable`, `tools enable|disable`, `auth logout`, `sessions optimize`, `memory reset`, plus two sites (iOS preflight, `BotAgentViewModel.perform`) that re-judged by exit code one layer above a correct verdict #verification
- [gotcha] **The optimistic mirror has an idle twin.** Fixing idle `/queue` (P44b) left idle `/steer` with the same false hint and an un-cancellable turn; when a fix lands on one member of a `case` family, walk the siblings #chat
- [convention] **On a shared working tree, `git commit -- <paths>`.** `a1e333cc` swept eleven staged P43b files into a P44 commit; content complete, authorship mixed; history left alone #process
- [convention] **Round-5 pre-merge scope was NEW findings only (P46), PRE filed** — the round-3/4 rule held; the NEW set was 17 items across the branch's own P44/P45 work #process
- [fact] Post-P46b: ScarfCore 3003, Mac `scarfTests` 1253 serial (125 s), scripts 20/20, both schemes build; the only recurring failure is t-f3820038 in a parallel run #testing
- [decision] The seventeen product decisions in the round-5 report are open; Alan decides before P47–P51 are scoped #process


## P46b — remediation of the P46 review (`a856d981`, `b14e39f3`)

Eight findings from an independent review of P46's six commits (`9ca4d384` … `b44dfefd`),
all on `fix/whole-surface-audit-r4`. Two commits: the behaviour changes, then the sweep.

### The lessons

- [gotcha] **A fix aimed at the OPTIONS leaves the BINDING.** P46's "the row widens on RAW
  membership" was right and incomplete: `PickerRow` binds the raw stored string as its
  SELECTION and the sentinel row is tagged `""`, so a whitespace-only `reasoning_effort` —
  which `levels(capabilities:selected:)` correctly widens nothing for — matched no tag at all
  and the control rendered blank. Decision 13's failure, reintroduced one layer down by its own
  fix, for the third phase running. The question "what does this control SELECT" now has one
  answer, `HermesReasoningEffort.pickerSelection(for:)`, used by all four pickers instead of
  three `isEmpty` tests at the call sites #ux
- [gotcha] **A picker with no sentinel row cannot represent the absent value at all.** The
  per-model override rows had no `""` tag, so an empty `agent.reasoning_overrides` entry was a
  blank control with no fix available. They get one CONDITIONALLY — only when the stored value
  is empty — because `HermesReasoningEffort.isValid("")` is false and
  `PowerSettingsWriter.setReasoningOverrides` refuses the whole batch over it: an
  always-offered "Default" row would be a control the user can move and the save then silently
  declines. Selecting it REMOVES the override, which is what an absent entry means —
  `resolve_per_model_reasoning_effort` returns `None` and `resolve_reasoning_config` falls
  through to the global row (`hermes_constants.py:935-941`, `:970-976` @ `v2026.9.7`)
- [gotcha] **`CharacterSet.whitespaces` is not `str.strip()`.** Python's bare `strip()` takes
  newlines and tabs; `.whitespaces` is spaces and tabs. `normalizedLevel` trims
  `.whitespacesAndNewlines` now, or a value carrying a newline reads as non-empty to Scarf and
  as the ABSENT key to Hermes
- [gotcha] **Leaving a write on its bare spelling is not neutral just because its reader is.**
  P46 kept `gateway_restart_notification` off `bridgeResolvedKeys` on the honest-half rule —
  correct about the reader, and it left the write CREATING the top-level `<platform>:` block on
  a nested-only host, which `platform_section` then bridges from
  (`gateway/config_loader.py:171-180` @ `v2026.9.7`), un-bridging every
  `platforms.<p>.<shared key>` beside it. Option (b): move the READER onto
  `sharedPlatformScalar` for `slack` and `telegram` and let both pairs onto the allowlist, so
  the write lands wherever the bridge source already is and creates nothing #capability-gating
- [gotcha] **`batchTopLevel` counted the key it was about to move.** P46's "resolve against the
  file as the batch will LEAVE it" swept up every bare two-segment key in the batch — including
  the shared one about to be rewritten — so the toggle's own
  `slack.gateway_restart_notification` pinned the prefix to `slack` and the rewrite resolved
  straight back onto the block it exists to avoid. A key `split(key:)` accepts is no longer
  evidence of a block
- [gotcha] **A test that asks `git` about the repository is a merge-time tripwire.**
  `theBranchScopeMatchesGit` pinned the checked-in scope list against
  `git diff 5be08f2e..HEAD`: red on a shallow clone, and red on `main` after the merge the first
  time anyone edits a test file, for a reason unrelated to the rule being swept. The list is
  what the pin was buying and the list is already checked in — regenerated from that diff at
  `b44dfefd` (identical, 66 basenames), frozen, read unconditionally, git call deleted. Future
  phases APPEND one line for an ordinarily-named file; a phase-numbered suite still needs none
- [gotcha] **A matcher that cannot see its own subject looks healthy.** The long-sleep rule
  captured `([0-9][0-9_]*)`, integer digits only, so `Thread.sleep(forTimeInterval: 0.9)`
  measured as `0` and `.seconds(0.5)` as `0` — both under a floor they are at or over. The two
  sites in scope happened to be whole-number nanosecond spellings, which is why nobody noticed.
  Fraction captured, conversion lifted into a testable `fixedSleepSeconds(in:)`, calibrated over
  all four spellings — and the calibration suite lives in the sweep's OWN file, because its
  cases are sleep spellings written as literals and anywhere else in scope the rule would read
  them as real sleeps
- [gotcha] **Check-then-act over a lock you dropped for the round trip.**
  `HermesManagedInstallCache.managedInstall` released the lock for the whole probe and then
  wrote back unconditionally, so an `invalidate` that landed meanwhile was silently undone and a
  re-provisioned host served its PRE-provision marker for the life of the process. Per-key
  generation counter, snapshotted before the probe (and RECORDED, so `invalidateAll` can see a
  key whose first probe is in flight) and compared before the store
- [gotcha] **P46's own lesson, one method over.** `cached(for:)` still handed out a stored
  VERDICT — a function of the marker AND `hasManagedMarkerContents`, which is exactly the
  coupling P46 broke `managedInstall` over. The entry keeps the marker only; the verdict is
  derived per call from the CALLER's capabilities, so the below-floor "any marker ⇒ NixOS"
  reading (`hermes_cli/config.py:327-330` @ `v2026.6.19`) no longer outlives detection
- [convention] **A parameter that IS the fix gets no default.**
  `duplicatedAsNewJob(existingNames:)` defaulted to `[]`, which made P46's collision fix opt-in;
  a caller that forgets re-creates the `AmbiguousJobReference` (`cron/jobs.py:1831-1846` @
  `v2026.9.7`). Required now, `[]` passed explicitly where there is nothing to collide with
- [gotcha] **Split AFTER the quotes, not before.** `parseFlatFlowList` cut on every `,`, so
  PyYAML's one-item `["a,b"]` came back as two items that `stripYAMLQuotes` then tidied into a
  plausible-looking pair nothing downstream could question. Quote-aware splitter reusing
  `closingQuoteIndex`, shared with `parseFlatFlowMap` (where the same comma had been turning the
  whole map into "unparseable"). Checked against PyYAML 6.0.3

### The product decisions

- [decision] **Normalise at the SELECTION, not at the tag.** A raw pick still writes the raw
  value; only the whitespace-only case is folded onto the sentinel, because that is Hermes's own
  absent-key reading.
- [decision] **The override row's sentinel says "Default", not "Hermes default".** Walked: an
  empty per-model override falls through to the GLOBAL row, which may itself be set — a
  different claim from the global row's own fallback, and the same distinction `AuxiliaryTab`
  already draws.
- [decision] **Only `slack` and `telegram` moved.** The general hazard — ANY bare
  `<platform>.<unshared>` key creating the block, including `GatewayConfigWriter.saveList`'s
  direct-YAML allowlist writes, which the `config set` resolution never sees — is filed as
  `t-f655c541` with file:line and the walk, and documented on `HermesPlatformSharedKeys` under
  "The hazard this type does NOT close".

### Two P46 tests asserted what P46b changes

Corrected, not exempted. `HermesP46Tests.aSharedKeyWhoseReaderIsHardCodedTopLevelIsNotMoved`
re-aimed at `discord`/`matrix`/`mattermost`, whose readers ARE still hard-coded, with its other
half (`theRestartToggleMovesNowThatItsReaderDoes`) added beside it; and
`HermesP45Tests.aWhitespaceOnlyValueIsTheSentinel`, which pinned the options and left the
selection — the half that was actually broken.

### The fresh-eyes pass (`a9060755`)

- [gotcha] **A quote OPENS a scalar; it is not one.** The first draft of `splitFlowEntries`
  treated a quote anywhere as opening a quoted span, so a plain scalar carrying an apostrophe
  swallowed the separator after it — PyYAML 6.0.3 reads `[a'b, c]` as two PLAIN scalars.
  Narrowing it to "the start of an entry" then broke the map arm, where a quoted VALUE
  legitimately begins mid-entry (`{a: "x,y"}`). The rule is where a scalar can BEGIN: start of
  content, after a `,`, or after a `:`. Six shapes cross-checked against PyYAML 6.0.3, the
  quoted map KEY with a comma (`{'a,b': x}`) among them — the other half of the original bug,
  since `splitFlowEntry` never received a whole entry to split.

**P46b test results.** ScarfCore `swift test`: **3003 tests in 225 suites, 0 failures** (the
`ACPClientStartIdempotenceTests` load flake appeared on one full-parallel run and was 5/5 green
in isolation — `t-f3820038` — and did not reproduce on the final run). Mac full serial
`-only-testing:scarfTests`: **1253 tests in 170 suites, 0 failures**, 125 s. `scarf` and
`scarf mobile` both build; no new warnings in any touched file. **43 new tests in 10 suites**
across `HermesP46bTests.swift` (ScarfCore and `scarfTests`) plus the recalibrated sleep rule in
`HermesP38SourceSweepTests`.

**Tasks filed.** `t-f655c541` (the bare-unshared-key bridge hazard).



## Round-5 product decisions (Alan, 2026-09-12) — binding for P47–P51

Decisions on the seventeen product calls in `documents/hermes-v0.21.1-whole-surface-audit-round5.md`. Branch `fix/whole-surface-audit-r5` from `main` at `59fffa19`.

1. **Plugins pane goes under the managed-install read-only lock** (P47, `f093af74` + `1e88ab3e`; folds t-8f55df7d for that pane). Alan chose the lock over the run verdict. The env-var-only (`HERMES_MANAGED`) host still falls through to the marker per round-4 decision 1, so the install verdict must ALSO carry `managedRefusalAnchored` + `failureWins` before `HermesPluginInstallOutcome.parse` — the lock is the primary door, the verdict is the fallthrough, never "Installed and enabled" on a refused enable.
2. **`auth logout` with no auth state is a success with a neutral note** (P47, `f093af74` + `1e88ab3e`), the gateway "nothing was running" shape.
3. **`memory reset --yes` with nothing to reset is a success with the same neutral note** (P47, `f093af74` + `1e88ab3e`; the single reset alert in P47b `d1c46223`).
4. **`ProcessPipeDrainer` is retired onto `Process.startDraining`/`waitDraining`** (P48, `b34493a5`); one drain primitive, the file deleted.
5. **`ServerTransport.runProcess`'s `timeout` becomes non-optional** (P48, `b34493a5`; the iOS half in P48b `36395fc4`), one signature across both conformers and the test doubles.
6. **The four streaming spawns get `continuation.onTermination` + `terminate()` only** (P48, `4dd7911d`); no rewrite of the read loop.
7. **The 90 remaining stability-sweep sites are taken as one wave, its own commit in P48** (`3719917d`, the sweep widened in `33953111`), closing t-f43f0af5 and dropping the sweep's scoping.
8. **Test fixtures shrink** (P48, `86b49af1`): clock started before `Process.run()`, the 300 MB bomb and 64 MB drain duel sized to the bound.
9. **`hasACPSetSessionModel` is retired** (P49, `c718237d`): the model chip and project model binding turn on for 0.6.0–0.12 hosts.
10. **`hasYOLOSlashCommand` is deleted** (P49, `c718237d`).
11. **The pre-v0.21 recurring-`error` hint says "duplicate it"** (P50, `55e464f8`), the button already rendered on that arm.
12. **Fleet-copied `pre_run_script` is a downgrade note at the `copyableCronJobs` seam** (P50, `39b888d1`; its catalogue row in P50b `94c88e7f`), the P42 shape; the job is still copied.
13. **iOS `CronEditorView.isValid` refuses a spent one-shot on create/duplicate only** (P50, `55e464f8`; its second door, the `Enabled` toggle, gated in P50b `82881859`); a prompt-only edit goes through.
14. **The YAML reader stops trimming Unicode spaces** (P51, `76206b4d`): a space+tab `yamlWhitespace` set, faithful to PyYAML.
15. **Signal/WhatsApp pairing is disabled on a remote context with a sentence naming the host** (P51, `c838c562`), the `runBackup` posture.
16. **Reasoning-override keys match exactly** (P51, `c838c562`; the rule extracted to a function in P51b `698bee29`); two casings coexist as Hermes reads them.
17. **iOS renders `unsupportedLevelNotice` beside the read-only effort value** (P51, `c838c562`; the empty-auxiliary-effort correction in P51b `698bee29`).



## Whole-surface remediation — P47 (CLI verdict residue, `t-a498595f` + the Plugins half of `t-8f55df7d`)

Commits `f093af74` (the four verdicts, ScarfCore) and `1e88ab3e` (the Plugins lock, the call
sites, the `--` separators, the stale doc) on `fix/whole-surface-audit-r5`. Round-5 decisions 1, 2
and 3.

### The lessons

- [gotcha] **A `save_config` door is a call PATH, not a verb named after a config write.**
  Round 4 enumerated five doors by walking `save_config`'s named callers; round 5's sixth,
  `plugins install --enable`, hid inside an *install*. `cmd_install`
  (`hermes_cli/plugins_cmd.py:702`) → `_set_plugin_enabled` (`:754`) → `_write_config_value`
  (`:115-120`) → `save_config`, whose managed arm prints `Cannot save configuration: …` and
  bare-`return`s (`hermes_cli/config.py:2315-2318` @ `v2026.9.7`) — and `:755` prints
  `✓ Plugin <name> enabled.` on top of it, at exit 0. The enumeration that finds these is the
  addendum's lesson 2 — grep `runHermesCLI(` callers and judge each on its tagged output — not a
  list of verbs #verification
- [decision] **The lock and the verdict are both required, and they are not redundant.** Alan
  chose the lock; the verdict is the fallthrough, because `HERMES_MANAGED` belongs to the systemd
  service and not to the shell Scarf's transport opens, so an env-var-only managed host is
  invisible to the `.managed` probe and reaches the refusal anyway. "Never *Installed and
  enabled* on a refused enable" is the invariant; two mechanisms hold it on the two host shapes
- [gotcha] **A `.disabled` control keeps the value it held.** The install sheet's "Enable after
  installing" toggle DEFAULTS to on, so greying it out on a managed host would have left it
  sending `--enable` — the lock would have been decorative. Its `Binding` reads `false` while
  locked (and `enableOnInstall` itself is untouched, so unlocking restores the user's choice),
  with the `&& !viewModel.isManagedHost` guard at the call site as the belt. The general rule:
  **when you disable a control, ask what its BINDING still reports**, which is the P46b picker
  lesson one control-type over #ux
- [decision] **The Plugins lock is scoped to ACTIVATION, not to the pane.** `cmd_install`,
  `cmd_update` and `cmd_remove` write the plugin DIRECTORY (`plugins_cmd.py:740`, `:794-830`,
  `:887-898` @ `v2026.9.7`), which `is_managed()` never guards, so locking them would be the
  P39c mistake in reverse — a managed host has more reason to manage its plugin directory, not
  less. ~~Only `_set_plugin_enabled` reaches `save_config`.~~ **Corrected by P47b:** `cmd_update`
  (`:794`) → `_rescan_after_update` (`:810`) → `_set_plugin_enabled(name, enable=False)` (`:847`)
  on a `dangerous` scan verdict, printing `Plugin '<name>' has been disabled.` (`:848-851`)
  regardless — so Update DOES have a config-write arm. The VERDICT catches it
  (`HermesPluginsUpdateVerdict.judge`, `managedRefusalAnchored` with `failureWins`), not the lock;
  the decision stands, its stated reason did not. A source test pins the count at exactly
  two `.disabled(viewModel.isManagedHost)` sites, so a third forces a re-walk
- [convention] **"Nothing to do" is a success with a neutral note** — now the house answer,
  applied to three verbs across two rounds. `auth logout`'s `No provider is currently logged in.`
  (`hermes_cli/auth.py:2180`) and `No auth state found for {name}.` (`:2185`), and
  `memory reset --yes`'s `Nothing to reset — no memory files found in …`
  (`hermes_cli/main_agent_cmds.py:33`). The user asked for the provider to be logged out / the
  memory to be empty, and it is; the `warning` is what stops the banner claiming a removal that
  did not happen. Same shape as round-4 decision 2's `gatewayNothingRunning`
- [gotcha] **A success marker that is a PREFIX of the verb's own in-progress line proves nothing.**
  `sessions optimize` prints `Optimizing session store (FTS merge + VACUUM)…`
  (`hermes_cli/sessions_cmd.py:811`) on every run before it can fail; the success line is
  `Optimized {n} FTS index(es).` (`:817`). The trailing space in `"Optimized "` is the whole
  separation, and it has its own test #verification
- [convention] **Once a verdict lands, the failure branch must stop quoting the exit code.**
  `HealthViewModel`'s "Optimize failed (exit 0)" would have been the original bug in a new voice;
  it quotes Hermes's own reason line now, and where a run printed nothing recognisable it says
  that rather than naming a status the verdict has just declared meaningless. Same edit on both
  memory-reset sites #ux
- [fact] **`--` is safe wherever the parser is a plain positional, and each one was opened.**
  `sessions rename` (`subcommands/sessions.py:210-213`), `sessions delete` (`:100-102`),
  `auth logout` (`subcommands/auth.py:59-61`), `auth reset` (`:40-45`), `webhook remove`
  (`subcommands/webhook.py:42-43`), `webhook test` (`:45-48`) — no `nargs=REMAINDER` anywhere, so
  argparse's separator applies. The flag comes FIRST and the separator after it
  (`sessions delete --yes -- <id>`): everything past the first `--` is a positional, so an
  appended `--yes` would exit 2. `ChatViewModel` was the only rename site without the separator,
  so the identical rename worked from the Sessions pane and exited 2 from Chat — both delete
  sites and both rename sites share one argv builder now #hermes-cli
- [fact] **`_forward_command` DISCARDS a handler's return code unless `forward_return=True`**
  (`hermes_cli/main.py:1755-1772`, raised at `:3399`), and only `cron`, `kanban` and `project`
  pass it (`:1779`, `:1781`, `:1783`). So `status`, `webhook`, `doctor`, `dump`, `import` and
  `mcp` exit 0 unless the callee itself calls `sys.exit`. This is the structural answer to "why
  is this verb exit 0" and it is worth checking before assuming a return value means anything
  #hermes-cli

### The lesson-2 sweep, and what it found

Every `runHermesCLI(` / `runHermes(` caller across `scarf/scarf`,
`scarf/Packages/ScarfCore/Sources` and `scarf/Scarf iOS` (119 sites) was listed and each verb's
handler read at `v2026.9.7`.

- **Already sound, re-confirmed**: `cron run` (output-judged through `CronViewModel.runOutcome`
  with `failureWins`), `cron incidents ack` (reads the `not found or already closed` marker),
  `webhook subscribe` (judged on the `Secret:` line), `cron remove`/`pause`/`tick`,
  `profile use` (`_die` → `sys.exit(1)`), the kanban core mutators (`_err` / `_ok_or_err` /
  `_bulk_apply` all return ≥1), `tools enable|disable` (P46). Read-only, exit code sufficient:
  `mcp catalog`, `proxy providers`, `secrets bitwarden status`, `dump`, `status`, `doctor`.
- **Out of P47's scope, filed as `t-4edfd804`** with file:line on both sides: `webhook remove`,
  `webhook test`, `backup`, `import <path>`, `migrate xai --apply`, `curator run|pin|unpin`, and
  `kanban specify|decompose --all`'s partial-failure exit 0.
- **iOS has no twin** for any P47 verb except `memory reset`, which was fixed alongside the Mac;
  the iOS Plugins pane (`scarf/Scarf iOS/Plugins/PluginsView.swift`) carries no mutation control
  at all, so the lock has nothing to arm there.

### The fresh-eyes pass on P47's own diff

- The Mac memory-reset failure branch reached `"exited with status 0"` on a `.unconfirmed` run —
  the exit code the verdict exists to stop trusting. Both platforms say Hermes printed no result
  instead, and the now-dead `trimmed` binding went with it.
- The iOS reset joined stderr BEFORE stdout; the markers are on stdout, so the order was flipped
  (the same reason P46 gave `runHermesCLI` a separator).
- `PluginsViewModel.install` shelled through `fileService` while `enable`/`disable`/`update` used
  the injectable `cliRunner`, so the first draft of the install test could not reach the real
  path at all — it ran a live `hermes`. Moved onto the seam; **a verdict rule that lives at a call
  site needs that call site to be reachable from a test, or the test proves nothing.**

**P47 test results.** ScarfCore `swift test`: **3023 tests in 229 suites**, one clean run;
subsequent full-parallel runs showed only the known load flakes — `ACPClientStartIdempotenceTests`
(`t-f3820038`, 5/5 in isolation) and `M0bTransportTests.localTransportRunProcessDrainsLargeStdoutAndStderr`
timing out at its 10 s ceiling under load (23/23 in isolation, filed as `t-d964ab17` for P48's
decision-8 fixture work). Mac full serial `-only-testing:scarfTests`: **1271 tests in 174 suites,
0 failures**, 126 s — run twice, green both times. `scarf` and `scarf mobile` both build with no
new warnings. **38 new tests in eight suites** across two `HermesP47Tests.swift` files (ScarfCore
20, `scarfTests` 18); each behavioural fix was watched failing against its reverted form. Both new
files are phase-named, so they are in the P38 sweep's scope by name and no `branchTouchedTestFiles`
append was needed.

**Tasks filed.** `t-4edfd804` (the round-6 exit-0 family), `t-d964ab17` (the M0b load flake).
`t-8f55df7d` updated: Settings and Plugins closed, the other seven panes still open, with the
Plugins lock recorded as the second worked example of how to scope one.


### P47b — review remediation (`d1c46223`)

One commit on `fix/whole-surface-audit-r5`, remediating the independent review of P47's
`f093af74` + `1e88ab3e`. Four of five findings were real; the fifth was real as written.

- [gotcha] **A three-state verdict needs three branches at the call site, not two.**
  `HealthViewModel`'s `sessions optimize` strip had `succeeded` / `exitCode != 0` / else, and the
  else swallowed `.unconfirmed` — an exit-0 run that printed neither
  `Optimized {n} FTS index(es).` (`hermes_cli/sessions_cmd.py:817` @ `v2026.9.7`) nor
  `Error: optimization failed:` (`:815`) rendered `"Optimize failed. "` with an EMPTY tail when
  the run printed nothing at all. P47's own convention ("once a verdict lands, stop quoting the
  exit code") was applied to both memory-reset sites and missed here. Generalised: **when a
  verdict has a `confidence`, grep every consumer for a two-way `if` on `succeeded`** #ux
- [convention] **A message a detached hop decides is a `static` function.** The fix was untestable
  where it lived — `HealthViewModel` has no injectable runner, so the strip's text could only be
  reached through a live `hermes`. `sessionsOptimizeSummary(outcome:exitCode:trimmed:)` is the
  P47 lesson ("a verdict rule at a call site needs that call site reachable from a test") applied
  to a pure formatter instead of a seam #verification
- [gotcha] **A call chain cited as A → B → C must be re-walked, not paraphrased.** P47 wrote
  `cmd_enable`/`cmd_disable` → `_set_plugin_enabled` → `_write_config_value`. At `v2026.9.7`
  `cmd_enable` (`plugins_cmd.py:987`) and `cmd_disable` (`:1182`) call `_save_plugin_sets`
  DIRECTLY (`:1022`, `:1196`); `_set_plugin_enabled` (`:944`) is a SIBLING caller of the same
  door, reached from `cmd_install` (`:754`), `_rescan_after_update` (`:847`) and the dashboard
  APIs (`:1711`, `:1786`). The door is `_save_plugin_sets` (`:914-916`) →
  `_save_enabled_set`/`_save_disabled_set` (`:910`, `:906`) → `_write_config_value` (`:115-120`).
  **Name the door, not whichever caller you happened to open first** #verification
- [gotcha] **"Verb X has no config write" is a claim about every arm of X.** Update's lock
  exemption was justified with "only `_set_plugin_enabled` reaches `save_config`" — false twice
  over: it is not the only caller, and `cmd_update` itself reaches it on the dangerous-scan arm
  (`:794` → `:810` → `:847`, printing `has been disabled.` at `:848-851` regardless). No shipped
  bug (the verdict's `managedRefusalAnchored` + `failureWins` catches it), but the decision was
  standing on a false sentence, corrected above #verification
- [gotcha] **Rich `Panel` output is not column 0.** The anchoring rationale named the plugin's own
  `after-install.md` echo as the untrusted text the prefix anchor defends against — but
  `_display_after_install` (`:391-404`) renders it inside a `Panel`, so every line arrives behind
  a `│` and could never anchor. The real column-0 untrusted text on the install path is the
  `[dim]` community-index lines, which echo the entry's `ref` and `install_identifier`
  (`:694-697`). **Before citing a line as a spoofing hazard, check how rich PRINTS it** #hermes-cli
- [convention] **A test that asserts more than the code path can reach is labelled breadth by
  CHOICE.** `everyAnchoredRefusalSpellingLands` pinned `Cannot set`/`Cannot unset` on the install
  path, where the only reachable managed line is `Cannot save configuration: …`
  (`config.py:2317` → `managed_error("save configuration")` `:453-455` → `format_managed_message`
  `:445-450`). The breadth is worth keeping — `managedRefusalAnchored` is one SHARED list and a
  door added later must land here too — so it is renamed `everySharedRefusalMarkerLandsOnThisDoor`
  and says what it guarantees, rather than implying Hermes emits all three #verification
- [gotcha] **Two sibling `.alert`s on one view is a coin-toss.** P47 stacked a second `.alert` on
  `MemoryView` for decision 3's neutral note. The two are mutually exclusive by construction (one
  branch of one `if` sets each), so they collapse into one alert driven by a
  `ResetAlert` enum through `presenting:` — the title is `Text`, so both voices stay localized #ux

**Test results.** Mac full serial `-only-testing:scarfTests`: **1278 tests in 177 suites, 0
failures**, 123 s (was 1271/174 at P47). ScarfCore `swift test`: **3023 tests in 229 suites**, the
only issue the known `ACPClientStartIdempotenceTests` load flake (`t-f3820038`, 5/5 in isolation);
`--filter P47` 20/20. **7 new tests in three suites** appended to `scarf/scarfTests/HermesP47Tests.swift`
(`SessionsOptimizeStripP47bTests`, `MemoryResetAlertP47bTests`, `CorrectedCitationsP47bTests`) plus
a seventh argument on `CatalogueCoverageP47Tests`. Both test files are phase-named, so no
`branchTouchedTestFiles` append was needed. iOS untouched.



## Whole-surface remediation — P48 (transports and C10 residue, `t-86311c5a`)

Seven commits on `fix/whole-surface-audit-r5`: `b34493a5` (one drain primitive, a required
timeout, the descriptors), `4dd7911d` (the streaming spawns), `df6993cd` (the probe and the
script runner), `33953111` (the app target off the cooperative pool, and the widened sweep),
`86b49af1` (the timing bets and the fixtures), `3719917d` (the repo-wide stability wave),
`9cd3b986` (the fresh-eyes pass and its correction). Round-5 decisions 4–8, folding `t-10eb7c17`
and `t-12d04477`, closing `t-f43f0af5`, `t-f3820038` and `t-d964ab17`.

### The lessons

- [decision] **Decision 4 done: `ProcessPipeDrainer` is deleted, not patched.** It was a SECOND
  drain implementation carrying both defects `ProcessPipeDrain` had already fixed — an unbounded
  `Capture.wait()` and readers on the fixed-width `.utility` global queue — and the two Mac
  transports were its only callers. The generalisable shape: **a defect fixed in one primitive
  does not reach a second copy of that primitive, and a second copy is invisible precisely
  because it has a different name.** Both transports' overrun arms were also `terminate()` then a
  BARE `waitUntilExit()`; the behavioural test that catches it is a child with SIGTERM trapped to
  ignore AND a grandchild holding the pipe's write end, which hangs the old code forever and
  returns in ~5 s on the new #c10
- [decision] **Decision 5 done, and the iOS conformer was the finding nobody filed.** No
  production caller ever passed `nil`, so making `timeout` non-optional was pure compile-time
  hardening on the Mac — but `CitadelServerTransport.asyncRunProcess` ACCEPTED the parameter and
  then never read it: every iOS remote exec drained the Citadel stream to its end with no ceiling
  at all. It races the drain against the budget now, the way the neighbouring `runScript` already
  did. **An optional parameter and an ignored parameter look identical at the call site**, and
  changing the type is what surfaced the second one #c10
- [gotcha] **`Task.detached` is not an escape from the cooperative pool, and it is the shape a
  phase reaches for when it wants one.** P43c named this; P48 widened
  `ProcessAsyncWaitP43cTests` to READ `Task { … }` / `Task.detached { … }` closure bodies and one
  level of synchronous indirection, over a second root (`scarf/scarf`), and it immediately
  reported ELEVEN live sites — most of them created by P48's own earlier commits, every
  `waitUntilExit(timeout: 0)` escalation sitting directly in a `Task` closure. `SpotifyAuthFlow
  .reapDetached`, the site P43c had called "the shape to NOT copy", was another. New
  `Process.waitUntilExitAsync(timeout:)` carries the ones with no drain. **The sweep earned its
  keep on the diff that widened it** #testing #c10
- [decision] **Decision 6 done with a box, because the hook races the spawn.**
  `continuation.onTermination` is installed before `run()` returns, so a consumer that cancels
  during the spawn and the adoption of the child are a genuine race; `StreamingChild` takes
  whichever arrives second and reaps there. Reaping is `waitUntilExit(timeout: 0)` — "the
  deadline is already gone by definition" — on a THREAD. The stderr half is the same P43 lesson
  once more: `readToEnd()` after the wait and only on a non-zero exit, so >64 KB of stderr
  deadlocked a parent still pulling stdout
- [convention] **`ProcessOutputInbox` was the wrong cure for `SSHScriptRunner` and
  `Process.startDraining` was the right one.** The brief named the P40 inbox; the inbox is
  String-based and drains destructively, and this accumulator is `Data` — per-chunk
  `String(data:)` would split a UTF-8 sequence across a pipe read. `startDraining` +
  `collect(grace:)` has the property that actually mattered (wait for the last EOF, not for the
  process to go), is bounded, and is the app's one primitive. **Take the PROPERTY a cure supplies,
  not the type it was supplied in** #conventions
- [gotcha] **A dropped `Pipe` closes both its descriptors, so three of round 5's fd findings were
  false.** Measured: 50 created-and-dropped `Pipe`s leave `/dev/fd` at 4; 50 `/bin/echo` spawns
  whose ATTACHED stdout pipe is never closed take it from 4 to 54, one per spawn, because
  Foundation's reaping machinery outlives the caller's reference. So "the launch-failure arm leaks
  2 fds", "a stdin-less spawn leaks its read end" and the proxy's "leaks 2 fds per failed Start"
  are all wrong — the leak needs a SPAWN. This is P43b's "every relaunch leaked two fds"
  correction met a second time in the same family; the three tests say in their own text that they
  pass against the pre-P48 code and are measurements, not proofs #verification
- [gotcha] **A behavioural test that passes against the reverted code is a regression guard, and
  must say so.** `SSHScriptRunner`'s snapshot-at-exit truncation is a RACE and did not reproduce
  on demand; the two tests written for it pass on the old code too. They are kept, relabelled,
  and the shape sweep beside them is what actually goes red. The alternative — quietly shipping
  them as proof — is how a suite fills with tests nobody has ever seen fail #testing
- [decision] **Decision 7 done: the stability sweep is repo-wide and the scoping is gone.** 89
  subscript-after-count sites in 35 files, each fixed by turning the count `#expect` into
  `try #require` (P46's choice — it stops the test rather than the host). `try? #require` was
  already clean outside the old scope. `isInSweepScope`, `branchTouchedTestFiles`,
  `legacySuiteFiles`, `isPhaseSuite` and the deletion-floor test are all deleted; the premise
  floor is now a plain file count (484 real, floor 300). **Future phases append nothing.** The
  known false positive was TIGHTENED rather than exempted: an optional-chained subscript
  (`map[1]?.first`) is a Dictionary read and cannot trap #testing
- [decision] **Decision 8 done, and the lever was the clock, not the payload.**
  `zipDirectory`/`unzipArchive` start the budget BEFORE `Process.run()` — a fork+exec is part of
  the operation the caller bounded, and starting the clock after the spawn quietly hands the child
  however long the machine took to start it. That is what let the overrun duel go from 64 MB
  against 300 ms to 8 MB against 25 ms. The 300 MB template bomb became 6 MB against an INJECTED
  4 MB ceiling, with the shipped 256 MB constant pinned by its own test: **the guard reads a
  declared number and compares it: the size of the number is not the mechanism** #testing
- [fact] **`t-f3820038` diagnosed and closed.** Every reported `ACPClientStartIdempotenceTests`
  failure was `timed out waiting for condition` against a 3 s helper ceiling on a machine running
  3000 other tests — a ceiling that bounds a hang being written as if it measured latency. It is
  30 s now; the two gate spins, which had NO ceiling and turned a failed assertion above them into
  a hung `swift test`, are bounded and record an issue; and the vacuous mid-test check (a 50 ms
  nap, then "no second channel yet", which a not-yet-scheduled task satisfies trivially) is a latch
  proving the second task's body ran plus a checked settle window
- [fact] **`t-d964ab17` closed: the fixture, not the drain.**
  `M0bTransportTests.localTransportRunProcessDrainsLargeStdoutAndStderr` spent its 10 s ceiling on
  **512 shell forks** (`seq 1 256` × `seq 1 1018`). `head -c … /dev/zero | tr` is two processes
  per stream and the test runs in 0.06 s
- [convention] **A process-global test seam is a `.serialized` you did not ask for.**
  `Analytics.install(_:)` is one slot, and any test that builds an `AppCoordinator` emits into
  whatever is installed — so `CronViewAccessibilityTreeTests` and `SidebarRestructureTests` could
  pollute an analytics assertion in another file. `AppCoordinator` takes its tracker as a
  parameter; the `section_viewed` tests move to a new un-`.serialized` suite, and only the three
  whose SUBJECT is the seam stay serial #testing
- [gotcha] **The P22 main-actor sweep did not know `Thread.detachNewThread`.** It knows
  `nonisolated` and `PlatformSetupHelpers.detached`, so the bounded escalation added to
  `HermesProxyService.stop()` — on a thread, inside a main-actor-isolated `func` — read as a
  violation. A thread has no actor, so it is an opt-out; `Task.detached` is NOT, and a test pins
  that asymmetry, because the two look alike and mean opposite things

### Left open

- `HermesFileService.runShellProbe` stays synchronous, with its reason in the source: its only
  caller is the `enrichedShellEnv` `static let` initializer, which Swift cannot make `async`. The
  `ProcessAsyncWait` sweep carries no allowance for it — the sweep reads `func` declarations and
  not property initializers, and saying that is better than an entry implying otherwise.
- `ServerTransport.runProcess` is still SYNCHRONOUS, so a caller in `async` code still blocks its
  own thread; only the transports' internal waits moved. Making the seam `async` end-to-end is ~50
  call sites across three targets and was out of proportion here.

**P48 test results.** Mac full serial `-only-testing:scarfTests`: **1284 tests in 180 suites, 0
failures**, 118 s (P47b baseline: 1271→1278 tests in 177 suites, 123 s) — six more tests, five
seconds faster, which is decision 8 paying for itself. ScarfCore `swift test`: **3038 tests in 233
suites, 0 failures**, 27 s. The two standing load flakes (`t-f3820038`, `t-d964ab17`) are fixed
rather than tolerated, but "no reruns needed" was read off ONE clean final run and did not
hold: P48's own three `/dev/fd` measurements were themselves a new load flake — a
process-global count sampled once around 30 spawns, so a neighbouring suite's in-flight
descriptors land in the delta — reproduced by the round-5 review at 2 failures in 5 full
runs and fixed in P48b (five consecutive clean full runs there). `scarf` and `scarf mobile`
both build with no new warnings. **21 new tests in five suites** across two `HermesP48Tests.swift`
files (ScarfCore 14, `scarfTests` 7), plus six calibration cases on `ProcessAsyncWaitP43cTests`
and two pinned constants on `ProjectTemplateBoundsP43Tests`. Four behavioural fixes were watched
failing against their reverted form (the SIGTERM-proof overrun arm, the stderr deadlock, the
orphaned child, the two source sweeps); three fd tests and two script-runner tests are labelled
in their own text as guards rather than proofs.


### P48b — review remediation

Five commits on `fix/whole-surface-audit-r5`: `d5abbe0a` (Stop asks before it waits), `8f0caf26`
(the fd measurements stop counting the neighbours), `9acc8dbe` (the last three bare
`AppCoordinator`s), `36395fc4` (the iOS exec timeout closes its channel), `1376fd58` (a vacuous
settle, an uncalibrated matcher, an over-claiming comment). Seven of the eight review findings
were confirmed and fixed; one was wrong and is recorded as such.

- [gotcha] **A bounded-wait primitive's budget is a POLL, not a grace period — so the signal has
  to be sent first.** `HermesProxyService.stop()` passed `stopCeiling` to
  `waitUntilExit(timeout:)` and nothing else, and that primitive signals only once its budget is
  SPENT: Stop polled a child nobody had asked to leave for three seconds and only then sent
  SIGTERM, which is STRICTLY WORSE than the bare `terminate()` P48 replaced. Every other
  escalation in the tree passes `timeout: 0` precisely because it has already signalled or
  already spent its budget (`StreamingChild.reap`, `SSHTransport.runLocal`'s timeout arm,
  `TestConnectionProbe`) — the one site that passed a real number was the one that got it
  backwards. **A helper whose doc says "escalates" can still be the wrong call when the caller
  owes it an action first** #c10
- [gotcha] **A source test that greps a literal does not pin an ORDER.** The guard test for the
  above asserted `code.contains("waitUntilExit(timeout: ceiling)")`, which the defective shape
  satisfies perfectly. It now slices `func stop()`'s body and compares the positions of
  `terminate()` and the wait. When the defect IS the sequence, the test has to read the sequence
  #testing
- [gotcha] **A process-global measurement is a flaky test in a parallel suite, and widening the
  threshold cannot fix it.** The three `/dev/fd` delta tests sampled once around 30 spawns; a
  neighbouring suite's in-flight descriptors land in that window, so the review reproduced 2
  failures in 5 full runs at a delta of 16 against a threshold of 10 — noise the same size as the
  signal. The fix is the SHAPE of the measurement, not its bound: three trials, smallest delta,
  because the leak is deterministic (+30 every trial) and the neighbours are transient #testing
- [convention] **A seam converted for the suites that own it is not converted.** P48 gave
  `AppCoordinator` a `usageTracker` parameter and moved only the analytics suites onto it; three
  sites in two other files still built `AppCoordinator()` and still emitted into the one
  installed tracker. Fixed as a repo-wide sweep in its own file
  (`AnalyticsSeamInjectionP48bTests`) rather than as three call sites — the next bare
  construction will be written by someone who never read the decision #testing
- [decision] **The iOS exec timeout closes the channel now, via `withExec`.** P48's ceiling was
  raced OUTSIDE the stream: `executeCommandStream` hands back only the `AsyncThrowingStream` and
  discards the `Channel` (`Citadel Sources/Citadel/TTY/Client/TTY.swift:269-339`), and that
  stream installs no `onTermination` — cancelling the reader stopped the READER and left the
  remote command and its SSH channel running until it finished by itself. `withExec` is the
  public API that OWNS the channel and closes it on return or throw, so the timeout is thrown
  from inside the closure; `SSHExecACPChannel` was already the precedent in the same package.
  Both execs (`asyncRunProcess`, `runScript`) now share one drain, differing only by an enum for
  how a mid-stream failure is reported #c10
- [gotcha] **A settle-poll seeded from the property it polls returns on the first sample.**
  `HermesFileWatcherAtomicReplaceTests` seeded `settled = watcher.lastChangeDate` and returned
  when a fresh read equalled it — always true immediately, so the 700 ms settle was ~0 and the
  storm test armed against an undrained backlog. A settle is a QUIET WINDOW: seed outside the
  domain (`Date.distantPast`) and require the value to hold across the window #testing
- [convention] **A sweep matcher gets hoisted and calibrated, especially when a phase adds an arm
  to it.** P48 tightened the subscript-after-count matcher with an optional-chain exemption while
  it was still inline and uncalibrated — and a matcher that stops matching reports nothing and
  looks exactly like a clean tree. Hoisted to
  `HermesP38SourceSweepTests.subscriptAfterCountOffenses(in:)` with four cases next door, the way
  `FixedSleepMatcherP46bTests` pins the sleep matcher #testing
- [fact] **The review's `SSHTransport.runLocal` finding is WRONG, and the disproof is two lines.**
  It reads the `terminationHandler` being installed after `proc.run()` as a lost race that would
  report `.timeout` for a successful run. Darwin's Foundation fires the handler even when it is
  assigned AFTER the child has already exited: a standalone probe (`/usr/bin/true`, then
  `Thread.sleep(1)`, THEN assign the handler) reports "handler fired", and a 40×`/usr/bin/true`
  behavioural test passes against the un-reordered code in 0.079 s. Nothing was changed there —
  a cosmetic reorder would have shipped a comment asserting a mechanism that does not exist
  #verification
- [fact] **`zipDirectoryIsBounded` proves a bounded refusal, not a lost duel.** With decision 8's
  clock starting before `Process.run()`, the 25 ms can go to the fork+exec rather than to `zip`'s
  compression, so the comment claiming `zip` cannot finish in time over-claimed. The comment now
  states what holds either way and the test asserts the wall-clock bound #testing

**P48b test results.** ScarfCore `swift test` full, **five consecutive runs, 3038 tests in 233
suites, 0 failures** (29.5 / 27.7 / 26.5 / 26.2 / 26.0 s) — the fd flake did not reappear. Mac
serial, the touched suites plus `HermesP38SourceSweepTests`, `MainActorSpawnDisciplineP22Tests`
and the analytics pair: 54 tests in 10 suites + 4 XCTest cases, 0 failures. The analytics suites
and their two former polluters run together with `-parallel-testing-enabled YES` three times, 0
failures. `scarf mobile` builds clean; ScarfIOS's new `CitadelExecChannelP48bTests` (3 tests)
passes. Four of the fixes were watched failing against their reverted form (the missing
`terminate()`, the bare `AppCoordinator()`s, and both shape tests).


## Whole-surface remediation — P49 (capability floors, `t-89264409`)

One commit `c718237d` on `fix/whole-surface-audit-r5`. Round-5 decisions 9 and 10, plus the
report's suggested follow-on re-walk.

### The tag walk (every blob re-opened, C2)

- `set_session_model` in `acp_adapter/server.py`: **`:466` @ v2026.3.17** (0.3.0 — the earliest
  tag that has an `acp_adapter/` at all), **`:482` @ v2026.3.30** (`pyproject.toml` = **0.6.0**,
  Scarf's supported minimum, with a working body: `state.model = model_id`, agent rebuilt through
  `_make_agent`, `save_session`), **`:929` @ v2026.9.7**. So the answer to the brief's "if the
  method is NOT there at the v0.6.0 tag, pin at the first tag instead" is: it IS there, at the
  floor and before it.
- `CommandDef("yolo", …)`: absent from `hermes_cli/commands.py` at v2026.3.30; **`:96` @
  v2026.4.3** (0.7.0); `:181` @ v2026.9.7. `yolo` appears in `acp_adapter/server.py` at zero tags.
- ACP usage payload: `Usage(...)` built from five keys at **`:325-336` @ v2026.3.30**,
  **`:1050-1059` @ v2026.5.7** (0.13.0, the claimed floor) and **`:917-924` @ v2026.9.7** — no
  compression count at any of them.

### The lessons

- [gotcha] **A floor on an ACP METHOD hides more than a floor on a CLI verb, because nothing
  fails loudly.** `hasACPSetSessionModel` was false on 0.6.0–0.12 hosts that all have
  `set_session_model`; the chip, the project binding, the Models sidebar row, the Chat Settings
  menu item and the iOS badge just were not there, and the ChatViewModel path *logged* "bound but
  not applied" and dropped the preset. A wrong CLI floor produces a missing button someone
  reports; a wrong RPC floor produces a quietly poorer app. The retirement is unfloored, like
  `reset`/`context`/`version` #capability-gating
- [gotcha] **An unread flag is where a wrong floor survives longest.** Both re-walk failures
  (`hasInsightsCommand`, `hasDashboardCommand`) were "no consumer yet — kept because the floor is
  source-verified", and the floor was not verified at all: `hermes insights` is
  `hermes_cli/main.py:4634` at **v2026.3.30 = 0.6.0** (below the supported minimum → deleted, the
  P15/P23 rule) and `hermes dashboard` is `hermes_cli/main.py:4458` at **v2026.4.13 = 0.9.0**,
  absent at v2026.4.8 = 0.8.0 (→ re-floored 0.16 → 0.9). A re-walk should sample the
  consumer-free flags deliberately, not at random #capability-gating #verification
- [fact] **A tolerant decode is not evidence a field exists.** `ACPClient.prompt` accepts
  `compressionCount` and `compression_count`, and `TODO(WS-8-Q1)` had been asking since M-phase
  "confirm the wire field name once v0.13 is available". v0.13 came and went; the field is on no
  tag. The plumbing stays (the chip's `> 0` test hides a never-sent field, and a future
  gateway/`session/update` path is the landing pad) but all three doc comments now state the fact
  with citations rather than the question. Folded into `t-1febd6fa` #verification
- [convention] **When a flag is deleted, leave the walk behind as a comment where the flag was.**
  Each retirement in `HermesCapabilities.swift` carries the tags and line numbers that justified
  it, so the next phase inherits the walk instead of repeating it — and a source test asserts the
  record is still there. Same reason P23 wrote the `hasSessionsRename` removal into the file.
- [gotcha] **Removing a gate means asking what the gated branch also DID.** The two
  `ProjectChatSettingsSheet` guards each carried an `isLoading = false` / `isSaving = false` +
  `dismiss()` tail, and `ChatViewModel`'s carried `currentModelPreset = nil`. Dropping a guard
  whose body is not just `return` silently drops those too — each was re-checked against the
  function's remaining exits (`load()` ends with `self.isLoading = false` unconditionally; the
  `setSessionModel` catch arm already nils the preset) #conventions

### Disposition

- **Decision 9 — fixed.** Flag deleted; seven consumers ungated across three targets
  (`ChatViewModel.applyProjectModelPreset`, `SessionInfoBar` chip + three doc comments
  (the third — the chip's own consumer comment — was missed by P49 and fixed in P49b),
  `ChatModelBadge` doc, `ProjectChatSettingsSheet` section + `load()` + `save()`,
  `SidebarView.sections` (`.models` now unconditional), `SidebarProjectsWell` Chat Settings menu
  item, iOS `ProjectDetailView` badge, `ACPClient.setSessionModel` doc). The Chat Settings menu
  item also stopped gating on `hasSessionEditAutoApproval`, since the sheet now always has a
  working section; the v0.15 gate survives INSIDE the sheet on the auto-accept row.
- **Decision 10 — fixed.** Flag and its three test assertions deleted; `M9SlashCommandTests`'s
  roster check now pins `hasSessionsSlashCommand` instead, and the two sibling docs that said
  "kept for the same reason as ``hasYOLOSlashCommand``" no longer link a deleted symbol.
- **`hasContextCompressionCount` — walked, kept, re-documented.** `SessionInfoBar.swift:380` still
  reads it and `RichChatViewModel.acpCompressionCount` still feeds it, so the plumbing is not dead
  and was NOT removed.
- **Follow-on re-walk — 20 flags, 13 groups, 18 correct.** Confirmed at floor + previous tag:
  `hasOneShot` (`hermes_cli/_parser.py:97` @ v2026.4.30), `hasCronWorkdir` (`main.py:8506`),
  `hasGoals` (`commands.py:103` @ v2026.5.7), `hasGatewayList` (`main.py:8723` @ v2026.5.7),
  `hasDockerExtraArgs` (`config.py:622` @ v2026.5.16), `hasHermesProxy` (`main.py:1476`),
  `hasBitwarden` (`agent/secret_sources/bitwarden.py` @ v2026.5.28), `hasMCPCatalog`
  (`hermes_cli/mcp_catalog.py` @ v2026.5.28), `hasKanbanGoalMode` (`kanban.py:345` @ v2026.6.5),
  `hasCuratorConsolidate` (`agent/curator.py:203` + `config.py:2030` @ v2026.6.19),
  `hasMaxConcurrentSessions` (`gateway/config.py:546`), `hasCronAttachToSession`
  (`cron/jobs.py:867` @ v2026.7.1), `hasMCPReauth` (`mcp_config.py:952` @ v2026.7.1),
  `hasElevenLabsDeepInfraSTT` / `hasDeepInfraTTS` (v2026.7.20, neither at v2026.7.7.2),
  `hasCuratorAdopt` (`curator.py:344`/`:748` @ v2026.7.30, zero at v2026.7.20),
  `hasApprovalsSuggest` (`git ls-tree`: file at v2026.7.30, absent v2026.7.20), `hasCronRuns`
  (`subcommands/cron.py:159` @ v2026.7.20), `hasReasoningEffortUltra` (`hermes_constants.py`
  tuple gains `ultra` at v2026.7.20; ends at `max` at v2026.7.7.2), Bot Mode's
  `tools/bot_mode_probe.py` (present v2026.8.16.2, absent v2026.8.16), `_has_pause_marker`
  (`cron/jobs.py:482` @ v2026.8.13, zero at v2026.8.3), `get_managed_system`'s contents-read arm
  (v2026.8.19 vs the existence-only form at v2026.8.18), `hasPeerRunCommands`
  (`subcommands/peer.py:432-434` @ v2026.9.7, zero at v2026.8.27), `hasCronDoctor`
  (`subcommands/cron.py:184` @ v2026.9.7 / `:325` @ v2026.8.31, absent v2026.8.27),
  `hasPluginsCompat` (`subcommands/plugins.py:105` + `plugins_cmd.py:2060` @ v2026.9.7, zero at
  v2026.8.31), `hasCronCreatePaused` (`subcommands/cron.py:84,86` @ v2026.9.7, zero at
  v2026.8.31). Two wrong, both fixed here (see the lesson above). **Nitpick, not changed:**
  `hasPeerRunCommands` and `hasCronDoctor` cite line numbers without naming the tag; both are
  v2026.9.7 numbers and correct there (`cron doctor` sits at `:325` at v2026.8.31).
- **Filed `t-54ec6eb3`** for the remaining ~85 un-sampled flags — the full re-walk, now that the
  sampling rate has produced a 10% error rate twice in two rounds.

**P49 test results.** ScarfCore `swift test`: **3049 tests in 236 suites, 0 failures** (was
3046/235 before the phase), one clean run. `--filter 'P49|HermesCapabilities'`: 140/140. Mac
serial `-only-testing:scarfTests`, three batches, non-zero counts each: the new suite + the sweep
+ the sidebar suites **23/23**, the ChatViewModel family **32/32**, the P47/parity/analytics
family **105/105**. `scarf mobile` builds clean. **17 new tests in four suites** across two
`HermesP49Tests.swift` files (ScarfCore 11, `scarfTests` 6). Both files are phase-named and P48
retired the sweep's scope list, so nothing was appended to it.

**A filter that names a non-existent suite poisons the whole run.** The first Mac batch printed
`23 tests in 4 suites` for a command naming 23 suites, because one bad `-only-testing` name
(taken from a `final class` that was a nested helper, not a suite) silently dropped the rest.
Addendum lesson 9 says a filter matching nothing still prints TEST SUCCEEDED; the stronger form is
that ONE bad name can drop its siblings, so the test COUNT is the only signal — check it per batch.

### P49b — review remediation (`b1cb58d7`)

Four findings from the independent review of `c718237d`, all accepted.

- **The chip's own consumer comment was the one P49 missed.** P49 corrected three doc comments
  (`ACPClient.prompt`, `RichChatViewModel.acpCompressionCount`, `HermesCapabilities`) and left
  `SessionInfoBar.swift:373-377` — the comment sitting directly on the gate — still saying "a
  v0.13 host sees the chip the first time the agent compacts" and blaming the absence on
  "a pre-v0.13 host (which always reports 0)". Rewritten to the fact with citations, and
  `_build_usage_update` (`acp_adapter/server.py:345-357` @ v2026.9.7) added to the walk: it
  emits `UsageUpdate(size, used)` and no compaction count either, so BOTH ACP paths are covered.
  [gotcha] **A comment sweep that fixes the library's docs and skips the view's is the wrong
  half.** The view comment is the one the next reader of the gate actually reads.
  #verification #capability-gating
- [gotcha] **A source-sweep test that asserts only the line the fix did NOT touch is vacuous.**
  The P49 test named "…its comment stops claiming a v0.13 host sends one" asserted the gate
  expression and nothing else, so it passed on the pre-fix tree. The rule that binds: when the
  deliverable is *prose*, assert the OLD text is absent as well as the new text present, and
  prove it by running the test against the pre-fix blob. #testing
- [gotcha] **An exemption by BASENAME is a coincidence, not a rule.** The ScarfCore sweep
  exempted its own file via `URL(#filePath).lastPathComponent` — which also matched
  `scarf/scarfTests/HermesP49Tests.swift`, the phase-named Mac twin, which spells the retired
  flag on five non-comment lines. Every phase names its files after the phase, so twin basenames
  are the NORM in this tree, not an accident. Exempt by full `#filePath`, and blank string
  literals before matching so an assertion *about* a retired flag isn't read as a consumer of
  it. #testing #conventions
- **C1 nuance — the pre-probe window is a real, accepted delta.** The P49 disposition above says
  the retirement makes the surfaces render on 0.6.0+ hosts; it does not say what changed *before*
  a probe lands. Three sites previously required a non-nil capabilities store —
  `SidebarProjectsWell.swift:510` (`if let caps = capabilitiesStore?.capabilities`),
  `SidebarView.sections`' `.models` entry (`caps?.hasACPSetSessionModel ?? false`) and iOS
  `ProjectDetailView.swift:78` (`capabilitiesStore?.capabilities…?? false`) — so on a 0.13+ host
  they were hidden until the capability probe returned and then appeared. They now render
  immediately. On a 0.13+ host the settled state is byte-identical; **the pre-probe window is
  not**, and that flicker-removal is intended (the surfaces apply on every supported host, so
  there is nothing to wait for). A `?? false` fallback is a *loading* state as much as a
  capability answer, and ungating deletes both #capability-gating
- `ACPClient.setSessionModel`'s doc lost a dangling "The" left by P49's edit.

**P49b tests.** ScarfCore full `swift test`: **3049 in 236 suites, 0 failures** (unchanged —
this phase added assertions, not tests). `--filter 'P49|HermesCapabilities'`: **140/140**. Mac
serial `-only-testing:scarfTests/ModelSurfaceUngatingP49Tests -only-testing:scarfTests/HermesP38SourceSweepTests`:
**11 tests in 2 suites**, pass. Both remediations verified failing without the fix: the comment
test records **8 issues** against `c718237d`'s `SessionInfoBar.swift`, and the full-path sweep
still reports a hit when a real `caps?.hasACPSetSessionModel` read is injected into
`SidebarView.swift`. Nothing appended to the sweep's scope list (P48 retired it).


## Whole-surface remediation — P50 (cron/kanban residue, `t-a397264c`)

Round-5 decisions 11, 12 and 13, plus the section's LOWs. Two commits on
`fix/whole-surface-audit-r5`: `55e464f8` (decisions 11 + 13 + the LOWs) and
`39b888d1` (decision 12, the fleet note).

**What was wrong.**

*Decision 11 — the last hint that named a refused gesture.* P30 fixed the
`noFutureOccurrences` family's copy ("edit the schedule to run it again" →
"duplicate it") and P38 pinned it with a test. That test enumerated the
`noFutureOccurrences` family ONLY, so `errorNeedsNewerHermesHint` — the arm for
a recurring `error` job on a host in `[0.20.6, 0.21.0)` — kept "edit the
schedule to re-arm it" through two more rounds.

*Decision 12 — the field with no note.* A `[proj:]` cron job that is NOT
`no_agent` but carries a `script` was fleet-copied with the field dropped in
silence: green "created", prompt intact, no stdout injection ever again.

*Decision 13 — a gate one axis too wide.* `CronEditorView.isValid` refused Save
on ANY spent one-shot. The bug it was built for (P42b) is a DUPLICATE seeding a
dead time; applying it to an edit meant a user could not fix the PROMPT of a
job whose time had passed, with nothing on screen naming why.

**What shipped.**

- `errorNeedsNewerHermesHint` now says "duplicate it to schedule a new one",
  six locales, with the refusal walked in the doc comment.
- `HermesCronJob.hasPreRunScript` (`noAgent != true` AND a non-blank `script`)
  + the downgrade note at BOTH seams: `FleetApplyViewModel`'s caveat list (what
  the user approves) and `FleetApplyExecutor`'s success-arm counter (what the
  pass reports), in the shape round-4 decision 8 gave monitor jobs.
- `CronEditorView.oneShotTimeIsUnusable` keys on the SCHEDULE, not the sheet: a
  spent time is refused unless it is the record's own already-stored value,
  unedited.
- LOW: the cron detail pane's PRIMARY "Run now" gained
  `.disabled(viewModel.refusesTerminalJobLocally(job))`, which the row menu and
  `BotRoutinesView` already had.
- LOW: `KanbanWatchFilter` deleted (no non-test reader; its doc asserted a
  `kanban watch --json` that does not exist).

**Tags opened (not grepped).**
- `cron/jobs.py` @ `v2026.8.27` — `update_job`'s schedule block (`:2310`,
  `:2322`, `:2345`), its terminal guard (`:2367-2375`), `is_terminal_job`
  (`:638-640`), `create_job` (`:1915`, no terminal guard → Duplicate is
  accepted).
- `cron/jobs.py` @ `v2026.9.7` — `update_job` (`:1930-1968`),
  `_reject_terminal_activation` (`:1865-1878`), `_apply_schedule_update`
  (`:1899-1910`), `_fill_missing_next_run` (`:1912-1927`),
  `_complete_job_record` (`:1463-1465`), `_advance_after_run` (`:2192-2240`).
- `hermes_cli/subcommands/cron.py` @ `v2026.9.7` — the whole `cron create` /
  `cron edit` argparse (`:20-135`).
- `hermes_cli/cron.py` @ `v2026.9.7` — `_JOB_ARG_FIELDS` (`:539-543`),
  `cron_create` (`:567-591`), `_script_health_issue` (`:453-465`).
- `hermes_cli/kanban_parser.py` @ `v2026.9.7` — the `watch` command
  (`:359-365`).

**Findings of the walk.**

- [fact] **There is no `--pre-run-script`; the flag is `--script`, and that is
  why the copier still must not forward it.** `cron create --script`
  (`hermes_cli/subcommands/cron.py:41-46` @ `v2026.9.7`) maps onto the record's
  `script` key through `_JOB_ARG_FIELDS` (`hermes_cli/cron.py:540`) and
  validates NOTHING at create time — the only existence check is `cron doctor`'s
  `_script_health_issue` (`:453-465`), run on demand. So the flag would be
  ACCEPTED and the job would land green pointing at a file under the SOURCE
  host's `~/.hermes/scripts/`. **An accepted flag is not a copyable field when
  the value is a path into the other host's filesystem.** Script-file
  replication is `t-848d3adc` #cli #fleet
- [gotcha] **A prompt-only `cron edit` of a spent one-shot IS accepted, and the
  reason is the record's `enabled` flag, not its state.** `_complete_job_record`
  retires a one-shot as `enabled=False, state="completed", next_run_at=None`
  (`cron/jobs.py:1463-1465` @ `v2026.9.7`), so `_reject_terminal_activation`
  (`:1865-1878`) finds `state` in the terminal set, `enabled` not `True` and
  `next_run_at` nil and passes, and `_fill_missing_next_run` (`:1912-1927`)
  returns on its first line. The shape Hermes would still refuse is a never-run
  GHOST (`state="scheduled", enabled=True`, no `next_run_at`), where
  `_fill_missing_next_run` raises — but that record only exists because an older
  Scarf wrote it, and the P42b gate is what stops a new one #cron #verification
- [gotcha] **A test that pins a copy rule over one arm of a family licenses the
  others.** `HermesCronRecoveryP38Tests.deadEndHintDoesNotSuggestEditingTheSchedule`
  listed three `noFutureOccurrences` spellings and called it done, which is
  precisely why the `error` arm survived two audits with a remedy Hermes
  refuses. The replacement enumerates the static hints AND drives
  `recoveryOffer` over every arm that produces one #testing
- [convention] **A downgrade note lands at the PREVIEW seam and the REPORT
  seam.** Third application of P42's "a fix at the executor is a fix in one of
  two places": the caveat the user approves and the count the pass returns are
  different code, and a note in one of them is a number that does not match the
  outcome #fleet

**Deliberately NOT done.** The unlocalized `.help(…)` literals (~~a scan of
`scarf/scarf` + `scarf/Scarf iOS` against the catalogue found 28, not the
report's 18~~ — **corrected by P50b: 21, not 28**; that scan mapped every `\(x)`
to `%@` and truncated any literal containing an escaped `\"`) were filed under
`t-3bcd1d7f` rather than fixed here. Not a
mechanical six-locale pass: ~21 new keys × 6 locales across 15 files owned by
other phases, and a third of them carry interpolation or `^[…](inflect:)`
morphology whose catalogue key shape is the unresolved part of that task.

**Tests.** ScarfCore `swift test` **3057/3057** (one run showed a single
unattributed issue that did not reproduce — the known parallel-load flake,
`t-f3820038`). Mac serial, eight suites plus the new one and
`HermesP38SourceSweepTests`: **46/46**. `scarf mobile` builds. **Eleven** new tests in
four suites: `CronRecoveryHintP50Tests` (3) and `CronSourceShapeP50Tests` (3) in
`ScarfCoreTests/HermesCronRecoveryP50Tests.swift`, `FleetPreRunScriptP50Tests`
(2) in its own file, `FleetCronNoteP50Tests` (3) in `scarfTests`. **Nine of the
eleven** were watched failing against the pre-fix file; the other two could not
be, and saying otherwise was the claim P50b corrected.
`CronRecoveryHintP50Tests.aV021HostStillGetsResumeAndNoHintAtAll` is a C1 pin on
the arm the fix does NOT touch, so it passes before and after by construction,
and the two `FleetPreRunScriptP50Tests` cases exercise
`HermesCronJob.hasPreRunScript`, which does not exist before the fix — a compile
failure, not a watched assertion.


### P50b — review remediation (`82881859`, `94c88e7f`)

Six findings from the independent review of `55e464f8` + `39b888d1`. Five fixed,
one disagreed with in part.

**MED 1 — the counter with no row.** `FleetApplyExecutor`'s new
`preRunScriptDowngrades` note shipped a `String(localized:)` with no
`Localizable.xcstrings` entry while its three siblings all had one. Six locales
added, plus a FILE-scoped forward gate
(`FleetApplyExecutorCatalogueP50bTests`): every `String(localized:)` in that file
must have a catalogue row.

**MED 2 — the editor's second door.** Decision 13 widened iOS
`CronEditorView.isValid`, which newly put Save within reach of an ungated
`Enabled` toggle: flipping it on a `completed` one-shot wrote
`enabled: true, state: "completed"` into `cron/jobs.json` — the shape
`_reject_terminal_activation` (`cron/jobs.py:1865-1878` @ `v2026.9.7`) refuses and
the list row's own toggle already declines. The editor takes the shared
`CronRecoveryOffer` now (no default), the edit sheet passes the record's own,
new/duplicate pass `.none`.

**MED 3 — the `--json` the alarm missed.** `HermesKanbanEvent`'s doc comment
still claimed `hermes kanban watch --json`; the P50 alarm grepped one file. Fixed
and widened over `ScarfCore/Sources` + `scarf/scarf` + `Scarf iOS`.

**LOW 4 / LOW 5.** `t-3bcd1d7f`'s plan and the counts above, corrected.

**LOW 6 — Duplicate off the long press.** Now a trailing swipe action beside
Delete.

**The lessons.**

- [gotcha] **Widening a validity gate opens every control the Save button
  guards, not just the one you widened it for.** Decision 13's axis was the
  SCHEDULE, and it was right about the schedule; what it did not ask is what
  ELSE the Save it just unlocked can now write. `Enabled` had been unreachable
  on a spent one-shot only because Save was. Before widening a gate, enumerate
  the fields the write carries and ask which of them the OLD gate was
  incidentally protecting #verification
- [gotcha] **Two doors into one write must be gated by one predicate, and the
  second door is usually a form.** `IOSCronViewModel.setEnabled` refused a
  terminal resume through `offer.refusesResume`; `CronEditorView` wrote the same
  field with no gate at all, and on iOS there is no CLI behind the form to catch
  it (`saveJobs` rewrites `cron/jobs.json` directly). Round-4's "the optimistic
  mirror has an idle twin", one layer up: the twin of a TOGGLE is the EDITOR
  #cron
- [convention] **A locked control writes the record's stored value, not
  `false`.** P47 taught that a `.disabled` control keeps the value its binding
  holds; the follow-on is that forcing the safe-looking value is its own bug. A
  recurring job in `error` is terminal AND enabled, so forcing `false` on the
  locked arm would have quietly disabled it on a prompt-only save. Write back
  what `jobs.json` already says #ux
- [gotcha] **A source scan that maps every `\(x)` to one specifier is wrong for
  a third of its hits.** P50 called 28 `.help(…)` literals unlocalized; 21 are.
  An `Int` interpolation catalogues as `%lld` and a `String` as `%@`, the source
  does not say which, and the answer is to enumerate BOTH assignments and accept
  any hit. The same scan also truncated every literal containing an escaped
  `\"`. Both are fixed in `FleetApplyExecutorCatalogueP50bTests`, which is the
  machinery `t-3bcd1d7f` should generalise #testing #verification
- [fact] **iOS's cron write path is `cron/jobs.json`, not `state.db` — C3 is not
  in play, and the guards are already there.** `IOSCronViewModel.saveJobs` goes
  through `GuardedJSONStore`: damage refusal on a stat-confirmed twice-failed
  read, stale-clobber refusal against the loaded bytes, and a `.bak` of the
  replaced content (the P7 addendum). It is a deliberate, documented design for
  a Hermes-owned JSON file, not a C3/C5 drift — what it does mean is that no CLI
  argparse stands behind an iOS cron form, so every validation Hermes would have
  performed has to live in the form #cron #ios
- [gotcha] **An alarm is only as wide as the path it greps.** P50's
  `nothingClaimsAJSONFlagOnKanbanWatch` read `KanbanFilters.swift` — the file it
  had just emptied — while the identical false citation sat in
  `HermesKanbanEvent.swift`. When you delete a claim, the test that stops it
  coming back walks the TREE, not the file #testing

**Tests.** Eight new (six in `ScarfCoreTests/HermesP50bTests.swift`, three in
`scarfTests/HermesP50bTests.swift` — one of the ScarfCore six and the ScarfCore
`kanbanWatchFilterIsStillGone` are alarms on already-correct state, the other
seven watched failing against the pre-fix files). ScarfCore `swift test`
**3065/3065**. Mac serial, six suites (`FleetApplyExecutorCatalogueP50bTests`,
`FleetCronNoteP50Tests`, `HermesP38SourceSweepTests`, `LocalizationCatalogTests`,
`LocalizationF7RecoveryTests`, `CatalogueCoverageP47Tests`): **26/26**.
`scarf mobile` builds.

**Hermes citations re-opened.** `hermes_cli/kanban_parser.py:355-375` @
`v2026.9.7` (the `watch` argparse — confirmed `--assignee/--tenant/--kinds/
--interval`, no `--json`); `cron/jobs.py:1865-1878` @ `v2026.9.7`
(`_reject_terminal_activation`, re-read for the editor gate).


## Whole-surface remediation — P51 (settings/YAML residue, `t-f406c932`)

Commits `76206b4d` (the reader's trim, ScarfCore), `c838c562` (decisions 15/16/17 **plus the
control-character refusal in `commitSave`**) and `c93c2287` (the platform config keys + the C10
residue **plus the `.xcstrings` rows for `c838c562`'s two new strings**) on
`fix/whole-surface-audit-r5`. The two parentheticals in bold are P51b's attribution
correction: `c93c2287`'s message DESCRIBES the control-character refusal, which actually landed
in `c838c562`, and the localisation rows for the strings `c838c562` introduced landed in
`c93c2287` — so `c838c562` alone fails `LocalizationCatalogTests`. History is not rewritten (a
shared branch); the record is corrected here.
Round-5 decisions 14, 15, 16 and 17, plus the surface's MED and LOW residue.

### The lessons

- [gotcha] **`CharacterSet.whitespaces` is not PyYAML's whitespace, and the direction is
  lossy.** Foundation's set is Unicode `Zs` PLUS tab; PyYAML's scanner keeps every `Zs`
  character as ordinary CONTENT — part of the plain scalar, the key, the list item, the flow
  entry. Confirmed on the real interpreter (6.0.3): `model: gpt\u{A0}` →
  `{'model': 'gpt\xa0'}`, and the same for U+3000, U+2009, U+1680, U+202F, U+205F, U+2003,
  leading and trailing, in values AND keys AND list items AND both flow shapes. `yaml.safe_dump`
  emits such a value BARE, so a value Hermes itself wrote rendered SHORT in Scarf and the next
  save persisted the trimmed form over the one the agent was using. One `yamlWhitespace`
  (space + tab) now serves all seventeen trims in the reader #yaml
- [decision] **TAB stays in the narrowed set although PyYAML does not trim one.** `model: gpt\t`
  and `model:\tgpt` are both `ScannerError` at 6.0.3 — that document does not load AT ALL, and
  `load_config` discards the whole config.yaml layer (`gateway/config.py:775-791` @
  `v2026.9.7`). Trimming a character that only ever appears in a file Hermes refuses decides
  nothing, and keeping it matches `plainKeySeparatorIndex`'s existing note
- [invariant] **A PARSER trim and a `.strip()` MIRROR answer to different sources, and unifying
  them is the bug.** `normalizedScalar` keeps `.whitespacesAndNewlines` deliberately: it is the
  last step before a TYPED comparison, and every Hermes reader on the other side calls Python's
  `str.strip()` — `_bool_token`'s `str(value).strip().lower()` (`gateway/config.py:31`),
  `_normalize_approval_mode`'s `mode.strip().lower()` (`tools/approval_context.py:207`),
  `parse_reasoning_effort`'s `str(effort).strip().lower()` (`hermes_constants.py:884`), all @
  `v2026.9.7`. Python's `str.strip()` removes all 29 characters for which `c.isspace()` holds,
  U+00A0 and the `Zs` block included — so `reasoning_effort: high\u{A0}` IS `high` to Hermes,
  and narrowing here would have made Scarf claim the host ignores a value it honours. Same
  reason `normalizedLevel` was left alone. A test pins the two rules DISAGREEING on one input
  #config-parsing
- [gotcha] **A dead key can have a CEILING as well as a floor, and the count is by CALL SITE.**
  `discord.allow_any_attachment` reads as a v0.15 feature and is one — but the Discord adapter
  stopped CALLING `_discord_allow_any_attachment` at `v2026.7.1` (0.18.0) while the getter
  lingered to `v2026.8.31`, and only at `v2026.9.7` is the getter gone and the key a documented
  no-op (`hermes_cli/config_defaults.py:1448`;
  `website/docs/user-guide/messaging/discord.md:703`). Grepping the SYMBOL would have put the
  window's end three releases late. Tag-by-tag call count: v2026.5.16 absent, v2026.5.28 → 2,
  v2026.5.29 → 2, v2026.6.5 → 2, v2026.6.19 → 2, v2026.7.1 → 0, and 0 through v2026.9.7. So
  `hasDiscordAllowAnyAttachment` is `atLeastSemver(0,15,0) && !atLeastSemver(0,18,0)` — the
  first flag in the file whose upper bound is load-bearing #capability-gating
- [decision] **Gated, not retired, and C1 is the reason.** Retiring the row would have changed
  what a v0.15–v0.17 host renders, and "a pre-target host must render byte-identical to the
  prior Scarf release" is exactly about those users. The row hides where it does nothing and
  the WRITER follows the row
- [gotcha] **Hermes's per-model override lookup is case-SENSITIVE, so a tidy dedupe deletes a
  live setting.** `resolve_per_model_reasoning_effort` is `variant in overrides`
  (`hermes_constants.py:929-941` @ `v2026.9.7`) over `_canonical_model_variants` (`:892-926`),
  which recovers dots↔dashes and adds/strips provider prefixes but NEVER changes case.
  `Claude-Opus` and `claude-opus` are two live entries; the editor's `caseInsensitiveCompare`
  replace-on-add removed one from the FILE, because `setReasoningOverrides` rewrites the block
  from what the editor holds. The rule: **before deduping a key, ask the CONSUMER how it
  compares** — the round-5 twin of lesson 1's "ask which axis the consumer keys on"
- [gotcha] **A view that spawns LOCALLY is a local-only affordance, whatever path it is
  handed.** `EmbeddedSetupTerminal` is a `LocalProcessTerminalView` with no transport in the
  path, so on a remote context WhatsApp's pairing ran `context.paths.hermesBinary` — the REMOTE
  absolute path — as a local executable, and Signal's link landed in the LOCAL `~/.hermes` that
  the remote gateway never reads. Both reported success. `signalCLIInstalled` made it worse: it
  probes the LOCAL login shell's PATH, so the buttons' own enablement was a fact about the wrong
  machine. `runBackup`'s posture (decision 15) — one sentence naming the host, buttons disabled,
  and the terminal pane REPLACED by the sentence rather than left to fail in view #ux
- [convention] **A refusal that lives at a shared door beats fifteen copies at the forms.** The
  control-character refusal went into `commitSave`, not into the three forms the finding named:
  the hazard is a property of "free text into a config.yaml scalar", and a per-form check is
  fifteen chances to forget the sixteenth. It is a VISIBILITY guard, not a parse guard, and the
  reason is the EMITTER — a form's config keys go out through `hermes config set`, so HERMES
  writes them with PyYAML (`hermes_cli/config.py:2307` → `utils.py:262` `yaml.dump` @
  `v2026.9.7`) and the file stays loadable; what the user gets is a value they cannot see and
  Hermes will never match. Ordered by LABEL inside the helper, because the batch is a
  `Dictionary` whose order changes between runs and the refusal must not name a different field
  each Save #ux
- [gotcha] **The parity gate is the forcing function, and it fired on the first run.** Moving
  `mattermost.require_mention` onto config.yaml made `MattermostSetupViewModel` a config WRITER,
  and `AllConfigWritersParityTests.everyConfigWriterFileIsRegistered` failed until it was
  registered. Exactly the shape `HermesPlatformSharedKeyWriteP44Tests` has for the allowlist:
  a test that makes the NEXT step mandatory rather than optional #verification
- [fact] **Mattermost's `require_mention` is config-first, env-fallback, and Scarf had it
  inverted.** `_extra_or_env("require_mention", "MATTERMOST_REQUIRE_MENTION", "true")`
  (`plugins/platforms/mattermost/adapter.py:504`, helper `:491-494` @ `v2026.9.7`) consults
  `config.extra` FIRST. The form READ config and WROTE `.env`, so the toggle snapped back on the
  next load AND the write was inert on any config carrying the key. One side both directions
  now — with a new `MattermostSettings.requireMentionIsSet` (raw beside normalised, the
  `approvalModeRawScalar` shape) so an ABSENT key can still fall back to `.env`, which is
  exactly when Hermes uses it. Nothing migrated silently
- [gotcha] **P37 finding 5 has a mirror image.** `NtfySetupViewModel.load` opened with `guard
  let cfg = snapshot.config?.ntfy else { return }`, so an unreadable config.yaml discarded a
  `.env` half that HAD been proved — blanks shown for values Scarf held in hand. The guard moves
  below the `.env` assignments; the latched `loadRefusal` still refuses the Save. The general
  shape: **an early `guard` over one of two independently-proven reads throws away the other
  one**

### The lesson-5 sweep, and what it found

Three shapes were grepped across `scarf/scarf/`, `scarf/Packages/ScarfCore/` and
`scarf/Scarf iOS/`.

- **The `.whitespaces` trim in a YAML reader** — two more, filed as `t-295ef4d2` with line
  numbers. **(Incomplete — P51b found three more: `HermesBotProfileYAML` (20 sites),
  `HermesBotPeersYAML` (`:53`, `:55`) and `SkillFrontmatterParser` (`:31`). `t-295ef4d2` now
  names all five; the "Cleared" list below was also written as if the search had been
  exhaustive and was not.)** The two P51 found: `GatewayConfigWriter` (`:502`, `:594`, `:641`, `:644-645`, the same file as
  `t-38ae4f26`'s open quote-escape gap) and `ProfileRoutesYAML` (ten sites, and its entries ARE
  Scarf-written through `quoteIfNeeded`, so its round trip is lossy in the rewriting direction).
  Cleared: `HermesEnvService` (dotenv, a different format), `HermesFileService:498/:963/:2729/
  :2790` (`.env` scans, a presence heuristic, a CLI-output scan), and every remaining hit in the
  app target, which is a WRITER-side trim of a typed field — correct per P41b.
- **The main-actor `enrichedEnvironment()` / spawn** — five more, filed as `t-f30054a8`:
  `SpawnDiscipline`'s next wave. `SpotifyAuthFlow:133` is the LITERAL idle twin of the
  `NousAuthFlow.start()` fix this phase landed (lesson 3, and it should take the same
  `startTask` + `launch(localEnvironment:)` shape); `OAuthFlowController:252` and
  `MCPLoginController:237` are one fix behind a `@MainActor ProcessFactory` typealias;
  `HealthViewModel:1180` and `HermesProxyService:82` are plain. Cleared: every `.onAppear` in
  both UI trees now carries no main-actor `loadState()` / `readFile` / `loadProven` /
  `runHermesCLI`.
- **The unconditional below-floor write** — NONE beyond Discord. Only two of the fifteen forms
  gate a row on a capability at all (Discord and Telegram), and both now carry the captured set.

### The fresh-eyes pass on P51's own diff

- **`NousAuthFlow` had a THIRD instance of the shape it was being fixed for.**
  `handleTermination:219` read `auth.json` through the context's transport on the main actor —
  an SSH round trip at the moment the sheet reports its result. Moved with the other two. The
  rule: when a file is opened for one C10 site, grep that file for the primitive, not for the
  line.
- **The first draft of the control-character helper was not deterministic.** It iterated the
  caller's array, and the caller built it from a `Dictionary` — so a form with two bad fields
  named a different one on each Save. The sort belongs in the HELPER, so determinism is a
  property of the rule rather than of one call site.
- **The oracle test's own assertion was malformed.** It compared PyYAML's `json.dumps` output
  against the LITERAL character, but `json.dumps` escapes non-ASCII — so the assertion could
  only ever fail, and a sloppier version of it (a no-op `replacingOccurrences`) could only ever
  pass. It asserts the `\uXXXX` form now, derived from the scalar value.
- **Commit 2 did not build in isolation.** It shipped the two view models that call
  `PlatformSetupHelpers.remoteOnlyHostNotice` and held the helper back for commit 3. Amended.
  On a phased branch, a commit that names a new helper must carry it.

**P51 test results.** ScarfCore `swift test`: **3091 tests in 246 suites, 0 failures**, twice,
no flakes. Mac serial, by suite name with non-zero counts: **122 tests in 17 suites, 0
failures** — `HermesP38SourceSweepTests` 3, `LocalizationCatalogTests` 10,
`MainActorSpawnDisciplineP22Tests`, `SpawnDisciplineP43Tests`, `AllConfigWritersParityTests` 5,
`HermesFileServiceConfigParityTests`, `ConfigReadProofP33Tests`, `GwF4OutcomeMessageChannelTests`,
`HermesManagedRefusalP39Tests`, `HermesManagedLockP39cTests`,
`HermesP28CrossPhaseRemediationTests`, the three `HermesP37*` suites,
`AnalyticsFeatureUsageEventsTests`, `NousAuthFlowParserTests`, plus the five new P51 suites.
`scarf` and `scarf mobile` both build. **45 new tests in 10 suites** across two
`HermesP51Tests.swift` files (ScarfCore 26, `scarfTests` 19); every behavioural fix was watched
failing against its reverted form (30 issues for the trim, 3 for the window flag, 1 for the
Mattermost presence field, 3 for the pairing guards, 1 for the dedupe, 3 for the two platform
writes). `Localizable.xcstrings` +82 lines, 0 deletions, two keys × six locales. Both new test
files are phase-named, so they are in the P38 sweep's scope by name and no
`branchTouchedTestFiles` append was needed.

**Tasks filed.** `t-295ef4d2` (the two remaining Unicode-`Zs` trims), `t-f30054a8` (the five
main-actor env/spawn sites).


### P51b — review remediation (`6b7c5ffc`, `698bee29`)

Seven findings from an independent review of P51's three commits, on `fix/whole-surface-audit-r5`.
Two commits: the mattermost behaviour, then the extraction and the two corrected claims.

- [gotcha] **A read and a write that are consistent with EACH OTHER can still both be wrong.**
  P51 moved `mattermost.require_mention` from `.env` to config.yaml and left reader and writer
  on the same bare top-level spelling. The Scarf round trip worked, which is why it passed
  review — but `require_mention` is a `_SHARED_KEYS` member, so on a nested-only host the bare
  write CREATES the top-level `mattermost:` block, `platform_section`
  (`gateway/config_loader.py:171-180` @ `v2026.9.7`) takes that block as the bridge source, and
  every `platforms.mattermost.<shared key>` beside it stops reaching `extra`. P46b's "leaving a
  write on its bare spelling is not neutral just because its reader is", one platform over and
  one phase later. Option (b) again: reader onto `sharedPlatformScalar`, pair onto
  `bridgeResolvedKeys` #platforms
- [gotcha] **A PRESENCE field is a second reader and needs the same precedence as the value.**
  `requireMentionIsSet` (P51's own new field) was a flat `values[…] != nil`. Beside a
  bridge-resolved value read it would have fired the `.env` fallback for a key that IS there
  (nested) and not fired for one that is not — the fallback inverted exactly where it matters
  #config-parsing
- [gotcha] **P37 finding 5's mirror image survived the commit that fixed it.** `c93c2287`
  moved `NtfySetupViewModel`'s early `guard let cfg` below the `.env` reads and left the
  identical guard in `MattermostSetupViewModel`, two view models over in the same diff. The
  sibling walk (round-5 lesson 3) applies to a diff's OWN files, not only to `case` arms
- [gotcha] **A test that re-implements the rule cannot fail when the code drifts.**
  `HermesP51Tests.afterAdding` was a private copy of decision 16's rule under a comment calling
  itself "the function the view now uses"; `AgentTab.addNew` kept its inline filter. Two green
  tests and the only real signal was a `caseInsensitiveCompare` grep — a pin on one SPELLING of
  the bug. Extracted to `HermesReasoningEffort.overridesAfterAdding`; the comment was the tell,
  and a comment that asserts an extraction is worth checking against the call site #testing
- [gotcha] **"One door" claims decay by one caller.** `commitSave`'s comment said all fifteen
  forms share it; `GatewayBehaviorViewModel` calls `PlatformSetupHelpers.saveForm` directly
  (two-step save, not a `PlatformSetupForm`). Benign — it sends booleans — but the claim was
  load-bearing for the control-character guard's scope. Corrected, and a source test now pins
  the count of direct `saveForm` callers at one, named, so the next caller argues for itself
- [decision] **Finding 7 disagreed with: `setReasoningOverrides`'s `.whitespaces` trim stays
  WIDE.** Decision 14 narrowed a PARSER, because PyYAML keeps `Zs` as scalar content. This is a
  writer-side cleanup of a user-typed field and Hermes compares an override key EXACTLY
  (`variant in overrides`, `hermes_constants.py:929-941` @ `v2026.9.7`), so an untrimmed
  trailing U+00A0 would be written quoted and match no model ever. Narrowing would CREATE dead
  overrides. "Exact" in decision 16 is about case, not whitespace. Recorded on the site, pinned
  by three tests, and excluded explicitly in `t-295ef4d2`
- [gotcha] **A lesson-5 sweep is only as good as its grep scope.** P51's `.whitespaces` sweep
  named `GatewayConfigWriter` and `ProfileRoutesYAML` and missed `HermesBotProfileYAML` (20
  sites), `HermesBotPeersYAML` (2) and `SkillFrontmatterParser` (1) — and the memory note
  claimed completeness. `t-295ef4d2` is extended to all five with line numbers; the bot-profile
  one is deliberately NOT swept, because that file is a surgical WRITER of `profile.yaml` and a
  changed trim moves what the writer takes as the key/value span, not just what a reader reports
- [convention] **A phased branch's commit MESSAGES drift from its commit CONTENTS, and history
  is not the place to fix it.** `c93c2287`'s message describes the control-character refusal
  that landed in `c838c562`, and the `.xcstrings` rows for `c838c562`'s strings landed in
  `c93c2287` — so `c838c562` alone fails `LocalizationCatalogTests`, the same class as P51's own
  "commit 2 did not build in isolation" note, caught one commit later. The branch is shared;
  attribution is corrected in this section instead. The forward rule is the one P51 already
  wrote: **a commit that names a new helper or a new string must carry it** — and localisable
  strings count as a carried dependency, because `LocalizationCatalogTests` is what makes them
  one #process

**P51b test results.** ScarfCore `swift test`: **3102 tests in 249 suites**, one failure —
`ProcessDrainP43Tests` "backup's zip refuses instead of hanging when it outstays its budget", a
timing assertion (`elapsed < 8`, measured 17.9 s) under full parallel load; **14/14 green in
isolation** and unrelated to this phase's files, the same class as `t-f3820038`. Mac serial by
suite name, non-zero counts: **30 tests in 7 suites, 0 failures** across
`MattermostEnvFallbackSurvivesP51bTests`, `GatewayBehaviourIsTheOnlyDirectSaveFormCallerP51bTests`,
`MattermostRequireMentionSideP51Tests`, `ReasoningOverrideExactDedupeP51Tests`,
`PlatformFormControlCharacterP51Tests`, `HermesP38SourceSweepTests`, `LocalizationCatalogTests`,
`AllConfigWritersParityTests`, `HermesFileServiceConfigParityTests`. `scarf mobile` builds.
**12 new tests in 4 suites** across two `HermesP51bTests.swift` files (ScarfCore 11,
`scarfTests` 2 — one per commit). Both behavioural fixes were watched failing against their
reverted form: 8 issues for the bridge move, 1 for the guard. Both new files are phase-named, so
they are in the P38 sweep's scope by name and no `branchTouchedTestFiles` append was needed.

**Tasks updated.** `t-295ef4d2` extended from two readers to five, with the bot-profile risk and
the `PowerSettingsWriter` exclusion written in.



## Round 5 — memory audit (2026-09-12)

A tier-wide pass over `.memory/` against `fix/whole-surface-audit-r5` at `698bee29` (P47–P51b,
`f093af74`..`698bee29`). `memory_health` went from **56 flagged → 32**; the `codeChanged` bucket,
which is the only one an audit can actually close, went **36 → 12** (high severity 36 → 12;
`conventions/` and `project/` are now CLEAN, `decisions/` and `architecture/` converging). Broken relations: **0 before,
0 after** (the round-4 repairs held). The residue is the 13 `outsideTaxonomy` refiles, 5 honestly
ungrounded notes, 2 deprecated, and 12 drifted notes whose drift PREDATES this branch or whose
subject round 5 never touched — they are left flagged rather than stamped on a claim nobody checked.

**All seventeen round-5 product decisions** were checked against their phase section and the commit
that shipped them; all seventeen agreed as written, and every one already carried its `(P##)`
pointer. **None carried a commit hash** — that is this round's difference from round 4 — so all
seventeen decision lines were annotated, one `find_replace` per line, with the shipping commit(s)
and, where a `b` phase completed or corrected the decision, that commit too: 1–3 `f093af74` +
`1e88ab3e` (3 also `d1c46223`), 4–5 `b34493a5` (5 also `36395fc4`), 6 `4dd7911d`, 7 `3719917d`
(+ `33953111`), 8 `86b49af1`, 9–10 `c718237d`, 11 `55e464f8`, 12 `39b888d1` (+ `94c88e7f`),
13 `55e464f8` (+ `82881859`), 14 `76206b4d`, 15–17 `c838c562` (16 and 17 also `698bee29`).

**Corrected — claims this branch made false.** The sweep ran the named symbols across the whole
tier; most were already correctly tensed by the phases themselves, which is new and is the reason
this round's correction list is short.
- [[A managed Hermes install refuses every config write at exit 0 — one marker, five verbs, one probe]]
  (`scarf/architecture/a-managed-hermes-install-refuses-every-config-write-at-exit`) — the note's
  headline enumeration was FIVE verbs and P47 found a sixth. The prose line now names
  `plugins install --enable` and says the list is a floor, not a total; a new `## Round 5 (P47)`
  section carries the call-PATH lesson, the lock-AND-verdict decision, and the `.disabled`-keeps-
  its-value gotcha. (The title still reads "five verbs" — renaming it would break the permalink;
  the body corrects it in its first paragraph.)
- `scarf/features/model-presets-feature` — its `[gating]` line still read "Single flag
  `hasACPSetSessionModel` (>= v0.13.0). Pre-v0.13 hosts hide …", which P49 made false for all five
  surfaces. Rewritten to UNGATED with the tag evidence, the old floor kept as history. Also gained
  `source_paths` (it had none) — it is still in the refile queue under `features/`.
- `scarf/decisions/hermes-v0.15-capability-gating-decisions` — "under hasACPSetSessionModel (v0.13)"
  re-tensed with a dated P49 annotation.
- `scarf/decisions/hermes-v0-16-compatibility-decisions` — the `[cli]` flag roster listed
  `hasInsightsCommand` and `hasDashboardCommand` as v0.16 flags. Annotated: the first is DELETED
  (its verb is at 0.6.0, below the supported minimum) and the second re-floored **0.16 → 0.9.0**.

Checked and found ALREADY correct at HEAD, correctly tensed by the phase that changed them:
`ProcessPipeDrainer` (the two mentions both read "is DELETED"), `isInSweepScope` /
`branchTouchedTestFiles` / `isPhaseSuite` / `legacySuiteFiles` (the scan note's P48 section already
says the machinery is gone and the sweep is repo-wide), `hasYOLOSlashCommand`, `KanbanWatchFilter`
(only in this note's own P50 section), "edit the schedule" (every mention is historical narrative
about the copy P30 shipped and P50 replaced), `allow_any_attachment` (the v0.15–v0.17 window is
already in `setup-forms-write-the-resolved-default-settings-treats`),
`mattermost.require_mention` (P51b's move is already in
`a-platform-s-shared-keys-are-bridged-from-one-section-so`, including the `[todo]` list it left),
and `AnalyticsFeatureUsageEventsTests` (memory only ever claimed the `-only-testing` nested-suite
trap, which is untouched).

**Distilled into existing notes rather than forked** — three of the four targets already owned
their lesson, written by the phase itself:
- `architecture/judging-a-hermes-verb-by-its-output-the-exit-0-refusal` already carries P47's
  "enumerated by grepping `runHermesCLI(` callers" — no edit needed.
- `architecture/process-waitdraining-lives-in-scarfcore…` already carries the C10 primitives and
  "`Task.detached` is NOT the escape / is the same cooperative pool" — no edit needed.
- `conventions/a-source-scan-test-must-be-calibrated…` already carries the sweep going repo-wide,
  and the `Thread.detachNewThread`-vs-`Task.detached` asymmetry — no edit needed.
- [[Hermes Capability Gating Pattern]] DID need it: **"a tag walk counts CALL SITES, not symbols"**
  was added, with `allow_any_attachment`'s tag-by-tag call count, the load-bearing upper bound
  `atLeastSemver(0,15,0) && !atLeastSemver(0,18,0)`, and the C1 reason it was gated and not retired.

Two more durable facts were folded into the notes that own their subject rather than forked into
new ones: the `trigger_job`-uses-the-BARE-`is_terminal_job` fact (Run Now on a terminal job is a
guaranteed exit 1, so resume and trigger need SEPARATE predicates) into
`architecture/hermes-cron-recovery-is-three-doors-not-one-and-scarf-must`, and decision 12's
downgrade-note seam plus P50b's file-scoped catalogue gate into
`decisions/phase-1-milestone-3-fleet-and-portfolio-dimension-implementation-decisions`.
**No new note was written this round** — every round-5 lesson had an owner.

**Re-confirmed against HEAD** (`review_memory` with `claim: code`, so their drift is cleared
honestly, each after opening the code it anchors to): the managed-install note, `Hermes Capability
Gating Pattern`, `process-waitdraining…`, `a-source-scan-test…`, `hermes-cron-recovery…`,
`a-platform-s-shared-keys…`, `a-yaml-reader-is-opted-in…`, `the-acp-adapter-s-slash-roster…`,
`setup-forms-write-the-resolved-default…`, `ssh-circuit-breaker…`, `unguarded-write-seam…`,
`mac-config-reads…`, `proving-a-read…`, `a-watcher-tick…`, `a-vnode-watch…`,
`hermes-authored-file-fixtures…`, `driving-cron-and-kanban-from-xcuitest…`,
`multi-server-architecture-scarf-2.0`, `hermes-version-targeting-strategy`,
`hermes-version-compatibility-target`, `hermes-v0-21-1-audit-findings`,
`hermes-v0-21-compatibility-decisions`, `phase-1-milestone-3-fleet…`, `model-presets-feature`.

**Nothing was retired.** No note was found superseded — the round-5 changes corrected floors and
primitives that existing notes already described, rather than invalidating a note outright.

- [todo] **Refile queue, still 13 notes, still Alan's call** — UNCHANGED from round 4 and
  re-verified as the same set: `design/` (2 — Scarf Design System, iOS Platform Rules),
  `features/` (4 — Model Presets, Project Dashboards, Project-Scoped Chat, Template Config Schema
  v2), `integration/` (5 — Hermes Integration, ACP image handling, thinking-models reasoning
  column, v0.16 wire verification, v0.18.2 audit findings), `overview/` (1) and `profile/` (1).
  Round 5 moved none of them: mass-refiling is a structural decision, not an audit one. It DID
  fix one of them in place (`features/Model Presets Feature`, above) and gave it `source_paths`
  #memory
- [todo] **Twelve notes stay `codeChanged` deliberately** — their anchors moved in round 5 but
  their subject did not (chat session layer, iOS session resume, Marker rendering, Bot Mode Phase A,
  the v0.18/v0.20/v0.20.4 audit notes, post-v2.24 backfill, section-audit remediation, the UI
  release gate, ScarfGo/App Store). Stamping them `claim: code` without opening their anchors is
  the failure mode this audit exists to prevent, so they are left visible for a round that has the
  budget to read them #memory
- [todo] **The five `needsGrounding` notes are unchanged from round 4** and still honest — they
  describe Hermes-side or workflow facts with no Scarf file to anchor to #memory


## P52 — cross-phase remediation of the round-5 branch (`189b3193`, `06698470`, `96089feb`)

Three commits on `fix/whole-surface-audit-r5`, closing the cross-phase review of P47–P51b.
Counts: ScarfCore `swift test` 3106 tests / 250 suites + 42 / 3 suites, green; Mac serial
`-only-testing` over ten suites, 99 tests, green; `scarf` and `scarf mobile` both build.

### The lessons

- [decision] **`OffPool.run { }` exists because `Task.detached` answers the WRONG question.**
  P22 asked "is this off the main actor?" and `Task.detached` answers yes, so it is the shape a
  phase reaches for — P48 said exactly that, and P51 then created three more instances for work
  that BLOCKS (an SSH `readFile`; `enrichedEnvironment()`, whose `swift_once` initialiser is two
  `zsh` probes at 5 s + 3 s). A detached task is still on the cooperative pool: one thread per
  core, unable to grow. Seven sites routed through the new helper, including
  `PlatformSetupHelpers.detached` (which every setup form's load and save goes through) and
  `HealthViewModel`'s seven-way `async let` batch, **whose own comment claimed `Task.detached`
  was what kept it off the pool** — the misconception was documented in the source as the cure.
  The generalisable form: a rule stated in a decisions note is re-broken every phase; a rule with
  a NAMED HELPER and a sweep is not #c10
- [gotcha] **A `Thread` cannot be cancelled, so the contract is "the result is dropped, never the
  work".** That is not a regression — it is exactly what `Task.detached { … }.value` did, since a
  detached task inherits no cancellation and `Task.value` on a non-throwing task cannot throw one.
  Worth writing down anyway: a caller that reads "off-main" as "cancellable" writes a cleanup that
  never runs #c10
- [gotcha] **A timing bet fails on the grader's load, not on the defect.** The first
  off-pool-concurrency test compared elapsed wall time against a fraction of the serial total; it
  passed under `--filter` and went red in the full parallel `swift test` run purely from machine
  load — in the same run that made `ProcessDrainP43Tests`'s zip-overrun test fail and then pass
  in isolation. Rewritten as a RENDEZVOUS: 32 concurrent calls each announce arrival and block
  until all 32 have arrived, which a fixed-width pool cannot satisfy, with a bounded wait so a
  regression fails instead of hanging. **Prove the property, do not time it** #testing
- [decision] **The stability sweep's premise floor was measuring names, not files.** It counted a
  `Set` of `lastPathComponent` — 335 real `.swift` files across the three roots collapse to 322 —
  against a floor of 300 that the doc justified with "484 test files", a number that was never the
  count of anything measured. A whole root going quiet would have passed. It counts URLs now,
  floor 250, and asserts each root non-empty separately: **a total cannot tell you which root went
  quiet.** Its self-exemption moved from basename to `#filePath` (P49b's shape) #testing
- [convention] **A citation can be derived instead of copied.** `HermesFileService.swift:2468-2484`
  (the `stopGateway` verdict docstring) was pasted onto three sites as the cite for
  `enrichedShellEnv`, which is `:2566-2583` with probes at `:2575` and `:2580`.
  `enrichedShellEnvCitationsAreCurrent` finds the real `runShellProbe(script:` line in the source
  and fails any nearby comment whose range does not bracket it — P26's self-updating-citation idea
  made cheap. It goes red when the file shifts, which is the maintenance it exists to force #conventions
- [decision] **A version WINDOW must own both of its ends.** `hasDiscordAllowAnyAttachment`'s tag
  walk is correct and re-verified (calls at v2026.5.28–v2026.6.19, none from v2026.7.1, getter
  gone at v2026.9.7), but the row was previously UNGATED, so the window removes a control from
  ≤v0.14 hosts as well as v0.18+ ones — and the C1 paragraph argued only the v0.15–v0.17 half.
  Now owned in a sentence: C1 protects a host that HONOURS a setting, and at both ends nothing
  reads the key — `hermes_cli/config_defaults.py:1446-1448` @ v2026.9.7 calls it a
  "DEPRECATED no-op … Kept so existing configs don't error" (blob opened at the tag). The flag
  also joins `HermesCapabilitiesTests`, where a reader goes to learn what a version turns on,
  with a note telling the next phase NOT to copy the v0.15 line into the v0.18+ all-on tests #c1


## P53 — pre-merge remediation of the round-6 NEW findings (`1b0b641e` … `7abbdd45`)

Eight commits on `fix/whole-surface-audit-r5`, closing the nine NEW findings of the round-6
whole-surface audit. Eight fixed; one of the nine was WRONG as written and is recorded as such.
Counts: ScarfCore `swift test` **3125 tests / 252 suites**, green (one run failed with a single
unattributed issue and passed clean on the immediate rerun — the known load flake, `t-f3820038`);
ScarfIOS `swift test` **57 tests / 11 suites**, green; Mac serial over fourteen suites **79 tests**,
green; `scarf` and `scarf mobile` both build.

### The lessons

- [gotcha] **A per-LINE sweep proves nothing about multi-line code, and every real instance is
  multi-line.** P52's `OffPool` sweep required `Task.detached` and a blocking needle on the SAME
  line, so all four detached closures in the tree passed it — the sweep was written against the
  toy form of the defect it had just fixed by hand. It brace-matches the closure now, reusing
  `ProcessAsyncWaitP43cTests.detachedClosureHits`' walker, with a calibration test planting a
  needle several lines in. The same defect recurred twice more in one round:
  `HermesP50bTests`' `kanban watch` alarm required the verb and `--json` on one line (a wrapped
  doc comment defeats it, which is exactly the shape P50b's own bug had), and
  `CitadelExecChannelP48bTests` located a throw by a literal that a second argument re-wrapped.
  **When the thing you are matching spans lines, the matcher has to** #testing
- [fact] **The round-6 report's `HealthViewModel:177` finding is WRONG, and the disproof is the
  brace match it asked for.** That `Task.detached` is a pure ORCHESTRATOR: every one of its seven
  blocking calls already rides its own `OffPool.run`, `loadState()` included. A brace-matching
  sweep flags it anyway, so the needle exemption is per LINE — a needle on a line that also spells
  `OffPool.run` is not a hit, and a body that wraps one of two blocking calls still reports the
  other. **A widened matcher's first job is to not report the thing that was already fixed** #c10
- [decision] **`TestConnectionProbe`'s detached closure STAYS detached.** The report named the
  whole closure; the closure is written to SUSPEND (`Task.sleep` poll, `waitDrainingAsync`), which
  is correct and deliberate, and converting it to `OffPool.run` does not even compile — the
  closure is `async`. Exactly one call in it blocks, `enrichedEnvironment()`, and that one is
  hoisted to an `OffPool.run` before the spawn. **"This closure blocks" and "a call in this
  closure blocks" are different findings with different fixes** #c10
- [gotcha] **A sweep's roots are a claim about scope, and nobody re-reads them.** All three C10
  sweeps omitted `scarf/Packages/ScarfIOS/Sources` — the iOS SSH runtime — so
  `CitadelServerTransport.runSync`'s unbounded `semaphore.wait()` was invisible to every one of
  them for five rounds. P48's lesson ("a sweep that stops at its own module's edge blesses the
  other half of the same codebase by omission") was written about the app target and not applied
  one module further. All three walk it now with PER-ROOT floors (14 files: a shared `> 20` would
  have made the floor the thing that failed), and `MainActorSpawnDisciplineP22Tests` asserts root
  MEMBERSHIP, because deleting a root deletes its floor with it #c10 #testing
- [decision] **The iOS sync bridge is bounded, and the seam is written down rather than papered
  over.** `runSync` blocks the caller's thread on a semaphore while the work runs on a
  `Task.detached`, i.e. the cooperative pool — a caller that is itself on a pool thread competes
  with the work it is waiting for. The wait takes the CALLER's budget plus a named grace now
  (`runProcess` passes `timeout + syncGrace`; the eight SFTP verbs pass `sftpCeiling`, since
  `ServerTransport`'s file verbs carry no budget), with no default on the parameter. The real fix
  is `t-02f830f4` — updated with the iOS half, including the instruction to DELETE these
  assertions rather than satisfy them. On expiry the result is abandoned, not cancelled #c10
- [gotcha] **Two arms of a race must not build two different errors.** The iOS exec's drain caught
  its cancellation and raised `.timeout(partialStdout: stdout)` with everything it had read, while
  the budget arm raised `.timeout(partialStdout: Data())` — and the budget arm is the one that
  WINS a timeout, since `group.next()` returns the first to finish and `cancelAll()` then discards
  the drain's throw. Every iOS timeout reported empty output. A shared `PartialStdout` accumulator,
  which is what `SSHTransport.runLocal:1176` does with `drain.collect()` #c10
- [gotcha] **The exit-0 family had one more member, and P47b's own generalisation named it.**
  P47b said "when a verdict has a `confidence`, grep every consumer for a two-way `if` on
  `succeeded`" and then did not. `CredentialPoolsViewModel.removeOAuthProvider` had exactly that
  `if`, so `HermesAuthLogoutVerdict`'s `.unconfirmed` arm fell into the failure branch and a
  silent exit-0 run rendered **"Remove failed: exit 0"** — the status the verdict had just
  declared meaningless. Three branches now, in a `static` formatter (`removeFailureSummary`), the
  `sessionsOptimizeSummary` shape, with three catalogue rows in six locales #ux
- [decision] **Mattermost's boolean vocabulary is NOT the universal boolish set, and the quotes
  decide.** `adapter.py:504-505` @ `v2026.9.7` reads
  `str(...).lower() not in {"false", "0", "no"}` — three words, no `off`, where slack, discord and
  telegram all carry four. Scarf read the key with two wrong readers: `parseEnvBool` (a four-word
  truthy ALLOWlist, so `off`/`y`/anything-unrecognised read FALSE where Hermes reads true) on the
  `.env` side, and `boolishValue` on the config side, which is right for bare `off` (PyYAML →
  `False` → `"false"`) and wrong for quoted `"OFF"` (a `str`, not one of the three words, so
  TRUE — and `boolishValue` strips the quotes that are the whole difference). Two coercions in
  `HermesYAML` mirroring the real chain (PyYAML resolve → `str()` → three-word compare),
  documented the way `busyAckEnabled` is; the comment calling `busyAckEnabled` the ONE such key is
  corrected to two. A calibration test pins that the two readers must DISAGREE — if they ever
  agree the key is pointless #c5 #hermes-cli
- [gotcha] **A decision that gates the buttons has to gate the SENTENCE above them.** Round-5
  decision 15 keyed Signal's pairing buttons on `remotePairingNotice` and left the prerequisite
  row rendering the LOCAL `detectSignalCLI()`: on a remote window the green "signal-cli is
  available on PATH" is a true sentence about the wrong machine and the orange "install it first"
  is an instruction that would change nothing. The row shows the shared host sentence now, read
  BEFORE the probe — a line beside the verdict would leave the wrong claim on screen #ux
- [gotcha] **A hint that names a remedy is walked like a button — including from inside a MODAL.**
  P50b gave the iOS cron editor's locked-`Enabled` footer the LIST BANNER's sentence, whose two
  arms name "Resume & Run Now" (the row's context menu) and "duplicate it" (the row's swipe, which
  P50b itself added for this reason). The sheet covers that list and has only Cancel and Save, so
  both hints named gestures the reader could not perform. `editorEnabledLockNote` DERIVES the
  reason clause from the banner's own sentence — one rule, two framings — and names the gesture
  that reaches each remedy after dismissal. Round-5 lesson 4, one surface over #ux
- [gotcha] **A guard that pins INDENTATION fails on a refactor and passes on the bug.** P50b's
  Enabled-gate check pinned the toggle, a newline and twenty-four spaces in one literal; its
  call-site check counted `recoveryOffer: ` file-wide, which also matches the `init` parameter and
  the stored property, so `passed >= sites` read 5 against 3 and would have held with every call
  site bare. Tokens matched independently and ordered; arguments counted inside a paren-matched
  `CronEditorView(` #testing
- [gotcha] **A floor written for one sweep does not protect its siblings.**
  `HermesP38SourceSweepTests`' two other sweeps walk the same three roots, both `continue` past an
  unreadable file and a nil enumerator, and had no floor at all. Hoisted to one
  `assertTheSweepRead` — per root AND total, since neither catches the other's failure. The same
  commit made `AnalyticsSeamInjectionP48bTests` recursive (`contentsOfDirectory` reads ONE level,
  so a test in a subdirectory left the sweep) and moved its self-exemption from basename to
  `#filePath`, the P49b/P52 shape #testing
- [gotcha] **A line-keyed allowance is a tripwire on your own edits, and that is a feature.**
  Adding a sweep root shifted `ProcessAsyncWaitP43cTests.swift` by eleven lines and the sleep
  allowance `:603` stopped matching — caught by its own staleness check, in the same run as the
  offence it was allowing. Rebased to `:614` #testing

**Hermes citations re-opened.** `plugins/platforms/mattermost/adapter.py:491-494`, `:504-505` @
`v2026.9.7` (the `_extra_or_env` helper and the three-word falsy set); `plugins/platforms/slack/
adapter.py:3407`, `:3649`, `:5924` @ `v2026.9.7` (the four-word set, for the contrast);
`gateway/platforms/_shared.py:17-30` @ `v2026.9.7` (`get_scoped_secret` — `val if val is not None
else default`, which makes an EMPTY env var a value and therefore true); `hermes_cli/auth.py:2180`,
`:2185`, `:2189` @ `v2026.9.7` (the logout arms).

**Commits.** `1b0b641e` (the off-pool sweep brace-matches), `a0fd3683` (ScarfIOS joins the three
C10 sweeps; the bounded bridge and the partial stdout), `49b10a5e` (the OAuth remove's third
branch), `727d2b17` (mattermost's three-word falsy set), `70b478ab` (the Signal prerequisite row),
`e71a47f5` (the cron editor's lock note), `b09d152f` (five test guards that were not guarding),
`7abbdd45` (the withExec guard brace-matches).

**New test files.** `scarf/scarfTests/HermesP53Tests.swift` (8 tests, 2 suites),
`scarf/Packages/ScarfCore/Tests/ScarfCoreTests/HermesP53Tests.swift` (18 tests, 2 suites — the
"14" this said was a miscount, corrected in P53b, which took it to 21),
`scarf/Packages/ScarfIOS/Tests/ScarfIOSTests/CitadelTransportP53Tests.swift` (6 tests). All are
phase-named, so no `branchTouchedTestFiles` append was needed (that scope list is gone since P48
anyway). Both sweep fixes were watched failing against their reverted form.


### P53b — review remediation (`5dfebff8` … `d0ff84ea`)

Six commits on `fix/whole-surface-audit-r5`, closing seven findings of an independent review of
P53. Six fixed, one (LOW 5) fixed differently from how it was written, and one of its two named
cases DISPROVED. Counts: ScarfCore `swift test` **3128 tests / 252 suites** green; ScarfIOS
`swift test` **58 tests / 11 suites** green; Mac serial over seven suites **41 tests** green;
`scarf mobile` builds.

- [gotcha] **P53's own lesson, one level down: a per-LINE exemption inside a brace-matching
  sweep.** P52's `OffPool` sweep brace-matches the closure, and the exemption that keeps an
  already-pooled needle from being reported was still per line — so the REAL form,
  `await OffPool.run {` with the blocking call on the next line, was reported, and a trailing
  `// OffPool.run` comment exempted a line outright. The exemption brace-matches the region now
  and strips comments first (leaving `://` alone). **When the sweep spans lines, so must
  everything it consults** #testing #c10
- [gotcha] **`editorEnabledLockNote` reverse-engineered the seam between reason and remedy from
  punctuation, and two of the three arms carry an em dash inside their own REASON.** The
  past-deadline one-shot ("Can't resume \"X\" — the one-shot time (…) is in the past …") rendered
  as three words and no reason at all; the terminal one-shot lost the clause after its dash. A
  `ResumeRefusal` struct carries reason, remedy and joiner; the assembled sentences are
  byte-identical, so the banner and the Mac parity tests are untouched. **A second framing of a
  sentence needs the pieces, not a parser** #ux
- [gotcha] **A sweep's roots claim scope, and its floors claim depth — P53 fixed the first and
  left the second.** All three C10 sweeps gained `Packages/ScarfIOS/Sources` in P53; the TEST
  sweeps in `HermesP38SourceSweepTests` never gained `Packages/ScarfIOS/Tests`, and the
  `try! #require` sweep had a SECOND roots list of its own (naming ScarfCore's inner
  `ScarfCoreTests`, missing the package's other test target) with no premise floor at all. One
  list now, with a per-root floor each: a shared total of 250 is carried by the two big roots, so
  a four-file root that stopped enumerating was invisible. `theRootRosterIsComplete` pins roster
  AND floors. The widened walk found one real site (`parts[0]` after a count `#expect` in
  `ScarfIOSSmokeTests`) #testing
- [gotcha] **`Int(_:)` is not PyYAML's `int` resolver, and the difference INVERTS the answer.**
  `0x0` and `0b0` load as the int zero — falsy to mattermost's three-word compare — while
  `Int("0x0")` is nil, so both fell to the string compare and read TRUE; `0_0` and `0x_0` did the
  same via the `_` separators. `pyYAMLIntIsZero` ports the resolver's five alternatives, and only
  its ZERO answer matters (every non-zero integer is true under both readings). **The review's
  `0o0` case is WRONG: PyYAML's octal alternative is `0[0-7_]+`, which admits no `o`, so `0o0`
  stays a string and really is TRUE** — verified against a live PyYAML oracle, which is what the
  new test table is. `0X0`, `0B0` (the pattern is lower-case only) and `08` are the same species
  of near-miss and are all true #c5 #hermes-cli
- [gotcha] **A grep proves the token exists, not which arm it sits in.**
  `theTimeoutArmReadsTheAccumulator` proved the drain's mirror with
  `code.contains("partial.append(bytes)")` — moved into the `.stderr` arm or below the loop, that
  grep still passes and every iOS timeout reports empty output again. The loop is `absorb` now,
  generic over any sequence of exec chunks, and the test STAGES the race: a drain that has read a
  chunk and is still waiting against a budget that wins. It fails when the mirror is removed
  #testing #c10
- [gotcha] **An `#expect` inside an `if` is not an assertion, and a one-sided assertion is half a
  test.** `theNoteNamesNoUnreachableGesture` guarded its check on the note naming a gesture, so a
  note naming none would have passed as if checked; `theSharedNoticeNamesTheHost` asserted only
  that a LOCAL context yields nil, and nothing about the notice naming the host — the entire
  point of the row's change. Both unconditional now #testing



## Round 6 — merge of P47–P53 and what this branch taught (2026-09-12)

Branch `fix/whole-surface-audit-r5` (P47–P53b, 43 code commits) merged to `main` as `d53d3cbe` with `merge(whole-surface-audit-r5)`; not pushed. Round-6 report: `documents/hermes-v0.21.1-whole-surface-audit-round6.md`; follow-ups P54–P58 (`t-daf369c1`, `t-a7eb12e5`, `t-19ba24a5`, `t-b24e5fba`, `t-10161ba1`) with eleven product decisions open for Alan.

- [gotcha] **A lesson stops at its own phase's files.** P48 named `Task.detached` a false escape; P51 reached for it three times and P48's file-local sweep could not see across the file. P49b fixed basename exemptions in the sweep it edited, not the one it had read. "Walk the siblings" must include the MACHINERY a phase inherits — the sweeps, roots and exemptions — not just `case` arms #process
- [gotcha] **A number in a comment is a claim nobody executes.** "484 test files" (335), `HermesFileService.swift:2468-2484` (`:2566-2583`) copied to three sites, "14 tests" (18). Pin counts and citations with a test or re-measure them at review #verification
- [gotcha] **Cite a tag, never a release.** `hasKanban` at 0.12 came from a release note that announced its own revert; the tag has no `kanban.py`. Nine consumers, C5's four-dead-features class #capability-gating
- [gotcha] **A verdict's `.unconfirmed` arm needs every consumer grepped for a two-way `if`.** P47b fixed `sessions optimize`'s and left `auth logout`'s from the same commit #verification
- [gotcha] **C1 is argued on the axis the clause names.** A gate ADDED to a previously ungated surface removes the control on every range outside the window; say which ranges render differently than the last release, in the source #capability-gating
- [gotcha] **iOS writes what the CLI would have validated.** The iOS cron editor's stale `next_run_at` across a schedule change (round-6 HIGH) is the first instance of P50b's rule that every `cron edit` validation must live in the `jobs.json` form #ios
- [convention] **`-only-testing:scarfTests/<File>` matches nothing when the suite name differs from the file**; a filtered command with one bad name silently drops it and prints TEST SUCCEEDED over the rest. Read the suite names, confirm the count #testing
- [fact] Final pass at `d0ff84ea`: ScarfCore 3128/252, Mac `scarfTests` serial 1337/195 (126 s), ScarfIOS 58/11, scripts 20/20; both schemes build. Memory health 56 → 32 after the round-5 audit #testing
- [decision] The eleven product decisions in the round-6 report are open; Alan decides before P54–P58 are scoped #process


## Round-6 product decisions (Alan, 2026-09-13) — binding for P54–P58

Decisions on the eleven product calls in `documents/hermes-v0.21.1-whole-surface-audit-round6.md`. Branch `fix/whole-surface-audit-r6` from `main` at `d53d3cbe`.

1. **`hermes import` gets `--force`; Scarf's restore sheet is the consent** (P54). Judge on `Import complete:` / `Warnings (N files skipped):` / `⚠ Session data replaced by older backup contents:` (`hermes_cli/backup.py:948-959` @ v2026.9.7). No stdin pipe. **Shipped** `018194b7` (the five ScarfCore verdicts) + `acefd89a` (the call sites); corrected in P54b by `a3f4647a` (the seal has three states) and `28ba0cfb` (the catalogue rows), and in P55b by `3696127c` (a green seal on a restart nobody confirmed).
2. **`curator run` with `curator.consolidate` false renders a neutral note beside the success** (P54), the pin/unpin note shape; no `--consolidate` on Run Now. **Shipped** `018194b7` + `acefd89a` (`CuratorService` / `CuratorViewModel`); catalogue rows in P54b `28ba0cfb`.
3. **`/goal` and `/subgoal` mirrors are dropped; the `default:` arm shows the P44 "sent as an ordinary prompt" notice** (P55). Investigated first: `/goal` IS a real Hermes command in the TUI and gateway from v2026.5.7 (`hermes_cli/commands.py:103`; `:113` is that same `CommandDef` at v2026.9.7 — corrected in P55b) and `/subgoal` from v2026.5.16, but the ACP adapter's `_COMMANDS` (`acp_adapter/commands.py:44-66` @ v2026.9.7) has never carried either at ANY tag and unknown commands fall through to the model (`:94-95`). Scarf chats over ACP, so on every host the text is a plain prompt. File a task to gate a real door if a future tag adds them to the ACP table. `maybeTriggerKanbanOnboarding()` moves with the winner; `TODO(WS-2-Q7)` resolved. **Shipped** `a275f59a`; corrected in P55b by `e6cfe38d` (the `:113`→`:103` citation and the word-boundary mirror sweep), `9d2c151e` (the notice's catalogue row + six translations) and `475dec73` (the three catalogue rows for the pill that no longer exists).
4. **`off` stays in `disableAliases`; doc line only** (P55). The surface is Settings → Agent (Mac + iOS); users disable reasoning with the picker's `none` row. Quoted `"off"` arises only from a hand-edited config and the writer canonicalises it to `none` on the next save. Edge case, not fixed. **Shipped** `ac135138` (doc line only, `PowerSettingsWriter`).
5. **`hasGatewayAllowlists` keeps the v0.13 floor; the one-release hide of Discord `allowed_channels` / Telegram `allowed_chats` on 0.12 hosts is stated in the flag doc with the tag walk** (P55). No per-platform flags. **Shipped** `ac135138` (three floors re-walked at the tag); the flag doc's citations corrected in P55b `e6cfe38d`.
6. **Kanban Review column gets both transitions** (P56): `review → done` via `kanban complete`, `review → upNext` via `kanban reopen-review`; older hosts keep the honest refusal. The decision as written named `hasKanbanV015`; P56's tag walk found `complete_task` accepts `review` only from v2026.8.13 (0.20.1) and `reopen-review` lands at the same tag, so the gate is the new `hasKanbanReviewExits = isV0201OrLater`. A decision that names a flag is still a floor claim and gets walked (lesson 11). **Shipped** `e4e25ccb` (both transitions + the new flag at `HermesCapabilities.swift:1448`, `public var hasKanbanReviewExits: Bool { isV0201OrLater }`) and `058ea28c` (the refusal copy for a transition no version fixes); corrected in P56b by `6a641ee8` (the v0.20.4 MARK group's five enumerating tests now name it).
7. **Fleet copy forwards `--repeat` from `job.repeatSpec.times`** (P56). **Shipped** `e3eeaca7` (`HermesCronJob` + `FleetApplyPlan`, `FleetCronCopyP56Tests`).
8. **Fleet copy drops the model pin with a downgrade note at both seams** (P56), the P50 `pre_run_script` shape (`hasModelPin`, caveat, `modelPinDowngrades` counter + catalogue row). **Shipped** `e3eeaca7` (both seams: `FleetApplyExecutor` + `FleetApplyViewModel`, `FleetModelPinNoteP56Tests`).
9. **Drag-to-Running shows a confirm sheet** (P56) naming that a board-wide `kanban dispatch` pass runs and may pick a different task, before running it. **Shipped** `9c882c65` (`KanbanBoardViewModel` + `KanbanBoardView`, catalogue rows, `KanbanDispatchConfirmP56Tests`).
10. **The four streaming spawns port ACP's `DispatchSourceRead` line reader** (P58); no parked thread per stream. **Shipped** `d0d4031c` (the `PipeReader` port); corrected in P58b by `081f4437` (the blank-line semantics inherited from ACP), `1e4c75b4` (one `proc.run()` rationale on all four spawns) and `720dbdc2` (the close watchdog's `terminate()`), and by `d0cf0b4e` (the trailing-line drop was an accident, not a decision).
11. **The iOS `runProcess` seam goes async now via `asyncRunProcess`** (P58); the Mac half stays on t-02f830f4. **Shipped** `769b6c98` (`ServerTransport.asyncRunProcess` + the six iOS view models, `AsyncRunProcessSeamP58Tests`); corrected by the fresh-eyes pass `b26c0a1f` (an async start has a second click the synchronous one could not) and by `881bcaa9` (iOS does not stream, whatever the comment said).

## Whole-surface remediation — P54 (CLI verdict residue r6, `t-daf369c1`, superseding `t-4edfd804`)

Commits `018194b7` (the five verdicts, ScarfCore), `acefd89a` (the call sites and the
three-state rendering) and `ccb1a8a4` (the iOS `COLUMNS`) on `fix/whole-surface-audit-r6`.
Round-6 decisions 1 and 2.

### What was actually broken

- **HIGH, and worse than "mis-judged": `hermes import` never worked from Scarf.** Not a
  wrong verdict — an unreachable verb. `run_import` gates on
  `not args.force and not _confirm_import_overwrite(...)` (`hermes_cli/backup.py:942` @
  `v2026.9.7`), and that confirm returns `True` only into an EMPTY home; on any real one it
  calls a bare `input()` (`:836`) on the closed stdin the GUI child inherits → `EOFError` →
  `Aborted.` → `sys.exit(1)` (`:837-839`). **Every** restore into a live Hermes home failed,
  with a bare "Restore failed" and no hint that a prompt nobody could answer was the cause.
  Decision 1: pass `--force` (`subcommands/import_cmd.py:16-17`, present at all four tags),
  Scarf's restore sheet is the consent, and **no stdin pipe** — writing `y` would be Scarf
  consenting on the user's behalf.
- `backup`: `Backup incomplete: {path}` + `Warnings (N skipped):` (`:666`, `:679`) and
  `No files to back up.` (`:633`) all rendered "Backup saved" — and `extractZipPath` matches
  the incomplete line's path, so a partial archive was revealed in Finder under it.
- `webhook remove|test`: three exit-0 arms each. `webhook` is `_forward_command`ed without
  `forward_return`, and the disabled-platform gate (`webhook.py:99-101`) returns before the
  handler ever dispatches.
- `debug share`: `(failed to upload: …)` prints AFTER the success block at exit 0
  (`debug.py:494`), so two of three pastes read as three.
- `curator run`: decision 2's prune-only note. `migrate xai --apply`: two exit-0 arms folded
  into one sentence by a `contains("no changes")` test, telling the user "nothing to migrate"
  on the arm that means "references found, rewrite did not land".

### The lessons

- [gotcha] **When a verb's failure rate is 100%, suspect a PROMPT before suspecting the
  input.** The import bug survived five audit rounds because "Restore failed" is a plausible
  thing to see once. The tell is structural: a CLI that offers `--force`/`--yes` offers it
  because its default path blocks on a TTY, and a GUI child never has one #hermes-cli
- [invariant] **`.unconfirmed` is gated on the confidence ALONE, never on `detail` being
  empty.** `judge` fills `detail` with `lines.last` on every arm, so
  `confidence == .unconfirmed && detail.isEmpty` falls through to the failure voice and
  renders "Backup failed: Scanning ~/.hermes ..." — a progress line presented as Hermes's
  reason for a refusal it never made. **Five** helpers shipped this in P54's first draft and
  every one passed its own three-branch test, because every unconfirmed fixture in the suite
  was the EMPTY string. A three-state suite needs an unconfirmed case WITH output; there is
  one per verdict now #verification
- [gotcha] **Read the library call, not just the `print`.** The first draft built a rationale
  and a fixture on `hermes webhook test` printing `Response (500)`. It cannot:
  `urllib.request`'s default opener installs `HTTPErrorProcessor`, which raises for any code
  outside `200..<300`, so a rejecting gateway takes the `except Exception` arm and prints
  `Error: HTTP Error 500: …` — plus an `Is the gateway running?` hint that is wrong, since it
  plainly is. A fabricated fixture in an enum whose header promises verbatim transcription is
  worse than no fixture #verification
- [gotcha] **`--` is NOT safe on a verb with two list-valued parsers, and the report was
  wrong to list one.** `kanban archive` carries both `task_ids` (`nargs="*"`) and
  `--rm`/`purge_ids` (`nargs="+"`) — `kanban_parser.py:335-338` — so `archive --rm -- a b`
  hands the ids to the POSITIONAL and leaves the destructive flag empty: exit 2, or a silent
  ARCHIVE where the user asked for a permanent delete. The absence is pinned by a test that
  anchors on the function's last statement rather than a fixed character window. P47's rule
  ("safe wherever the parser is a plain positional") is intact — this parser is not one
  #hermes-cli
- [convention] **A success may carry a `detail`, but only where the emitter's line IS the
  result**, and the struct's doc names every exception. Two: `webhook test`'s
  `Response ({status}): {body}` and `backup`'s `Backup incomplete: {path}` #conventions
- [gotcha] **A number in a comment is a claim nobody executes — twice this phase.** The iOS
  `COLUMNS` rationale said the memory-reset marker "is 74 characters and wraps at 80"; it is
  66. `SettingsViewModel.extractZipPath`'s doc said Hermes prints `Backup saved to …`, which
  no tag walked has ever printed. The first was caught only because the test re-measured it
  #verification

### Corrections to the round-6 report and to `t-4edfd804`

- `curator pin/unpin` were **not** already `--`-separated; neither were `restore`/`archive`.
  All four take the shared `_SKILL` positional (`curator.py:595`) and all four have it now.
- `kanban purge` must NOT take a separator (above).
- `kanban specify|decompose` has no Scarf caller; `migrate xai` is output-judged, so its
  finding was copy only — confirmed, and the copy was still wrong on one arm.

### C1

Every marker opened at `v2026.6.19`, `v2026.7.30`, `v2026.8.19`, `v2026.9.7`. Two ranges
differ and the docs say which: **`v2026.6.19` has no `Backup incomplete:` arm at all**
(`:314` prints the complete line unconditionally), so the incomplete branch can never fire
there and the pane renders exactly as before; and `⚠ Session data replaced by older backup
contents:` is **new at `v2026.9.7`**, so the shrink note never fires on an older host. Both
additive. `--force` is on the `import` parser at all four tags, so the HIGH fix is safe on
every host in range and improves every one of them.

**Test results.** ScarfCore `swift test`: **3165 tests in 259 suites** (a `main` worktree at
`d53d3cbe` runs 3128 in 252), one clean full run; later full runs showed
`ProcessDrainP43Tests`' `elapsed < 8` and `OffPoolP52Tests`' `allArrived` flaking under load —
**both reproduced on that `main` worktree** (3 of 5 full runs there), so they are pre-existing
load flakes, not this phase's, and both pass in isolation on both branches (`t-46f089cf`). ScarfIOS
`swift test`: **60 tests in 12 suites**. Mac full serial `-only-testing:scarfTests`:
**1374 tests in 200 suites, 0 failures**, 136 s — run twice, green both times (the first at
1368/199, before the fresh-eyes suite was added). `scarf` Debug and `scarf mobile` both build
clean with no new warnings.

**76 new tests in 13 suites** across three phase-named files: ScarfCore 37 in 7,
`scarfTests` 37 in 5, ScarfIOS 2 in 1. Eleven of the `scarfTests` ones are the fresh-eyes
remediation, and the `.unconfirmed`-with-output suite was watched failing against the
reverted guard before it was kept.


### P54b — remediation of the P54 adversarial review

Commits `218ddf38` (the four citations, the orphaned `///` block, and C1 below the
walked window), `a3f4647a` (the three-state seal) and `28ba0cfb` (the catalogue rows,
`profile rename --`, and the iOS width test) on `fix/whole-surface-audit-r6`.

**P58's inheritance from P54 (item 8, not widened here).** P54 edited six
`Task.detached { … fileService.runHermesCLI(…) }` sites, all of which are blocking
process waits that round-6 lesson 15 says belong in `OffPool.run { }`, and all of which
P58 owns: `SettingsViewModel.runBackup()` and `runRestore(fromPath:)`,
`WebhooksViewModel.test(_:)` and its private `runAndReload(_:success:judge:verb:)`,
`ProfilesViewModel`'s private `runAndReload(_:success:)`, and
`HealthViewModel.runDebugShare(local:)`.

**What was actually wrong.**

- **MED — thirty-four `String(localized:)` keys, zero catalogue rows.** The wrap makes a
  literal extractable; the row makes it translated, and Xcode only extracts when someone
  opens the catalogue in the app target. Thirteen keys collided with rows earlier phases
  had already added, so **twenty-two** were missing, not ~35 — every "printed no result.
  Check the host." arm among them. Added with six locales each (de/es/fr/ja/pt-BR/zh-Hans),
  and `BannerCatalogueP54bTests` now asserts membership AND translation against the decoded
  catalogue, with a planted needle and a floor.
- **LOW-MED — four wrong `file:line`s** in the ScarfCore fixture headers: the backup scan
  lines are `:627`/`:640` (not `:625`/`:641`, which are `scan_started = …` and
  `errors = []`); `_import_members`' first `errors.append` is `:889` (not `:895`, which is
  `before = _count_session_rows(target)`); `curator.py`'s auto counters are `:172-176`, and
  `:177-180` is the background/dry-run pair that does not fire on that arm.
- **LOW-MED — the iOS `COLUMNS` fix had no test**; a source scan pins the ordering and that
  the width comes from `LocalTransport.wideColumns` rather than an inlined number.
- **LOW — `profile rename` was the fourth un-separated positional.** Two plain positionals,
  `old_name` (`hermes_cli/subcommands/profile.py:77` @ `v2026.9.7`) and `new_name` (`:79`)
  — the report's `:77-78` was off by one on the second — with no list-valued option behind
  them, so P47's rule applies and P54 edited that exact line without adding `--`.
- **LOW — the seal was two-state while the text was three.** `runBackup`/`runRestore` routed
  `.unconfirmed` through `showSaveFailure`/`.failure` and `WebhooksViewModel` set
  `messageIsError = !outcome.succeeded`, so "printed no result" arrived under the red
  triangle and was announced "Failed: …". `OutcomeMessage` carries a `Kind` now and
  `OutcomeMessageBar` takes `kind:` with **no default** (lesson 10) across all 24 call
  sites; the neutral arm is `questionmark.circle.fill` in `ScarfColor.warning`, the
  spelling `MCPServerTestResultView` already used for the same verdict.
- **LOW — an orphaned `///` block** in `CuratorService` between `resume()` and `pin(_:)`;
  a doc comment attached to no declaration is swallowed rather than shown, so it is a
  `// MARK:` block now.
- **LOW — C1 for the ADDED gates below the walked window.** Opened at the oldest tag in the
  repo, `v2026.3.30` (v0.6.0): `hermes_cli/backup.py` and `hermes_cli/debug.py` **do not
  exist** (both arrive at `v2026.4.13`) and `main.py` carries no `backup`, `import` or
  `debug` parser, so all three verbs are unknown there, route to the agent at exit 0 (C5),
  and land on `.unconfirmed` — where before P54 the same host read "Backup saved" /
  "Restore complete" / "Upload complete" over work that never happened. `webhook.py`, by
  contrast, exists at `v2026.3.30` with every judged marker already in place (`:84`, `:211`,
  `:217`, `:226`, `:257`, `:260`).

**The lessons.**

- [gotcha] **`String(localized:)` is the extraction hook, not the translation.** A wrapped
  key with no catalogue row ships English on every locale, silently, and the call-site test
  that proves the wrap passes the whole time — P54's did, and its doc comment said the wrap
  was what made the string translated. Pair every localization sweep with a test that
  decodes `Localizable.xcstrings` and asserts the row #verification
- [gotcha] **A line-number allowance is calibrated, so an unrelated one-line insert breaks
  it.** Adding one stored property to `GwF4OutcomeMessageChannelTests`' probe moved both of
  its `allowedFixedSleeps` entries by one and the P38 sweep failed — which is the sweep
  working as designed, and the reason it re-measures rather than trusting the comment #verification
- [convention] **When a verdict gains a third state, the SEAL is a consumer too.** Lesson 12
  ("grep every consumer for a two-way `if`") was read as a search over text formatters; the
  colour, the glyph and the VoiceOver prefix are consumers of the same verdict and P54 left
  all three two-state. Grep the rendering, not only the prose #conventions
- [gotcha] **A `///` block that precedes a blank line precedes nothing.** DocC attaches a
  doc comment to the next declaration only when nothing separates them; a group header
  between two declarations must be `//` or `// MARK:` #conventions

**Test results.** ScarfCore `swift test`: **3165 tests in 259 suites**, clean, and
`--filter P54` **37 in 7**. Mac full serial `-only-testing:scarfTests`: **1385 tests in 203
suites, 0 failures**, 125 s (1374/200 before this phase: **11 new tests in 3 new suites**).
The eight P54/P54b suites filtered together executed **48 tests in 8 suites**. `scarf` Debug
builds clean with no new warnings; no iOS source was touched, so `scarf mobile` was not
rebuilt. Both new-fix tests were watched failing first: the catalogue suite against the
pre-fix `Localizable.xcstrings`, and `everyProfilePositionalCarriesTheSeparator` against the
un-separated `rename` line.


## Whole-surface remediation — P55 (capability floors r6 + the `/goal` mirrors, `t-a7eb12e5`)

Two commits on `fix/whole-surface-audit-r6`: `ac135138` (the three re-floored flags and
the three doc-only decisions) and `a275f59a` (round-6 decision 3 — the `/goal` and
`/subgoal` mirrors, Mac + iOS). Round-6 decisions 3, 4 and 5.

### The tag walk (every blob OPENED, C2)

- **`hasKanban` 0.12 → 0.13.** `git ls-tree v2026.4.30 hermes_cli/kanban.py` lists
  nothing, and `kanban` appears **zero** times in `hermes_cli/commands.py` and zero in
  `hermes_cli/main.py` at that tag (`pyproject.toml` = **0.12.0**). At **v2026.5.7**
  (0.13.0): the module exists, `CommandDef("kanban", "Multi-profile collaboration board
  …")` is `commands.py:163`, `cmd_kanban` is `main.py:5278`, the parser is built at
  `main.py:9232-9237`.
- **`hasMCPIdentityHeader` 0.20.4 → 0.20.1.** `tools/mcp_tool.py` at **v2026.8.3**
  (0.20.0) has `identity_header` ×0, `strict_redirect_headers` ×0, no `cwd=config.get("cwd")`.
  At **v2026.8.13** (0.20.1) all three: `:40` (module header), `_resolve_identity_header`
  `:1335`, `_apply_identity_header` `:1389`, `strict_redirect_headers` `:3035`, stdio
  `cwd=config.get("cwd")` `:2705`.
- **`hasBotChatCreationCLI` 0.21 → 0.20.5.** `--query-file` absent from
  `hermes_cli/_parser.py` at **v2026.8.18** (0.20.4); at **v2026.8.19** (0.20.5) the chat
  parser's mutually-exclusive query group is `:303-316` (**P55b correction**; `:302-314` was
  off by one at both ends) with both members anchored on their `add_argument(` line —
  `-q`/`--query` `:304` and `--query-file` `:307`. Every other flag of the create argv at
  that same tag: `--in` `:401`, `--continue`/`-c` `:411-412`, `--create-if-missing` `:421`,
  `-Q`/`--quiet` `:379-380`. **`--profile`/`-p` is not a parser argument**: `:20-23` is the
  `PRE_ARGPARSE_INHERITED_FLAGS` relaunch table, and `:16-19` says in so many words that
  `main._apply_profile_override` consumes the flag before argparse runs.
- **`hasHermesAudit` — floor CONFIRMED, doc wrong.** `hermes_cli/security_audit.py` absent at
  **v2026.5.16** (0.14.0), present at **v2026.5.28** (0.15.0). The verb is
  `hermes security audit`: `dest="security_command"` `main.py:12358`, the `"audit"` sub-parser
  `:12363`, `cmd_security` `:6218-6225` — all @ v2026.5.28. The v2026.5.28 and v2026.5.29
  blobs of `security_audit.py` are the SAME blob (`82d414e0`), so `HealthViewModel`'s
  "byte-identical back to v2026.5.29" is true of the floor tag too, and now says so.
- **`hasGatewayAllowlists` — floor kept, cost measured.** `gateway/config.py` at
  **v2026.4.30** (0.12.0) reads exactly ONE allowlist: Discord `allowed_channels`
  `:770-771`. Telegram there has only `group_allowed_chats` `:828-832`. At **v2026.5.7**:
  Slack `:812-813`, Discord `:839-840`, Telegram `allowed_chats` `:902-903`, DingTalk
  `:991-992`, Mattermost `:1013-1014`, Matrix `allowed_rooms` `:1030-1031`.
- **`off` in `disableAliases`.** `parse_reasoning_effort`'s set is `{"none","false","disabled"}`
  at **v2026.7.7** (`hermes_constants.py:816`) and **v2026.9.7** (`:885`) — `off` in neither,
  nor in `VALID_REASONING_EFFORTS`.
- **`/goal` and `/subgoal`.** Real TUI/gateway commands (`hermes_cli/commands.py:103` @
  v2026.5.7 — **P55b correction**: `:113` is that `CommandDef`'s line at v2026.9.7, not at
  the floor tag; `/subgoal` from v2026.5.16) and on the ACP table at **no tag**:
  `_SLASH_COMMANDS` `acp_adapter/server.py:163-173` @ v2026.5.7 and
  `SlashCommandsMixin._COMMANDS` `acp_adapter/commands.py:44-66` @ v2026.9.7 carry nine
  names each — **not the same nine** (`compact` became `compress`), but neither has ever
  carried `goal` or `subgoal`, which is the only claim the decision rests on. Unknown
  names fall through at `commands.py:94-95`.

### What was actually broken

- **HIGH — `hasKanban` was a release note, not a floor.** `RELEASE_v0.12.0.md` announces a
  board that the same cycle reverted. On a 0.12 host five consumers lit up — the sidebar
  Kanban entry (`SidebarView.sections:54`), the cockpit Board panel
  (`ProjectCockpitView.visiblePanels:270`), the `hasKanban:` argument passed to
  `AppCoordinator.upgradeProject` from the cockpit (`:248`) and the projects well
  (`SidebarProjectsWell:499`, which gates `ProjectUpgradeService`'s tenant mint), and the iOS
  project Kanban tab (`ProjectDetailView.visibleTabs:70`) — and every `hermes kanban …` argv
  was an unknown verb routed to the agent at exit 0. The board read *empty*, not
  *unsupported*: C5's four-dead-features class, with no error anywhere.
- **MED ×2 — two floors set by a flag nobody walked.** `hasMCPIdentityHeader` hid the MCP
  identity-header section (`MCPServerEditorView.swift:67`) on 0.20.1–0.20.3 hosts that
  honour all three keys. `hasBotChatCreationCLI` showed the unsupported note on
  `BotConversationView.swift:27` for 0.20.5 and 0.20.6 hosts whose parser takes every flag
  of the argv.
- **MED — the `/goal` pill was Scarf inventing state, on every host.** See the decision-3
  section below.
- **LOW — `hasHermesAudit`'s doc named `hermes audit`**, a verb that does not exist and would
  route to the agent (C5). The code always sent `hermes security audit`; only the doc lied.

### Decision 3 — the mirrors are gone

Deleted: `RichChatViewModel.activeGoal` / `activeSubgoals` / `recordActiveGoal` /
`recordSubgoal{Added,Removed,Cleared}` / `parseGoalArgument` / `parseSubgoalArgument` /
`truncatedToastGoal` and both argument enums; the `HermesActiveGoal` model; the
`SessionInfoBar` pill with `truncatedGoal`, `goalTooltip` and `onClearGoal` (and its
`ChatTranscriptPane` wiring, whose `onClearGoal` sent a `/goal --clear` that was itself an
ordinary prompt); the iOS `goalChip`, `supportsActiveGoal` and the `hasGoal` strand of
`projectContextBar`; both `case` arms on Mac and iOS. `TODO(WS-2-Q7)` and `TODO(WS-2-Q1)`
are resolved by deletion — the question each asked ("confirm the wire shape on a real v0.13
host") has no answer on any host.

Added: `RichChatViewModel.acpUnhandledSlashNotice(name:)` over
`acpUnhandledSlashNames = ["goal", "subgoal"]`, **capability-free** — there is no host
version on which the adapter answers these names, so a gate would be a second way of
writing `true`. It fires from the `default:` arm beside P44's `subFloorSlashNotice`, and
the turn keeps the ordinary working indicator (`/goal` was never in
`nonInterruptiveCommands`, so that half was already right).

`maybeTriggerKanbanOnboarding()` moved into the `default:` arm with the winner, behind
`ChatViewModel.goalArgumentDescribesATarget(_:)` — the one surviving reader of a `/goal`
argument, and it decides only whether to raise the teaching sheet, never what Scarf sends.
`ChatKanbanOnboardingSheet`'s doc no longer claims `recordActiveGoal` has already landed.

**C1.** These removals are ungated and apply on every host, which is the point: the ACP
answer is identical at every tag, so there is no version range where the pill was correct.
What each range renders differently than the last release: **every** range loses the pill,
the `+N` subgoal badge, the "Goal locked" / "Subgoal added" toasts and the iOS goal chip,
and gains a one-line notice plus the working indicator. That is a correction, not a
capability change — C1 protects a pre-target host from a surface that needs a newer Hermes,
not a client mirror no Hermes ever fed.

### The lessons

- [gotcha] **A doc that cites a RELEASE is a doc nobody walked, and a release note can
  announce a feature its own cycle reverted.** `hasKanban` at 0.12 cost five consumers and a
  whole verb family on one release; the v0.12 TAG has no `kanban.py` at all #capability-gating
- [gotcha] **Half a per-flag verification is still an un-walked floor.**
  `hasBotChatCreationCLI`'s doc cited five flags at the bracket tag and guessed the sixth —
  and the floor is set by exactly the flag that arrives LAST, so the one un-walked line was
  the only one that mattered #verification
- [gotcha] **"It is a real Hermes command" is the wrong question; "is it on the surface
  Scarf speaks to" is the right one.** `/goal` survived five audit rounds because every check
  confirmed the verb exists (it does, from 0.13) and none asked which roster — ACP's, the
  CLI's, or the gateway's — the consumer reads #acp #verification
- [gotcha] **Dropping an optimistic mirror means finding its READERS, not just its writers.**
  The `case` arm was the writer; the pill, the `+N` badge, the tooltip, the context-menu
  "Clear goal" (which sent another ordinary prompt), the iOS chip, the `projectContextBar`
  visibility strand, an `.animation(value:)` on a now-dead binding, and `reset()`'s two
  clears were the readers. The iOS build caught the last one — `value: hasGoal` compiles
  fine until the `let` above it is gone #conventions
- [convention] **An ACCEPTED gap states its price, measured.** Decision 5's doc line prices
  `hasGatewayAllowlists` by opening `gateway/config.py` at v2026.4.30: the round-6 report
  said two keys were hidden on 0.12 hosts, the tag says one (Discord's; Telegram had only
  `group_allowed_chats` then). Price the gap from the source, not from the finding that
  proposed it #capability-gating
- [gotcha] **A source-scan test for a REMOVAL must exempt comments, or it forbids its own
  tombstone.** The retired-symbol sweep failed on the `SessionInfoBar` comment recording what
  was removed and on `ChatKanbanOnboardingSheet`'s prose. Stripping whole-line comments before
  matching keeps the record legal and still catches a trailing-comment consumer — the planted
  needle proved both #testing

### Disposition

- `hasKanban` → `atLeastSemver(0, 13, 0)`, moved into the v0.13 MARK group with a tombstone
  left in v0.12's. **Fixed.**
- `hasMCPIdentityHeader` → `isV0201OrLater`; the v0.20.4 group header no longer claims it as
  the group's one genuine v0.20.4 floor (no member has one now). **Fixed.**
- `hasBotChatCreationCLI` → `isV0205OrLater`. **Fixed.**
- `/goal` + `/subgoal` mirrors → dropped, notice added, onboarding moved. **Fixed**, and
  `t-e9c464a9` filed to gate a real door if a future tag adds either to `_COMMANDS`.
- `off` in `disableAliases` → kept; the quoted-vs-bare PyYAML gap is one doc paragraph
  (round-6 decision 4). **Deliberately not fixed.**
- `hasGatewayAllowlists` → v0.13 kept; the one-release, one-key hide documented with the walk
  (round-6 decision 5). **Deliberately not fixed.**
- `hasHermesAudit` → doc corrected (verb name + floor tag). **Fixed.** `HealthViewModel`'s
  parser comment now cites the floor tag rather than the tag after it.
- `hasGoals` and `hasSubgoal` → kept, unretired, now consumer-free; both docs state the ACP
  absence with citations. The ~47 un-walked flags stay on `t-54ec6eb3`; nothing widened.

**Test results.** ScarfCore `swift test`: **3173 tests in 262 suites**, one failure —
`ProcessDrainP43Tests`' `elapsed < 8`, the load flake the P54 section already reproduced on a
`main` worktree; it passes in isolation here (`--filter ProcessDrainP43Tests`: **14 in 1**).
`--filter HermesP55`: **22 tests in 3 suites**. Mac serial
`-only-testing:scarfTests/HermesP55GoalArmTests -only-testing:scarfTests/ChatViewModelSendDedupTests
-only-testing:scarfTests/HermesP38SourceSweepTests`: **13 tests in 3 suites**, pass. `scarf`
Debug and `scarf mobile` both build clean.

**27 new tests in 4 suites** (ScarfCore 22 in 3, `scarfTests` 5 in 1); 14 obsolete tests
deleted with the API they exercised. Both fixes watched failing first: the capability
degradation assertions fail on the old floors by construction, and the Mac behavioural suite
was run against a re-planted `case "goal":` arm, where it recorded **5 issues across 3
tests** (the notice mismatch, `Goal locked` present, and `acpStatus` not
`agentWorking`) before the plant was reverted.

### P55b — the catalogue row (`9d2c151e`)

The fresh-eyes pass on `a275f59a` found the P54b trap one commit later: the new
`String(localized:)` key had no `Localizable.xcstrings` row, so
`acpUnhandledSlashNotice` would have shipped English on de/es/fr/ja/pt-BR/zh-Hans while
its call-site test passed. Row added beside P44's sibling key with all six translations,
and `HermesP55CatalogueTests` decodes the catalogue and asserts both — behind a
`strings.count > 1000` floor so a failed decode cannot pass as an empty dictionary.
Mac serial `-only-testing:scarfTests/HermesP55GoalArmTests
-only-testing:scarfTests/HermesP55CatalogueTests
-only-testing:scarfTests/BannerCatalogueP54bTests`: **10 tests in 3 suites**, pass.

- [gotcha] **A phase that adds ONE localized key hits the same trap as a phase that adds
  thirty-four.** P54b's remediation reads like a bulk-sweep lesson; it is not. The row is
  per key, and the only reliable check is a test that decodes the catalogue #verification

**A `-only-testing` filter takes the TYPE name, not the `@Suite` display string.** The first
Mac run named `scarfTests/Hermes P55 — the Mac /goal arm is the default arm` and printed
`8 tests in 2 suites` — the filter silently matched nothing and the run still said TEST
SUCCEEDED over the other two suites. `scarfTests/HermesP55GoalArmTests` is the form that
works; addendum lesson 9's count check is what caught it.


### P55b — remediation of the P55 adversarial review (`e6cfe38d`, `3696127c`, `475dec73`)

Three commits on `fix/whole-surface-audit-r6`, plus one P54b leftover. Every Hermes blob
below was re-opened with `git show <tag>:<path>` and the cited lines read with `awk`.

**1. `commands.py:113` was the v2026.9.7 line pasted onto the v2026.5.7 tag.** At
**v2026.5.7** `CommandDef("goal", …)` is `hermes_cli/commands.py:103` (`:113` there is
`CommandDef("config", …)`); at **v2026.9.7** the `goal` def really is `:113`. Corrected in
`HermesCapabilities.swift` (`hasGoals`), `RichChatViewModel.acpUnhandledSlashNames`, the
`architecture/the-acp-adapter-s-slash-roster…` note, and twice in the P55 section above.

**2. "the same nine names" was false.** Both ACP rosters carry nine, but they are not the
same nine: `_SLASH_COMMANDS` @ v2026.5.7 (`acp_adapter/server.py:163-173`) has **`compact`**
where `_COMMANDS` @ v2026.9.7 (`acp_adapter/commands.py:44-66`) has **`compress`**. The
claim decision 3 actually rests on — neither roster ever carried `goal` or `subgoal` — is
true at both tags and is what the docs now say. Reworded in both source files, the ScarfCore
suite doc, the roster note and the P55 tag walk.

**3. `_parser.py:302-314` was off by one at both ends, and half of it used a second anchor.**
At **v2026.8.19** the chat parser's mutually-exclusive query group is `:303-316`
(`add_mutually_exclusive_group()` at `:303`, close paren `:316`). Both members are now cited
on ONE convention — their `add_argument(` line: `-q`/`--query` `:304`, `--query-file` `:307`
(P55 mixed `:304`, an `add_argument(` line, with `:308`, a first-string line). And
**`--profile`/`-p` `:21-22` was never a parser argument**: `:20-23` is the
`PRE_ARGPARSE_INHERITED_FLAGS` table and `:16-19` states that `main._apply_profile_override`
consumes the flag before argparse runs. Fixed in `hasBotChatCreationCLI`'s doc, the ScarfCore
P55 suite doc, the P55 tag walk, and `decisions/bot-mode-phase-a-decisions` (the third paste
site of the same wrong range).

**4. HIGH — a green seal on a restart nobody confirmed.**
`PlatformsViewModel.restartBanner:259-265` had all three arms and then mapped the
`.unconfirmed` one to `OutcomeMessage.success(...)`: the honest neutral sentence arrived
under the green checkmark and was announced as a completed restart. P54b's bug pointing the
other way — Settings sealed the unknown RED, Platforms sealed it GREEN, and P54b fixed only
the red one. It takes `.unconfirmed(...)` now. Lesson-12 sweep of every
`confidence == .unconfirmed` consumer across `scarf/scarf` and `ScarfCore/ViewModels`: this
was the only site mapping the third arm onto a two-state constructor
(`MCPServersViewModel:524` was already correct; Health/Gateway return plain strings on a
different channel).

**5. MED — the third seal flag was never cleared by the two hand-written in-progress lines.**
`PlatformsViewModel:273` ("Restarting gateway…") and `PluginsViewModel:354` ("Installing
<x>…") set `message` + `messageIsFailure` and left `messageIsUnconfirmed` alone. An
unconfirmed message deliberately never auto-clears, so a prior neutral verdict kept its amber
question mark over the next operation's in-progress line. Both clear all three. Those two are
the only hand-written sites in the app — every other conformer goes through
`applySaveOutcome`.

**6. The mirror sweep did not sweep what the write-up said it swept.** The P55 section claims
`truncatedGoal`, `goalChip`, `supportsActiveGoal`, `hasGoal` and the "Goal locked" literal
went with the pill; the ScarfCore sweep's `retired` list named none of them. All five added —
matched on **word boundaries**, because `hasGoal` is a prefix of the live `hasGoals`
capability flag and a `contains` sweep would have false-positived on
`HermesCapabilities.swift` forever. Calibrated with a planted needle in both directions.

**7. Three orphaned catalogue rows.** P55 deleted the pill and left `Goal locked: %@`,
`Clear goal` and `Goal · %lld` in `scarf/scarf/Localizable.xcstrings` with their six
translations and no `String(localized:)` to extract them (2915 → 2912 keys). Confirmed
unreferenced outside comments and this phase's own tests, removed, and
`HermesP55CatalogueTests` asserts their absence against a still-present key.

**Tests.** ScarfCore `swift test --filter 'HermesP55|P54'`: **59 tests in 10 suites**, pass.
Mac serial by TYPE name (`-only-testing:scarfTests/{ThreeStateSealP54bTests,
BannerCatalogueP54bTests, IOSColumnsPrefixP54bTests, HermesP55GoalArmTests,
HermesP55CatalogueTests}`): **21 tests in 5 suites**, pass. Both new seal tests were proven
to fail on a reverted tree (`banner.kind == .unconfirmed` and the
`messageIsUnconfirmed = false` scan) before the fix was restored.
`xcodebuild -scheme scarf -configuration Debug build`: BUILD SUCCEEDED.

### The lessons (P55b)

- [gotcha] **A `file:line` is pinned to a TAG, and a line number walks between tags.**
  `commands.py:113` is correct — at v2026.9.7. Pasted beside `@ v2026.5.7` it is a citation
  that points at `CommandDef("config")`. When a doc cites one symbol at two tags, open it at
  both; the number is the part that moves #verification #capability-gating
- [gotcha] **"The same nine names" is a claim; "nine names each" is the measurement.** The
  rosters differ (`compact` → `compress`) and the sameness was never what the decision needed.
  A stronger-than-necessary claim is a claim that can be falsified without touching the
  conclusion — state the weakest fact that carries the argument #verification
- [convention] **One anchor convention per citation family.** A group of argparse flags cited
  half on `add_argument(` lines and half on first-string lines reads as five verified facts
  and is really five differently-measured ones. Pick the line the reader can find
  mechanically and use it for every member #conventions
- [gotcha] **A `file:line` in a table is not a `file:line` in the parser.**
  `_parser.py:21-22` is `PRE_ARGPARSE_INHERITED_FLAGS` — a list of flag NAMES — and citing it
  as "`--profile` is present in the parser at this tag" inverts the actual fact, which is that
  the flag is stripped before argparse ever sees it. Read the four lines above a cite #verification
- [gotcha] **Lesson 12's two-way `if` has TWO wrong answers.** P54b found `.unconfirmed`
  folded into the failure arm and fixed it; the identical commit left a sibling folding
  `.unconfirmed` into the SUCCESS arm. Sweeping for "the neutral arm painted red" finds half
  the family — sweep for the neutral arm reaching any two-state constructor #conventions
- [gotcha] **A message channel with three flags has three flags at every writer.** The two
  sites that set `message` by hand predate the third flag and nobody re-walked them when P54b
  added it. A field added to a protocol is a field every hand-written assignment now omits #conventions
- [gotcha] **A sweep list is a claim the write-up makes on the sweep's behalf.** P55's prose
  named five symbols the sweep never looked for. If a write-up says "X is gone everywhere",
  the list that proves it must contain X — and when X is a prefix of something live
  (`hasGoal` / `hasGoals`), `contains` cannot be the matcher #verification
- [gotcha] **Deleting a surface leaves its catalogue rows behind.** `.xcstrings` rows are not
  reachable from the Swift source, so no compiler and no test notices six translations of a
  string nothing renders. The delete checklist for a localized surface ends at the catalogue #conventions


## Whole-surface remediation — P56 (cron/kanban/fleet residue r6, `t-19ba24a5`)

Round-6 decisions 6, 7, 8 and 9, plus the section's two LOWs. Six commits on
`fix/whole-surface-audit-r6`: `d3db068c` (the iOS cron HIGH + lesson 14 + the
catalogue LOW), `e4e25ccb` (the Review column + the `--branch` LOW),
`9c882c65` (the dispatch confirmation + a sweep false positive),
`e3eeaca7` (the two fleet fields), `058ea28c` (fresh-eyes remediation) and
`070688ee` (a task id in a doc comment).

### The floor the decision got wrong

**Round-6 decision 6 named `hasKanbanV015`. The source says v0.20.1, and C2
wins.** Walked by OPENING `hermes_cli/kanban_db.py` at each tag, not grepping
a name: `complete_task`'s UPDATE reads `AND status IN ('running', 'ready',
'blocked')` at `v2026.8.3` (`pyproject.toml` = `0.20.0`) and `('running',
'ready', 'blocked', 'review')` at `v2026.8.13` (`0.20.1`) — and at the v0.15
floor `v2026.5.28` it is the three-status form too, as it is at every tag
below. Gating the Review exits on `hasKanbanV015` would have offered a drag
that `complete_task` returns `False` for on five releases' worth of hosts,
which `_bulk_apply` (`hermes_cli/kanban_output.py:61-69`) turns into
`cannot complete <id> (unknown id or terminal state)` at exit 1: a card that
springs back with a refusal Scarf invited. `reopen-review` lands at the SAME
tag (zero occurrences of `reopen-review`/`reopen_review` under `hermes_cli/`
through `v2026.8.3`, two from `v2026.8.13`), so ONE flag covers both doors:
`hasKanbanReviewExits = isV0201OrLater`.

### What was wrong

*The HIGH — a re-timed iOS cron job kept its old appointment.*
`CronEditorView.buildJob` forwarded `nextRunAt: existing?.nextRunAt` among the
runtime fields an edit must preserve. It is not one of them. The due scan
fires on the STORED instant (`_evaluate_due_job` reads
`job.get("next_run_at")` at `cron/jobs.py:2925` @ `v2026.9.7` and recomputes
only when it is absent), and only ONE kind self-repairs: `_reanchor_stale_cron`
(`:2801-2819`) re-anchors a `cron` instant off its expression's lattice, while
an `interval` fires once early and a `once` is RETIRED unrun by
`_retire_expired_oneshot` (`:2853-2865`). A one-shot moved to next Tuesday was
deleted for missing last Tuesday. The Mac has no twin — it shells `cron edit`,
where `_apply_schedule_update` rewrites the field.

*Lesson 14 — three of eight validations were missing.* `cron edit`'s gates,
enumerated from `cron_edit` (`hermes_cli/cron.py:594-632`) through
`update_job` (`cron/jobs.py:1929-1971`): five already lived in the form
(`_reject_terminal_activation` → `enabledIsLocked`; `job_payload_is_empty` →
the non-blank prompt, strictly stronger; the past-one-shot pair → P50's
`oneShotTimeIsUnusable`; `_IMMUTABLE_JOB_FIELDS` and
`_UPDATE_FIELD_NORMALIZERS` → fields the sheet has no widget for). Three did
not: a blank or malformed cron `expr`, an `interval` with no `minutes`, and an
unreadable one-shot `run_at`.

*Decision 7 — a doc note outlived the code it described.* `cronCreateArgs`'s
comment said `repeat` was "not modeled on `HermesCronJob`". True when written,
false since P38 added `repeatSpec` — and a bounded source job
(`repeat.times = 3`) was fleet-copied UNBOUNDED, running forever on every
target under a green "created".

*Decision 8 — the model pin dropped in silence*, the P50 `pre_run_script`
shape applied to `--model`/`--provider`/`--reasoning-effort`.

*Decision 9 — one card, the whole board.* `hermes kanban dispatch` has no
per-task selector (`hermes_cli/kanban_parser.py:346-353` @ `v2026.9.7`), so
dropping ONE card on Running spawned workers for every assigned `ready` task
in priority order — and could start a different one first.

### What shipped

- `nextRunAt: scheduleMoved ? nil : existing?.nextRunAt`, reusing the flag
  `buildJob` already computes. Clearing hands recomputation to
  `_recover_missing_next_run` (`:2690-2710`), which is what
  `clearingNextRunAt()` already documents for the `setEnabled` fallback.
- `HermesCronJob.scheduleFormRefusal(kind:expression:runAt:carriedIntervalMinutes:)`
  + `CronScheduleFormRefusal`. Shape-only and faithful to `parse_schedule`'s
  own pre-filter (`:755-756`), not a croniter reimplementation.
  `carriedIntervalMinutes` is what the save would WRITE, not what the record
  holds, so a kind switch into `interval` is caught. A minutes field for the
  form is `t-b74c65a4`.
- `hasKanbanReviewExits`, the `.review` source arms, `KanbanService
  .reopenReview` / `reopenReviewArgv`, and `KanbanTransitionStep.reopenReview`.
  `plan(for:caps:)` takes `caps` with NO default (lesson 10).
- `KanbanBoardViewModel.pendingDispatch` + `confirmPendingDispatch()` /
  `cancelPendingDispatch()`, and a `confirmationDialog` naming the board-wide
  pass. `attemptMove` returns before the optimistic mutation too, so a
  cancelled drop needs no rollback.
- `repeatCount: job.repeatSpec.times` in the fleet copier; `hasModelPin` /
  `modelPinFields` + the note at both seams.
- `KanbanCreateRequest.branch` DELETED rather than gated.

### Findings of the walk

- [gotcha] **A decision that names a capability flag is a hypothesis, not a
  citation.** Round-6 decision 6 said `hasKanbanV015` and the real floor is
  v0.20.1 — five releases apart, and the gap is exactly the range where the
  UI would have offered a gesture the host refuses. C2 binds the phase agent
  even when the product decision already named a flag: open the file at the
  floor tag AND the tag before, then gate #capability-gating #verification
- [gotcha] **`next_run_at` is the one runtime field a schedule change
  invalidates, and "preserve every field the editor doesn't own" is what hid
  it.** The rule is right for `last_run_at`, the failure counters and the
  delivery state; applying it uniformly carried a DERIVED field across the
  edit that derived it. When a form forwards a record's machine fields, ask
  which of them the edited fields compute #cron #verification
- [gotcha] **Three validations, one silent shape.** A blank `expr`, a missing
  `minutes` and an unreadable `run_at` all make `compute_next_run` answer nil
  (`:1096-1123`), and the due scan's recovery path cannot arm a record it
  cannot compute — so the job sits in the list saying "scheduled" and never
  fires. Nothing errors, nothing logs where a GUI user would see it. On a
  platform that writes Hermes's own JSON, the form is not a convenience over
  the CLI's validation, it IS the validation (P50b's iOS rule, third
  application) #cron #ios
- [fact] **`--repeat` needs no capability flag, and the walk is the reason
  rather than the assertion.** `cron_create.add_argument("--repeat",
  type=int, …)` is at `hermes_cli/subcommands/cron.py:38` @ `v2026.9.7` and at
  `hermes_cli/main.py:3936` @ `v2026.3.30` (0.6.0, the charter's minimum
  supported Hermes), first appearing at `v2026.3.17` (0.3.0) — below the
  floor. Every supported target renders it identically. `repeat.completed` is
  deliberately not carried: `create_job` stamps `completed: 0` regardless
  (`cron/jobs.py:1779`) #fleet #cli
- [gotcha] **"Not modeled" is a claim with a date on it.** The copier's doc
  said `repeat` was not on `HermesCronJob`; P38 put it there and the comment
  outlived the fact by two rounds, which is exactly how P42's
  "Hermes Kanban has no `project_id` column" survived three releases. A
  NOT-FORWARDED list is a list of claims about other code, and it needs
  re-reading whenever that code grows #verification
- [convention] **An accepted flag is not a copyable field when the value
  names something only the source host resolves.** Third application of P50's
  `--script` rule: `--model`/`--provider`/`--reasoning-effort` would all be
  ACCEPTED at `v2026.9.7` (`subcommands/cron.py:66-77`), and forwarding one
  the target has no provider or credential for lands a green "created" job
  that fails on its first run, days later. Drop it, let
  `_compute_provider_model_snapshots` (`cron/jobs.py:1599-1620`) resolve the
  target's own default, and SAY SO at both seams #fleet
- [gotcha] **A version refusal must be scoped to the transitions the gate is
  about.** This phase's own fresh-eyes review (`058ea28c`): the
  `hasKanbanReviewExits` guard sat above the whole `from == .review` block, so
  `review -> blocked` — refused at every tag, because `block_task` updates
  only `WHERE … AND status IN ('running', 'ready')` (`kanban_db.py:2929`) —
  was told it needed Hermes v0.20.1. Upgrading would not have helped. A gate
  that swallows a neighbouring refusal replaces a true reason with a false
  remedy #capability-gating #ux
- [gotcha] **A confirmation that parks the gesture must park the OPTIMISTIC
  mutation too.** `attemptMove` returns before `optimisticOverrides` is
  written, so a cancelled drop leaves the card where the user picked it up. Had
  the sheet been raised after the override, cancelling would have left a card
  sitting in Running until the next poll disagreed with it #kanban #ux
- [gotcha] **`== nil` on a subscript is proof the subscript is a Dictionary
  read.** `HermesP38SourceSweepTests.noSubscriptFollowsACountExpectation` was
  RED at `475dec73` (reproduced on a worktree at that commit) on
  `strings[key] == nil` — a variable-keyed dictionary read, which the
  string-literal and `?`-chain exemptions did not cover. An Array subscript is
  non-Optional, so `== nil` on one does not compile; the comparison itself is
  the proof. Matcher tightened again rather than the file exempted (P48's
  rule), with a calibration case AND a planted needle #testing
- [gotcha] **Never re-serialize a whole `.xcstrings` to add a row.** The first
  attempt round-tripped the catalogue through `json.dumps` with sorted keys
  and produced a **44,082-line** diff for five new rows — Python's code-point
  sort is not Xcode's collation, and the real change was buried. The commit
  was reset and redone as a textual insert after a named anchor key: 200 lines
  for the same five rows. Key ORDER in that file is cosmetic and Xcode
  rewrites it on its next extraction; the diff is not #testing #process

### C1

`hasKanbanReviewExits` gates a surface that DID NOT EXIST: before P56 every
drag out of Review threw "No CLI path exists for this transition." on every
host. Below the floor the refusal is unchanged in effect and now names the
host version instead of claiming no path exists; above it, two refusals become
two working verbs. No version range renders a control it had in the last
release. `--repeat` takes no gate (present at every supported tag, walked
above). The `--branch` deletion needs no C1 argument either: no production
caller ever set it, so every host renders exactly as before — which is also
why deleting beat gating, against a new flag plus its four-test floor group
guarding a field nothing fills. The iOS schedule refusals are version-free by
construction: they port `parse_schedule`'s shape gate, which iOS bypasses on
EVERY host because it writes `cron/jobs.json` directly.

P59 note: the surface this section gates reaches the CLI through
`confirmPendingDispatch` → `KanbanService.runHermes` → `Task.detached { transport.runProcess }`
(`KanbanService.swift:740-763`), which is a listed pending C10 site — `KanbanService.swift:runProcess(`
in `pendingOffPoolSites`. P59's needle widening did NOT convert it (its own
`await runHermes(…)` call sites are the async seam and are correctly not hits); it stays
on the baseline, owned by `t-406d56d6`.

**Tests.** ScarfCore `swift test`: **3213 tests in 269 suites** (a worktree at
`475dec73` runs **3173 in 262**) — **+40 tests in +7 suites**. The only
failures on either tree were `M4ACPIOSTests`' two `.requestTimeout(method:
"initialize")` cases, which **reproduced on that `475dec73` worktree in the
same run** and pass in isolation (`M1ACPTests|M4ACPIOSTests` → 46/46): the
known ACP parallel-load flake (`t-f3820038` / `t-46f089cf`), not this phase's.
Mac filtered serial over `KanbanDispatchConfirmP56Tests`,
`FleetModelPinNoteP56Tests`, `HermesP38SourceSweepTests`,
`SubscriptAfterCountMatcherP48bTests`, `LocalizationCatalogTests`,
`FleetCronNoteP50Tests`, `FleetApplyExecutorCatalogueP50bTests`,
`CatalogueCoverageP47Tests`, `MainActorSpawnDisciplineP22Tests`: **57 tests in
9 suites, 0 failures**. `scarf` Debug and `scarf mobile` both build clean.

**Nine catalogue keys in six locales.** `FleetApplyExecutorCatalogueP50bTests`
— P50b's file-scoped forward gate — caught the model-pin row's absence before
it was committed, which is the case it was built for.

**Tasks filed.** `t-b74c65a4` (an interval-minutes field for the iOS cron
form, the feature behind this phase's refusal) and `t-b290817d` (a reason
sheet on `review -> upNext`, and a result sheet on `review -> done`).


### P56b — adversarial-review remediation of P56

Three findings, all fixed on `fix/whole-surface-audit-r6`:

- `6a641ee8` — `hasKanbanReviewExits` sits in the `// MARK: v0.20.4` group at an
  `isV0201OrLater` floor. The group is the right home (its header already says
  the MARK is a location, never evidence, and since P55 no member has a v0.20.4
  floor), but the five group-enumerating tests in `HermesCapabilitiesTests.swift`
  never named the new member. Added to all five with 0.20.1-floor polarity: ON at
  0.20.3 / 0.20.4 / 0.20.5 / 0.21.0, OFF at 0.20.0.
- `aa708b9c` — `cron/jobs.py:755-756` @ `v2026.9.7` is the *comment* above the
  cron pre-filter; the code is `:757-758`. The wrong range was pasted at five
  sites (`HermesCronJob.swift:1209, 1248, 1633`; `HermesCronP56Tests.swift:19, 96`).
  All corrected after re-opening the blob; the neighbouring cites in the same
  comments (`:729-730`, `:1112-1114`, `:1122`) re-opened and correct.
- `e7e2d71e` — `KanbanDispatchConfirmP56Tests`'s doc claimed the park test
  observes "the CLI task it spawns". It cannot: `KanbanBoardViewModel.init`
  builds a concrete `KanbanService` with no injection point, so no argv spy is
  available. Reworded to what it does observe (parked `pendingDispatch`, absent
  optimistic override, nil `lastError`) and why the absent override stands in.

**Lesson: a flag's MARK group is a floor claim too.** The group header is read as
evidence whether or not it was meant that way, and — more concretely — every
group-enumerating test is a membership contract. Adding a flag to a MARK group
without adding it to that group's all-on / degradation / patch-still-on tests
leaves the new flag's floor unproven at every boundary the group already guards.
Either the header states the group is a location and each member carries its own
verified tag (the shape here), or the header names a floor every member honours;
either way the enumerating tests must list every member.

Verification: `swift test --filter 'HermesCapabilitiesTests|P56'` → 170 tests in
8 suites passed. `-only-testing:scarfTests/KanbanDispatchConfirmP56Tests` (serial,
isolated DerivedData) → 7 tests in 1 suite passed (7 `@Test`s in the file).
`xcodebuild -scheme scarf -configuration Debug build` → BUILD SUCCEEDED.



## Whole-surface remediation — P57 (YAML reader residue, `t-b24e5fba`)

Three commits on `fix/whole-surface-audit-r6`: `ea83357d` (the folded-scalar continuation hoist),
`a3a6564b` (the boolish trim + int resolver) and `27b17954` (the flat-dotted-key `isBlock`).
Round-6 settings/YAML section, all three items MED/MED/LOW, no product decision needed.

**Attribution correction, P51b's rule applied to P57's own split.** All three findings touch
`HermesYAML.swift`, and `ea83357d` committed that file WHOLE — so it also carries `a3a6564b`'s
`strippedScalar` / `isQuotedScalar` / `pyYAMLIntBoolToken` / `boolishValue` and `27b17954`'s
`ParsedYAML.dottedLiteralPaths`, none of which its message describes. Each commit still builds
and passes its own suite in isolation; only the message-to-diff mapping is off. History is not
rewritten (the branch is shared with other phase agents, and the addendum's own commit rule
exists because of that), so the record is corrected here. **The lesson: splitting by FINDING
when two findings share a file means committing by HUNK, not by path — `git commit -- <file>`
takes the whole file and the message silently over-claims the smaller half.**

### The oracle

A PyYAML **6.0.3** harness under the scratchpad, in the shape earlier phases used: Python emits
adversarial documents through Hermes's own writer options and reports what the loader reads back;
a throwaway ScarfCore test diffs `HermesYAML.parseNestedYAML` / `boolishValue` against it and
writes the disagreements to a file. Hermes's emitter is `atomic_yaml_write` →
`yaml.dump(data, Dumper=IndentDumper, default_flow_style=False, sort_keys=False,
allow_unicode=True)` (`utils.py:262-271` @ `v2026.9.7`) — **no `width=`**, so the folding happens
at the emitter's default 80 columns, which is the whole finding.

| corpus | before | after |
|---|---|---|
| 572 folded `yaml.dump` documents (3 nesting depths × 10 hazard tails × every length that folds) | **44** | **0** |
| 2 065 adversarial bool scalars (33 words × 5 pads × 5 pads × bare/`'`/`"`), `boolishValue` | **1 041** | **0** |
| the same 2 065 through the true-by-default rule | **525** | **0** |
| the maintainer's real 657-line `config.yaml`, 435 leaf keys | — | **0** |

No fourth class of disagreement surfaced, so nothing was filed under "found but not fixed".
The harness stayed in the scratchpad — it is a measurement, not a checked tool; what shipped is
nine verbatim fixtures plus a live-interpreter lane in `HermesP57Tests.swift`.

### The lessons

- [gotcha] **A fold point lands wherever the spaces are, so a continuation line routinely begins
  with `- ` or `#`.** `parseNestedYAML`'s continuation join sat BELOW the comment skip and behind
  `!isListItem`: a `- ` continuation was read as a list item (value truncated at the fold, plus a
  phantom `lists[<enclosing path>]` entry) and a `#` continuation was dropped as a comment — and
  since a `#` is exactly what makes PyYAML SINGLE-quote the scalar, that case also left a
  dangling opening `'`, which `normalizedScalar` then cut a second time at the ` #` it could now
  see. Hoisted above both guards #yaml
- [decision] **The `#` arm of the hoist is narrower than the `- ` arm, and the EMITTER is why.**
  A deeper `#` line can also be a real indented comment, which PyYAML discards. The
  discriminator: PyYAML never emits a PLAIN scalar whose continuation begins with `#` (a `#`
  after a space forces a quoting style), so a folded `#` continuation always sits inside a
  still-OPEN quoted scalar. `HermesYAML.isOpenQuotedScalar` is that test, run on the ACCUMULATED
  value so a multi-line fold keeps working. The `- ` arm needs no narrowing — a genuine list item
  can never sit deeper than the sibling scalar before it, the argument `lastScalarIndent` already
  carried #yaml
- [convention] **Lesson 6, applied to my own comment.** The first draft wrote "0 occurrences,
  verified over the same corpus" into the source. A zero-occurrence claim is cheap to re-measure,
  so it is now a test (`theEmitterNeverFoldsAPlainScalarOntoAHashLine`, which also asserts the
  sweep FOLDED something so it cannot pass on an empty sweep), and the 572/44 provenance counts
  moved out of the comment and into this note #testing
- [gotcha] **A `.strip()` mirror must strip on the same SIDE of the quotes Python does.**
  `_bool_token` is `str(value).strip().lower()` (`gateway/config.py:29-32` @ `v2026.9.7`) over
  the object PyYAML loaded — for a quoted scalar that object is the quoted BODY. `boolishValue`
  and `boolTrueDefault` compared the body verbatim, so `" false"` / `"\tyes\t"` / `" 1"`
  recognised nothing and fell to the caller's default: ON for a true-by-default key whose host
  had it OFF. New `HermesYAML.strippedScalar` = `normalizedScalar` + `.whitespacesAndNewlines`
  INSIDE the quotes. Round-5 decision 14's parser/mirror split is untouched and a test pins the
  two functions disagreeing #config-parsing
- [gotcha] **P53b's int-resolver port only answered ZERO, and the token set has two members.**
  `_bool_token` compares `str(int)`, so `01`, `+1`, `0x1`, `0b1` are the token `"1"` and `00`,
  `-0`, `0x0`, `0b0` are `"0"`. `pyYAMLIntBoolToken` adds the ONE answer to `pyYAMLIntIsZero`,
  unsigned or `+`-signed only (`str(-1)` keeps its sign, so `-1` stays unrecognised), and every
  other integer stays `nil` because `str(2)` is in neither set. Gated on the scalar being BARE —
  a quoted `'01'` is a `str` no resolver touches #config-parsing
- [decision] **`display.busy_ack_enabled` took the trim and NOT the resolver.** Its comparison
  downstream is `os.environ.get(…, "true").lower() != "true"` (`gateway/run_busy.py:727`, bridged at
  `gateway/run.py:1816-1821`), not `_bool_token` — so `1` is `str(1)` == `"1"`, which is not `"true"`,
  and routing it through `boolishValue` would have read an int `1` as ON. The narrower word set
  stays; only the strip moved inside the quotes. Pinned in a test that asserts both halves #config-parsing
- [gotcha] **A flat dotted key faked a platform block, through Scarf's own flat parse.**
  `HermesPlatformSharedKeys.isBlock` matched the `slack.` descendant prefix against
  `values["slack.enabled"]`, so a hand-edited top-level `slack.enabled: true` answered TRUE.
  PyYAML keeps that line as the independent key `"slack.enabled"`; `yaml_cfg.get("slack")` is
  `None` and `platform_section` (`gateway/config_loader.py:171-180` @ `v2026.9.7`) falls through
  to `platforms.slack`. `ParsedYAML` now surfaces `dottedLiteralPaths` (which `parseNestedYAML`
  has tracked since P38 for the last-wins purge) and `isBlock` excludes them AND their
  descendants — `slack.enabled:` opened as a header is `{"slack.enabled": {…}}`, still not a
  `slack` dict #platforms

### The lesson-5 sweep

Every reader comparing a scalar to `true`/`false`/`yes`/`no`/`on`/`off` across `scarf/scarf/`,
`scarf/Packages/ScarfCore/`, `scarf/Packages/ScarfIOS/` and `scarf/Scarf iOS/`.

- **Fixed** (all four on Scarf's write path): `HermesYAML.boolishValue`,
  `HermesConfig+YAML.boolTrueDefault` (now a call, not a copy), `busyAckEnabled`, and the
  `gateway_restart_notification` re-implementation of `boolTrueDefault`'s rule at
  `HermesConfig+YAML.swift:~770`.
- **Filed, appended to `t-295ef4d2`** rather than duplicated:
  `MCPServerEditorViewModel.boolishSSLVerify:116-121` (a `.whitespaces` trim — the `t-295ef4d2`
  shape; its NON-unquoting is deliberate, a quoted `"true"` is a CA-bundle path named `true`) and
  `RichChatViewModel.swift:1299` (trim already correct, no int pass, read-only hint, LOW).
- **Cleared:** `HermesFileService.boolishOptional` (strips after unquote and carries the
  `_parse_boolish` type gate), `HermesManagedInstall.system(fromMarker:)` (a marker file, already
  stripped), `ProfileRoutesYAML` and `Scarf iOS/Settings/SettingEditorSheet.swift:313` (both
  delegate to `boolishValue` and inherited the fix), `HermesFileService:753` and the remaining
  app-target hits (writer-side typed fields, correct per P41b), `HermesServiceTier`,
  `HermesApprovalMode`, `PowerSettingsWriter` (not bool-word compares).

### The fresh-eyes pass on P57's own diff

- **Four of the nine fold fixtures did not exercise the bug.** The first draft picked documents
  by "the string contains `- ` / `#`", not by "the CONTINUATION LINE begins with it" — so four
  folded at a point that left the hazard mid-line and passed against the un-hoisted reader. Caught
  by watching the reverted run: 4 failures out of 8 fixtures. Re-picked from the corpus by the
  property that actually matters; the reverted run now fails 10 times over 9 fixtures. **A drift
  fixture has to be selected by the failing SHAPE, not by the failing INPUT's spelling.**
- **`dottedLiteralPaths` had to exclude descendants, not just the key.** The first cut excluded
  only the dotted path itself, so `slack.enabled:` opened as a block header left
  `slack.enabled.nested` matching the `slack.` prefix and `isBlock` answered TRUE again — the
  same bug one indent down.
- The `lastScalarPath == nil` arm (a deeper line after a flow map/list value) keeps its old
  swallow semantics, and blank lines are still skipped before the continuation test, so the hoist
  changes only the two line shapes it names.

**P57 test results.** ScarfCore `swift test`: **3 231 tests in 272 suites, 2 issues** — both
`M4ACPIOSTests` `.requestTimeout(method: "initialize")` under full parallel load; **2/2 green in
isolation** (`--filter M4ACPIOSTests`), the `ACPClientStartIdempotenceTests` flake family
(`t-f3820038`). **18 new tests in 3 suites**, in THREE ScarfCore files, one
per finding — `HermesP57FoldTests.swift`, `HermesP57BoolTests.swift` and
`HermesP57DottedKeyTests.swift` (P57's own write-up said "all in one
`HermesP57Tests.swift`", a file that does not exist; corrected by P57b):
`HermesP57FoldedContinuationTests` (7 tests / 9 fold fixtures ×2
parameterized lanes), `HermesP57BoolishTests` (6 / 33 scalars ×3 parameterized lanes),
`HermesP57DottedBlockTests` (5). Each fix watched failing against its reverted form: **10 issues**
for the hoist, **25** for the boolish trim + resolver, **3** for `isBlock`. `scarf` builds Debug.
No Mac, iOS or `scripts/` source touched, so no Mac-suite, `scarf mobile` or `unittest` run was
owed beyond the build.


### P57b — the adversarial review of P57

Four commits on `fix/whole-surface-audit-r6`: `ccc21bcc` (the double-quoted body's escapes),
`7e9f2ec2` (`busy_ack_enabled` takes no trim, and quoted `yes` is a string), `172ded54` (the
dotted key's DEPTH), `8dc79784` (a block scalar's body is not YAML). Two of the five findings
were P57's own regressions; three were pre-existing. All five fixed; nothing filed.

Each commit is one finding, and the two that share `HermesYAML.swift` were staged BY HUNK
(`git apply --cached` of a selected subset) rather than by path — P57's own lesson, applied.

#### The oracles

PyYAML **6.0.3**, `yaml.safe_load` / `yaml.dump`, every expected answer printed and pasted into
a Swift table. Each corpus is re-measured by the test that claims it, size included.

| corpus | before | after |
|---|---|---|
| 918 bool scalars (51 spellings × bare/`'`/`"` × every pad each can carry on ONE line), `display.busy_ack_enabled` | **144** | **0** |
| the same 918 through `boolishValue` | **168** | **0** |
| 96 block-scalar documents (6 headers × 16 bodies), `values[<key>]` | **96** | **0** |
| 12 `yaml.dump`-emitted escape fixtures, `boolishValue` | 8 of 10 rows + 4 | **0** |

The "before" columns are Swift-measured by reverting each fix and re-running the same corpus,
not modelled.

#### The lessons

- [gotcha] **A trim is a per-READER claim about the Hermes side, not a reader-wide default.**
  P57 gave `display.busy_ack_enabled` `strippedScalar` because `_bool_token` strips. This key
  never reaches `_bool_token`: `_bridge_section_to_env` exports `str(section[key])` UNSTRIPPED
  (`gateway/run.py:1816-1821` @ `v2026.9.7`) and `gateway/run_busy.py:727` compares `.lower()`
  of that to the literal `"true"`. Quoted `' true'` DISABLES the ack on the host and post-P57
  Scarf drew it ON — and the comment above the reader asserted a strip that does not exist.
  Reverted to no trim; the comment now cites the two lines that show it #config-parsing
- [gotcha] **The three-word list was right only for a BARE scalar, and had been wrong since it
  was written.** `["true","yes","on"]` is correct only because PyYAML's bool resolver turns all
  nine spellings into `True` → `str(True).lower()`. QUOTED, `'yes'` and `'on'` are the strings
  `yes`/`on` and disable. The two arms are now different vocabularies with the QUOTES as the
  whole difference — `mattermostRequireMention(configScalar:)`'s shape, whose `pyYAMLTrue` set
  the reader now shares. The bare arm also compares the LOWERED text for anything the resolver
  leaves a string, so `tRuE` enables and `oN` does not: a row no hand-written word list finds,
  and only a full-cross corpus surfaces #config-parsing
- [gotcha] **A `.strip()` mirror must strip the DECODED string.** `strippedScalar`'s
  double-quoted arm returned the body verbatim, and `yaml.dump({"k": "false\t"})` really emits
  `k: "false\t"` — the escape is *why* the emitter chose double quotes. Eight literal characters
  matched nothing and a true-by-default key read ON. New `HermesYAML.unquotedScalar` runs
  `YAMLScalar.unquote`'s escape table on the quoted arm; `normalizedScalar` stays verbatim
  because its other caller RE-EMITS the value #yaml
- [gotcha] **A dotted key is evidence against a section only when the dot CROSSES that
  section's boundary.** P57 excluded every path under a dotted literal, which also excluded one
  written INSIDE a real block: `slack:` + `  a.b:` + `    c: 1` is `{'slack': {'a.b': {'c': 1}}}`,
  a genuine `slack` dict, and Scarf answered `platforms.slack` for it — P57's own bug, one indent
  down. The path cannot separate the two shapes; only where the dot was WRITTEN can, so
  `ParsedYAML.dottedLiteralParentDepths` records `stack.count` at the line and the exclusion is
  `parentDepth < sectionDepth`. Counting components of the parent STRING would break the moment a
  dotted key is itself opened as a header. The recorded-`maps` test moved under the same
  exclusion: a literal `platforms.slack:` header under `gateway:` records
  `maps["gateway.platforms.slack"]` and claimed the nested section it merely looks like #platforms
- [gotcha] **A `|`/`>` block scalar is not an empty section, and an opted-in key really carries
  one.** The header pushed a stack frame, so the BODY was parsed as YAML — `- ` lines became a
  phantom `lists[<key>]`, `#` lines vanished, and the value was never recorded. Hermes's own docs
  tell users to hand-edit `config.yaml` with `agent:` / `  system_prompt: |` over a `#####` body
  (`optional-skills/security/godmode/SKILL.md:136-148` @ `v2026.9.7`), and
  `HermesPersonalities.parseUserDefined(yaml:)` reads
  `agent.personalities.<name>.system_prompt` — so a block-scalar personality prompt rendered
  EMPTY in Scarf while the host rendered the whole body. `PendingBlockScalar` now claims every
  line deeper than the key verbatim, with PyYAML's clip/strip/keep chomping and `>` folding
  (including the more-indented-line escape hatch) #yaml
- [convention] **A "0 disagreements" claim names the corpus it was measured on, and the test
  re-measures that corpus's SIZE.** P57's note reported 44/572 and 1041/2065 with no way to tell
  a shrunken table from a fixed reader. Each P57b suite asserts its own row count and rejects
  duplicate rows before asserting zero, so the number keeps meaning something #testing
- [convention] **A test that pins the DEFECT's spelling has to become a test of the rule.**
  `ConfigYAMLWriterSafetyTests.chompedAndIndentedBlockScalarHeaders…` asserted
  `values["agent.system_prompt"] == nil` — the block-scalar bug, written down as an expectation.
  What it was protecting (never the folded garbage `"|- role: assistant tone: dry"`, never a lost
  sibling) survives beside the real body and a no-phantom-child check #testing

**P57b test results.** ScarfCore `swift test`: **3 251 tests in 276 suites, 1 issue** — the
`ProcessDrainP43Tests` zip-budget timing test under full parallel load; **14/14 green in
isolation**. **16 new tests in 3 suites**, one ScarfCore file per finding:
`HermesP57bStrippedScalarTests` (4 / 10 oracle rows), `HermesP57bBusyAckCorpusTests`
(4 / 918 rows × 2 readers), `HermesP57bNestedDottedKeyTests` (7 shapes), plus
`HermesP57bBlockScalarTests` (5 / 96 documents). Each fix watched failing against its reverted
form: **12** issues for the escape decode, **10** for the busy-ack revert (144 and 168 corpus
rows), **2** for the depth rule, **96/96** for the block scalar. `scarf` builds Debug and
`scarf mobile` builds for the iOS Simulator (the reader is shared). No Mac-target, `scripts/` or
UI source touched.


## Whole-surface remediation — P58 (C10 residue r6, `t-10161ba1`)

Eight commits on `fix/whole-surface-audit-r6`: `d0d4031c` (the streaming port and `PipeReader`),
`47c87787` (the widened `OffPool` sweep and fifteen `runHermesCLI` sites), `769b6c98` (the iOS
`async` seam, decision 11), `55fdf8a5` (the five main-actor env sites and the P22 shell-env sweep),
`f0f79433` (the ACP close watchdog), `881bcaa9` (the iOS-streaming doc claim and its test),
`d0cf0b4e` (the trailing-line semantic flip), `b26c0a1f` (the fresh-eyes pass). Round-6 decisions
10 and 11. Closes `t-10161ba1`, folds `t-f30054a8`; appends to `t-02f830f4` and `t-406d56d6`; files
`t-78ced4d2`.

Full detail: [[Process.waitDraining lives in ScarfCore — the two halves of a piped spawn, and the poll-interval trap]]
and [[A source-scan test must be calibrated against the target's default actor isolation]].

### The lessons

- [decision] **Decision 10 done, and the cure was one folder away under a different name.** The four
  streaming spawns read stdout with `Task.detached { while true { handle.availableData } }` — a
  blocking `read(2)` for the life of a stream whose consumer is `tail -F`, so one open Logs pane
  held one cooperative-pool thread permanently. `ProcessACPChannel`'s PRIVATE `PipeLineReader` had
  cured exactly this after the 2026-07-13 wedge; it is hoisted to `PipeReader`, generalised over
  framing (`.rawChunks` / `.lines`) rather than copied, and ACP keeps byte-identical semantics
  through an `acpLines` factory. P48's "a second copy of a primitive is invisible precisely because
  it has a different name" — applied before the second copy existed #c10
- [gotcha] **A test that proves "nothing is parked on the pool" must not `await` its own timeout.**
  Under the regression the pool can schedule nothing, so an `await`-based bound needs the very
  thread it is trying to prove is missing, and the test HANGS instead of failing. The rendezvous
  blocks its own thread on a `DispatchSemaphore` — no scheduling required — which is why the suite's
  helpers are deliberately the `noasync` ones. Calibrated against the reverted transport: the park
  test, the partial-tail test and the fd-close test all go red, and the whole suite's other tests
  slow from 0.7 s to 10.5 s because they were starved too #testing
- [gotcha] **The sweep's NEEDLE LIST is a scope claim nobody re-reads, exactly like its roots.**
  P52's sweep knew the two calls P51 got wrong and nothing else, so P54 added six violations while
  it was green. Seven needles later the tree has **42** real hits where it reported 2. P53's lesson
  was about the matcher; this is the same lesson about the vocabulary #c10 #testing
- [gotcha] **A brace-matching walker that does not strip comments reads PROSE.** The first widened
  run's top hit was `PipeReader.swift`'s own doc comment quoting the defect it replaced — matched
  from inside the sentence, and invisible to the per-line `///` filter because the matched body
  starts mid-line. **A sweep whose first report is the documentation of the fix is one the next
  phase stops reading.** Comments are blanked in place now, line count preserved #testing
- [convention] **The remainder is a COUNTED baseline, not an allowlist.** P58 fixed the 20 hits on
  the paths its task named and recorded the other 29 in `pendingOffPoolSites` as
  `basename:needle → count`, owned by `t-406d56d6`. An extra hit in a listed file still fails, and
  so does fixing one without taking it off the list — a bare allowlist would have hidden both
  directions. The two `ProfilesViewModel` entries are named as the shape that does NOT convert
  mechanically: they are inside `RemoteProfileExport.run`'s synchronous `runCLI:`/`streamFile:`
  function values #testing
- [decision] **Decision 11 done: `ServerTransport.asyncRunProcess` exists and
  `CitadelServerTransport` OVERRIDES it.** The iOS bridge was a thread blocked on a semaphore while
  the exec it waited for ran as a detached task on the same pool — the waiter competing with the
  work. The override deletes both hops; `runSync` survives for the seven SFTP file verbs, whose
  protocol signatures are still synchronous, **and for the synchronous `runProcess`, which P58b
  measured as still having a live iOS caller** — `ServerContext.UserHomeCache.probe`
  (`ServerContext.swift:343`), unguarded ScarfCore compiled for iOS, reaching the transport through
  `ServerContext.sshTransportFactory`. Eight callers, not seven. The DEFAULT implementation (the two Mac transports)
  hands the synchronous call a thread via `OffPool` and says in its own doc that this is the smaller
  claim — `t-02f830f4` still owns the end-to-end conversion #c10
- [gotcha] **A rule stated once is re-broken; four twins of `c93c2287` were still live.**
  `NousAuthFlow.start()` stopped resolving `enrichedEnvironment()` on the main actor in September and
  `SpotifyAuthFlow` (its literal twin), both OAuth/MCP `defaultProcess` paths, `HealthViewModel`'s
  dashboard spawn — whose `proc.run()` had been moved off and whose env line one statement above had
  not — and `HermesProxyService.start()` (whose own `stop()` was moved off in P48) had not. Eight
  seconds of frozen window on the click that opens a sign-in sheet, because a `static let`
  initialiser is a `swift_once` and a main-actor reader arriving during the launch warm-up BLOCKS on
  the token #c10
- [gotcha] **Splitting a synchronous flow around an `await` creates a second click that could not
  exist before, and drops a flag the UI reads.** Found in P58's own fresh-eyes pass:
  `HermesProxyService.start` raises `isRunning` only after the spawn, so once it became `async` two
  clicks could put two `hermes proxy` children on port 8645 — a second `isStarting` latch spans the
  hop. And `MCPLoginController`/`OAuthFlowController` raised `isRunning` in the half that moved into
  `launch`, i.e. AFTER the environment hop, against `MCPLoginController`'s own comment saying the
  sheet must look live from the click #c10
- [gotcha] **`errno == EBADF` on a closed descriptor is a load flake, and this suite proved it on
  itself.** Its park test opens dozens of pipes at once and the process reuses the lowest free fd
  immediately, so a recycled number is a valid fd. The assertion that survives recycling is `fstat`
  identity — the number must no longer name OUR pipe. P48's `/dev/fd` lesson, one layer down
  #testing
- [decision] **A trailing line with no newline is DELIVERED by the streaming transports now, and
  still dropped by ACP.** `M3TransportTests` had recorded the drop as "the documented behaviour";
  it was the blocking loop's leftover buffer, and the consumer is a log list, so the dropped line was
  a line of the user's log that silently never appeared. `deliverPartialAtEOF` is per caller — half
  a JSON-RPC frame is not a frame. The shipped assertion went red on the full run, which is exactly
  what a deliberate semantic change should trip
- [fact] **`HermesLogService`'s iOS streaming claim was false and is now executable.**
  `CitadelServerTransport.streamLines` is an M3 stub that finishes immediately, so the iOS Logs pane
  never streamed; the comment said it did, through a Citadel exec channel. The test LOCATES the stub
  by its declaration and asserts the comment against what it finds — and flips when someone wires it
  (`t-78ced4d2`). Round-6 lesson 6 applied to a claim about a sibling's behaviour #verification
- [decision] **The ACP close watchdog's "force-kill if still running" did neither.** It sent SIGTERM
  and stopped, so a child trapping INT and TERM survived `close()` with the pipes and the pid. Full
  escalation now, pid-guarded, with a named `closeGrace` the test computes its ceiling from. Against
  the reverted watchdog the behavioural test takes 14 s and fails; green it takes 4 s

**Test results.** ScarfCore `swift test`: **3267 tests in 280 suites** — one full run clean apart
from `ProcessDrainP43Tests`' `elapsed < 8` zip-overrun bet, the load flake P54 reproduced on a
`main` worktree; green in isolation (`ProcessDrainP43Tests`, 14 tests). ScarfIOS `swift test`:
**60 tests in 12 suites**, green. Mac full serial `-only-testing:scarfTests`: **1411 tests in 207
suites, 0 failures**, 139 s (P54's baseline: 1374 in 200). Filtered runs during the phase, by TYPE
name: `scarfTests/OffPoolDisciplineP52Tests` + `scarfTests/MainActorSpawnDisciplineP22Tests`
together **27 tests**, green. `scarf` Debug and `scarf mobile` both build clean.

**20 new `@Test`s** (P58b re-measured; the note first said 37): ScarfCore
`StreamingSpawnPipeReaderP58Tests` (10), `IOSStreamingClaimP58Tests` (1) — both in one file, 11
`@Test`s — `ACPCloseWatchdogP58Tests` (2), `AsyncRunProcessSeamP58Tests` (3); plus 4 in `scarfTests`
inside the two existing sweep suites (2 in P52, 2 in P22). Six suites touched, four of them new.
Also the fifteen call-site changes and the flipped `M3TransportTests` assertion. Against the
REVERTED transport the two that go red are `longLivedStreamsParkNoPoolThread` and
`localStreamLinesDeliversPartialTail`; the fd-close test (`cancelClosesTheDescriptor`) does NOT —
it is a pure `PipeReader` test and a transport revert cannot reach it. The claim that it did was
never executed.


### P58b — remediation of the P58 adversarial review

Three commits on `fix/whole-surface-audit-r6`: `081f4437` (the blank-line semantics `PipeReader`
inherited from ACP), `1e4c75b4` (one `proc.run()` rationale, enforced on all four spawns, plus the
timeout ceilings), `720dbdc2` (the close watchdog's `terminate()` and the `runSync` caller count).

- [gotcha] **A primitive hoisted from ONE consumer carries that consumer's semantics, and every
  other adopter silently re-derives each one.** P58 lifted `PipeLineReader` out of
  `ProcessACPChannel` and did the hard part right — it noticed that ACP's trailing-partial DROP was
  ACP's and made `deliverPartialAtEOF` a parameter. It then shipped ACP's
  `guard !lineData.isEmpty else { continue }` as the framing's unconditional behaviour, so the two
  `streamLines` transports lost every blank line: `printf 'a\n\nb\n'` yielded `["a","","b"]` at
  `8dc79784` and `["a","b"]` at `b26c0a1f`, and the only consumer is the Logs pane, where a blank
  separator line is a line of the user's log. **Parameterising one inherited semantic is evidence
  that the others were not audited, not that they were.** The rule the hoist needs is to enumerate
  every branch the donor's behaviour depends on and ask the question once per branch — here two
  branches, `deliverPartialAtEOF` and `skipEmpty`, neither with a default (round-6 lesson 10) #c10
- [gotcha] **A test timeout is a CEILING when it is only ever paid on the failure path, and a BET
  when the green path spends it.** The park test's four probes took 6.5 s of a 10 s bound under
  full-suite load; under the regression they never arrive at all. So the bound was measuring the
  grader's machine, not the defect — raised to 60 s, along with `EventInbox`'s waits and
  `OffPoolP52Tests`' 32-thread rendezvous (`allArrived`, which failed 2 of 6 full parallel runs on
  the reviewer's machine and is not P58-induced). Round-5 P52's "prove it by rendezvous, not by the
  clock" applies to the rendezvous's own ceiling #testing
- [decision] **A rationale written at one call site is an assertion; a needle is the enforcement.**
  P58 moved `HermesProxyService.start`'s spawn into `OffPool.run` because `run()` blocks on
  fork/exec, and left `HealthViewModel`, `MCPLoginController` and `OAuthFlowController` on
  `Task.detached { try proc.run() }`. All four agree now, and `run()` is the P52 sweep's eighth
  needle — identifier-bounded, since `OffPool.run { … }` takes a closure and never spells the empty
  parens. It finds seven more (`SSHTransport` ×2, `SSHScriptRunner` ×2, `LocalTransport` ×2,
  `TestConnectionProbe`), baselined with counts on `t-406d56d6`: their `run()` sits inside pipe
  wiring and a drain it owns, so a mechanical wrap would move the plumbing too #c10
- [gotcha] **`guard proc.isRunning` is a CHECK, not a hold.** `ProcessACPChannel`'s close watchdog
  then called `terminate()`, which on a process reaped in the gap raises an ObjC exception —
  uncatchable in Swift. `kill(pid, SIGTERM)` cannot trap: a stale pid returns ESRCH. The residual
  window is pid recycling, which nothing short of a pidfd closes and which `terminate()` did not
  close either; it is now one stated sentence instead of an unexamined one
- [fact] **Three numbers in the P58 write-up were unmeasured, and all three were wrong.** "Twelve
  iOS call sites" is eleven (`git diff 8dc79784..b26c0a1f | grep -c '^-.*runProcess('`). "37 new
  tests in 5 suites" is 20 `@Test`s across six suites, four of them new. "The fd-close test goes red
  against the reverted transport" is false — `cancelClosesTheDescriptor` is a pure `PipeReader`
  test a transport revert cannot reach; the two that do go red are
  `longLivedStreamsParkNoPoolThread` and `localStreamLinesDeliversPartialTail`. And `runSync` has
  eight callers, not seven: `ServerContext.UserHomeCache.probe` (`ServerContext.swift:343`) is
  unguarded ScarfCore compiled for iOS and still calls the SYNCHRONOUS `runProcess` through
  `ServerContext.sshTransportFactory`. Round-6 lesson 6, one round later, in the write-up that
  taught it #verification


## Round 6 — memory audit (2026-09-13)

A tier-wide pass over `.memory/` (and `wiki/` where a page states a fact this branch changed)
against `fix/whole-surface-audit-r6` at `720dbdc2` (P54–P58b, `d53d3cbe`..`720dbdc2`, 39 commits,
141 files). `memory_health` went **71 flagged → 52**; the `codeChanged` bucket — the only one an
audit can actually close — went **52 → 33** (high severity 52 → 33). **Broken relations: 0 before,
0 after** (the round-4 repairs still hold). The residue is the 13 `outsideTaxonomy` refiles,
5 honestly ungrounded notes, 2 deprecated, and 33 drifted notes whose anchors this branch touched
but whose SUBJECT it did not.

**All eleven round-6 product decisions** were checked against their phase section and the commit
that shipped them; all eleven agreed as written. Every one already carried its `(P##)` pointer and
**none carried a commit hash**, so all eleven lines were annotated, one `find_replace` per line,
with the shipping commit(s) and the `b` commit where one corrected it: 1–2 `018194b7` + `acefd89a`
(1 also `a3f4647a`, `28ba0cfb`, `3696127c`; 2 also `28ba0cfb`), 3 `a275f59a` (+ `e6cfe38d`,
`9d2c151e`, `475dec73`), 4–5 `ac135138` (5's citations also `e6cfe38d`), 6 `e4e25ccb` + `058ea28c`
(+ `6a641ee8`), 7–8 `e3eeaca7`, 9 `9c882c65`, 10 `d0d4031c` (+ `081f4437`, `1e4c75b4`, `720dbdc2`,
`d0cf0b4e`), 11 `769b6c98` (+ `b26c0a1f`, `881bcaa9`).

**Decision 6's flag correction verified.** The decision line already carried P56's correction; the
flag it names is right and so is the commit — `public var hasKanbanReviewExits: Bool { isV0201OrLater }`
at `HermesCapabilities.swift:1448` at HEAD, shipped in `e4e25ccb`, inside the `// MARK: v0.20.4`
group (1381–1532) whose header states it is a LOCATION and not evidence.

**Corrected — claims this branch made false.** The `.memory/` tier came through this round almost
clean: the phases re-tensed their own subjects as they went (`hasKanban` 0.13, `hasBotChatCreationCLI`
0.20.5, `KanbanCreateRequest.branch` gone, `--repeat` forwarded, `PipeReader`, the Review exits, the
`/goal` mirrors, every YAML reader lesson). **One** memory correction and **six** wiki pages:
- `scarf/architecture/hermes-cron-recovery-is-three-doors-not-one-and-scarf-must` — its
  `scheduleFormRefusal` constraint cited `parse_schedule`'s pre-filter at `cron/jobs.py:755-756`.
  That range is the COMMENT above the code; P56b (`aa708b9c`) corrected the five sites in source to
  `:757-758` and the note still had the old one. Re-tensed in place with the correction and its
  commit.
- `wiki/Slash-Commands.md` — listed `/goal` and `/subgoal` among the capability-gated ACP-advertised
  commands. Removed, with a dated block explaining why they were never ACP names at any tag.
- `wiki/Hermes-Version-Compatibility.md` — the v0.14 baseline paragraph presented `/subgoal` as a
  live Scarf surface; now leads with the withdrawal and says the v0.13/v0.14 rows below are HISTORY
  of what Hermes shipped, not a description of Scarf. Its v0.15 Kanban clause also lost
  `--branch`-on-create and gained the Review-exits floor.
- `wiki/Sidebar-and-Navigation.md` — "Worktree + model surfacing" claimed per-task `--branch` on
  create; corrected, plus two new bullets (the Review column's two exits at the v0.20.1 floor, and
  the board-wide dispatch confirmation).
- `wiki/Projects-and-Profiles.md` — same `--branch` claim in the v0.15-wave paragraph, corrected.
- `wiki/ACP-Subprocess.md` — "**Read loop** runs detached: `availableData` …" was the defect P58
  deleted. Rewritten as `PipeReader` / `DispatchSourceRead`, with ACP's two framing semantics
  (`deliverPartialAtEOF: false`, `skipEmpty: true`) checked against `PipeReader.acpLines` at HEAD.
- `wiki/Gateway-Cron-Health-Logs.md` — the Backup & Restore section, which described a restore that
  had never once worked; now carries decision 1's fix and the three-state judging.

Swept and found ALREADY correct at HEAD: `hasKanban` 0.12 (both the board note and the v0.15 gating
note carry P55's dated re-floor), `hasMCPIdentityHeader`, `hasBotChatCreationCLI`,
`hasKanbanV015`/Review-column, `--branch`, `repeat` "not modeled" (the fleet note's `[gotcha]` about
a not-forwarded LIST going stale), `runSync`, `PipeLineReader`/`PipeReader`, `Task.detached` as the
C10 escape, the `availableData` loop, `boolishValue`, `.whitespaces` trimming, `isBlock` dotted keys,
block scalars, `busy_ack_enabled`, dispatch board-wide, `OutcomeMessage`, `runProcess`/`asyncRunProcess`.

**Distilled into the notes that OWN them rather than forked** — four edits, no new note:
- [[Hermes Capability Gating Pattern]] gained **"a decision that NAMES a flag is a hypothesis, not a
  citation"** (decision 6 vs. the v0.20.1 source) and **"a flag's MARK group is a floor claim too,
  and every group-enumerating test is a membership contract"** (P56b `6a641ee8`). "Cite a tag, never
  a release" was already there — P55 wrote it into this note itself.
- `architecture/process-waitdraining-lives-in-scarfcore…` gained P58b's **"a hoisted primitive
  carries its donor's semantics — enumerate every branch the donor's behaviour depends on"**
  (`skipEmpty` shipped as unconditional after `deliverPartialAtEOF` was correctly parameterised), the
  `proc.run()` eighth-needle decision, the `guard proc.isRunning` is-a-check-not-a-hold gotcha, the
  eight-caller `runSync` count, and the ceiling-vs-bet rule for test timeouts.
- `architecture/judging-a-hermes-verb-by-its-output-the-exit-0-refusal` gained **"the SEAL is a
  consumer of the verdict too"** — the `OutcomeMessage.Kind` triad, `kind:` with no default across
  24 call sites, and P55b's green-seal-on-an-unconfirmed-restart — plus the note that P54's six
  edited `runHermesCLI` sites are C10 sites P58 owns.
- `conventions/fast-test-iteration-commands-swift-test-vs-xcodebuild` gained the THIRD way
  `-only-testing` matches nothing: **it takes the TYPE name, never the `@Suite` display string**.
- The YAML reader note needed nothing — P57b had already written **"a trim is a per-READER claim
  about the Hermes side"** into it as an `[invariant]`, with `busy_ack_enabled` as its evidence. The
  cron note already owned "every `cron edit` validation, and where each one lives on iOS"; only its
  citation needed fixing. The source-scan note already owned the widened-sweep lessons.

**Re-confirmed against HEAD** (`review_memory` with `claim: code`, each after opening the code it
anchors to — 16 notes): `Hermes Capability Gating Pattern`, `a-yaml-reader-is-opted-in…`,
`a-platform-s-shared-keys…`, `kanban-board-architecture-v2-7-5`, `hermes-cron-recovery…`,
`phase-1-milestone-3-fleet…`, `judging-a-hermes-verb…`, `macos-accessibility-label-conventions`,
`the-acp-adapter-s-slash-roster…`, `a-source-scan-test-must-be-calibrated…`,
`process-waitdraining…`, `columns-400-rides-the-judged-spawns…`,
`argparse-protects-positionals…`, `transport-atomic-write-parity…`,
`chat-session-layer-mechanism-map…`, `hermes-version-targeting-strategy`,
`hermes-version-compatibility-target`, `hermes-v0-21-1-audit-findings`,
`hermes-v0-21-1-compatibility-decisions`.

**Nothing was retired.** No note was found wholly superseded — round 6 corrected floors, primitives
and citations that existing notes already described.

**Tasks.** All six phase tasks are `done` with artifacts naming their commits (`t-daf369c1`,
`t-a7eb12e5`, `t-19ba24a5`, `t-b24e5fba`, `t-10161ba1`, and `t-4edfd804` closed as superseded by
P54). All seven tasks the phases created exist on the board with file:line evidence (`t-fc4d3a6f`,
`t-62dee8aa`, `t-46f089cf`, `t-e9c464a9`, `t-b74c65a4`, `t-b290817d`, `t-78ced4d2`), and
`t-02f830f4` / `t-406d56d6` / `t-295ef4d2` all carry their appended round-6 content (the iOS seam
and the eight `runSync` callers; the exact 42-hit counted baseline; P57's lesson-5 sweep).
**One task corrected:** `t-e9c464a9` carried the same `hermes_cli/commands.py:113` @ `v2026.5.7`
paste that P55b fixed in source — now `:103`, with the "same nine names" claim corrected to
`compact`-vs-`compress` as well.

- [todo] **Refile queue, still 13 notes, still Alan's call** — UNCHANGED from rounds 4 and 5 and
  re-verified as the same set: `design/` (2), `features/` (4), `integration/` (5), `overview/` (1),
  `profile/` (1). Mass-refiling is a structural decision, not an audit one #memory
- [todo] **Thirty-three notes stay `codeChanged` deliberately** — their anchors moved in round 6
  (mostly `HermesCapabilities.swift`, `SettingsViewModel.swift`, `HermesFileService.swift`,
  `SSHTransport.swift` and `LocalTransport.swift`, each touched by several phases) but their subject
  did not: the managed-install refusals, the host-default picker, pairing verdicts, the vnode watch,
  the watcher tick, GuardedTextFile, the unguarded write seam, mac-config reads, the transport
  writeFile grep, the ControlMaster probe, the SSH circuit breaker, scene-phase pause/resume,
  `.task` vs `onAppear`, streaming-chat throttling, ActivityBubble segmentation, iOS session resume,
  Multi-Server Architecture, ScarfGo (both notes), export surfaces, Hermes-authored fixtures,
  no-raw-print, XCUITest reliability, registry write locks, setup forms, the unified AGENTS.md
  renderer, Bot Mode Phase A, the v0.18/v0.20/v0.20.4/v0.21 decision notes, section-audit
  remediation, and Model Presets. Stamping them `claim: code` without opening their anchors is the
  failure mode this audit exists to prevent #memory
- [todo] **The five `needsGrounding` notes are unchanged from rounds 4 and 5** and still honest —
  they describe Hermes-side or workflow facts with no Scarf file to anchor to #memory


## P59 — cross-phase remediation of the round-6 branch (`64d87812` … `befa36c2`)

Seven commits on `fix/whole-surface-audit-r6`, closing the cross-phase review of P54–P58b.
Counts: ScarfCore `swift test` **3276 tests / 281 suites + 42 / 3 suites**, green on two full
runs; ScarfIOS `swift test` **60 tests / 12 suites**; Mac full serial `-only-testing:scarfTests`
**1421 Swift Testing tests in 209 suites + 4 XCTest**, 0 failures; `scarf` Debug and
`scarf mobile` both build.

- `64d87812` the `OffPool` sweep's needle set, widened from 7 to 11
- `47fc0631` three `.unconfirmed` two-way collapses
- `92cc984d` the missing `No result: %@` catalogue row + a real file scan
- `989f45ed` `WebhooksViewModel`'s three hand-written banners
- `2cbbfe7c` the kanban teaching sheet's missing `hasKanban` gate
- `705d8380` `hasBotChatCreationCLI`'s group + three corrected Hermes citations
- `befa36c2` the `ProcessDrainP43Tests` load flake

### The lessons

- [gotcha] **A sweep that names the WRAPPED call cannot see the wrapper.** P58's needles asked
  about `runHermesCLI(` and `runProcess(`; twenty ViewModel sites spell
  `ctx.runHermes(` / `ctx.runHermesSplit(`, which is `ServerContext+Mac.swift:21-24` — one line
  around `runHermesCLI`, i.e. the identical process spawn or SSH exec. Same for `readText(` /
  `readFile(`: `KanbanToolsetDetector` rode an SFTP round trip on the cooperative pool for four
  rounds inside `Task.detached { context.readText(path) }`. The generalisable form: when a phase
  adds a needle, it must ask **who else spells this call by another name** — a one-line
  convenience wrapper is the commonest such name, and it is invisible to a vocabulary built from
  the sites the last phase happened to get wrong #c10 #testing
- [decision] **A needle whose ASYNC twin shares its spelling needs a rule, not an exemption.**
  `SkillsViewModel` has its own `static func runHermes(executable:…) async`, which is
  `transport.asyncRunProcess` underneath — round-6 decision 11's cure. Ten of its call sites sit
  inside `Task.detached` bodies and none parks a thread. Dropping the needle would hide the twenty
  real sites; exempting the file would hide a future real one in it. The rule is the asymmetry
  itself: `ServerContext.runHermes` is `nonisolated` and synchronous so `await` can never precede
  it — **awaited ⇒ the async twin, bare ⇒ the blocking seam** — and it is calibrated with both
  shapes planted in one body #c10 #testing
- [convention] **The baseline grew from 29 to 38 because the sweep can SEE more, which is what a
  widening is supposed to do.** Eleven `readText(`/`readFile(` entries are left with a reason:
  none is the one-line shape, and three (`CuratorViewModel`, `LogTailWidgetView`,
  `ProjectCockpitViewModel`) `await` inside the detached body, which `OffPool.run`'s synchronous
  closure cannot take — splitting those is a refactor of the load, not a wrap. Converting
  `BotConversationViewModel`'s whole staging body took three `runProcess(` hits off in the same
  pass, so the number moved in both directions. `baselineSizeIsPinned` re-measures the 38/26 the
  prose claims (lesson 6) #testing
- [decision] **`.unconfirmed` is gated on the CONFIDENCE ALONE — and P59 reversed P53 to say so.**
  P53 kept the output tail on `auth logout`'s unconfirmed arm, reasoning "the line is the only
  thing worth showing". P54b then settled the rule the other way on `backup`, `sessions optimize`
  and `debug share`, because `judge` fills `detail` with `lines.last` on the unconfirmed arm too:
  the tail is whatever the CLI printed last, and rendering it after "Remove failed: " asserts that
  Hermes gave that sentence as its reason for a refusal it never made. The hand-picked fixture
  reads well; `Scanning credentials …` does not, and the formatter cannot tell them apart. **A
  fixture for an unconfirmed arm must carry NON-EMPTY output, or it cannot distinguish the two
  gates** — every earlier fixture used empty output, which is why three collapses survived four
  rounds of review #c5
- [gotcha] **The memory-reset collapse was written TWICE, in two targets, under the same
  comment.** Mac `MemoryView` and iOS `MemoryListView` both had `outcome.detail ?? (exit-code
  branch)`. Not drift — identical twins, which a behavioural test on either one would have passed.
  The three branches now live in `HermesMemoryResetVerdict.failureSummary`, with a source scan
  proving both views still CALL it (a behavioural test cannot see a consumer that stopped calling)
  #conventions
- [gotcha] **A hand-maintained key list cannot catch a key nobody adds to it.**
  `BannerCatalogueP54bTests` checked 34 typed-out keys and missed `No result: %@` — the third
  seal's VoiceOver label, added by P54b beside `Failed: %@` and `Succeeded: %@`, which are
  translated in all six locales. The seal that exists to avoid asserting a refusal announced
  itself in English. The suite now also SCANS `OutcomeMessageBar.swift` for every
  `String(localized:)` in its catalogue spelling, with a premise floor and a planted fixture
  #testing
- [decision] **A version claim in a doc comment that no line implements is worse than none.**
  `maybeTriggerKanbanOnboarding` documented a "host pre-dates v0.12" skip and had NO gate at all,
  while its button runs `hermes tools enable kanban --platform cli` — an unknown verb below the
  floor, which Hermes routes to the agent at exit 0 (C5). The detector could not stand in: it
  reads `config.yaml`, and a pre-floor config has no `kanban` toolset for exactly the reason the
  sheet must not offer to add one, so `.disabled` is what such a host answers. Gated on
  `hasKanban` through a pure `shouldOfferKanbanOnboarding(capabilities:dismissed:)`; the floor is
  **v0.13** (`hermes_cli/kanban.py` absent at `v2026.4.30`, present at `v2026.5.7`, where the
  slash roster's `CommandDef("kanban", …)` is `hermes_cli/commands.py:163` and NOT in `kanban.py`
  — this line said "with `CommandDef(…)`" as if the module carried it; P60 re-opened both tags),
  not the v0.12 the release notes said
  #c5 #c2
- [gotcha] **`a275f59a` inserted a function between a doc block and its declaration**, so the
  "skipped when…" list documented the argument parser instead. A doc comment has no anchor a
  compiler checks; the attachment is now pinned by a test #conventions
- [decision] **A flag in the wrong MARK group is a flag no group test covers.**
  `hasBotChatCreationCLI` (floor v0.20.5) was declared in the v0.21 group and enumerated in NO
  group test — not the v0.21 four, where it would have contradicted
  `v0205HostHidesEveryV021Flag`, and not the v0.20.5 four either. P55/P56b's rule is "the MARK is
  a location, never evidence", which is why `hasMCPIdentityHeader`/`hasKanbanReviewExits` stayed
  put: **no v0.20.1 group exists**. Here one does, so the flag MOVED and joined all four v0.20.5
  group tests plus the "v0.20.5 surface stays alive" tail of the v0.21 test. Same principle, two
  outcomes, and the note says which applies when #c1
- [gotcha] **An elapsed-time assertion that cannot fail on the defect is a flake generator.**
  `ProcessDrainP43Tests`'s `elapsed < 8` was read as proving boundedness, but the UNBOUNDED zip of
  its fixture takes ~200 ms — faster than the refusal path — so no threshold distinguishes
  bounded from complete. The discriminator is the thrown `did not finish`, already asserted; the
  ceiling can only catch a HANG. Raised to 30 s with the arithmetic written (0.025 + 2 + 2 + 1 ≈
  5.03 s of bounded waiting, `ProcessTimeout.swift:80`/`:246`). **Before raising a timing ceiling,
  ask what failure it can actually see** — the answer decides whether to raise it or delete it
  #testing
- [convention] **Three Hermes citations were wrong by 2–3 lines each**, all re-opened at
  `v2026.9.7`: `backup.py:921/:924/:936` → `:923/:926/:934` (exits `:924/:927/:935`);
  `cron/jobs.py:779-780` → `:781`; `:816-822` → `:817-823`. And `--query-file` was `:308` in one
  test and `:307` in two other places — `:307` is the `add_argument(` call, matching how its
  sibling `-q`/`--query` is cited at `:304`. The pattern is always the same: the cite lands on a
  neighbouring line of the right block, which reads plausible and is unverifiable by eye #c2


## P60 — pre-merge remediation of the round-7 NEW findings (`93ddd327` … `83a0874c`)

Eight commits on `fix/whole-surface-audit-r6`, closing the round-7 whole-surface audit's findings
that this branch INTRODUCED. Counts: ScarfCore `swift test` **3281 tests / 282 suites + 42 / 3
suites**, green on two full runs; ScarfIOS `swift test` **60 tests / 12 suites**; Mac full serial
`-only-testing:scarfTests` **1427 Swift Testing tests in 209 suites + 4 XCTest**, 0 failures;
`scarf` Debug and `scarf mobile` both build.

- `93ddd327` the phantom final `""` every `+`-chomped block scalar counted as a trailing blank
- `35820200` the `OffPool` sweep's needles 12 → 15, plus its per-root floors and roster pin
- `1a81eca1` the `/dev/fd` delta measured once
- `8fbfb7b6` the kanban dispatch confirm parked ahead of the plan
- `66bf7f40` the iOS cron editor's three unreachable catalogue rows
- `3b31cc5a` `HermesMemoryResetVerdict.failureSummary`'s two missing rows, and the scan widened
- `20193227` `profile create|delete|rename`'s missing `--`
- `83a0874c` three claims in comments, none of them executed

### The lessons

- [gotcha] **`components(separatedBy:)` yields a PHANTOM element for text that ends in its own
  separator, and a parser that treats lines as data will consume it.** `HermesYAML`'s line loop
  skipped the trailing `""` everywhere EXCEPT inside a block scalar, where it was appended as a
  body line — so every `|+` / `>+` / `|2+` scalar that ENDS the document (the shape a real
  `config.yaml` has: the prompt is usually the last key) grew one spurious newline. The P57b
  corpus could not see it because all 96 of its documents carry a `note: end` sibling AFTER the
  block, which closes it before the phantom line is reached: **a corpus that always puts a
  terminator after the construct under test never tests the construct at the end of input.** New
  oracle: 10 headers × the 16 P57b bodies = 160 newline-terminated documents, 48 of which failed
  #testing
- [decision] **Documents with NO trailing newline are a separate, unaudited class and P60 did not
  claim them.** PyYAML gives `"hello"` (not `"hello\n"`) for `prompt: |` over a body with no final
  break, and Scarf gives `"hello\n"` for all 108 such docs the first draft of the corpus
  generated. A file on disk ends in a newline and a Swift `"""` literal is the only producer of
  the other shape, so the corpus was narrowed to the 160 terminated documents rather than
  widening the fix past what was measured. Filing the divergence honestly beats a silent drop
  #c2
- [gotcha] **A needle CANNOT match its own `Split` sibling, and that is the same property the
  baseline relies on.** `containsNeedle` bounds a needle on the left by identifier and on the
  right by the needle's own trailing `(` — so `runHermesCLI(` sees nothing of
  `runHermesCLISplit(`, which is exactly what keeps the two baseline keys from double-counting
  and is exactly what hid nine split sites in `Task.detached` bodies for three rounds. Same shape
  twice more: `CuratorService.runHermesSync` (its own nonisolated static wrapper one frame above
  `transport.runProcess`) and `HermesVersionCache.capabilitiesSync` (spawns `hermes --version`
  and waits on a cold cache). **The rule, now written in `blockingNeedles`' own doc comment
  because P58, P59 and P60 each learned it separately: a needle must be accompanied by every
  one-call wrapper of it in the tree** — a `Split` sibling, a `…Sync` façade, a `ServerContext`
  convenience. A wrapper blocks for exactly as long as the thing it wraps #c10 #testing
- [decision] **Only the plain `await Task.detached { … }.value` shape converts in a remediation
  pass; the rest is baselined with a reason each.** Three sites were that shape
  (`CuratorService.status()`, `CuratorService.runHermes` — the single seam every `curator` verb
  funnels through — and `IOSSettingsViewModel`'s managed-install probe) and were converted with
  timeouts unchanged. The other eleven are multi-statement bodies ending in
  `await MainActor.run { … }`, which `OffPool.run`'s SYNCHRONOUS closure cannot take whole: the
  conversion is a split of the load, not a wrap, and `PeersViewModel`'s 600 s DM timeout (the
  CLI's own `DM_TIMEOUT_S`) has to survive it. Baseline 38/26 → **49/32**, re-measured by
  `baselineSizeIsPinned`, which now pins the NEEDLE count too (2 → 7 → 8 → 12 → 15); the eleven
  are appended to `t-406d56d6` with a table of reasons #c10
- [convention] **`> 0` is not a floor, and existence is not membership.** The sweep's premise
  check let a root that enumerated ONE file pass, and its root list had no roster pin — the two
  gaps P38 and P22 had each already closed for their own sweeps. Per-root floors in P38's table
  shape (populations 299/50/217/14, floors 200/30/150/8) and P22's membership assertion. This is
  lesson 3 applied to the machinery rather than the code: **when you learn a rule, find every
  sweep that should enforce it and confirm it does** #testing
- [gotcha] **An elapsed-time ceiling is not the only single-sample measurement in the tree.**
  `onlyReadEndsLeak` took ONE `/dev/fd` before/after pair per arm, and `/dev/fd` is
  PROCESS-global: a neighbour's in-flight spawn lands in the window, and the flat arm's threshold
  of 10 is the same size as the noise. Smallest delta over three trials, the shape round-5 P48b
  already cured for the two ScarfCore transport tests. The minimum is conservative for BOTH
  assertions here, because noise can only ADD descriptors #testing
- [decision] **A confirmation keyed on the destination is the plan's property claimed by proxy.**
  `attemptMove` parked the board-wide dispatch sheet on `destination == .running` BEFORE calling
  `KanbanService.plan`, so Done, Triage, Review and Archived → Running each showed the sheet, took
  the user's yes, and failed afterwards with a banner. The plan is pure, so computing it first
  costs nothing; the gate is now `plan.steps.contains(.dispatch)`, which is wrong in neither
  direction — it asks on `[.unblock, .dispatch]` and stays quiet on a refusal or on a future
  Running route with no dispatch step. Still parked ahead of the optimistic mutation #c5
- [gotcha] **A catalogue row in six locales is worth nothing if the call site's TYPE picks the
  verbatim overload.** `CronEditorView.init(title: String)` fed `.navigationTitle(title)`, whose
  `StringProtocol` overload renders its argument as-is; all three titles already had rows, two of
  them HAND-MAINTAINED in `iosOnlyKeys` for exactly this sheet, and not one ever resolved.
  `LocalizedStringResource` + `Text(title)`. A behavioural test cannot see this — the wrong
  overload renders the English string, which is what the test's own locale expects — so it is
  asserted by spelling, with the three keys read FROM the source by regex rather than typed into
  the test #conventions
- [gotcha] **P59's own cure grew the same gap one file away.** `HermesMemoryResetVerdict.failureSummary`
  — the formatter P59 created by collapsing the Mac and iOS twins — wrapped both its sentences in
  `String(localized:)` and neither had a catalogue row, beside four siblings in the same file
  translated in six locales and six "printed no result. Check the host." rows for other verbs. The
  P54b file scan, added by P59 precisely because a hand-typed key list cannot catch a key nobody
  adds to it, was still pointed at ONE file. Widened to `HermesCLIOutcome.swift`, with a per-file
  premise floor (a shared one is cleared by the bigger file alone) #testing
- [convention] **A source scan cannot know an interpolation's TYPE, and the extractor can.**
  `localizedKeys` writes `%@` for every `\(…)`; Swift writes `%d` for an `Int32` and `%lld` for an
  `Int`, so `…exited with status \(exitCode)` is `…status %d.` in the catalogue and a scan
  insisting on `%@` reports a row that is right there. Each `%@` is now tried as `%@`, `%d` and
  `%lld` and a key matches if ANY spelling has a row — a relaxation of the KEY, never of the
  requirement, planted both ways including an invented key that matches under none #testing
- [decision] **`argparse` protects a positional only from flags it does not know.**
  `profile_name` / `old_name` / `new_name` are plain positionals (`hermes_cli/subcommands/profile.py:19`,
  `:41`, `:77`, `:79` @ `v2026.9.7`), so a bot or profile name beginning with `-` exits 2 with a
  usage block. `BotsService.Lifecycle`'s three argvs had no separator at all and `delete` put
  `--yes` AFTER the positional — a second positional for a parser that takes one, once `--` is
  present. Every option before the separator, every positional after. `--` is safe on this parser
  by P47's rule: no option here is list-valued. Walked the siblings and found the idle twin —
  P47 gave `rename` and `delete` the separator on the Mac VM and left `create`. The test runs each
  verb with a name that IS a real flag on that parser, which is the only way to tell the separator
  from luck #c5
- [convention] **The third copy of a citation is where it drifts.** `CommandDef("kanban", …)` is
  `hermes_cli/commands.py:163` at `v2026.5.7`, and `HermesCapabilities` and `HermesP55Tests` both
  say so; P59's two newer copies said the roster entry arrives WITH `hermes_cli/kanban.py`, which
  reads as the module carrying it. Both tags re-opened. Same round, same lesson 6 as P59's own
  three off-by-two Hermes cites #c2
- [decision] **Two single-waiter/empty-result shapes are stated rather than changed.**
  `PipeEOFSignal.waiter` is ONE slot: a second concurrent `wait()` overwrites the first
  continuation and that caller never resumes. Every call site is one-await-per-signal (each
  streaming spawn owns its own signal), so the slot is honest — but the doc now says so, and says
  the fix for a second waiter is an ARRAY resumed in `signal()`, not a hopeful extra call. And
  `CitadelServerTransport.runSync`'s own expiry throws `partialStdout: Data()` on purpose:
  `PartialStdout` serves the INNER budget, the arm a slow command hits, while this one is the
  backstop reached only when the async op blew past its timeout plus `syncGrace` and never
  returned, with the detached task still holding its drain #c10


## Round 7 — merge of P54–P60 and what this branch taught (2026-09-13)

Branch `fix/whole-surface-audit-r6` (P54–P60, 54 code commits) merged to `main` as `c721dbf3` with `merge(whole-surface-audit-r6)`; not pushed. Round-7 report: `documents/hermes-v0.21.1-whole-surface-audit-round7.md`; follow-ups P61–P65 (`t-11371e30`, `t-fa0043f6`, `t-d2000dc5`, `t-d1d324ff`, `t-ad965a68`) with ten product decisions open for Alan.

- [gotcha] **A needle's wrappers are a derivable set, and the sweep must carry all of them.** P59 fixed `ctx.runHermes(`; the same round left `runHermesCLISplit(`, `runHermesSync(`, `capabilitiesSync(` (16 sites). Enumerate every one-call wrapper of a needle mechanically, not by recall #c10 #testing
- [gotcha] **The sweep's DOMAIN is the gap, not its needles.** Eleven blocking seams in plain `async func`s and actor methods (backup/restore/logs) are invisible to a `Task.detached`-body walker by construction. A second matcher over async bodies and non-`nonisolated` actor methods is the fix (P63) #c10
- [gotcha] **A hoisted primitive carries its donor's semantics; ask once per branch.** P58's `skipEmpty` and P57b's `+`-chomp phantom blank were both branches nobody re-derived when the code moved #verification
- [gotcha] **A floor set by a Hermes COMMENT is a release-note floor.** `hasXAIVoiceCloning` survived six rounds because the tag diff is real and lands on the right line. Open the implementation at the tag before #capability-gating
- [gotcha] **A decision that names a flag is a floor claim and gets walked.** Decision 6 named `hasKanbanV015`; the exit verbs are v0.20.1 #capability-gating
- [gotcha] **An edited field computes other fields.** `next_run_at` (round 6), then the model-pin snapshots and the duplicate's strip list (round 7): ask which stored fields Hermes recomputes when this field changes #ios
- [gotcha] **`-only-testing` takes the TYPE name; the `@Suite` display string matches nothing and prints TEST SUCCEEDED** #testing
- [gotcha] **zsh: `git show $t:hermes_cli/x.py` is silently wrong** (`:h` is a history modifier); write `"${t}:hermes_cli/x.py"`. A plausible source of past phantom "absent at the old tag" verdicts #process
- [fact] Mac PARALLEL `xcodebuild test` is red and has been (84 issues / 8 suites on the branch, 124 / 12 on `main` at `d53d3cbe`, shared-global-state suites); serial is the usable signal and every report must say so #testing
- [fact] Final pass at `83a0874c`: ScarfCore 3281/282 (+42/3), ScarfIOS 60/12, Mac `scarfTests` serial 1427/209 (142 s), scripts 20/20; both schemes build. OffPool baseline 49 hits / 32 keys on `t-406d56d6` #testing
- [decision] The ten product decisions in the round-7 report are open; Alan decides before P61–P65 are scoped #process

## Release blockers (2026-09-13)

Branch `fix/release-blockers` from `main` at `c721dbf3`. Four round-7 blockers,
six commits, all `fix(release):`.

| Commit | What |
| --- | --- |
| `79d2fecb` | `GatewayConfigWriter`: a block-scalar header is not an inline value |
| `cd43b9d2` | backup / restore / logs stop blocking on SSH (10 sites) |
| `baac0639` | Web Dashboard row gated on `hasDashboardCommand`; daemon stop ceiling |
| `74567c5b` | seven `.unconfirmed` arms stop asserting a refusal |
| `bd838c39` | the dashboard's escalation is a thread, not a Task |
| `38593ebf` | the YAML suite obeys the test-host stability sweep |

New suites: `HermesReleaseBlockerYAMLTests` (9), `UnconfirmedSkillsVerdictArmTests`
(3) — ScarfCore; `AsyncFunctionBlockingSeamTests` (2), `WebDashboardGateTests`
(4), `UnconfirmedVerdictArmTests` (6) — app target.

Full runs, all green: ScarfCore `swift test` 3293 tests / 284 suites; ScarfIOS
`swift test` 60 / 12; Mac serial `-only-testing:scarfTests` 1439 / 212;
`scarf` Debug build and `scarf mobile` (generic iOS Simulator) build both
BUILD SUCCEEDED.

Pre-fix issue counts (the "fails without the fix" evidence): 36 / 8 of 10 /
3 / 17 + 9.


## Hermes v0.21.2 (v2026.9.11) — target bump (2026-09-14)

Not a parity cycle. Hermes shipped v0.21.2 four days after our v0.21.1 target; Alan asked whether to check before release prep. A targeted check at the tag found nothing breaking, and the target was bumped on `main` in one commit.

- [fact] Verified at the tag: SCHEMA_VERSION 30 unchanged, no table removed, every column Scarf probes present, `check-hermes-tables.py --tag v2026.9.11` `lanes=5/5`; hosted rooms moved to `shared-state.db` (Scarf never reads them); `acp_adapter/server.py` changed four lines of `/model` provider detection; no verb or flag Scarf issues was removed (`plugins search` lost two args Scarf never passes); every judged output marker byte-identical; Smoke + Live UI plans green against the installed 0.21.2 #capability-gating
- [decision] **`hermes backup` gets `--keep 0` on v0.21.2+** (`hasBackupKeep = isV0212OrLater`, the v0.21.2 MARK group's only flag): from v2026.9.11 the CLI defaults to `--keep 3` and deletes older `~/hermes-backup-*.zip` in the output directory (`subcommands/backup.py:23-26`, `backup.py:696-698`); Scarf's "Backup Now" must not delete files nobody asked to delete. `HermesBackupVerdict.argv(capabilities:)` has no default (lesson 10); below the floor the flag is an argparse error so the argv stays bare #c6
- [gotcha] **A Hermes default can change under a verb Scarf shells with no argv change at all.** The C5 walk asks "does the argv still parse"; this one parsed identically and deleted files. On a target bump, diff every `add_argument(... default=...)` on the verbs Scarf issues, not only the added/removed arguments #capability-gating
- [todo] Not adopted this cycle, on t-ad965a68: the CLI now re-derives `repeat` when a cron edit flips one-shot ↔ recurring (`_rederive_repeat_for_schedule_change`) and snapshots the unpinned model at create; the iOS `jobs.json` form does neither #ios
- [fact] Counts after the bump: ScarfCore filtered 174/9, Mac serial 1442/213, scripts 20/20, both schemes build #testing


## 3.2.0 cut — the UI gate ran the unit half in parallel (2026-09-14)

- [gotcha] **`scripts/ui-gate.sh` had no `-parallel-testing-enabled NO`.** The Full plan carries scarfTests + scarfUITests; all 16 UI tests passed and the gate still reported FAIL because the 1442 unit tests ran under Xcode's default parallelism and hit the known shared-state suites (`ChatViewModelStartLifecycleTests`, `MainActorBlockingWritesP11Tests`) — the exact fact round 7 recorded ("serial is the usable signal") one line above the machinery that did not know it. Round-6 lesson 3 again: a fact in a report must reach the script that runs the gate. Fixed by adding the flag with a comment naming the suites; the `.serialized` remedy for those suites stays on P63 (`t-d2000dc5`) #testing #process


## 3.2.0 cut — the Release archive is a gate Debug cannot stand in for (2026-09-14)

- [gotcha] **`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` is Release-only, so Swift 6 isolation diagnostics are warnings in every Debug build and test run and errors only at `release.sh`'s archive.** The 3.2.0 Universal archive failed on nine of them across three files, all from the branch's `OffPool`/`Task.detached` conversions: `@MainActor` view models' `static let` timeouts read inside off-actor closures (`GatewayViewModel.probeTimeout/mutationTimeout`, `TestConnectionProbe.probeTimeout` — the app target defaults declarations to `@MainActor`), a captured `var args` (`WebhooksViewModel`), and a weak `self` used in a nested `MainActor.run` without its own capture list. Same class the 3.1.0 notes recorded. Fixed in one commit; the rule for a phase that moves work off an actor: mark the constants it reads `nonisolated static let`, freeze `var`s to `let` before the closure, and re-capture `self` in every nested closure #concurrency #release
- [convention] **Before `release.sh`, run the Release archive** (`scripts/test-build.sh`, or `xcodebuild … -configuration Release ARCHS='arm64 x86_64' archive` into a scratch path). Every whole-surface round should end with it; six rounds ended with Debug only #release #process
- [gotcha] The 3.2.0 cut also hit the gate's parallel-unit red (fixed, `63408e4d`) and a one-off test-host exit (`t-28fcd354`). Three cut attempts, three different classes; none a product defect #testing
