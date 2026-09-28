# Blind re-audit: Scarf ↔ Hermes v0.21.5 (whole app)

- Date: 2026-09-27 · Code: `main` @ 12018c8f (includes the 3a9da0b8 remediation merge) · Hermes reference: `~/.hermes/hermes-agent-v0215` (tag v2026.9.24, 0.21.5)
- Method: identical to the 2026-09-26 whole-app audit — 15 section auditors (Opus, read-only, no sub-agents), journeys-first trace, touchpoint inventory, every P0/P1 sent to an independent adversarial verifier.
- **Blind:** auditors and verifiers were barred from `documents/audits|plans|reports`, the remediation tickets, and git history. Memory, wiki and the open task board were allowed. One auditor (S04) saw a single grep line from a barred ticket; its finding (S04-F2) was verified from code independently.
- Section reports + verifier log: `documents/audits/hermes-v0.21.5-blind-reaudit/`.

## Headline
**No P0. 4 confirmed P1, 26 P2, 28 P3 (58 distinct findings, after merging 2 duplicate pairs).** Every section's primary journeys work against 0.21.5; all 15 verdicts are WORKS-WITH-ISSUES, none BROKEN. The P1s are one default-config chat issue (compacted history) and three remote/provider-specific breaks.

## Section verdicts
| Section | Verdict | P0 | P1 | P2 | P3 |
|---|---|---|---|---|---|
| S01 Chat transport (ACP) | Works with issues | 0 | 0 | 1 | 1 |
| S02 Chat events | Works with issues | 0 | 1* | 0 | 3 |
| S03 Chat surfaces | Works with issues | 0 | 0 | 2 (+1 merged) | 2 |
| S04 Sessions data | Works with issues | 0 | 1 | 1 | 1 |
| S05 Config & settings | Works with issues | 0 | 0 | 1 | 2 |
| S06 Models & providers | Works with issues | 0 | 1 | 0 | 3 |
| S07 Gateway & platforms | Works with issues | 0 | 0 | 6 | 2 |
| S08 Cron | Works with issues | 0 | 0 | 1 | 2 |
| S09 MCP | Works with issues | 0 | 0 | 1 | 0 |
| S10 Skills & plugins | Works with issues | 0 | 0 | 2 | 2 |
| S11 Projects core | Works with issues | 0 | 0 | 2 | 2 |
| S12 Templates / mini-apps / projects MCP | Works with issues | 0 | 1 | 2 | 1 |
| S13 Kanban / bots / peers / profiles | Works with issues | 0 | 0† | 3 (+1 merged) | 3 |
| S14 Health / logs / memory / backup | Works with issues | 0 | 0‡ | 2 | 1 |
| S15 Servers / transport / iOS | Works with issues | 0 | 0 | 2 | 3 |

\* auditor P2, verifier upgraded to P1. † auditor P1, verifier downgraded to P2. ‡ auditor P1 (duplicated by S03), verifier downgraded to P2.

