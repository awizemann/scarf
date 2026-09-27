# Scarf ↔ Hermes v0.21.5 — whole-app audit (ranked)

Date: 2026-09-26 · Task: t-8565a7f4 · Scarf main @ ec82be9e (3.4.0) · Hermes reference: tag `v2026.9.24` (0.21.5), read-only worktree `~/.hermes/hermes-agent-v0215`.
Evidence: per-section reports, verifier verdicts and agent briefs in `documents/audits/hermes-v0.21.5-full-app-audit/`.

## Verdict

No section is broken end to end. The everyday paths — chat over ACP, sessions/search reads, settings writes, cron, gateway control, skills/plugins CLI, projects, templates catalog install — work against 0.21.5. But the audit found **2 P0, 12 P1, 40 P2, 18 P3** real defects, almost all pre-existing (not caused by the 0.21.x upgrades) and none previously tracked. That confirms the premise: release-diff audits never re-read these paths.

- **P0 (2):** both in MCP. Editing a server can invert its tool blocklist into an allowlist of exactly the blocked tools; no OAuth MCP server (54 of 64 catalog entries) can be added at all.
- **P1 (12):** default bot can't chat; every Nous user sees a false "chats will fail" banner whose fix breaks their config; skills installed flat/deep are invisible; "reasoning off" doesn't turn reasoning off; Run Now fires every other overdue job; Server Backup writes to state.db (charter C3) and Restore can corrupt it; remote hosts saved without Test Connection can't run any CLI verb; remote default-profile windows write into another profile; built-in skills refuse to load on Linux; WhatsApp Cloud save disables a working adapter; Dashboard's `.hermes/` "shadowing" banner is false and its fix breaks project config.

Verification: every P0/P1 (and 7 escalation candidates) went to an independent verifier that tried to disprove it. 0 were refuted; 4 were raised (S08-F1, S11-F1, S14-F2 → P1; S01-F1 merged into S13-F2); S07-F4 and S12-F1 are borderline P1. **P2/P3 were not adversarially verified** — they are source-cited by the section auditor only.

## Section verdicts

| # | Section | Verdict | P0 | P1 | P2 | P3 |
|---|---|---|---|---|---|---|
| S01 | Chat transport (ACP lifecycle) | Works w/ issues | – | – | 1 | – |
| S02 | Chat events (RichChatViewModel) | Works w/ issues | – | – | 3 | 1 |
| S03 | Chat surfaces (slash, voice, personalities) | Works w/ issues | – | – | 4 | 2 |
| S04 | Sessions, search, dashboard data | Works w/ issues | – | – | 3 | 1 |
| S05 | Config engine + Settings | Works w/ issues | – | 1 | 1 | – |
| S06 | Models, providers, credentials | Works w/ issues | – | 1 | 2 | 4 |
| S07 | Gateway, platforms, webhooks | Works w/ issues | – | 1 | 4 | – |
| S08 | Cron | Works w/ issues | – | 1 | 1 | 1 |
| S09 | MCP | **Broken (2 P0)** | 2 | – | 2 | 2 |
| S10 | Skills, plugins, curator, tools | Works w/ issues | – | 2 | 2 | 1 |
| S11 | Projects core | Works w/ issues | – | 1 | 2 | 2 |
| S12 | Templates, projects MCP, mini-apps | Works w/ issues | – | – | 5 | 1 |
| S13 | Kanban, bots, peers, profiles | Works w/ issues | – | 2 | 3 | 1 |
| S14 | Health, logs, memory, backup | Works w/ issues | – | 2 | 4 | 1 |
| S15 | Servers, transport, iOS deltas | Works w/ issues | – | 1 | 3 | 1 |

Confirmed working (highlights): every state.db column/table Scarf queries exists with the assumed meaning, and state.db is opened read-only on both backends; all 245 config keys Scarf writes pass Hermes's own validator (2 exceptions below); every CLI argv in cron, skills, plugins, curator, auth, profiles, kanban, peers, sessions, backup matches the tagged argparse; exit-0-on-failure paths are judged by output everywhere except the ones listed; ACP initialize/new/load/prompt/cancel/set_mode/set_model/permission all match; the provider-table gate `check-hermes-tables.py --tag v2026.9.24` is `lanes=5/5`.

