# Blind re-audit remediation — plan (B-phases)

Source: `documents/audits/hermes-v0.21.5-blind-reaudit.md` (0 P0, 4 P1, 26 P2, 28 P3) and section reports + verifier log in
`documents/audits/hermes-v0.21.5-blind-reaudit/`. Goal: fix every finding, correct every related memory note / wiki page,
then audit the whole touched surface and repeat for anything new. Same process as the R-phases
(`documents/plans/hermes-v0215-audit-remediation-plan.md`).

## Decisions from Alan (2026-09-27)
- S06-F1 providers: **hide unsupported** — the picker lists only providers Hermes 0.21.5 can route; model preflight warns
  when an existing config names a provider Hermes can't route. Correct `aggregator-providers-must-skip-...` note.
- S07-F6 Spotify: **fix local, guide remote** — add a Client ID field so first-time local sign-in completes; on remote
  hosts show the exact command to run on the host instead of a sign-in that can't finish.
- S01-F2 Stop: **one Stop control for main chat and Bot Chat, Mac + iOS**; fold in all of t-14157321 (Stop + its two
  chat minors; its ProjectIdentity case-fold minor goes to B03). Close t-14157321 when B06 lands.

## Defaults (no decision needed — match Hermes)
- S02-F1: transcript reads use Hermes's display projection (`active = 1 OR compacted = 1`, still honouring
  `display_kind = 'hidden'`), like `get_resume_conversations` (hermes_state_messages.py:1273-1293). Correct
  `hermes-v0-18-compatibility-decisions.md:18`.
- S04-F1: remote JSON support is detected by running `json_valid('{}')` in the preflight, not by version.
- S12-F1: remote paths with `~` are resolved against the probed remote home before any containment check; the uninstall
  outcome lists anything left behind honestly.
- S13-F1: comment/event ids decoded leniently (synthesized ids; per-element lossy decode).
- S03-F3/S13-F4: kanban opt-in targets the `acp` platform (Scarf chat), keeping Hermes's `hermes-acp` defaults.
- S10-F2: drop the 40-row "All Sources" client filter; use Hermes's own search.
- S12-F2: the registered `scarf-projects` MCP server receives the profile's home explicitly (args), not via env.
- Every fix respects charter C1, C3, C5, C10. No agent edits `Localizable.xcstrings` (one i18n pass in B10).

## Mechanics
- Integration worktree `/Users/awizemann/Developer/Scarf-wt/blind-integration` on `fix/hermes-v0215-blind`, cut from main.
- Phase worktree `/Users/awizemann/Developer/Scarf-wt/bNN` on `fix/hermes-v0215-blind-bNN`, cut from integration at wave start.
- Brief: `documents/plans/hermes-v0215-blind-reaudit-remediation-agent-brief.md`.
- 4 agents per wave, file-disjoint by design. UI tests only by the orchestrator, serialized. Other projects on this Mac run
  UI tests — check `pgrep -f "[x]codebuild.* test"` before app-hosted test runs.
- Orchestrator per phase: audit diff against plan + findings, re-run tests, audit memories written, merge, mark task done.

## Phases

### Wave 1 (all four P1s)
| Phase | Scope | Main files |
|---|---|---|
| B01 Transcript & sessions data | S02-F1 (P1), S04-F1 (P1), S04-F2, S04-F3, S11-F1 | HermesDataService, Remote/LocalSQLiteBackend, SessionsViewModel, ProjectSessionsViewModel (+ iOS twins) |
| B02 Models & providers | S06-F1 (P1), S06-F2, S06-F3, S06-F4 | ModelCatalogService, ModelPickerSheet, ModelPreflight, NousSubscriptionService, OAuthFlowController, scripts/check-hermes-tables.py if a lane is warranted |
| B03 Templates & projects | S12-F1 (P1), S12-F2, S12-F3, S12-F4, S11-F2, S11-F4, t-14157321 ProjectIdentity case-fold | ProjectTemplateUninstaller, ServerContext/HermesPathSet (remote home), ProjectsMCPRegistrar, scarf-projects-mcp, TemplateExportSheet, CatalogService, FleetApplyPlan, ProjectDoctorService |
| B04 Kanban, bots & profiles | S13-F1, S13-F2, S13-F3, S03-F3/S13-F4, S13-F5, S13-F6, S13-F7 | HermesKanban* models, KanbanCompleteResultSheet, KanbanToolsetDetector/Enabler, ChatKanbanOnboardingSheet, Profile routing, profile export, bot rename |

