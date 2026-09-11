---
title: Hermes v0.21.1 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-21-1-compatibility-decisions
tags: [hermes, capability-gating, versioning, settings, hermes-v0-21-1]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/WebToolsBackendRoster.swift, scarf/scarf/Features/Settings/Views/Tabs/WebToolsTab.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: ca6ae1e8832242f31b5c6ccdd3b390186b1af8cb
created: 2026-09-08
updated: 2026-09-11
reviewed: 2026-09-10
reviewed_by: claude-opus-5
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
- [convention] `Process.waitUntilExit(timeout:)` (`Core/Models/ProcessTimeout.swift`)
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
2. **`/steer` was a dead ACP row below v0.13.** `RichChatViewModel`'s roster gated `queue` on `hasACPQueue` and let `steer` fall through `default: return true`, on a comment saying it "works on v0.11+ during an active turn" — a CLI/TUI fact. Walked: `steer` first at **v2026.5.7** (0.13.0), `acp_adapter/server.py:170`, the line ABOVE `queue` (`:171`); `acp_adapter/` at v2026.4.30 has no `steer` anywhere. Over ACP an unknown name is not an error (`commands.py:88-95` @ v2026.9.7), so each click burned a turn. New `hasACPSteer` with the four-test pattern, and `hasACPSteerOnIdle` now EXPRESSED as it (the idle fallback shipped at the same tag, `server.py:812-820`) rather than restating the floor. **Two existing tests asserted the bug** and now assert the floor (`availableCommandsExposesSteerButHidesV013OnV012`, `SlashMenuLogicTests.availableCommandsHidesQueueOnPreV013`) — P34's exact pattern, one row late.
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