## P0

**S09-F1 · MCP tool blocklist inverts into an allowlist on the second save.**
Scarf's writer always emits `include:` (bare when empty) before `exclude:`/`resources:`/`prompts:` (`HermesFileService.swift:2273-2280`); the parser never leaves the `tools.include` state (`:1451-1468`), so excluded tools read back as included and `resources/prompts: false` read back as true. The editor seeds from that misread and always rewrites (`MCPServerEditorViewModel.swift:67-70, 433-439`), so the next save writes `include: [the blocked tools]`, which Hermes treats as a whitelist (`tools/mcp_tool_registration.py:209-225`). Catalog installs with `default_excluded` hit it on first edit (`MCPServersViewModel.swift:377-391`). No test round-trips through Scarf's own parser. Repro: `include:` / `exclude: [delete_repo]` / `resources: false` → reads `include=[delete_repo], resources=true`.

**S09-F2 · No OAuth MCP server can be added.**
`mcp add NAME --url U --auth oauth` is run with stdin as a pipe fed `"\n\n"` and no PTY (`HermesMCPAdd.swift` `.oauth` arm; `HermesFileService.swift:447-448, 580-667`). Hermes refuses to build an OAuth provider when stdin isn't a TTY (`tools/mcp_oauth.py:311-339`, `tools/mcp_oauth_manager.py:316-319`), drops `auth: oauth`, the unauthenticated probe fails and "Save anyway?" defaults to No (`hermes_cli/mcp_config.py:544-561, 666-676`) → "Add failed". Affects custom OAuth, the Linear preset, 54/64 catalog entries, local and remote. If the server allows unauthenticated tools/list it is saved *without* auth and reported "Added". Fix: catalog → `hermes mcp install <id>` (writes auth + vendor oauth block first, tolerates probe failure: `hermes_cli/mcp_catalog.py:523-528, 620-645`); custom/preset → write YAML then `mcp login`.

## P1 (ordered by reach)

