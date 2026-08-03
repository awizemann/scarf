# Hermes v0.20.0 (v2026.8.3) Release Audit — Findings & Plan

Audited 2026-08-03 against Scarf v2.17.2 (main @ 3d89290). Baseline: Hermes v0.18.2 (v2026.7.7.2) —
this delta spans v0.19.0 (v2026.7.20), v0.19.1 (v2026.7.30), and v0.20.0: ~5,719 commits.
Method: 8 parallel per-surface read-only agents against a detached worktree at the tag
(`~/.hermes/hermes-agent-v0.20.0-audit`), with the v2026.8.3 argparse executed live for the CLI pass.

## Verdict (the two deciding questions)

- **state.db schema changed?** SCHEMA_VERSION 19 → 25, but **zero columns Scarf queries changed** —
  everything is additive (new messages cols `effect_disposition/api_content/display_kind/display_metadata`;
  new sessions cols incl. `pinned`, `last_activity_*`, `profile_name`; new tables `system_prompts`,
  `session_model_usage`, `async_delegations`, `delivery_obligations`). New external-content FTS layout
  on fresh DBs is compatible with Scarf's search JOIN in both shapes (rowid == messages.id in both).
  NOTE for the next audit: DDL moved from `hermes_state.py` → `hermes_state_common.py`.
- **Anything new reaching the ACP client unhandled?** **No.** Method and session_update discriminator
  rosters are identical across the delta; Scarf's `.unknown` fallback covers the rest.

→ **Moderate additive cycle** with a short list of forced fixes; not a parity push.

## A. Upgrade-forced (0.20 regressions if unfixed)

1. **`/compact` → `/compress` rename (ACP).** Hermes acp_adapter/server.py dropped the `compact`
   handler; unknown slash commands fall through to the LLM. Scarf hardcodes `compact` at
   RichChatViewModel.swift:457 and :1063 (`sessionRequiredCommandNames`). Capability-gate the rename
   (`isV020OrLater`). Confidence: high.
2. **Curator status header renamed** `agent-created skills:` → `curator-managed skills: N total
   (agent-created=X bundled=Y)` (+ empty sentinel `no curator-managed skills`) — Scarf's parser at
   HermesCuratorReport.swift:226 reports totalSkills=0 on 0.20 hosts. Accept both prefixes.
   Tests: HermesCuratorParserTests.swift:20,73,106. High.
3. **Provider tables — check-hermes-tables.py exits 1 (4 FAILs):**
   - `providerAliases` (ModelCatalogService.swift:884): add `ai-gateway`/`aigateway`/`vercel-ai-gateway` → `vercel`;
     `fireworks-ai`/`fw` → `fireworks`; `solar` → `upstage`.
   - `ModelPreflight.aggregatorProviders` (:103): add `vercel`.
   - `overlayOnlyProviders` (:729): add `fireworks` (api-key, api.fireworks.ai) and `vertex`
     (OAuth2 SA/ADC — needs authType mapping; fix the stale "models.dev-backed" comment at :761).
   - `modelAliases` (:642): add `deepseek/deepseek-chat` and `deepseek/deepseek-reasoner` → `deepseek-v4-flash`
     (retired 2026-07-24, wire-remapped upstream).
   - Stale comments: "Vercel AI Gateway was deleted" at :648 and :690.
   - Release-note claim "kimi-k2.x retired" is an overstatement — no wire remap; NO alias needed.
4. **Platform roster:** add `buzz` (Nostr; user-gated via `allowed_users`, NO GatewayAllowlistKind
   mapping) to KnownPlatforms (HermesTool.swift:42). Decide whether to list `a2a` (infrastructure).
5. **`agent.max_turns` default 60 → 500** — update UI default/placeholder text (SettingsViewModel.swift:196).

## B. Pre-existing bugs found in the sweep (not caused by 0.20)

1. **Skills uninstall/update always broken:** `skills uninstall --yes` / `skills update --yes` —
   flag never existed; argparse exit 2 at both tags. SkillsViewModel.swift:473 and :503 (at :503 the
   `--yes` also displaces the optional name positional). Fix: drop `--yes`. High (executed argparse).
2. **`agent.runtime_metadata_footer` is a silent no-op** — key never existed in Hermes; real key is
   `display.runtime_footer.enabled` (nested block with `fields:`). AdvancedTab.swift:182,
   HermesConfig+YAML.swift:392, HermesConfig.swift:899. High.
3. **Google Chat platform id + allowlist doubly dead:** Hermes id is `google_chat` (underscore);
   adapter gates users via GOOGLE_CHAT_ALLOWED_USERS and never reads `allowed_channels`.
   HermesTool.swift:73, GatewayAllowlistKind.swift:78. High.
4. **`microsoft-teams` id mismatch** — Hermes id is `teams`. HermesTool.swift:62. High.
5. **`busy_ack_enabled` per-platform write is a no-op** — Hermes reads global
   `display.busy_ack_enabled` only (per-platform granularity is `display.platforms.<p>.busy_ack_detail`).
   GatewayBehaviorViewModel.swift:113-116. High.