## P1 — confirmed by independent verifier
| ID | Finding | Scarf | Hermes @ tag | Verifier |
|---|---|---|---|---|
| S02-F1 | **Compacted chats lose their earlier turns in Scarf.** Every transcript path (chat resume, skeleton/full/reconcile, "Load earlier", Sessions detail; Mac + iOS via ScarfCore) reads only `active = 1` rows. Hermes 0.21.5 compacts **in place by default** and archives older turns as `active=0, compacted=1`; its own resume projection shows them (Hermes bug #92080 — "user turns read as deleted"). ACP replay can't rescue it (Scarf suppresses it; it's active-only too). Data is still on disk; search still finds it. The compaction summary itself is hidden by Hermes by design (sub-claim refuted). Decision note `.memory/decisions/hermes-v0-18-compatibility-decisions.md:18` is stale. | `HermesDataService.swift:1355-1357` (`transcriptVisibleClause`), callers `:837-842`, `:917-922`; `RichChatViewModel.swift:3227,3369,3390,3693,3791`; `SessionsViewModel.swift:470` | `hermes_cli/config_defaults.py:554,658-663`; `hermes_state_messages.py:735-750,1273-1293` | CONFIRMED, upgraded P2→P1 |
| S04-F1 | **Remote hosts with sqlite3 < 3.38 get a lossy session list.** JSON support is decided from the version string, not tested (local does test). Ubuntu 22.04, Debian 11, RHEL 8/9 fail the gate though their sqlite3 almost certainly has JSON1. Result: reset/branch continuations vanish from Sessions, chat sidebar, Dashboard (Mac + iOS); historical compressed chats open with only the root segment. Resume still reaches the right tip. | `RemoteSQLiteBackend.swift:385-387,409-418`; gates `HermesDataService.swift:375-392,429,1828,2106`; compare `LocalSQLiteBackend.swift:359` | `hermes_state_common.py:67-74` (json_extract used unconditionally) | CONFIRMED P1 (JSON1-in-distro-packages is external knowledge, not tested on a live host) |
| S06-F1 | **Model picker offers providers Hermes can't route.** The Remote catalog lists all 223 models.dev providers; Hermes's `resolve_provider` accepts 37 (live run). Mistral, Groq, Cerebras, Together, Perplexity, Cohere, Moonshot, Zhipu save fine, preflight says "configured", then chat fails loudly with "Unknown provider" even with the API key set. Mainstream providers work. `.memory/decisions/aggregator-providers-must-skip-the-model-provider-mismatch.md:31` repeats the "catalog = known providers" assumption. | `ModelCatalogService.swift:132-190`; `ModelPickerSheet.swift:1169,1402-1419`; `ModelPreflight.swift:41-63` | `hermes_cli/auth.py:1500-1509`; `acp_adapter/session.py:500-537` | CONFIRMED P1 (186 is an upper bound — `openai` routes via custom) |
| S12-F1 | **Remote template uninstall leaves the project folder and skills on the host but reports success.** Remote defaults are literal `~/projects` and `~/.hermes`; the uninstaller's path guard refuses anything not starting with `/`, so every file lands in "Skipped — outside this project" (a notice, not a block). Registry row, cron jobs, memory block and Keychain items are removed; the success screen says the folder was removed and lists no leftovers; template skills stay visible to the agent. Comment at `:1083-1084` ("remote template installs don't exist yet") is stale. | `ProjectTemplateUninstaller.swift:118,138,547-599,1090-1091`; `ServerContext.swift:141,162-172`; `HermesPathSet.swift:64`; `TemplateUninstallerViewModel.swift:90` | n/a (Scarf-side delete decision) | CONFIRMED P1 |

## P2
| ID | Finding | Scarf |
|---|---|---|
| S14-F1 (+S03-F1) | Hermes Voice can't find Python on a fresh official install: `install.sh` writes `~/.local/bin/hermes` as a bash launcher (`exec venv/bin/python …`); all three discovery strategies miss it. Hermes-voice playback silently falls back to the system voice; Live Voice fails "no Python". Opt-in features → P2 (verifier). | `HermesPythonDiscovery.swift:23-59`; `MessageSpeechService.swift:166-175`; Hermes `scripts/install.sh:2118-2176` |
| S13-F1 | Kanban comments never display ("No comments yet." always). `kanban show --json` emits comments without `id`; Scarf requires it and one `try?` drops the whole array. Events all get id 0 (duplicate ForEach ids). Live-probed. Verifier: P2 (secondary tab, all setups). **Orchestrator note: arguably P1** — Comments is the default tab and carries agent BLOCKED/CHANGES REQUESTED reasons. | `HermesKanbanComment.swift:37`; `HermesKanbanTaskDetail.swift:50`; `HermesKanbanEvent.swift:52` |
| S03-F3 (+S13-F4) | "Enable kanban tools" writes `platform_toolsets.cli`, but Scarf chat runs on the `acp` platform (reads `platform_toolsets.acp`; default `hermes-acp` excludes kanban). The "enabled" toast is false for Scarf chats. | `KanbanToolsetDetector.swift:76-97`; `KanbanToolsetEnabler.swift:76` |
| S01-F2 | No Stop control for a running turn in Mac or iOS chat (wiki documents one); cancel only on teardown / voice barge-in. (t-14157321 covers Bot Chat only.) | `RichChatInputBar.swift:272-290` |
| S03-F2 | Model badge goes stale: not reset on new session, ignores typed `/model` and Hermes's `current_model_id`. | `ChatViewModel.swift:311,1831,1944` |
| S04-F2 | Export of a compressed conversation exports only the latest segment; Markdown/Quarto never pass `--lineage logical`. | `SessionsViewModel.swift:766-768,919-934` |
| S05-F1 | Terminal "Modal mode" picker offers `always/never`; Hermes accepts `auto/direct/managed` and silently coerces to `auto`. | `TerminalTab.swift:62`; `SettingsViewModel.swift:791` |
| S07-F1 | Slack "Reply Mode" writes `platforms.slack.reply_to_mode`, never read by the adapter. | `SlackSetupViewModel.swift:73` |
| S07-F2 | Blank WhatsApp reply prefix writes `""`, removing Hermes's default self-chat header. | `WhatsAppSetupViewModel.swift:92` |
| S07-F3 | Gateway restart during a running agent turn shows "restart failed" after 60 s while Hermes is draining (up to ~1815 s) then restarts. | `HermesFileService.swift:1501`; `GatewayViewModel.runServiceAction` |
| S07-F4 | Mattermost `require_mention`: `.env` now wins over config; a stale `MATTERMOST_REQUIRE_MENTION` makes the toggle inert and the form wrong. | `MattermostSetupViewModel.swift:84,106` |
| S07-F5 | BlueBubbles "Send read receipts" shows off while Hermes sends them; turning it off never takes effect. | `IMessageSetupViewModel.swift:55,69` |
| S07-F6 | Spotify sign-in can't complete for a first-time user (no client ID; wizard EOF) or on any remote host (callback on host loopback). | `SpotifyAuthFlow.swift:165-172` |
| S08-F1 | Monitor-mode cron jobs show `monitor_last_output.txt` instead of the latest run `.md` in "Last run output" and the project widget (no `*.md` filter; "m" sorts last). | `HermesFileService.swift:399-401` |
| S09-F1 | After Clear Token the MCP editor still says "Token on disk", keeps the oauth badge, and wrongly says Hermes will re-auth on its own (it raises `OAuthNonInteractiveError`; user must run `mcp login`). | `MCPServerEditorView.swift:82-83,396-414`; `MCPServerEditorViewModel.swift:563-571` |
| S10-F1 | Updating a catalog-installed plugin succeeds but Scarf reports failure (doesn't recognise "updated to <sha>" / "already at catalog pin"). | `HermesCLIOutcome.swift:2166-2170` |
| S10-F2 | Hub search on "All Sources" only filters the first 40 browse rows; the #79 workaround's premise is gone (Hermes search now falls back to registries). | `SkillsViewModel.swift:463-476,577` |
| S11-F1 | Project Sessions tab filters only the host's 200 newest sessions of all kinds; older project chats drop out and the empty state says they "may have been deleted". | `ProjectSessionsViewModel.swift:124,142` |
| S11-F2 | Fleet apply skips template-installed cron jobs (`[tmpl:x] [proj:uuid] …` names). | `FleetApplyPlan.swift:286` |
| S12-F2 | Bundled `scarf-projects` MCP server always uses the sticky `active_profile` home (Hermes strips `HERMES_HOME` from MCP env), so a `-p work` agent edits the other profile's projects. | `ProjectsMCPRegistrar.swift:235-239`; `scarf-projects-mcp/main.swift:96` |
| S12-F3 | Template export sheet recomputes its plan on the main actor ~3×/keystroke (~25 SSH ops per keystroke remote) — charter C10. | `TemplateExportSheet.swift:139,149,243` |
| S13-F2 | `kanban stats --json` `by_assignee` is nested; Scarf decodes `[String:Int]`, so glance counts vanish once any task is assigned. | `HermesKanbanStats.swift:38` |
| S13-F3 | Complete sheet says result is optional; Hermes refuses result-less completion from non-review states, so drag-to-Done fails (and Blocked/Scheduled cards end up in Up Next). | `KanbanCompleteResultSheet.swift:30,33` |
| S14-F2 | iOS memory Save overwrites MEMORY.md/USER.md without a conflict check; concurrent agent writes are silently lost (Mac guards this). | `IOSMemoryViewModel.swift:190-191` |
| S15-F1 | Remote writes to paths with spaces/quotes/non-ASCII likely fail: scp spec is shell-quoted but OpenSSH 10 scp uses SFTP mode (quotes become literal). PLAUSIBLE — not live-tested. | `SSHTransport.swift:332,421` |
| S15-F2 | Six Diagnostics/pill hints send users to "Manage Servers → Edit", which doesn't exist (missing feature tracked t-83d2fe; hints new). | `ServerRegistry.swift:205` + hint sites |

## P3
| ID | Finding | Scarf |
|---|---|---|
| S01-F1 | Approval-mode chip keeps a hand-picked mode after reconnect; Hermes doesn't persist it. | `ChatViewModel.swift:2569-2608` |
| S02-F2 | Live tool output empty for `skill_manage` edits (diff-only) and `web_extract`. | `ACPMessages.swift:648-656` |
| S02-F3 | `/queue` indicator drops one entry per turn; Hermes drains all. | `RichChatViewModel.swift:2982-2984` |
| S02-F4 | With `compression.in_place: false` only, header tokens/cost freeze after rotation. | `RichChatViewModel.swift:2092-2101` |
| S03-F4 | Quick command names saved with case; Hermes lowercases typed commands. | `QuickCommandsViewModel.swift:65-91` |
| S03-F5 | `/new <name>` drops the name (Mac + iOS). | — |
| S04-F3 | Session list doesn't hide `tool`/`kanban`/`oneshot` sources; kanban worker runs inflate counts. | `HermesDataService.swift:375-392` |
| S05-F2 | Terminal backend list omits built-in `vercel_sandbox` (stale "removed" comment). | `SettingsViewModel.swift:36-40` |
| S05-F3 | `.managed` marker parser doesn't honour `false/0/no/off` opt-out. | `HermesManagedInstall.swift:88-95` |
| S06-F2 | Nous "last refreshed" warning never appears (ISO8601 without fractional seconds). | `NousSubscriptionService.swift:126-129` |
| S06-F3 | Local Anthropic OAuth opens two browser tabs. | `OAuthFlowController.swift:389-396` |
| S06-F4 | `modelAliases` map deepseek-chat/reasoner to `deepseek-v4-flash`; Hermes uses `deepseek-flash`. | ModelCatalog aliases |
| S07-F7 | Feishu domain / WhatsApp mode defaults differ from Hermes when the env key is absent. | — |
| S07-F8 | Mac webhook list failure shows "No webhook subscriptions" (iOS reports error). | — |
| S08-F2 | Natural-language schedules never get the host-zone note; justified by a non-existent `cron set-display` verb. | `CronScheduleFormatter.swift:113-139` |
| S08-F3 | Run Now doesn't refresh doctor/incident diagnostics. | `CronViewModel.swift:917-958` |
| S10-F3 | Skill/plugin details read keys Hermes doesn't use (`allowed_tools`, `related_skills`, `tool_override`…). | — |
| S10-F4 | Install-from-URL offers tarballs (Hermes accepts `.md` only); iOS points at a non-existent Mac screen. | — |
| S11-F3 | Mac local project chat never shows git-branch chip (bare `git`, no PATH search). | `GitBranchService.swift:47`; `LocalTransport.swift:271` |
| S11-F4 | Project Doctor compares cron `workdir` textually; Hermes resolves symlinks → false findings. | `ProjectDoctorService.swift:365-369,469-471` |
| S12-F4 | Catalog cache read/written over transport on the main actor. | `CatalogService.swift:203-205` |
| S13-F5 | Profile Routing explainer ignores `user_id` and `bot_profile`. | — |
| S13-F6 | Local profile export named `.tgz` lands as `.tar.gz` but says "Exported". | — |
| S13-F7 | Renaming the default bot validated as a profile id. | — |
| S14-F3 | Logs component filter prefixes wrong ("CLI" misses `hermes_cli.*`, "Agent" misses `run_agent`). | `LogsViewModel.swift` |
| S15-F3 | `removeServer` runs `ssh -O exit` synchronously on the main actor (10 s) — C10. | `ServerRegistry.swift:233` |
| S15-F4 | iOS Citadel never rewrites `~/` → `git -C ~/…` fails; no branch chip on ScarfGo. | `CitadelServerTransport.swift:894-935` |
| S15-F5 | Local env probe hard-codes `/bin/zsh`; local hermes lookup ignores harvested PATH (bash/fish, Nix/venv). | `HermesFileService.swift:3161,3261` |

## Tracked (not counted)
S08: iOS direct `jobs.json` rewrite (design), t-b74c65a4, t-63ffcac4. S11: `.hermes.md`/`HERMES.md`/`AGENTS.override.md` hide the AGENTS.md block (memory caveat). S13: t-038695a3, t-b884cfbd. S15: t-83d2fe (Edit Server), t-93ddfdc4 (iOS host keys).

## Method & coverage
- Inventory: five greps (CLI, SQL, ACP, YAML/config, `~/.hermes` files) over `scarf/`, `ScarfCore`, `ScarfIOS`, `Scarf iOS` → 400 Swift files + 7 bundled skill/slash resources (first run: 301; the recreated greps are a superset — only a deleted file dropped out). Assigned by the same section rules; HermesFileService split by `// MARK:` region; 0 unassigned.
- Live probes: `--help` only for auditors; verifiers ran Hermes's own functions against scratch `HERMES_HOME`s (resolve_provider ×223, `kanban show --json`), never the real `~/.hermes`.
- Verification: 6 P1 candidates → 4 CONFIRMED (one upgraded from P2), 2 DOWNGRADED to P2; 1 duplicate pair merged at P1-candidate stage (S03-F1 = S14-F1), 1 at P2 (S03-F3 = S13-F4).
- Not verified live: S15-F1 (scp/SFTP quoting), S04-F1's distro JSON1 premise.

---

## Comparison with the original audit (written after the blind results above)

| | P0 | P1 | P2 | P3 | Total |
|---|---|---|---|---|---|
| Original (2026-09-26, pre-fix) | 2 | 12 | 40 | 18 | 72 |
| Blind re-audit (2026-09-27, post-fix) | 0 | 4 | 26 | 28 | 58 |

**No original finding reappears as the same defect** (one reappears as a deeper defect in the same code — see below). The journeys behind the two original P0s (MCP blocklist round-trip, OAuth MCP add) and the original P1s (default-bot chat, Nous preflight, skills scan depth, reasoning none, Run Now, backup/restore, remote binary hint, profile pinning, Linux built-in skills, WhatsApp Cloud, shadow banner) were re-traced by the blind auditors and reported as working. Verification was stricter this time (6 P1 candidates → 4 confirmed, 2 downgraded; original: 0 refuted).

**Where the new findings sit relative to the old ones**
- **Incomplete earlier fix (1):** S03-F3/S13-F4 — the original S13-F5 fix made "Enable kanban tools" work on configs without `platform_toolsets.cli`, but `cli` is the wrong platform for Scarf chat altogether (`acp`). Same code, deeper defect.
- **Seen but not fixed last time (1):** S04-F2 (export of a compressed chain exports only the tip) was noted as an observation in the R15 touched-surface audit and not ticketed.
- **Residue of an earlier fix (2):** S08-F2 (host-zone note skipped for natural-language schedules; original S08-F3 added the note) and S15-F2 (hints point at an Edit Server screen that doesn't exist; original S15-F1 noted the missing UI).
- **Same class as an old finding, different code (5):** S12-F1 remote uninstall reports success while leaving files (class of original S12-F4); S14-F2 iOS memory save has no conflict guard and S15-F4 iOS never expands `~/` (the "iOS twin" pattern, original pattern 7); S12-F3/S12-F4/S15-F3 main-actor work (C10, class of original S03-F4); S11-F2 fleet apply ignores `[tmpl:]` job names (class of original S11-F5 attribution).
- **Genuinely new ground (rest):** mostly because the recreated inventory was wider (400 vs 301 files — bot views, platform setup forms, Citadel transport, kanban models were not all in the first manifests) and because verifiers ran Hermes functions live (223-provider routing sweep, `kanban show --json`).

**Missed by the first audit, present then too**
- S02-F1 (compacted history hidden) — in-place compaction was already the 0.21.5 default; the first audit's S04-F3 covered only the non-default rotated chain. A memory decision note endorsed the active-only read, and auditors trusted it (original pattern 4 again).
- S06-F1 (unroutable providers) — the first S06 focused on the Nous/aggregator mismatch in the same decision note; the catalog-wide routability question wasn't asked.
- S04-F1 (remote sqlite version gate) and S13-F1 (kanban comments decode) — plain misses.

**Memory notes to correct (with the fixes)**
- `.memory/decisions/hermes-v0-18-compatibility-decisions.md:18` — "Hermes reloads only the active set" is stale for display at 0.21.5 (S02-F1).
- `.memory/decisions/aggregator-providers-must-skip-the-model-provider-mismatch.md:31` — treats `loadProviders()` as the known-provider roster (S06-F1).
- `ProjectTemplateUninstaller.swift:1083-1084` comment ("remote template installs don't exist yet") and `SettingsViewModel.swift` "vercel_sandbox removed" comment are stale (code comments, fix with the code).

**Takeaway.** The remediation held: no regressions of the original defects, no P0, and the remaining P1s are narrower (remote-only, provider-specific, or long-session-only). The recurring root cause is the same as last time — Scarf re-implements a Hermes read (transcript visibility, JSON support, provider routability, path containment) instead of matching Hermes's own function, and a memory note blessed the old behaviour.
