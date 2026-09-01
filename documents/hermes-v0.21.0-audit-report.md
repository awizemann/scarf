# Hermes v0.21.0 ("Pantheon", v2026.8.31) audit vs Scarf — 2026-09-01

Scope: v2026.8.19 (0.20.5, Scarf's current target) → v2026.8.31 (0.21.0), 2,287 commits, including the intermediate v0.20.6 (v2026.8.27). Source-verified against a detached worktree of the tag; every finding cites file:line. Audit only — no code changed.

## Verdict (the two questions that decide the cycle)

1. **Did state.db schema change? Yes — but SCHEMA_VERSION is still 26.** New DDL arrives via the generic ADD-COLUMN auto-migrator, so detection must stay PRAGMA/sqlite_master-based, never version-based.
   - `messages._compressed_summary INTEGER NOT NULL DEFAULT 0` (hermes_state_common.py:475) — compaction-carrier marker.
   - New `gateway_heartbeats` table (hermes_state_common.py:523-538).
   - Bot Mode "hosted rooms" tables created **lazily** in state.db (`hosted_room_*`, ~10 tables; gateway/hosted_rooms.py:442-599, hosted_room_replicas.py, hosted_room_driver.py) — presence not implied by 0.21.0 being installed; gate on sqlite_master per table.
2. **Does anything new reach the ACP client unhandled? No.** acp_adapter delta is 2 commits / 30 lines; `_ADVERTISED_COMMANDS` byte-identical; clarify multi-question, seq-replay, bot mode, peer are all desktop-WS/CLI/gateway surfaces. Scarf's generic option/kind parsing absorbs the `allow_session` permission narrowing.

So this is **not a wire-parity emergency** — it's an additive cycle with a handful of forced fixes plus a large strategic opportunity (Bot Mode).

## Release-note claims refuted by source (law 1 strikes again)

- **`hermes approval-check` does not exist** at v2026.8.31 — zero hits anywhere in the tree. (Release notes cite #81137.)
- **"Six new providers" is really 3 new** (router/Ramp, nebius-token-factory, tencent-tokenplan); meta-ai, commandcode, actual predate v0.20.5.
- **Slack "native live cards #85476"** — no such change in this range; the Slack delta is unfurl controls + dup-turn fixes.
- `model_overrides` (#85560) and session pin/unpin (#80761) framed as new — both shipped by v0.20.5 and are already handled.

## FORCED by the upgrade (Tier 1)

1. **Dead config block: `auxiliary.web_extract.*` removed from Hermes** — Scarf still renders a Web Extract auxiliary row and writes 7 dead keys. Remove/gate the row (AuxiliaryTab.swift:33,370; SettingsViewModel.swift:477-499; HermesConfig+YAML.swift:189; HealthViewModel.swift:261). Companion: new `browser.snapshot_threshold`.
2. **`tavily` search/extract backend removed entirely** — Scarf's WebToolsTab pickers still offer it and would write an unknown backend (WebToolsTab.swift:26,38,44). `status` row renamed Tavily→Keenable (generic parse absorbs it).
3. **`agent.gateway_turn_lease_timeout` default 1800 → 5 s** — Scarf's parse default (1800) and stepper floor (60) can neither display nor set the new default (HermesConfig+YAML.swift:482, AgentTab.swift:55).
4. **`curator pin/unpin` exit-code change** — ineligible skills now exit 1 (Scarf's ensureSuccess throws with no friendly message); eligible-but-unmanaged pins exit 0 with an "unmanaged — run adopt" stdout note (CuratorService.swift:91-99). Also: `PROTECTED_BUILTIN_SKILLS` is now empty; `curator status` rows can include pinned-but-unmanaged skills.
5. **Offline `--version` emits no update line at all** (banner.py:344-380) — Health should treat "no line" as unknown, not up-to-date (HealthViewModel.swift:176,349).
6. **Config migration v39 retires the `bfl` toolset** — drop from any toolset picker sourced from cached lists (config_migrations.py:830-865). Also `_migrate_to_15` deleted: `display.interim_assistant_messages` absent-on-disk no longer implies false.
7. **MCP catalog snapshot 69% stale** — 20 → 65 entries, and Scarf prefills the **dead Atlassian `/v1/sse` URL** (404 since 2026-06-30; new URL `https://mcp.atlassian.com/v1/mcp/authv2`). New manifest key `tools.default_excluded` (25 entries) — Scarf's model already has toolsExclude; only the snapshot needs regenerating (OptionalMCPCatalog.swift:73-214).
8. **Session preview drift** — Hermes previews now exclude compaction-carrier rows and strip summary prefixes; Scarf's naive `substr(MIN(id) WHERE role='user')` shows summary boilerplate on compacted sessions and has no active/compacted filter (HermesDataService.swift:903-912 vs hermes_state_common.py:79-166).
9. **Cron jobs.json loader liberalization** — Hermes now accepts an ID-keyed map and bare `repeat` values; Scarf decodes `jobs` as array-only and can fail on a not-yet-normalized file (HermesCronJob.swift:487-504). Also: activating terminal (completed/error) jobs now raises; monitor-mode fields (`monitor_script/url/state`, `provider_snapshot`) pass through Scarf's `extra` safely.
10. **Provider tables — check-hermes-tables.py: 3 FAILs** — add `tencent-tokenplan` + `nebius-token-factory` to overlayOnlyProviders (+ 7 aliases: nebius, nebius-tf, nebius-tokenfactory, token-factory, tokenfactory, tokenplan, tencent-lkeap) and display names. Neither is an aggregator; aggregator set unchanged.
11. **Skills roster/semantics** — bundled roster 82→58 (github/ collapsed to software-development/github, mlops/ and smart-home/ gone, web/ added): dynamic scan copes, but tests/docs asserting categories break. `hermes-agent` is now an ESSENTIAL skill: a Scarf disable toggle on it is a silent no-op — hide or annotate it.

## PRE-EXISTING bugs surfaced (not upgrade-caused)

- **`gateway status` markers never match**: `"service is loaded"` exists only as a code comment; `"stale"` matches by accident (GatewayViewModel.swift:124-125). Real markers: `✓ Gateway is running (PID: …)` / `✗ Gateway is not running` / `(Running manually…)`.
- **Update-badge misses 2 of 3 shapes**: singular `1 commit behind` and count-less `Update available — run …` never match `.contains("commits behind")` (HealthViewModel.swift:176). Match `"Update available"` instead.
- **Dotted quick-command names corrupt config**: `quick_commands.v1.2_deploy.type` splits into nested maps (QuickCommandsViewModel.swift:75-77). 0.21.0 adds the fix mechanism: escape `.` as `\.` in interpolated key segments (new greedy-literal matching + phantom-sibling hard error — surface that error's output in Settings save failures too).
- **Dead read**: `agent.runtime_metadata_footer` exists in no Hermes version Scarf targets (HermesConfig+YAML.swift).
- **ACP `plan` and `usage_update` session_update discriminators unhandled** (fall to `.unknown`; both shipped v0.18-era). Feature-coverage decision, not a regression. `usage_update` in particular could power a live context/token display Scarf lacks.

## ADOPT candidates (additive, capability-gated at v0.21)

- **`hermes peer run/status/stop`** — async bot-to-bot runs with idempotency keys; full argparse + JSON output shapes captured in the CLI agent findings. Natural "Peers" surface; registry readable from config.yaml `bot_peers`.
- **`cron incidents` (list/ack) + `cron doctor`** — durable failure incidents live in a new `cron_incidents` table in cron/executions.db; doctor pairs with Health. `cron resume --run-now/--at` = "Trigger now". `--deliver bot-chat[:profile]` new delivery target.
- **Gateway control socket** (gateway/control_socket.py) — line-JSON `identify`/`status` over a UNIX socket: pid, profile, supervisor, code_sha, served_profiles. Strictly better liveness than parsing `gateway list`; needs a socket client (SSH helper for remote).
- **New settings surfaces** (each optional): `display.status_bar.fields`, `auxiliary.review.*` (new /review aux task), `approvals.unattended_mode`, `voice.client_direct` (relevant to Scarf remote voice), `browser.use_real_profile`/`extension_control` (security-sensitive; `hermes browser close-profile` is destructive — confirm-gated only), `web.cache_*`, `database.synchronous`, `delegation.request_overrides`, `compression.checkpoint_required` (careful: refuses codex_app_server api_mode — don't offer without gating), loop-watchdog knobs, `bot_mode.*`, `gateway.room_link_url`.
- **`gui --setup-tcc-identity`** — macOS TCC grants surviving Hermes updates; a good Health/doctor hint.
- **`kanban boards export/import`**; `sessions` title-uniqueness note: canonical "Bot Chat" sessions refuse rename server-side — Scarf's inline rename should handle the error.
- **Trap noted**: any future `hermes chat -q` shellout on a TTY now seeds an interactive session — must add `chat --oneshot`. No current Scarf site affected.

## BOT MODE — architecture findings and the Scarf decision

**What it actually is:** a ~36k-LOC bundled *Electron desktop plugin* over mostly pre-existing, client-agnostic backend primitives. A bot **is** a profile. Identity (name/color/shape/groups/hidden/pinned/avatar) lives in `profile.yaml` → `ui_meta['hermes-bots']` (64KB cap, per-key CAS via `profiles.configure`). The canonical **Bot Chat** is an ordinary hidden session uniquely titled `Bot Chat` (unique title index); the bot-mode protocol prompt injects only for such sessions (system_prompt.py:737-747, default-on `agent.bot_mode_protocol` but inert until any profile is bot-managed). Avatars: `blobatar@2.0.0` (external npm — byte-identical faces would need a Swift port; rasterized `assets/avatar.png` is readable when Desktop has backfilled it; legacy geometric fallback is a trivially portable hash).

**Message flows:**
- Bot-to-bot DM = a documented CLI shellout Scarf can issue verbatim: `hermes -p <name> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file <tmp>`; attribution prefix applied server-side; messages land as ordinary rows in the target profile's state.db.
- **Group rooms are 100% client-orchestrated** (rounds, @-routing, pass detection all in the Electron plugin; member turns are hidden sessions titled `Group: <roomId>`; only a 16-message bounded mirror is shared via ui_meta). Scarf joining an existing room as a peer client = becoming a second orchestrator = double-run turns. Separately, the server grew a *different*, lazily-created `hosted_room_*` subsystem in state.db (gateway/hosted_rooms.py + `gateway.room_link_url`) for cross-gateway rooms — relationship between the two room systems should be verified before Scarf touches rooms at all.
- Cross-machine: `hermes peer` (REST against the peer's api_server; no desktop needed) or a file-based relay (`~/.hermes/bot_relay/`) whose courier role is 4 ordinary gateway RPCs.

**Recommendation — build it, scoped:**
- **Phase A (high fidelity, cheap):** a "Bots" top-level section above Chat. Roster from `profiles.list` ui_meta (+ display_name/description from profile.yaml), avatar.png when present else Scarf-native faces, canonical Bot Chat per bot (title+include_hidden query — Scarf already reads state.db and drives ACP per profile), bot-to-bot DM via the documented CLI, routines via existing cron surfaces with the `[bot:<name>]` namespace, `hermes peer` list/dm/run for remote bots. All feature-detected (sessions.hidden column + ui_meta presence), gated `isV021OrLater` for the new verbs.
- **Phase B (defer / separate decision):** group rooms (a client-side round engine Scarf would own outright — doable since it's only session.create/resume + title conventions, but it is a real orchestrator with caps, pass-detection, and mirror-sync semantics), relay courier role, blobatar port.
- **Scarf's edge:** Alan's instinct about project structure is right — Scarf's multi-window, one-server-per-window architecture plus native profile handling means a Bots section can be a first-class sidebar peer of Chat/Sessions rather than a plugin bolted on. And Scarf reads the same stores, so bots created in Hermes Desktop appear in Scarf automatically (interop, not lock-in).

## Suggested phasing

- **Phase 1 (parity, ship as v2.23.0):** Tier-1 forced fixes 1–11 + `isV021OrLater` flag group + capability tests + check-hermes-tables green + MCP catalog regen.
- **Phase 2 (quick wins):** pre-existing bug fixes (gateway status markers, update-line matching, dotted-key escaping), cron incidents/doctor, preview parity.
- **Phase 3 (Bot Mode Phase A):** own branch, own design pass against `design/` tier.
- Charter: proposed separately (documents/scarf-charter-draft.md) — establishes identity/commandments before Bot Mode expands the app's scope.
