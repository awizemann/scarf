# GW-E0 — Raw transport write-site census & classification

Date: 2026-09-04 · Task t-8ffcb4d0 · Read-only phase of the Guarded-Write Enforcement plan
(`documents/plans/2026-09-04-guarded-write-enforcement-plan.md`).

Census command (re-run this session, main working tree):

```
grep -rn "\.writeFile(" scarf --include="*.swift" | grep -viE "Tests?/|Test\.swift|Tests\.swift|Mock"
```

**42 sites / 27 files** — the plan's grounding count reproduces exactly.

Classes: **G** guard-internal · **C** create-only scaffold · **O** authoritative overwrite ·
**R** destroy-shaped read-modify-write.

Tally: **G 9 · C 9 · O 9 · R 15**.

---

## 1. The table

`file:line` · class · target path · justification · exact E1 annotation (G/C/O only; R sites get
converted in E2 and take no annotation).

| # | file:line | class | target path | justification | E1 annotation |
|---|---|---|---|---|---|
| 1 | `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift:443` | O | caller-supplied (`writeText` seam) | Generic transport seam; bytes come from the caller, this frame reads nothing. The destroy shape, where it exists, lives in the four callers (see §3). | `// UNGUARDED-WRITE(O): generic writeText seam — bytes are the caller's; this frame reads nothing. Callers own their own read-then-write discipline.` |
| 2 | `…/Services/BotAgentConfigService.swift:457` | O | `<profile>/SOUL.md` | Whole-file replace with editor content; `readSoul` is re-run immediately before and THROWS on a present-but-unreadable file, so the write is refused rather than built on a degraded view. | `// UNGUARDED-WRITE(O): whole-file SOUL.md replace from editor content; readSoul re-verified above and throws on unreadable.` |
| 3 | `…/Services/BotsService.swift:279` | **R** | `<profile>/profile.yaml` | read-merge-write; merge base is `fileExists`-inferred and there is no zero-byte / retry probe. | — (E2) |
| 4 | `…/Services/GuardedJSONStore.swift:203` | G | `<path>.bak` | The guard's own one-deep backup. | `// UNGUARDED-WRITE(G): GuardedJSONStore's own .bak publish.` |
| 5 | `…/Services/GuardedJSONStore.swift:212` | G | caller's JSON sidecar | The guard's own publish, after the refusal/backup checks. | `// UNGUARDED-WRITE(G): GuardedJSONStore's own guarded publish.` |
| 6 | `…/Services/GuardedJSONStore.swift:271` | G | `<path>.corrupt-<stamp>` | The guard's own quarantine copy. | `// UNGUARDED-WRITE(G): GuardedJSONStore's own quarantine copy.` |
| 7 | `…/Services/KanbanToolsetEnabler.swift:110` | **R** | `~/.hermes/config.yaml` | Splice of the whole Hermes config from a prior read of the same file. | — (E2) |
| 8 | `…/Services/KanbanToolsetEnabler.swift:158` | **R** | `~/.hermes/config.yaml` | Same shape, disable path. | — (E2) |
| 9 | `…/Services/MiniAppStore.swift:75` | **R** | `<project>/.scarf/miniapps/<id>/state.json` | `load()` is `try? readFile … ?? [:]` — the textbook shape; one blip publishes `{}`. | — (E2) |
| 10 | `…/Services/NousModelCatalogService.swift:177` | O | `~/.hermes/scarf/<nous cache>.json` | Cache write from a fresh network fetch; no prior read of the file feeds the bytes, and the file is a pure cache. | `// UNGUARDED-WRITE(O): models cache published from a fresh network fetch; nothing read from this file feeds the bytes.` |
| 11 | `…/Services/ProjectContextBlock.swift:144` | **R** | `<project>/AGENTS.md` | `removeBlock` splices the user's own prose. Read failures throw and non-UTF-8 returns (good), but there is no stat+retry proof, no zero-byte rule, and no `.bak` — a truncated-but-successful read that still contains both markers republishes the truncation. Sibling `writeBlock` IS guarded; this half was left behind. | — (E2) |
| 12 | `…/Services/ProjectDashboardService.swift:385` | G | `projects.json.bak` | Inline registry guard's backup. | `// UNGUARDED-WRITE(G): saveRegistry's own one-deep .bak, inside the registry guard.` |
| 13 | `…/Services/ProjectDashboardService.swift:406` | G | `~/.hermes/scarf/projects.json` | Inline registry guard's publish (lossy/stale/empty refusals above it). | `// UNGUARDED-WRITE(G): saveRegistry's own guarded publish (loss/stale/empty refusals above).` |
| 14 | `…/Services/ProjectDashboardService.swift:507` | O | `<project>/.scarf/dashboard.json` | `saveDashboard` validates caller-supplied bytes and re-serializes THEM; nothing read from the destination feeds the output. | `// UNGUARDED-WRITE(O): dashboard bytes are the caller's, validated and reformatted; the destination is never read into them.` |
| 15 | `…/Services/ProjectSlashCommandService.swift:122` | O | `<project>/.scarf/slash-commands/<name>.md` | Serialized whole from the in-memory `ProjectSlashCommand` the user edited. | `// UNGUARDED-WRITE(O): command file serialized whole from the in-memory model; destination is not read into it.` |
| 16 | `…/Services/ProjectStore.swift:472` | G | `project.json.bak` | Inline record guard's backup. | `// UNGUARDED-WRITE(G): writeRecord's own one-deep .bak, inside the project.json guard.` |
| 17 | `…/Services/ProjectStore.swift:479` | G | `<project>/.scarf/project.json` | Inline record guard's publish (`inspectRecord` refusal upstream). | `// UNGUARDED-WRITE(G): writeRecord's own guarded publish (inspectRecord refusal upstream).` |
| 18 | `…/Services/RemoteRestoreService.swift:506` | G | `<remote path>.bak` | `mutateRemoteJSON`'s hand-rolled guard: backup. | `// UNGUARDED-WRITE(G): mutateRemoteJSON's own .bak, inside its stat+retry guard.` |
| 19 | `…/Services/RemoteRestoreService.swift:514` | G | remote `projects.json` / `cron/jobs.json` | Same guard's publish (stat+retry probe, zero-byte refusal, object-graph mutate). | `// UNGUARDED-WRITE(G): mutateRemoteJSON's own guarded publish (stat+retry probe above).` |
| 20 | `…/ViewModels/SkillsViewModel.swift:747` | **R** | `<skills dir>/…/SKILL.md` | `loadSkillContent` returns `""` on read failure or non-UTF-8; the editor then saves that empty buffer over the skill. | — (E2) |
| 21 | `scarf/scarf/Core/Services/CatalogService.swift:159` | O | `~/.hermes/scarf/<catalog cache>.json` | Cache write from a fresh network fetch. | `// UNGUARDED-WRITE(O): catalog cache published from a fresh network fetch; nothing read from this file feeds the bytes.` |
| 22 | `scarf/scarf/Core/Services/HermesEnvService.swift:151` | **R** | `~/.hermes/.env` | `setMany`/`unset` rebuild the file from a prior read; on read failure `setMany` falls back to a one-line header and publishes it — deleting every key Hermes owns. The `KeychainEnvMirror` writer of this same file was fixed in G2; THIS one was not. | — (E2) |
| 23 | `scarf/scarf/Core/Services/HermesFileService.swift:1422` | C | `config.yaml.scarf-backup-<stamp>` | Timestamped per-launch backup at a name that cannot pre-exist. | `// UNGUARDED-WRITE(C): per-launch timestamped config backup at a fresh, unique name.` |
| 24 | `scarf/scarf/Core/Services/HermesFileService.swift:2352` | **R** | caller-supplied (private `writeFile` seam) | Seam for five callers, three of them destroy-shaped: `saveMemory`/`saveUserProfile` (MEMORY.md / USER.md, whose loaders return `""` on failure) and the MCP `config.yaml` patch/restore at :1192/:1201/:1210. | — (E2, at the seam and/or its callers) |
| 25 | `scarf/scarf/Core/Services/KanbanTenantResolver.swift:197` | **R** | `<project>/.scarf/manifest.json` | `readManifest` nil ⇒ writes a SENTINEL manifest over the real one; also re-encodes through the model, dropping unknown keys. | — (E2) |
| 26 | `scarf/scarf/Core/Services/ProjectConfigService.swift:92` | **R** | `<project>/.scarf/config.json` | `load` returns nil on a `fileExists` false (inference) and the form then saves a file rebuilt from whatever it holds; the MCP writer of this same file was guarded in W1, this Mac-side one was not. | — (E2) |
| 27 | `scarf/scarf/Core/Services/ProjectConfigService.swift:105` | C | `<project>/.scarf/manifest.json` (cache) | Installer-time copy of the template's `template.json` into a fresh project. | `// UNGUARDED-WRITE(C): installer-time manifest cache into a freshly created project dir.` |
| 28 | `scarf/scarf/Core/Services/ProjectModelPresetBinding.swift:119` | **R** | `<project>/.scarf/manifest.json` | Identical shape to #25 — second writer of the same file with the same sentinel fallback. | — (E2) |
| 29 | `scarf/scarf/Core/Services/ProjectScaffolder.swift:98` | C | `<new project>/.scarf/dashboard.json` | Collision-checked, freshly created project dir. | `// UNGUARDED-WRITE(C): first write into a freshly created, collision-checked project dir.` |
| 30 | `scarf/scarf/Core/Services/ProjectScaffolder.swift:107` | C | `<new project>/AGENTS.md` | Same. | `// UNGUARDED-WRITE(C): first write into a freshly created, collision-checked project dir.` |
| 31 | `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:159` | C | `<project>/.scarf/config.json` | Install-time materialization from the plan. | `// UNGUARDED-WRITE(C): install-time materialization of config.json from the install plan.` |
| 32 | `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:169` | C | template project files | Install-time copy from the unpacked bundle. | `// UNGUARDED-WRITE(C): install-time copy from the unpacked template bundle.` |
| 33 | `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:199` | C | template skills files | Same. | `// UNGUARDED-WRITE(C): install-time copy of a template skill file from the unpacked bundle.` |
| 34 | `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:461` | C | `<project>/.scarf/template.lock.json` | Written once per install from the plan. | `// UNGUARDED-WRITE(C): install-time lock file, composed entirely from the install plan.` |
| 35 | `scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift:934` | **R** | `<project>/MEMORY.md` (or `~/.hermes/…`) | Splice of the user's prose. SEC-L5 closed the unbounded-region hole, but there is still no proof probe and no `.bak`: a truncated read carrying both markers republishes the truncation. The INSTALLER's appendix writer of this same file was guarded in G2. | — (E2) |
| 36 | `scarf/scarf/Core/Services/ProjectUpgradeService.swift:138` | **R** (conservative) | `<project>/.scarf/dashboard.json` | Not an RMW, but destroy-shaped by inference: gated only on `!transport.fileExists(dashboardPath)`, and a dropped round-trip answers `false` — publishing a placeholder over a real, agent-authored dashboard. This is the W1 "`fileExists` IS the inference" pattern, unfixed. | — (E2) |
| 37 | `scarf/scarf/Core/Services/ProjectUpgradeService.swift:200` | O | `<project>/.scarf/upgrade.json` | Provenance stamp composed entirely in memory. | `// UNGUARDED-WRITE(O): provenance stamp composed entirely in memory; the file is re-derivable.` |
| 38 | `scarf/scarf/Core/Services/SkillBootstrapService.swift:354` | **R** (conservative) | `<skills>/<category>/<skill>/SKILL.md` | The "keep the user's newer edit" decision rests on `fileExists` + `try? readFile` → nil ⇒ "missing", so a blip downgrades a hand-edited skill to the bundled copy with no backup. | — (E2) |
| 39 | `scarf/scarf/Core/Services/SkillBootstrapService.swift:382` | O | companion files beside `SKILL.md` | Bundle-owned companions, written only on the upgrade path that already decided to replace. | `// UNGUARDED-WRITE(O): bundle-owned companion file, written on the same upgrade decision as SKILL.md.` |
| 40 | `scarf/scarf/Core/Services/SlashCommandBootstrapService.swift:119` | **R** (conservative) | `<global slash-commands>/<name>.md` | Same version-gate-by-inference shape as #38. | — (E2) |
| 41 | `scarf/scarf/Features/Bots/ViewModels/BotConversationViewModel.swift:531` | C | `/tmp/scarf-bot-chat-<uuid>/message.txt` | Freshly minted 0700 dir; the path cannot pre-exist. | `// UNGUARDED-WRITE(C): staging file in a freshly minted per-send 0700 temp dir.` |
| 42 | `scarf/scarf/Features/Bots/ViewModels/BotsViewModel.swift:108` | O | `<profile>/assets/avatar.png` | Bytes are the picture the user just chose; the destination is never read. | `// UNGUARDED-WRITE(O): avatar bytes are the user's fresh selection; the destination is never read.` |

