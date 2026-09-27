# Hermes v0.21.5 audit remediation — plan

Source: `documents/audits/hermes-v0.21.5-full-app-audit.md` (2 P0, 12 P1, 40 P2, 18 P3) and section reports in
`documents/audits/hermes-v0.21.5-full-app-audit/`. Goal: fix every finding, correct every related memory note and
wiki page, then audit the whole touched surface and repeat for anything new.

## Decisions from Alan (2026-09-26)
- S03-F1 quick commands: **remove from the chat slash menu** (Mac + iOS); keep the Quick Commands page.
- S03-F2 personality: **relabel honestly** (applies to Hermes CLI/TUI/gateway, not Scarf chat); draft an upstream note in documents/upstream/.
- S11-F1: **delete** the `.hermes/` shadowing detector, banner and fix command.
- S12-F6: **keep** mini-app sessions in the project folder; correct the code comment, the decision note and the release-note/wiki claim so nothing promises isolation.
- Landing: integration branch `fix/hermes-v0215-audit`; each phase on its own sub-branch + worktree; orchestrator merges phases in; merge to main locally after the final audits. No push.

## Defaults (no decision needed)
- S04-F1/F2: match Hermes — hide archived + orphan delegate sessions; totals include delegate/rotated spend like `hermes insights`.
- S07-F4: Scarf's Webhook setup also writes `platforms.webhook.enabled`.
- S09-F2: catalog → `hermes mcp install <id>`; custom/preset OAuth → write YAML directly, then `mcp login`.
- S14-F2: no write to state.db ever — snapshot via SQLite online backup of a read-only connection (or `hermes backup`), include consistency, drop the checkpoint.
- Every fix respects charter C1 (gate on true Hermes floor, older hosts unchanged), C3, C5, C10.
- New UI strings: no agent edits `Localizable.xcstrings` (merge hot spot); one i18n pass at the end (R13).

## Mechanics
- Integration worktree: `/Users/awizemann/Developer/Scarf-wt/integration` (branch `fix/hermes-v0215-audit`).
- Phase worktree: `/Users/awizemann/Developer/Scarf-wt/rNN` on branch `fix/hermes-v0215-audit-rNN`, cut from the integration branch at wave start. Own DerivedData under the worktree.
- Memory/wiki: via memophant MCP and the MAIN checkout's `wiki/` — never a worktree copy of the managed tiers.
- Parallelism: 4 agents per wave, file-disjoint by design. UI tests only by the orchestrator, serialized.
- Per phase the agent runs: plan → implement → real tests (behaviour + round-trip, no checkbox tests) → build → targeted + full `scarfTests` serial → fresh-eyes review sub-agent → fixes → memory/wiki corrections → commit by path → report.
- Orchestrator per phase: audit diff against plan + findings, re-run tests, audit the memories written (keep/merge/retire), merge into integration, mark task done.

## Phases

### Wave 1
| Phase | Scope (finding IDs) | Main files |
|---|---|---|
| R01 MCP | S09-F1 (P0), S09-F2 (P0), S09-F3, S09-F4, S09-F5, S09-F6 | HermesFileService MCP region, HermesMCPAdd, MCP views/VMs |
| R02 Profile pinning | S13-F2, S13-F1, S01-F1, S13-F3, S13-F4, S13-F6 | HermesProfileScope, ACPClient+Mac, BotConversationViewModel, SSHTransport.composedRemoteCommand, CitadelServerTransport, Profiles (Mac+iOS) |
| R03 Config & models | S05-F2, S05-F1, S06-F1, S06-F2…F7 (+ check-hermes-tables aggregator lane) | SettingsViewModel, PowerSettingsWriter, AuxiliaryTab, ModelPreflight(+Tests), LocalModelProviders, CredentialPools, Nous services, ModelCatalogService, scripts/check-hermes-tables.py |
| R04 Cron | S08-F1, S08-F2, S08-F3, S11-F2, S11-F5, S03-F6 | CronViewModel, CronStatusWidgetView, CronScheduleFormatter, ProjectsViewModel/ProjectLifecycleService (archive), ProjectContextBlock, scarf-cron.md |

### Wave 2
| Phase | Scope | Main files |
|---|---|---|
| R05 Data safety & health | S14-F1, S14-F2, S14-F3, S14-F5, S14-F4, S14-F6, S14-F7 | RemoteBackup/RestoreService, RegistryWriteLock/GuardedTextFile, HealthViewModel, HermesLogService |
| R06 Skills & plugins | S10-F1, S10-F5, S10-F2, S10-F4, S10-F3 | SkillsScanner, BuiltinSkills bundle + bootstrap, iOS skill/plugin views, SkillsViewModel |
| R07 Gateway & platforms | S07-F3, S07-F4, S07-F1, S07-F2, S07-F5, S15-F2, S15-F5 | WhatsAppCloud/Webhook setup VMs, HermesConfig PlatformState, HermesPathSet/GatewayViewModel, iOS WebhooksView, HermesFileService gateway pgrep |
| R08 Server transport | S15-F1, S15-F3, S15-F4, S03-F5 | SSHTransport (after R02), AddServerViewModel, TestConnectionProbe, HermesFileService credential check, SlashCommandBootstrapService |

### Wave 3
| Phase | Scope | Main files |
|---|---|---|
| R09 Chat event pipeline | S02-F1, S02-F2, S02-F4, S03-F1 | RichChatViewModel, ACPMessages, quick-command menu (Mac+iOS) |
| R10 Chat controllers & chrome | S02-F3, S03-F2, S03-F3, S03-F4, S01-F2, S11-F3, S11-F4 | ChatViewModel, Scarf iOS/Chat/ChatView, SessionInfoBar, Personalities |
| R11 Sessions data | S04-F1, S04-F2, S04-F3, S04-F4 | HermesDataService, SessionsViewModel, InsightsViewModel, SessionPreviewSQL |
| R12 Projects & templates | S11-F1, S12-F1, S12-F2, S12-F3, S12-F4, S12-F5, S12-F6 (docs only) | ProjectHermesShadowDetector (delete), Dashboard, ProjectTemplate* , SecretsEnvBlock, MiniAppAgentSession comment |

### Close-out
| Phase | Scope |
|---|---|
| R13 i18n + full gate | Localize every new string; full serial `scarfTests`, ScarfCore + ScarfIOS `swift test`, iOS build, Smoke UI plan (orchestrator only) |
| R14 Orchestrator audit | Plan conformance per finding (72 IDs), memory audit (needed/redundant), fresh-eyes audit of the integration diff |
| R15 Touched-surface re-audit | Whole-surface audit of every file touched (not just the diff); new findings → new phases via the same process; then merge to main |