### Wave 2
| Phase | Scope | Main files |
|---|---|---|
| B05 Gateway & platforms | S07-F1…F8 | Slack/WhatsApp/Mattermost/iMessage/Feishu setup VMs, GatewayViewModel + HermesFileService gateway region (restart), SpotifyAuthFlow, Mac webhooks list |
| B06 Chat | S01-F2 + t-14157321 (Stop, Mac + iOS, main + Bot Chat), S01-F1, S02-F2, S02-F3, S02-F4, S03-F2, S03-F4, S03-F5 | RichChatInputBar, ChatViewModel, RichChatViewModel, BotConversationViewModel, ACPMessages, Scarf iOS/Chat, QuickCommandsViewModel |
| B07 Health, memory, voice & settings | S14-F1 (+S03-F1 silent fallback), S14-F2, S14-F3, S05-F1, S05-F2, S05-F3 | HermesPythonDiscovery, MessageSpeechService, IOSMemoryViewModel, LogsViewModel, TerminalTab/SettingsViewModel, HermesManagedInstall |
| B08 Cron, MCP & skills | S08-F1, S08-F2, S08-F3, S09-F1, S10-F1…F4 | HermesFileService cron region, CronScheduleFormatter, CronViewModel, MCPServerEditorView/VM, HermesCLIOutcome (plugins), SkillsViewModel, skill/plugin detail, install-from-URL sheet, iOS skill copy |

### Wave 3
| Phase | Scope | Main files |
|---|---|---|
| B09 Servers & transport | S15-F1, S15-F2, S15-F3, S15-F4, S15-F5, S11-F3 | SSHTransport (scp/SFTP quoting), diagnostics/pill hints, ServerRegistry.removeServer, CitadelServerTransport `~/`, HermesFileService env probe + local lookup, GitBranchService/LocalTransport |

### Close-out
| Phase | Scope |
|---|---|
| B10 i18n + full gate | Localize new strings; full serial `scarfTests`, ScarfCore + ScarfIOS `swift test`, iOS build, tables script, Smoke UI (orchestrator) |
| B11 Orchestrator audit | Plan conformance per finding (58 IDs), memory audit, fresh-eyes audit of the integration diff |
| B12 Touched-surface audit | Audit every touched area end to end (not only the diff); new issues → follow-up phases, same process |

### After close-out — B13 Env-first platform settings (task t-d83fc37d)
Alan (2026-09-27): separate task, run after B12. Same defect as S07-F4 (Mattermost, fixed in B05) in other platform forms.
- **Problem:** Hermes reads these keys from `.env` before config.yaml. When `.env` holds the variable, Scarf's form shows the
  config value and its toggle/save has no effect. Hermes: `gateway/platforms/_shared.py:106-128` (`extra_or_secret`, from
  0.21.3, commit 3dedb71f2f); env-only readers behind the bridge `gateway/config.py:829-831` (copies config into env only
  when unset) on every version.