6. **`slash_command_notice_ttl_seconds` doesn't exist in Hermes** at either tag.
   GatewayBehaviorViewModel.swift:126. High.

## C. Our upstream PRs — status at v2026.8.3

- **#64146 (aux payment-error mislabel): still needed.** Absent-credential paths still log
  "(payment / credit error)" via `_mark_provider_unhealthy` (auxiliary_client.py:2498/2544/2479);
  no reason parameter added. Keep the PR open; consider a rebase ping.
- **#45958 (ACP --toolsets / per-session tool scoping): still needed.** `_expand_acp_enabled_toolsets`
  unchanged; entry.py has no --toolsets. New adjacent knob: env `HERMES_ACP_SKIP_CONFIGURED_MCP=1`
  (skips global MCP discovery — useful for Scarf's metadata-only helper sessions).
- #23208 (kanban ACP session stamping): closed unmerged upstream; no change.

## D. Adoption candidates (gated adds — pick for scope)

**High value / low cost**
- `sessions.pinned` + `last_activity_at/description` in sidebar (schema-detect).
- Sessions export formats: `--format {md,html,qmd,trace}` (+ `--redact`) — export UI is JSONL-only today.
- `hermes approvals suggest --json` → allowlist proposals surface (Settings/Health).
- `hermes config get --json` as a cleaner config read path than file parsing.
- `hermes cron runs [job_id]` — per-job execution history in Cron tab; cron blueprints catalog later.
- Curator `adopt` / `list-unmanaged` + unmanaged count (gate `hasCuratorAdopt`).
- MCP `lazy` connect key toggle (gate `hasMCPLazyConnect`); `tools.include/exclude` glob help text.
- ACP `_meta.hermes.compactionSummary` → collapse/style replayed compaction summaries.
- `session_model_usage` table → per-model cost breakdown on Dashboard.

**Settings key surfaces (new in 0.19/0.20)**
- Compression: `threshold_tokens`, `model_thresholds`, `min_tail_user_messages`, `max_attempts`,
  `idle_compact_after_seconds`, proactive-prune trio, `progress_notices`.
- `agent.reasoning_overrides` (per-model dict — NOT settable via `hermes config set`; needs direct-YAML writer).
- `approvals.smart_policy`; `excluded_providers`; `auxiliary.title_generation` block + per-task `reasoning_effort`.
- STT: `stt.language` (+ per-provider); TTS: `tts.speed`, expanded `tts.xai.*`, `tts.deepinfra.*`.
- `secrets.bitwarden.encrypted_cache.*`, `secrets.command.*`; `telemetry.shared_metrics.enabled`;
  `database.journal_mode`/WAL knobs (advanced, for remote servers); `gateway.profile_routes` editor.
- `hermes import-agent` (onboarding) and `hermes sync` (skills sync) — bigger features, later.

## E. Awareness / no-ops (don't re-litigate)

- Delivery-obligation ledger real but gateway-internal (`delivery_obligations`, created lazily outside
  SCHEMA_SQL). Scarf never touches it.
- Completed one-shot cron jobs now retained (`state:"completed"`, enabled=false) — they'll appear in
  Scarf's cron list; icon mapping already exists; retention sweep prunes them.
- Mid-turn redirects landed in ACP: a plain prompt mid-turn now redirects the active turn instead of
  queueing. Scarf routes mid-turn input via explicit /steer//queue — verify composer never sends a
  bare prompt mid-turn (queuedPrompts mirror would desync). Medium.
- ACP model list now "Provider · model" names + much longer inventory — check picker doesn't
  double-prefix provider labels.
- /subscription, /topup, `!` shell, /init, /diff, /context, /focus, voice, artifacts, plugin SDK:
  ZERO ACP exposure (grep-verified). Do not build client UI for them.
- Smart approvals reach ACP only as a reduced permission-option set — parsed generically, renders fine.
- FTS sanitizer upstream now caps input at 2,048 chars — optional parity in sanitizeFTSQuery.
- Cron jobs.json: no new persisted fields; `latest_execution` is API-output-only, never in the file.
- managed_scope.py: zero diff. All ~30 security commits in the delta: server-side no-ops for Scarf.
- `postinstall` subcommand and `hermes_cli/memory_providers.py` deleted — Scarf never used either.

## Proposed scope (for green-light)

- **Phase 1 — forced fixes + pre-existing bugs (A + B):** capability group `v0.20 (v2026.8.3)` with
  `isV020OrLater`, /compress gating, curator header, provider tables to check-script exit 0, buzz
  roster, max_turns text; plus the six pre-existing fixes (skills --yes, runtime footer key,
  google_chat/teams ids, busy_ack path, TTL key removal). Capability tests mirroring the v0.18 cluster.
- **Phase 2 — high-value adds:** pinned/last-activity sidebar, export formats, approvals suggest,
  cron runs, curator adopt, compaction-summary styling.
- **Phase 3 — settings key surfaces** as a follow-on cycle.

Upgrade the local Hermes install to 0.20.0 before Phase 1 verification so live probes run against the target.
