# Pre-release blind audit: Scarf ↔ Hermes v0.21.5 (full coverage)

- Date: 2026-09-28 · Code: `main` @ 2e9965b5 (all B01–B13 fixes, pushed) · Hermes reference: tag v2026.9.24 (0.21.5)
- Method: 18 blind section auditors (Opus, read-only, no sub-agents), journeys-first trace, every P0/P1 sent to an
  independent verifier. Bar: normal use only; rare edge cases ignored; "works" is a good result.
- **Coverage (new): every production file, not a grep.** 664 files (all Swift in the Mac app, ScarfCore, ScarfIOS,
  Scarf iOS, ScarfDesign; bundled resources; repo scripts), each assigned to exactly one section (0 unassigned, 0
  duplicates). Every report has a per-file row; checked mechanically: **664/664 covered, 0 missing.**
- Blind: auditors barred from past audits, fix plans, R/B fix tickets and git history.
- Section reports + log: `documents/audits/hermes-v0.21.5-prerelease-audit/`.

## Headline
**No P0. 2 confirmed P1, 4 P2, 2 P3.** 12 of 18 sections came back WORKS with zero findings.

## Section verdicts
| Section | Files | Verdict | P1 | P2 | P3 |
|---|---|---|---|---|---|
| S01 Chat transport | 11 | Works | | | |
| S02 Chat events | 13 | Works | | | |
| S03 Chat surfaces | 42 | Issues | 1 | 1 | |
| S03b Voice | 28 | Works | | | |
| S04 Sessions data | 29 | Issues | | 1 | |
| S05 Config & settings | 32 | Works | | | |
| S06 Models & providers | 29 | Issues | | | 1 |
| S07 Gateway & platforms | 64 | Works | | | |
| S08 Cron | 15 | Works | | | |
| S09 MCP | 19 | Works | | | |
| S10 Skills & plugins | 47 | Works | | | |
| S11 Projects core | 76 | Issues | 1* | | |
| S12 Templates / mini-apps | 48 | Issues | | 1 | |
| S13a Kanban | 33 | Issues | | 1 | |
| S13b Bots / peers / profiles | 44 | Works | | | |
| S14 Health / logs / memory / backup | 31 | Works | | | |
| S15 Servers / transport / iOS | 67 | Issues | | | 1 |
| S16 App shell & shared | 42 | Works | | | |
\* auditor P2, verifier upgraded to P1.

## P1 (verified)
| ID | Finding | Scarf | Hermes | Verifier |
|---|---|---|---|---|
| S03-F1 | **Editing SOUL.md can wipe it.** The first Edit opens a blank editor (draft copied before the async load finishes); Save replaces the whole file and says "saved". SOUL.md drives the agent's identity in every session, local and remote. | `PersonalitiesView.swift:56-58,137-139`; `PersonalitiesViewModel.swift:63-87,152-159` | `agent/prompt_builder.py:1545` | CONFIRMED P1 (arguably P0; held at P1 because the blank editor is visible) |
| S11-F1 | **Project chat hides a project's own CLAUDE.md / .cursorrules.** With no AGENTS.md, the first project chat creates one holding only Scarf's block; Hermes loads one context type, first found wins, so every later Hermes session in that folder (CLI, gateway, mini-app) loses the project's instructions. Live-probed with Hermes's `build_context_files_prompt`. | `ProjectContextBlock.swift:237-244`; `ProjectAgentContextService.swift:111` | `agent/prompt_builder.py:1739-1747` | CONFIRMED, upgraded P2→P1 |

## P2
| ID | Finding | Scarf |
|---|---|---|
| S03-F2 | Bundled `/scarf-widget`, `/scarf-dashboard`, `/scarf-help` name widget kinds that don't exist and use `kind` instead of `type`, so agents build widgets `project_update_dashboard` refuses. | `BuiltinSlashCommands.bundle/scarf-*.md`; catalog `DashboardWidgetCatalog.swift:45-59` |
| S04-F1 | Export All offers Markdown/Quarto, which Hermes always refuses for a bulk export (reported honestly, but can never succeed). | `SessionsViewModel.swift:756-764`; Hermes `sessions_cmd.py:497-500` |
| S12-F1 | On a remote window the cockpit offers mini-app "Open"; the asset handler checks a Mac path and shows a 403. | `MiniAppSchemeHandler.swift:63-68`; `ProjectCockpitView.swift:369-377` |
| S13a-F1 | Drag to Running can leave the card in Running with no message when `kanban dispatch` skips it (cap reached / open parents); Scarf ignores `spawned`/`skipped_*`. | `KanbanBoardViewModel` (`attemptMove`, `mergePolledTasks`); `KanbanService.swift:493-512`; Hermes `kanban_ops.py:60-112` |

## P3
| ID | Finding | Scarf |
|---|---|---|
| S06-F1 | Proxy help says `hermes login <provider>` (deprecated; errors with a provider); should be `hermes auth add …`. | `HermesProxyView.swift:190` |
| S15-F1 | iOS `shellJoin` treats `$` as safe, so a single-word argument containing `$` expands remotely. | `CitadelServerTransport.swift:940-946` |

## Tracked (not counted)
t-62dee8aa (MCP remove "unconfirmed"), t-b74c65a4 (iOS cron interval field), t-ad965a68 (board-wide dispatch without confirm), t-78ced4d2 (iOS remote log follow), t-5ca5eae5 / t-93ddfdc4 (iOS host keys).

---

## Comparison with earlier audits (written after the results above)
| Audit | Files covered | P0 | P1 | P2 | P3 |
|---|---|---|---|---|---|
| #1 whole-app (2026-09-26, pre-fix) | 301 (grep) | 2 | 12 | 40 | 18 |
| #2 blind re-audit (2026-09-27) | 400 (grep) | 0 | 4 | 26 | 28 |
| #3 pre-release (2026-09-28) | **664 (all)** | 0 | 2 | 4 | 2 |

- **No finding from audit #1 or #2 recurs.** Every earlier P0/P1 area was re-traced and reported working.
- **Both P1s are in code the earlier audits did look at**, not only in newly covered files: Personalities and the project
  context writer were in earlier manifests. They're UI/state bugs (a load race; a file-creation side effect), not
  Hermes-contract drift — the class the earlier audits focused on least.
- **Newly covered files (app shell, design, diagnostics, scripts) came back clean.** Full coverage cost little and
  found nothing hidden there.
- **Trend:** findings fell from 72 → 58 → 8, and severity from 2 P0 / 12 P1 → 0 / 4 → 0 / 2.

## Release view
Ready once the two P1s are fixed; both are small and contained (fill the SOUL.md editor after load and refuse to save
an unloaded draft; don't create an AGENTS.md that shadows an existing CLAUDE.md/.cursorrules). The four P2s and two
P3s are safe to ship and can follow in a point release, or be folded in now — each is a few lines.