- **Keys (Hermes file:line @ v2026.9.24, from B05's sweep):**
  - From 0.21.3: Discord require_mention (`discord/adapter.py:4765-4780`), history_backfill (`:5040-5042`); Telegram
    require_mention (`telegram/adapter.py:5713-5735`); Matrix require_mention (`matrix/adapter.py:950`); Ntfy publish_topic
    (`ntfy/adapter.py:127`); allowlists — Telegram allowed_chats (`:5725-5731,5778`), Matrix allowed_rooms (`:539,873`),
    Mattermost allowed_channels (`mattermost:499`), Slack allowed_channels (`slack:6240-6260`), DingTalk allowed_chats
    (`dingtalk:256-267`).
  - Every version: Discord reactions (`:2935`), auto_thread (`:6001`), allowed_channels (`:4845-4866`); Telegram reactions
    (`:7090`); Matrix auto_thread, dm_mention_threads (`:877,879`).
  - Before 0.21.3 the env var decides when the config key is missing (Slack/Matrix/DingTalk allowlists, Discord
    history_backfill never reach `config.extra`).
  - iOS read-only rows (Discord require mention/auto-thread, Telegram/Matrix require mention) show config.yaml only.
  - Not affected: Slack require_mention/reply_in_thread/broadcast, Discord free_response_channels, Signal, Email, Home
    Assistant, Telegram `extra.*`, WhatsApp Cloud.
- **Step 0 (scope check):** confirm how users end up with these vars in `.env` in normal use (does `hermes gateway setup` /
  the platform wizards write them? which ones?). Keys nobody's normal setup writes → drop from scope.
- **Approach:** reuse the B05 Mattermost pattern — read the value Hermes actually uses (env-first per band), caption when
  `.env` decides it, save to config.yaml, and neutralise the `.env` line ONLY after `config set` succeeds; never drop the
  only allowlist. Per-band flags at the true floors (0.21.3 flip; pre-0.21.3 key-missing rule). iOS read-only rows show the
  effective value.
- **Lessons from the reverted B05 attempt (fresh-eyes FIX-FIRST):** wrong version bands, a Save that could drop the only
  allowlist, and `LC_ALL=C` needed for any remote shell parsing.
- **Phasing:** one phase, split by platform only if the diff gets large (Discord+Telegram first — most used). Same process:
  plan → fix → real tests (round-trip through Hermes's loader on a scratch HERMES_HOME) → foreground fresh-eyes → memory
  (`a-platform-s-shared-keys-are-bridged-from-one-section-so.md`, `hermes-v0-21-1-compatibility-decisions.md`) and wiki.

## Task ids
Parent t-f54a80d5 · B01 t-a16aae07 · B02 t-314cbfc4 · B03 t-b03a736b · B04 t-a7bbd63d · B05 t-6d767ade · B06 t-4111cb69 ·
B07 t-c2cbb8d4 · B08 t-1df802f0 · B09 t-dbf6ddc0 · B10 t-0a1f7a7a · B11 t-50748d49 · B12 t-f9da0584 · B13 t-d83fc37d

## Carried to B11/B12 (orchestrator log)
- B02: iOS preflight has no can't-route warning; `ModelCatalogService.provider(for:)`/`model(providerID:modelID:)` lack capabilities (no callers); kimi-coding plugin skipped by lane 8 static read.
- B03: `OffPoolDisciplineP52Tests` pins HermesFileService line numbers — breaks on every insert; consider anchoring on symbols instead.
- Alan (2026-09-27): known bugs on older Hermes bands get fixed behind their own flags (B02b providers <0.21.4, B04 kanban onboarding bands).
- Console locked 2026-09-27 evening: app-hosted scarfTests deferred to B10. Pending suites — B03: BlindB03TemplateTests (2 widget cases never run), WidgetPathResolverTests, WidgetSignatureBatchTests, ProjectsT1TrustAtUseTests, ProjectsMCPRegistrarTests, ProjectTemplateServiceTests, ProjectTemplateR12Tests, GwF1RefusalOrderingTests, ProjectsS2D2AppTests, OffPoolDisciplineP52Tests, CatalogServiceTests, CatalogViewModelTests. B01: SessionExportLineageB01Tests, ChatSessionsR16bMacTests, SessionExportRemoteDestinationTests, AuditP25SurfaceCopyTests, HermesP28CrossPhaseRemediationTests. B05: GatewayPlatformsB05Tests suites (SlackReplyModeB05Tests, WhatsAppB05Tests, FeishuDomainB05Tests, IMessageReadReceiptsB05Tests, MattermostPrecedenceB05Tests, WebhookListFailureB05Tests, SpotifyB05Tests, GatewayRestartDrainWatchB05Tests), MattermostRequireMentionSideP51Tests, MattermostEnvFallbackSurvivesP51bTests, AllConfigWritersParityTests, GatewayProcessScopeR07Tests, SpawnDisciplineP43Tests, MainActorSpawnDisciplineP22Tests. B02b: ModelsProvidersB02AppTests, HermesP7dSettingsCatalogTests. B04: KanbanDispatchConfirmP56Tests, KanbanCompletionGateB04Tests, KanbanChatEnableBandB04Tests, BotsViewModelTests, HermesP28CrossPhaseRemediationTests, BotConversationCLITransportE2ETests, KanbanOnboardingGateP59Tests, HermesP38SourceSweepTests, SeparatorsAndLocalizationP54Tests. B07: BlindB07MacTests, MessageSpeechServiceTests, MacChatF2bTests, VoiceLiveMacTests, HermesFileServiceConfigParityTests, HermesP45Tests. B09: BlindB09MacTests, OffPoolDisciplineP52Tests, SpawnDisciplineP43Tests, MainActorSpawnDisciplineP22Tests. B08: BlindReauditB08AppTests, CronP15DiagnosticRefreshTests, HermesP7fCronPeersTests, HermesMCPServerV0204RegressionTests, MCPOAuthAndTransportP24Tests. Manual smoke: MCP editor Clear Token → Sign In sheet chain on macOS. B06: ChatStopB06Tests, BotChatStopB06Tests, ChatModelBadgeB06Tests, QuickCommandNameB06Tests + regressions (BotConversationTests, ChatViewModelP7bTests, ChatViewModelStartLifecycleTests, ChatViewModelAutoAcceptEditsTests, PermissionApprovalEditShapeTests, ChatModelSwitchBusyTests, ChatReconnectHoldR17Tests, VoiceLiveMacTests, HermesV0215R18bMacTests). Then the full bundle serially.
- B03 → B06: project chats pass literal `~/projects/x` as ACP cwd (ChatViewModel.swift:1406,2164,2554 + iOS ChatView); Hermes doesn't expand it (acp_adapter/session.py:176-178). Expand with resolvedUserHome().
- B02b: picker blanks a saved named custom provider (custom_providers name) while the warning stays quiet — make consistent.
- B05 (for Alan): env-first (.env wins over config.yaml) affects other platform forms — Discord require_mention/history_backfill/reactions/auto_thread/allowed_channels, Telegram require_mention/reactions/allowed_chats, Matrix require_mention/auto_thread/dm_mention_threads/allowed_rooms, Ntfy publish_topic, Slack/Mattermost/DingTalk allowlists; iOS read-only rows too. Hermes: gateway/platforms/_shared.py:106-128 (extra_or_secret, from 0.21.3), gateway/config.py:829-831 bridge. Not built (scope). Lessons if picked up: env wins on old hosts when key absent; remove .env line only after config set succeeds; LC_ALL=C on remote kill -0.
- B01 seen, not fixed: on hosts with listable-child support, a search hit on a delegate session opens as its parent's chain instead of itself.
- B09 seen, not fixed: local ACP chat resolves hermes via HermesPathSet.hermesBinary fixed candidates only (HermesPathSet.swift:209, 49 call sites) — Nix/venv-only users may fail chat launch; Citadel shellJoin treats `$` as safe (~943); stale "two zsh probes 5 s + 3 s" comments (SpotifyAuthFlow, HermesProxyService, OAuthFlowController, HealthViewModel); remove+re-add same host race with late `ssh -O exit` (reconnects). fish probe unverified (no fish here).
- P52 citations must be restated after B08 merges (or anchored on symbols).
- B08 seen, not fixed: flow-style skill config entries; computeMissingConfig edge cases; AmbiguousJobReference on old cron edit; 'hermes mcp login' copy on <v2026.4.23; 6-field cron zone note; Sign In from editor drops unsaved edits; Hub search with ≥1 index hit misses registry-only skills (Hermes behaviour).
- B06 seen, not fixed: iOS /new name applied only on end_turn; Stop with /queue'd prompts may need a second Stop; old uppercase quick commands not migrated.
- B11 seen: bot picker (BotAgentView.swift:33) and model-preset picker (ModelPresetEditSheet.swift:51) blank/block custom providers — same regression class, fix in B12.
- B12 fix list: bot picker custom providers (BotAgentView.swift:33, read bot profile config), preset editor (ModelPresetEditSheet.swift:51 via ModelPresetsView.swift:52), ChatModelPreflightSheet.swift:31; template export sheet rescan on focus/button (TemplateExporterViewModel.swift ~58-80).
- B12 fix list: Mattermost save unsets .env line before config write (PlatformSetupHelpers.swift:85-104) — unset only after config write succeeds.