---

## 2. E2 conversion list (the 15 R sites)

Ordered by blast radius. "Rebuildable" follows the GuardedJSONStore doctrine: a file whose rows
exist nowhere else REFUSES forever (`projects.json` rule); a re-derivable index quarantines and
rebuilds.

| Site | Role of the file | Blast radius if truncated/emptied | Fit | Rebuildable? |
|---|---|---|---|---|
| **HermesEnvService:151** (`~/.hermes/.env`) | Hermes's own environment — API keys, provider config | Hermes stops working; the user's `ANTHROPIC_API_KEY` and every hand-added var are gone, with no `.bak`. Highest-value non-project file in the census. | Proof-based text probe (`GuardedJSONStore.inspect` + `Inspection` reclassification, as `KeychainEnvMirror` already does for this exact file) | **Irreplaceable — refuse.** Secrets are not re-derivable. |
| **KanbanToolsetEnabler:110 / :158** and **HermesFileService:2352 via :1192/:1201/:1210** (`~/.hermes/config.yaml`) | The whole Hermes configuration | Every setting, every MCP server entry, every toolset. Four independent writers, only one (HermesFileService) has a per-launch backup + read-back verification. | Proof-based text probe + `.bak`; ideally ONE `config.yaml` writer seam all four go through | **Irreplaceable — refuse.** Hand-authored. |
| **SkillsViewModel:747** (`SKILL.md`) | User-authored / hub-installed skill body | The skill's whole text, replaced with an empty file the loader's `?? ""` invented. | Proof-based text probe; the editor must also refuse to arm Save on a failed load | **Irreplaceable — refuse.** |
| **ProjectTemplateUninstaller:934** (`MEMORY.md`) | User's long-lived prose | Truncated read republished; no `.bak` today. | Proof-based text probe + `.bak` (mirror the installer's guarded appendix from G2) | **Irreplaceable — refuse.** |
| **ProjectContextBlock:144** (`AGENTS.md`, removeBlock) | User's project instructions | Same as above; sibling `writeBlock` is already guarded, so this is a one-line adoption. | `GuardedJSONStore` text path already used by `writeBlock` | **Irreplaceable — refuse.** |
| **BotsService:279** (`profile.yaml`) | Bot identity as Hermes reads it | Identity keys plus every key Scarf doesn't own (the YAML preservation contract) collapse to a stub. | Proof-based text probe (YAML, not JSON) | **Irreplaceable — refuse.** Hermes/Desktop also write it. |
| **ProjectConfigService:92** (`<project>/.scarf/config.json`) | Template config values incl. keychainRef URIs | Config values lost and the Keychain items they reference orphaned. The MCP writer of this file is already guarded — parity gap. | `GuardedJSONStore` (`inspectDecoding` + mutate, preserving unknown keys, as the MCP path does) | **Irreplaceable — refuse.** User-entered. |
| **KanbanTenantResolver:197** + **ProjectModelPresetBinding:119** (`<project>/.scarf/manifest.json`) | Template manifest / project bindings | A real manifest replaced by a `0.0.0` sentinel; unknown keys dropped even on the success path. Two writers, same file — convert together. | `GuardedJSONStore` + an `extra`-style unknown-key sweep on `ProjectTemplateManifest` | **Partly rebuildable** for a template-installed project (re-cacheable from `template.json`), irreplaceable for a bare one → refuse. |
| **MiniAppStore:75** (`miniapps/<id>/state.json`) | Mini-app persisted state | The mini-app's whole state; the purest `?? [:]` in the census. | `GuardedJSONStore` | **Rebuildable — quarantine and rebuild.** State is app-owned and re-creatable. |
| **ProjectUpgradeService:138** (placeholder `dashboard.json`) | Project dashboard | A real agent-authored dashboard replaced by the placeholder. | Not a store conversion: replace `!fileExists` with a proof-based probe (absent vs unreadable) and skip on anything but proven-absent | Fix is the gate, not the writer. |
| **SkillBootstrapService:354** + **SlashCommandBootstrapService:119** | Bundled skill / slash command, possibly hand-edited | A user's newer local edit downgraded to the bundled copy, silently and permanently (the version check then reports "current"). | Proof-based probe: `unreadable` ⇒ SKIP the install, never "assume missing". `.bak` before an overwrite would be cheap insurance. | Bundled content is rebuildable; the USER'S edit is not → skip on unreadable. |
| **HermesFileService:2352** seam (`MEMORY.md`, `USER.md` via `saveMemory`/`saveUserProfile`) | User's memory prose | `loadMemory` returns `""` on failure; the memory editor saves that over the file. | Proof-based text probe at the seam + refuse-on-failed-load in the editor | **Irreplaceable — refuse.** |

