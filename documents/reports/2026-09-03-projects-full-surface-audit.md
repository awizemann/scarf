# Projects Full-Surface Audit (P7) — security, performance, data integrity, accessibility

Date: 2026-09-03 · Branch: feat/projects-first-class @ 04ac924 · Four parallel specialist audits over the ENTIRE projects surface (not just this branch's changes). Companion to reports/2026-09-03-projects-stability-investigation.md. Fixes proposed as tasks: t-92 security batches, see TASKS.md "Projects S1/S2/D1/D2/PF/AX".

## Verdict

The branch's 9 commits hold up: all four auditors verified the new invariants (chokepoint refusal with no bypass call sites, per-row salvage, deterministic ids, atomic publishes, doctor repair discipline, honest tests — 1984 ScarfCore + 659 app tests green). What the audits found is mostly OLD surface the hardening didn't reach: adjacent registries with none of the new protections, trust decisions anchored in agent-writable files, tick-driven SSH cost, and a11y gaps in data-dense widgets.

## Security (3 HIGH, 5 MEDIUM, 5 LOW) — theme: trust re-derived from agent-writable files

- **H1** `template.lock.json` (agent-writable) drives uninstall deletion: absolute `projectFiles` paths and `skillsNamespaceDir` are deleted recursively with NO containment re-validation (`ProjectTemplateUninstaller.swift:64-74,160-181`); symlinks followed in `removeRecursively`. Arbitrary user-level file-tree destruction via one edited JSON + one user click.
- **H2** `keychain://` refs unrestricted: `TemplateKeychainRef.parse` accepts any service/account; `KeychainEnvMirror.reconcileAll()` resolves refs from agent-writable manifest/config at every launch and writes plaintext into `~/.hermes/.env` — project A's agent can exfiltrate project B's secret. Cross-project secret isolation is nil.
- **H3** `lock.configKeychainItems` drives `SecItemDelete` of arbitrary reachable items.
- **M1** image widget URL: no scheme/host validation (http/file:// allowed; auto-fires beacon) vs the webview widget's https+host pinning. **M2** mini-app `generated` flag is self-declared and keys the consent-sheet defaults. **M3** `miniapp_grants.json` agent-writable → agent can self-grant (fingerprint is computable). **M4** `project_register` accepts `/` or `$HOME` as root, making every containment check vacuous. **M5** slash-command `name` unvalidated on load; `delete(named:)` builds a path from it.
- LOWs: cron argv flag injection from template `jobs.json`; uninstall destroys untracked `.scarf/` content; zip-bomb on template inspect; TOCTOU on containment checks; exporter forwards agent schema into shared bundles.
- Clean: mini-app sandbox core (CSP connect-src none, containment, main-frame-only bridge, ACP auto-deny), webview policy, WidgetPathResolver, YAML patcher fail-closed, MCP stdio bounds, keychain API usage itself.

## Data integrity (2 CRITICAL, 7 HIGH, 7 MEDIUM, 4 LOW) — theme: the hardening stopped at projects.json

- **C1/C2** `miniapp_grants.json` and `session_project_map.json`: read failure ≡ empty, next write destroys the file (no salvage/quarantine/.bak/refusal). Session map is the SOLE record of session↔project attribution; 1MB cap + no pruning makes truncation inevitable; iOS over SFTP is the likeliest trigger. Both `persist()` functions are sole writers — drop-in chokepoints for the proven inspect/quarantine/refuse shape.
- **H3** `SSHTransport.writeFile` stages to a CONSTANT temp name (`path + ".scarf.tmp"`): concurrent remote writers publish each other's partial bytes — atomic publish, corrupt staging. Applies to projects.json too; the refusal guard can't see it.
- **H4** `ProjectEntry` round-trip drops unknown keys silently (no salvage record, no loss, no banner) — a newer Scarf's field or the future `bots` binding is erased by any older build's save.
- **H5** No cross-process locking anywhere (already tracked t-db8c745b) — chokepoint inspect-then-write is a TOCTOU between app and MCP helper; `.bak` holds the loser's state.
- **H6** Rename updates ONLY the registry; `project.json` keeps the old name forever → every chat injects the stale name via the AGENTS.md block; fleet + project_get disagree. **H7** the doctor cannot see name/path divergence (recordPathMismatch is repair-time-only). **H8** uninstall: local recursive delete destroys untracked `.scarf/` content; remote `rm -f` on a dir fails silently leaving a ghost the doctor then offers to ADOPT (re-registering the uninstalled project, original uuid, cron re-attached). **H9** adjacent stores are unguarded whole-file RMW (session map, grants, model presets).
- Mediums: grants never revoked + deterministic-id path reuse resurrects permissions; `ModelPresetService` actor serialization fictional (fresh instance per call site); name-keyed removal deletes duplicate rows; unbounded session-map growth; AGENTS.md block never stripped on removal; archive is an inert registry bool (cron/watchers/grants live on); no real move flow (hand-move bricks Upgrade, doctor silent).
- Lows: normalization not uniform across lookups (`ProjectStore.swift:154`, scaffolder, chat); iOS shares the unguarded session-map path; name/path-derived keychain slugs frozen at mint.
- 13 invariants verified holding (chokepoint no-bypass, salvage semantics, deterministic ids, rename uuid carry, atomic publish, doctor serialization, crash windows either atomic or doctor-caught).

## Performance (4 HIGH, 4 MEDIUM) — theme: everything hangs off the watcher tick

Baseline (20 projects, SSH, active chat stream → coalesced tick every 0.5-1.5s): **~55-70 SSH round-trips per tick**, +110 every 5 min when the doctor cache expires.
- **H1** cockpit reloads ALL facets per tick (8-12 round-trips: project.json/AGENTS/manifest/cron/MEMORY/miniapps/dashboard×2/upgrade probe), no mtime short-circuit, unconditional @Observable reassignment. **H2** menu probe cache re-probes 2×N per tick (~40 round-trips) for install-time-only facts. **H3** dashboard.json decoded twice per tick by two VMs (sidebar copy feeds only an icon). **H4** `updateProjectWatches` does no diff — remote poller torn down/re-baselined and ~2N local sources rebuilt per tick (absorbs changes landing mid-restart).
- **M1** main-actor sync transport IO: sidebar click = 2 blocking SSH ops; every registry mutator = 3-5 blocking ops (charter C10 exposure; pre-existing, P2-deferred). **M2** markdown_file/image widgets: unbounded reads, no downsampling, re-read+re-decode per tick. **M3** mini-app scheme handler: up to 64MB synchronous main-thread read. **M4** doctor scan (~110 ops) triggered by a background tick, contradicting its own docs.
- Clean: launch path fully off-main, watcher internals, registrar/skill bootstrap idempotence, saveRegistry single-read design, doctor scan bounds, SSH poller batching.

## Accessibility (baseline: real practice, 378 modifier uses; 12 findings)

- HIGH: registry-damage banner + doctor repair completion never announced (no announcements exist app-wide); doctor finding severity VoiceOver-invisible (icon hidden, not in label) — a regression vs the feature's own StatusGridCellView pattern; charts have no accessible values (pie = color-only for everyone); sparklines invisible + stat widgets ungrouped; kanban status = color-only 8pt dot.
- MEDIUM: sidebar icon buttons rely on .help only (regression vs cockpit's labeled buttons); table widget has no header semantics; fixed sizes/9pt fonts defeat text scaling (no @ScaledMetric app-wide); focus stranded after Repair All.
- LOW: log tails fragment + truncate for VO; mini-app WebView container unlabeled, inspector not modal-managed; inline sheet validation errors silent (native alerts elsewhere are fine).
- Clean: sidebar rows, cockpit panel bar (.isSelected), banner internals, sheets' keyboard shortcuts + labeled fields, ListWidget/StatusGrid non-color status channels.

## Proposed remediation batches (same phased process)

- **S1 (urgent)**: uninstall containment re-validation + symlink-safe removal; keychain ref namespace + project binding; SecItemDelete scoping. — the three HIGHs share one fix shape: re-derive trust at time-of-use.
- **D1 (urgent)**: adjacent-registry chokepoints (grants + session map get inspect/quarantine/refuse + .bak; model presets shared instance); SSH unique temp staging; unknown-key preservation in ProjectEntry.
- **D2 (high)**: rename propagation + doctor name/path divergence findings; uninstall ghost/untracked-content handling; name-keyed removal; archive semantics; session-map pruning; AGENTS.md strip on removal; normalization uniformity.
- **S2 (high)**: image URL policy; mini-app generated/consent defaults + grant self-certification; project_register root guard; slash-command name validation; security LOWs.
- **PF (high)**: tick decoupling (cockpit mtime short-circuit, menu probe cadence, single dashboard decode, watcher diff); widget read caps; async mutators (closes P2 deferral + C10 exposure); doctor-off-tick.
- **AX (medium)**: announcements (banner, repair completion), severity in labels, chart/sparkline/table accessibility, sidebar button labels, scaled metrics in widgets.

## Addendum — transport divergence + iOS probe (late-returning, most severe findings of the run)

- **CRITICAL: iOS Citadel `writeFile` is NOT atomic** (`ScarfIOS/CitadelServerTransport.swift:377-388`): SFTP open with `.truncate` zeroes the destination before the first 32KB chunk lands — a dropped cellular connection leaves AGENTS.md / session map / cron jobs.json as a fragment. Falsifies `ProjectDashboardService.swift:346-350`'s "atomic on every transport" premise. Fix: temp+rename in the SFTP path (+ TransportPrivateMode parity — Citadel enforces no 0600 at all).
- **CRITICAL: `RemoteRestoreService` rewrites remote `projects.json` via truncating Python `open(path,'w')`** (`RemoteRestoreService.swift:378-402`) — bypasses salvage/quarantine/refusal/.bak — and `try?` at :394 swallows transport failures so a failed rewrite (and failed cron pausing at :420-424) reports SUCCESS.
- **HIGH: `project.json` has no absent-vs-unreadable discrimination** (`ProjectStore.swift:77-94`): an SSH blip nils the load, `derive()` re-reads facets over the same sick transport and atomically commits a stripped record (board/presets/miniApps nulled). The registry's stat+retry probe pattern needs extending here; writeRecord has no .bak.
- **HIGH: remote watcher signature is mtime-seconds only**, first delta swallowed on every poller restart, and `saveRegistry` never compares against the load baseline — a ≥3s stale-overwrite window on remotes (recoverable via .bak, no refusal fires).
- **MEDIUM: SSH `readFile` channel lacks `-T`** (every other exec path has it) — a user's `RequestTTY` ssh_config or a chatty `~/.zshenv` corrupts reads → false quarantine + per-save .bak churn. **MEDIUM: scp remote spec unquoted** (`SSHTransport.swift:390`), SSH writeFile doesn't mkdir parent (local does), file mode not preserved on remote replace.
- **iOS writes four pieces of state through unguarded bespoke paths** (session map RMW — likeliest CRITICAL-2 trigger; cron jobs.json stale-clobber; SKILL.md silent-fail; AGENTS.md), and iOS never calls `loadRegistryDetailed`, so salvage/quarantine is invisible on iPhone (silently short list, no banner).
- **Missed in P6**: `BuiltinSlashCommands.bundle` (scarf-new.md:25, scarf-dashboard.md:20, scarf-widget.md:29) still instructs unconditional direct file edits — not gated on tool availability, even locally.
- Verified safe: Mac SSH atomic publish, remote .bak/quarantine, transport-independent refusal, shell escaping (except scp spec), chmod-before-mv, circuit-breaker scoping.