| ID | Defect | Scarf | Hermes @tag | Notes |
|---|---|---|---|---|
| S13-F2 | Default bot can never chat: `createCanonicalBotChat` rejects "default" via `HermesProfileScope.normalize` → first send (and every CLI-born bot chat send) fails; ACP launch has no `-p default` | `BotConversationViewModel.swift:419-501`, `ACPClient+Mac.swift:59-62` | `hermes_cli/main.py:613-622`, `profiles.py:2366-2368` | Every setup, incl. single-profile. S01-F1 merged here. |
| S06-F1 | False "Chats will fail at first prompt" banner for every Nous user with a vendor-prefixed model (which Scarf's own picker writes); "Use anthropic" moves provider off Nous | `ModelPreflight.swift:116-119, 164-187`; `ModelPickerSheet.swift:1302-1325` | `hermes_cli/model_normalize.py:30-32`, `agent/agent_init.py:460-462` | Decision note "[kept]" bullet wrong since written; `ModelPreflightTests.swift:142-157` pins it; table-check lane uses wrong source (`providers.py is_aggregator`). "Strip prefix" option may also be harmful. |
| S10-F1 | Skills scanner walks exactly 2 levels, never checks SKILL.md → flat (hub non-official, URL) and depth-3 (official nested) installs invisible or shown as fake skills | `SkillsScanner.swift:28-86`; feeds Skills tab, cron skill picker, template exporter | `agent/skill_utils.py:783-800`, `skills_hub.py:700-706` | Your machine: 25 flat + 16 depth-3 skills. |
| S05-F2 | Reasoning effort "none" → `config set … none` → Hermes coerces to null → provider default; UI says Saved | `SettingsViewModel.swift:708`, `HermesCLIOutcome.swift:1514-1516` | `hermes_cli/config.py:3240-3259`, `hermes_constants.py:1316, 1415-1438` | Since Hermes commit 5d4b97939e (v2026.9.7+). Reproduced. Fix: send `false`. |
| S08-F1 | Run Now always follows with `cron tick` (300 s cap), which fires every due/overdue job (deliveries included) and kills them at 300 s | `CronViewModel.swift:902-916` | `cron/scheduler_tick.py:88-116`, `cron/jobs.py:2789-2798` | Raised from P2. Tick only needed pre-v0.18 (no `Ran now:` line). |
| S14-F2 | Server Backup runs `sqlite3 state.db 'PRAGMA wal_checkpoint(TRUNCATE)' || true` — a write to state.db (charter C3); flag always true; WAL excluded so recent sessions can be missing | `RemoteBackupService.swift:231-243, 320, 424` | `backup.py:101-104` (uses `sqlite3.backup()`) | Raised from P2; same class as t-00ade623. |
| S14-F1 | Server Restore untars over live state.db; no gateway check, leftover `-wal/-shm` kept → malformed DB / lost sessions; says "Restore complete" | `RemoteRestoreService.swift:234-333, 351` | `backup.py:536-559, 854-866` | Safe on a fresh droplet (its main use). |
| S11-F1 | Dashboard "project-local Hermes home shadowing" banner is false (Hermes never used `<cwd>/.hermes` as home, at any commit); fires on any project `.hermes/` dir; its fix renames away project skills/plugins/verify manifest and may copy a stray project auth.json to global | `ProjectHermesShadowDetector.swift:6-18, 71-102, 146-177`; `DashboardView.swift:140-222` | `hermes_constants.py:53-59, 112-119`; `agent/skill_utils.py:431-437` | Raised from P2. Recommend deleting the detector. |
| S15-F1 | SSH server saved without Test Connection has no binary hint → every one-shot CLI call runs bare `hermes` in non-login `sh -c` → exit 127 on non-root `~/.local/bin` installs; chat works (login shell), confusing | `AddServerViewModel.swift:71-73, 124-128`; `SSHTransport.swift:658-691`; `HermesPathSet.swift:155` | install.sh ~2272-2313 | Save is the default button; no later fill; no edit-server UI (t-edit-srv). |
| S13-F1 | Remote window viewing default profile reads root `~/.hermes` but every hermes subprocess follows host's sticky `active_profile` → shows default's data, writes into another profile | `HermesProfileScope.swift:161-164`; `SSHTransport.swift:658-668`; `CitadelServerTransport:814` | `hermes_cli/main.py:603-622` | Scarf's own "Set as server's active profile" creates the state. `HERMES_HOME=<root>` does NOT fix it; only `-p default`. |
| S10-F5 | Built-in `scarf-template-author` / `scarf-miniapp-author` declare `platforms: [macos]` but are pushed to remote hosts → Linux Hermes hides and refuses them; New Project handoff names the skill | `BuiltinSkills.bundle/*/SKILL.md:7`; `NewProjectViewModel.swift:168, 203-207`; `AppCoordinator.swift:284` | `tools/skills_tool.py:207, 604-605` | |
| S07-F3 | WhatsApp Cloud form ignores `.env` (where Hermes's own wizard stores creds) → opens blank; saving without retyping token writes `enabled: false`, disabling a working adapter | `WhatsAppCloudSetupViewModel.swift:56, 92-104` | `gateway/config_env.py:194-206, 523-533`; `setup_whatsapp_cloud.py:146-150, 285` | Decision note premise stale. |

**Shared root cause (S13-F1, S13-F2, S01-F1):** `HermesProfileScope.normalize("default") == nil` is read as "root, no pin needed", but Hermes without `-p` follows `active_profile`. Fix once: move `BotAgentConfigService.profileFlag` (already correct, `BotAgentConfigService.swift:112-118`) into `HermesProfileScope` and use it at bot-chat creation, `acpArguments`, and the two remote transports.

## P2 (auditor-rated; not adversarially verified unless marked ✓)

| ID | Defect | Scarf |
|---|---|---|
| S07-F4 ✓ | Webhook setup writes only `WEBHOOK_ENABLED` (.env); every `hermes webhook` verb gates on config `platforms.webhook.enabled` → Webhooks tab can't be unlocked from Scarf (borderline P1; upstream has same gap) | `WebhookSetupViewModel.swift:48-54` |
| S12-F1 ✓ | Installer accepts only schemaVersion 1/2; exporter + author skill emit 3 when slash commands exist → slash-command templates uninstallable since v2.5 (P1 if a v3 template reaches the catalog) | `ProjectTemplateService.swift:66`; `ProjectTemplateExporter.swift:241-245` |
| S12-F6 ✓ | Mini-app agent session cwd = project root; Hermes builds the prompt from session cwd → project AGENTS.md/CLAUDE.md injected into the untrusted mini-app agent (documented trust boundary broken) | `MiniAppAgentSession.swift:14-36, 191` |
| S07-F1 ✓ | `PlatformState` decodes `connected`/`error`; Hermes writes `state`/`error_message` → Platforms/Tools status dots never Connected/Error (confirmed on live file) | `HermesConfig.swift:2280-2289` |
| S15-F2 ✓ | Gateway pgrep regex misses `--profile <name>` gateways → "Stopped" while running; also not profile-filtered | `HermesFileService.swift:2471-2476` |
| S14-F5 ✓ | Local memory save shares Hermes's `MEMORY.md.lock` path with an incompatible protocol → deletes Hermes's lock; spurious "Another Scarf process…" refusals; rare lost-entry race | `RegistryWriteLock.swift:187, 329, 358-370` |
| S04-F1 | Session lists/stats lack `archived = 0` and `_delegate_from IS NULL` → archived sessions and orphan subagents shown | `HermesDataService.swift:339-354` |
| S04-F2 | Dashboard/Insights totals exclude delegate-subagent (and rotated) sessions → spend under-reported vs `hermes insights` | `HermesDataService.swift:1714-1733, 2030-2060`; `InsightsViewModel.swift:190-198` |
| S04-F3 | Rotated compression chains (`compression.in_place: false`) open only the pre-compression transcript | `SessionsViewModel.swift:438-442` |
| S01-F2 | iOS stall detector reconnects after 75 s silence even while a permission prompt is pending or a long tool runs → kills the turn | `Scarf iOS/Chat/ChatView.swift:2534, 2550-2571` |
| S02-F1 | Local user bubble matched to state.db by exact text → duplicates/orphans for `/scarf-*`, image prompts, `/queue`, ACP slash commands | `RichChatViewModel.swift:2873-2876, 3018-3036` |
| S02-F2 | Live tool cards show `{}` args for built-in tools (Hermes sends `rawInput` only for unknown tools); consecutive calls collapse to "×N" | `ACPMessages.swift:290-309`; `RichChatViewModel.swift:285-294, 2359-2365` |
| S02-F3 | Send after connection loss echoes before `session/load` → Hermes history replay renders as new content | `ChatViewModel.swift:1160-1240` |
| S03-F1 | Quick commands offered in chat slash menu never run over ACP; literal `/name` sent as prompt | `RichChatViewModel.swift:1003, 2224-2241` |
| S03-F2 | Active Personality (`display.personality`) has no effect in ACP chats | `PersonalitiesViewModel.swift:110-126` |
| S03-F3 | YOLO chip checks `approvals.mode == "yolo"` (invalid) → never shows when approvals are `off`; help points to `/yolo` (not ACP) | `SessionInfoBar.swift:197, 207` |
| S03-F4 | Chat sidebar rename spawns `sessions rename` on the main actor (C10) | `ChatViewModel.swift:2711-2726` |
| S05-F1 | Auxiliary "Session Search" row edits `auxiliary.session_search.*`, dropped by Hermes in v2026.5.28 | `AuxiliaryTab.swift:61` |
| S06-F2 | llama.cpp option writes `model.base_url`, which Hermes's llamacpp path ignores | `LocalModelProviders.swift:149-160` |
| S06-F3 | Named profiles: Credential Pools/Nous read only profile `auth.json`; Hermes falls back to root → inherited creds shown absent | `CredentialPoolsViewModel.swift:114`; `NousSubscriptionService.swift:69-99` |
| S07-F2 | Multiplexer-served named profiles: platform states live in root `gateway_state.json` under `<profile>:<platform>` → empty list | `HermesPathSet.swift:73`; `GatewayViewModel.swift:276-300` |
| S07-F5 | iOS webhook list parser expects non-indented names; real output indented → always "Couldn't parse" | `Scarf iOS/Webhooks/WebhooksView.swift:127-172` |
| S08-F2 | Project cron widget badges raw `enabled` → paused/completed jobs show "DISABLED" | `CronStatusWidgetView.swift` `stateBadge` |
| S09-F3 | `connect_timeout` stored as float reads as absent; next editor save deletes it | `HermesFileService.swift:1063-1075, 1248-1249` |
| S09-F4 | Remote MCP login defaults to browser flow, which needs a pasted redirect URL; no stdin → can't finish | `MCPLoginSheet.swift:45`; `MCPLoginController.swift:147-158` |
| S10-F2 | iOS skill uninstall sends `category/name`; Hermes wants bare name → always refused (Mac fixed in t-ec6d2e6d) | `Scarf iOS/Skills/Installed/SkillDetailView.swift:283` |
| S10-F4 | iOS Plugins decides enabled from a `.disabled` file Hermes never writes → everything "Enabled" | `Scarf iOS/Plugins/PluginsView.swift:85-104` |
| S11-F2 | Unarchive resumes every project cron job, incl. ones paused before archive and template jobs created paused; archive pause failures dropped | `ProjectsViewModel.swift:650-671`; `ProjectLifecycleService.swift:137-186` |
| S11-F3 | iOS never applies a project's model preset, but shows "Model: <preset>" and tells the agent it was applied | `Scarf iOS/Chat/ChatView.swift:2919-3050`; `ProjectDetailView.swift:78-82` |
| S12-F2 | Remote project export silently drops config schema (reads manifest from Mac disk, not transport) | `ProjectTemplateExporter.swift:311-321` |
| S12-F3 | Template MEMORY.md block appended without Hermes's `\n§\n` delimiter → merges into user's last entry | `ProjectTemplateService.swift:290-298` |
| S12-F4 | Template uninstall reports success when `cron remove` fails; unreadable cron list files every job as "already gone" | `ProjectTemplateUninstaller.swift:151-163, 470-479` |
| S13-F3 | Remote named-profile window marks the viewed profile "active" (Hermes derives it from HERMES_HOME) → "Set as active" disabled for it | `ProfilesViewModel.swift:42-55, 380-386` |
| S13-F4 | ScarfGo profile parser takes first word → display-named profiles (every Scarf bot) dropped or mis-ided; failed list = empty | `Scarf iOS/Profiles/ProfilesView.swift:204-232` |
| S13-F5 | Kanban "Enable now" refuses on configs without `platform_toolsets.cli` (fresh profiles); message names wrong config path; detector over-reports | `KanbanToolsetEnabler.swift`, `KanbanToolsetDetector.swift` |
| S14-F3 | Restore always targets SSH user's `$HOME/.hermes`, ignores configured remote home | `RemoteRestoreService.swift:246-248, 702, 754` |
| S14-F4 | Health Status tab misparses `hermes status`: `✗` values counted as passing; `_row` sections empty | `HealthViewModel.swift:666-735` |
| S14-F6 | Remote Logs pane shows last 200 lines twice | `HermesLogService.swift:97-100, 144-153` |
| S15-F3 | "Hermes binary" override breaks for multi-word wrappers (quoted as one name); Test Connection loses the hint | `SSHTransport.swift:669-670`; `TestConnectionProbe.swift:106-117, 225-227` |
| S15-F4 | "No AI provider credentials" banner false for providers Scarf doesn't list (DeepSeek, Kimi, ZAI, MiniMax, HF…) and keyless local endpoints | `HermesFileService.swift:2596-2610, 2748-2831` |

## P3

| ID | Defect | Scarf |
|---|---|---|
| S02-F4 | Mid-turn status replies ("⏩ Steer queued…") glued to next streamed text (`messageId` ignored) | `RichChatViewModel.swift:2301-2316` |
| S03-F5 | Global `/scarf-*` commands bootstrapped only on local host; missing on remote + iOS | `scarfApp.swift:117-125` |
| S03-F6 | Bundled `scarf-cron.md` documents `--schedule/--prompt`, `cron list --json`, `print` delivery — none exist (LIVE) | `BuiltinSlashCommands.bundle/scarf-cron.md` |
| S04-F4 | `display_kind = 'hidden'` rows shown in transcripts/search/previews | `HermesDataService.swift:577-583, 919-927`; `SessionPreviewSQL.swift:289-300` |
| S06-F4 | Nous "subscription required" phrase changed → Subscribe button never appears | `NousAuthFlow.swift:173-179, 237-248` |
| S06-F5 | Nous catalog fallback lists only Hermes-3 models Hermes filters out | `NousModelCatalogService.swift:42-47` |
| S06-F6 | OpenRouter OAuth URL not detected → no auto-open | `OAuthFlowController.swift:506-519` |
| S06-F7 | `imageGenModels` stale (2 FAL models, xai/meta-ai/openrouter plugins) | `ModelCatalogService.swift:842-884` |
| S08-F3 | Cron schedules shown without timezone; Hermes uses its own zone | `CronScheduleFormatter.swift:146-213` |
| S09-F5 | List not force-reloaded after MCP sign-in → stale OAuth badge | `MCPServersView.swift:105` |
| S09-F6 | `mcp test` killed at 30 s, below Hermes's probe budget | `HermesFileService.swift:898-903` |
| S10-F3 | "Pinned by curator" badge reads pins from the wrong file (`skills/.usage.json`) | `SkillsViewModel.swift:232-242` |
| S11-F4 | Pre-resume AGENTS.md block refresh has no effect (Hermes reuses stored system prompt); comments wrong | `Scarf iOS/Chat/ChatView.swift:3122-3128`; `ChatViewModel.swift:1896-1928` |
| S11-F5 | Managed block tells agent `cron create --workdir` but not the `[proj:<uuid>]` prefix → agent-made jobs never attributed | `ProjectContextBlock.swift:362` |
| S12-F5 | Template secrets use shell-style `'\''` escaping python-dotenv can't parse → var dropped; `${` expanded | `SecretsEnvBlock.swift:90-101` |
| S13-F6 | Mac Profiles ignores `profile list` exit code → failure shows "No Profiles" | `ProfilesViewModel.swift:42-55` |
| S14-F7 | Local Logs live tail stops after log rotation | `HermesLogService.swift:115, 212-222` |
| S15-F5 | launchd install: pgrep's first match is the osascript wrapper → wrong PID in Health; stop fallback would signal osascript (LIVE) | `HermesFileService.swift:2479-2485` |

## Why these kept surprising us (patterns)

1. **Scarf never round-trips its own writes.** MCP tools block (S09-F1), template schema v3 (S12-F1), backup manifest flag (S14-F2), memory delimiter (S12-F3). Tests assert the writer's bytes or parse hand-written fixtures, never "write with Scarf → read with Scarf → read with Hermes".
2. **Hidden TTY / stdin assumptions.** `mcp add --auth oauth` (S09-F2), remote MCP browser login (S09-F4). Any Hermes path that branches on `isatty()` behaves differently under Scarf.
3. **"default" profile modelled as "no profile".** S13-F1, S13-F2, S01-F1, and S13-F3 are the same misunderstanding of Hermes's sticky `active_profile`.
4. **Memory recorded wrong or expired premises and later audits trusted them.** Nous aggregator "[kept]" (wrong from day one), WhatsApp Cloud "no env path" (expired), mini-app "process cwd" isolation (wrong at the tag), `.hermes/` shadowing (never true). A memory note that says "Hermes does X" needs the same file:line + tag citation as a finding, and a re-check each cycle.
5. **Scarf reimplements Hermes discovery instead of asking Hermes.** Skills depth (S10-F1), plugin enabled state (S10-F4), auth.json fallback (S06-F3), curator pins (S10-F3), gateway process matching (S15-F2/F5). Each duplicate drifts silently.
6. **Hermes output/key shapes drifted with no release-note mention.** `gateway_state.json` keys (S07-F1), `status` rows (S14-F4), webhook list indentation (S07-F5), profile display names (S13-F4), `config set none` coercion (S05-F2).
7. **iOS twins of Mac fixes.** S10-F2, S10-F4, S11-F3, S13-F4, S07-F5 — fixes landed on Mac only.

## Recommended fix phasing (for Alan to decide)

- **Phase A — P0 + one-liners:** S09-F1 (parser + round-trip test), S09-F2 (`mcp install` / direct YAML), S05-F2 (send `false`), S06-F1 (add nous + fix test + note + table-check lane), S08-F1 (gate the tick).
- **Phase B — profile pinning:** one helper, four call sites (S13-F1/F2, S01-F1, and check S13-F3).
- **Phase C — data safety:** S14-F1/F2 (use `hermes backup`/`import` semantics or `sqlite3 .backup` to a temp file; never checkpoint), S14-F5, S11-F1 (delete detector).
- **Phase D — discovery parity:** S10-F1, S10-F5, S07-F3, S15-F1, then the P2 list by section.
- **Phase E — iOS twins** and P3 cleanup.

## Memory notes to correct (after fixes land)

- `.memory/decisions/aggregator-providers-must-skip-the-model-provider-mismatch.md` — "[kept]" nous bullet is wrong (S06-F1).
- `.memory/decisions/section-audit-remediation-2026-09.md:43` — WhatsApp Cloud env premise stale (S07-F3); `:81-83` cost scoping not considered (S04-F2).
- `.memory/decisions/project-context-file-injection-release-note-awareness-not-a.md:38` — mini-app isolation premise false (S12-F6).
- `.memory/architecture/chat-session-layer-mechanism-map-and-2026-07-13-diagnosis.md:37` — extend accepted-low #2 or fix (S02-F3).
- `SessionProjectMap.swift` comment "no cwd column" is outdated (S04 note).

## Method and coverage

- **Inventory:** 306 files that touch Hermes (CLI, SQL, ACP, config.yaml, `~/.hermes` files) found mechanically and assigned to exactly one of 15 sections; `HermesFileService.swift` split by its MARK regions. 0 unassigned. Chat got 3 auditors, Projects 2.
- **Section audit:** journey-first trace (UI → VM → service → argv/SQL/ACP/key → Hermes handler at tag → output → parser → UI), local + remote, iOS deltas only. ~430 touchpoints marked OK, 67 FINDING, 10 TRACKED, 3 UNVERIFIABLE across the 15 inventories (touchpoints are grouped rows, not one per file).
- **Verification:** 11 independent verifiers on all P0/P1 plus 7 escalation candidates; live probes limited to `--help`/`--version`, a read of `gateway_state.json` key names, and Hermes functions imported against a scratch `HERMES_HOME`.
- **Out of scope by decision:** older-Hermes degradation (v0.6–v0.21.4), full iOS audit (deltas only — a follow-up session if warranted), style/perf, localization.
- **Not verified:** CJK trigram search; Nous `/v1/models` with the portal token; very large `session/load` replay vs the 60 s watchdog; whether a Scarf-side timeout kills the remote Hermes process; torn-copy half of S14-F2 (timing).