---

## 3. Surprises worth flagging

1. **`.writeFile(` is NOT the whole write surface.** Two helper wrappers hide call sites from the
   grep, and E1's rename will annotate the WRAPPER while the destroy shape lives in its callers:
   - `ServerContext.writeText` (site #1) — 4 real callers, and two of them are the `?? ""` collapse
     W1 closed elsewhere: `SettingsViewModel.saveDirectYAML:845` and `GatewayConfigWriter.saveList:229`
     both do `context.readText(path) ?? ""` on **`~/.hermes/config.yaml`**, splice, and publish. A
     dropped SSH round-trip or a non-UTF-8 byte therefore publishes a config.yaml containing only
     the section being edited. `IOSMemoryViewModel.save:150` is the same shape for MEMORY.md/USER.md
     (its loader sets `text = ""` on a transport failure and Save stays available).
   - `HermesFileService.writeFile` (site #24) — 5 callers, incl. the MCP `config.yaml` patch.
   These caller sites do not contain `.writeFile(` and would survive E1 untouched. **Recommendation:
   E1's scanner should also flag `writeText(` / any local `writeFile(_:content:)` helper**, or E2
   should route them through the guarded seam.
2. **`servers.json` bypasses transports entirely.** `scarf/scarf/Core/Persistence/ServerRegistry.swift`
   `load()` sets `entries = []` on ANY decode/read failure and `save():332` publishes the whole list
   via `Data.write(to:options:.atomic)`. That is the `projects.json` bug verbatim, on the file that
   holds the user's entire server list — and no amount of transport-level enforcement will ever see
   it. Out of GW scope as written; worth its own task.
3. **Parity gaps, not new bugs.** Three files already have ONE guarded writer and one unguarded one:
   `.env` (KeychainEnvMirror guarded / HermesEnvService not), `config.json` (MCP guarded /
   ProjectConfigService not), `MEMORY.md` (installer guarded / uninstaller not), and `AGENTS.md`
   (writeBlock guarded / removeBlock not). The guard was applied to the FILE via one writer, which is
   exactly the theme this plan exists to end.
4. **`manifest.json` has two writers** (`KanbanTenantResolver`, `ProjectModelPresetBinding`) with
   copy-pasted sentinel-fallback bodies, and BOTH re-encode through `ProjectTemplateManifest`, so
   unknown keys are dropped even when everything succeeds. Convert them as one unit.
5. **The version-gate-by-inference pattern** (`SkillBootstrapService`, `SlashCommandBootstrapService`)
   is a class the plan's R definition doesn't literally cover — no mutation of a prior read — but the
   failure mode is identical: a failed read is treated as "absent", and the user's newer file is
   destroyed. Classified R deliberately.
6. **Local-only `Data.write` writers** found in the completeness sweep that are legitimately outside
   the transport surface (staging/exports/diagnostics, not Hermes-owned live state):
   `ProjectTemplateExporter` (staging dir), `SessionsViewModel:778` and `ManageServersView:135`
   (user-chosen save panels), `SkillSnapshotService:230`, `RemoteBackupService:324/369`,
   `MetricKitSubscriber:130`, plus the transports' own internals (`LocalTransport:113`,
   `SSHTransport:403`). No action.
