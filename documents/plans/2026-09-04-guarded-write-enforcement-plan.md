# Guarded-Write Enforcement (GW) — Plan

Date: 2026-09-04 · Owner: orchestrator session · Origin: P8 audit theme "guards applied to files, not writers" — adoption of GuardedJSONStore is convention enforced by audit, not by the compiler. Goal: make it structural, whole-app, without breaking any existing functionality.

Grounding: 42 raw `.writeFile(` call sites across 27 files (census 2026-09-04, main @ 73fefe98); only 8 files adopt GuardedJSONStore. Unconverted writers include non-projects surfaces: BotsService, BotAgentConfigService, KanbanToolsetEnabler, KanbanTenantResolver, SkillsViewModel, SkillBootstrapService, HermesEnvService, NousModelCatalogService, CatalogService, ServerContext, HermesFileService.

Decisions (Alan, 2026-09-04): enforcement = BOTH compile-time rename AND CI scan test; scope = whole app.

## Invariants (every phase)
- No behavior change except where a destroy-shaped RMW is converted (behavior change = refusing to destroy data).
- ScarfCore + scarf scheme + ScarfIOS tests green before a phase closes; build Release config too (t-bb02177b precedent).
- Charter C3 (never write state.db), C6, C7, C8, C10 apply throughout.
- Each phase ends with the sub-agent's own fresh-eye audit of its diff and memory notes for durable learnings (with source_paths).

## Phases

### GW-E0 — Census & classification (read-only)
Read every raw write site; classify: (G) internal to a guard implementation (GuardedJSONStore itself, ProjectStore/Dashboard inline guard shape); (C) create-only scaffold (file cannot pre-exist / mkdir-style); (O) authoritative overwrite — content derives entirely from in-memory state or a fresh user action, not from a prior read of the same file; (R) destroy-shaped RMW — read → mutate → replace where a failed/absent read can publish a truncated file. For each (R): note the file it writes, blast radius, and whether GuardedJSONStore fits or a proof-based probe (ProjectContextBlock-style) fits better. Deliverable: documents/reports/2026-09-04-gw-e0-write-site-census.md with a table (file:line, class, target path, justification text to use in E1, convert? Y/N). No code changes.

### GW-E1 — Enforcement seam (mechanical, whole-repo)
1. Rename `writeFile` → `unguardedWriteFile` on the ServerTransport protocol and all conformances (local, SSH, Citadel/iOS, test transports/mocks). No shim left behind.
2. Every call site keeps identical behavior and gains `// UNGUARDED-WRITE(<class>): <reason>` (reason from E0 table) on the line above. GuardedJSONStore's internal publishes are class G.
3. New test (ScarfCore or scarf scheme, wherever the source tree is reachable) that scans Sources for: (a) any `.writeFile(` on a transport — must be zero; (b) any `.unguardedWriteFile(` without an UNGUARDED-WRITE annotation — must be zero. Keep the scanner dumb and fast (line-based), with a clearly documented escape hatch.
4. Full test suites green; Release builds.

### GW-E2 — Convert destroy-shaped RMW writers found by E0
For each (R) site outside the already-guarded set: convert to GuardedJSONStore (JSON sidecars) or proof-based probe + .bak (text files), preserving unknown keys where the file is shared/portable. One commit per surface (bots / kanban / skills / env / other) so blame stays legible. W1-style tests per conversion: transport-blip does not truncate; zero-byte is damage; quarantine-and-rebuild only where the file is rebuildable (follow the GuardedJSONStore doc's projects.json-vs-sidecar distinction — a file whose rows exist nowhere else refuses, it does not quarantine). Remove each converted site's UNGUARDED-WRITE annotation (the scanner enforces the shrinking allowlist).

### GW-E3 — GuardedSidecarStore conformance protocol + adoption docs
Small protocol (name at implementer's discretion) that packages the discipline for new stores: inspect → decode-or-quarantine → mutate → guarded publish, with associated-type document and defaulted implementations delegating to GuardedJSONStore. Refactor at least two existing adopters (e.g. MiniAppGrantStore, ModelPresetService) onto it to prove it carries their weight — behavior-identical, tests untouched and green. In-code doc comment is the adoption guide; add a pointer from GuardedJSONStore's header.

### GW-E4 — Orchestrator audit (this session)
Plan-conformance audit of E0–E3; validate every memory note the sub-agents wrote (needed? redundant? drift-anchored via source_paths?); fresh-eye pass over the combined diff.

### GW-E5 — Full-surface audit
Fresh-eyes specialist audits over the ENTIRE touched surface (every file/service the phases touched plus their callers), not just the diffs: security, performance, data integrity, accessibility (a11y only where the touched surface has UI). Findings → new tasks, same phased process.

## Task map
One Memophant task per phase, tagged gw-enforcement; orchestrator moves states (todo → doing → done) and is the only writer of the board.
