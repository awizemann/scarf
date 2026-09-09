---
title: Hermes v0.21.1 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-21-1-compatibility-decisions
tags: [hermes, capability-gating, versioning, settings, hermes-v0-21-1]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/WebToolsBackendRoster.swift, scarf/scarf/Features/Settings/Views/Tabs/WebToolsTab.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: 238674747424f516c7b840a69371d1b0fb004fa7
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-08
reviewed_by: claude-opus-5
---
The decision record for the v0.21.1 ("v2026.9.7") parity cycle, Phases 0–7.
Tag map: v2026.7.30 = 0.20.2, v2026.8.19 = 0.20.5, v2026.8.27 = 0.20.6,
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
