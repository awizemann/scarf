# Hermes v0.21.1 parity — shared brief for phase agents

You are executing ONE phase of the Hermes v0.21.1 (tag v2026.9.7) parity plan for Scarf, a native macOS/iOS Swift client for the Hermes agent. Read this whole brief, then your phase task (`get_task <id>` via the memophant MCP), then the findings in `documents/hermes-v0.21.1-audit-report.md` (the finding ids like A2/B1/C3 in your task refer to that report).

## Ground rules (charter commandments; absolute)

- C1: every Hermes-release-gated surface goes behind a `HermesCapabilities` flag; a pre-target host (v0.21.0 and older) must render byte-identical to today. Gate v0.21.1 surfaces on `isV0211OrLater` / per-feature flags in the `// MARK: v0.21.1 (v2026.9.7) flags` group of `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift` (Phase 0 creates the group; later phases add flags to it).
- C2: never trust a release note; cite Hermes `file:line` at the tag. Hermes source at the tag is available via `git -C ~/.hermes/hermes-agent show v2026.9.7:<path>` (fetch is done). If you need a tree, `git -C ~/.hermes/hermes-agent worktree add --detach ~/.hermes/hermes-agent-v0.21.1-audit v2026.9.7` and REMOVE it when done. Never touch the user's checkout at `~/.hermes/hermes-agent` itself.
- C3/C4: state.db is read-only; detect schema by PRAGMA/sqlite_master, never by version.
- C5: every `hermes` argv you add must be verified against the tagged argparse; never parse unknown-verb output as success. Safe live probes only: `hermes <verb> --help`, `--version`, explicit dry-runs. Never run a bare unknown verb, never run anything that mutates the user's Hermes home.
- C7: never `git add`/commit `.memory/`, `wiki/`, `design/`, `documents/`, `TASKS.md`, `tasks/`. Leave them dirty.
- C8: never push. Commit on the current branch `feat/hermes-v0211-parity` only.
- C10: nothing new on the main actor that spawns processes or reads state.db; every subprocess has a timeout.

## Working style

- Simple and elegant; reuse before adding; more thought, less code. Follow existing patterns in the file you are editing (look at how the v0.20.x / v0.21 flags, tests, parsers, and Settings rows were done and mirror them).
- Dev cycle per phase: (1) short grounding plan in your head; (2) execute; (3) test for real: build `xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build` and run the ScarfCore package tests (`cd scarf/Packages/ScarfCore && swift test` — some suites are known-flaky under full parallel load; rerun a flaky one in isolation with `--filter` before calling it a failure); (4) adversarial fresh-eyes audit of your own diff (read it as a reviewer who wants to find the bug; check pre-target degradation, unknown-version behavior, error paths, and that you exercised the real function not just your change); (5) one clean commit per logical unit, message ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Add tests in the pattern of the prior release: for capability flags mirror `HermesCapabilitiesTests.swift` (parse-the-version-line, all-flags-on, prior-host-hides-them, patch-release-still-on). For parsers add a drift alarm test with a verbatim fixture captured from the tagged Hermes source.
- Do not widen scope. If you find something outside your phase, create a Memophant task for it (`create_task`) with file:line and move on.

## Memory (memophant MCP, project `scarf`)

- Before coding, `search_memories` for the surface you touch and read what's there; correct stale notes with `edit_memory`.
- Write memory ONLY for durable things: a gotcha that cost you time, a non-obvious Hermes contract (with `source_paths`), an architecture change. Do not write memory for "I changed file X" — git records that. One note per fact, filed under architecture/conventions/decisions/operations/project/roadmap, with `source_paths` when grounded in code. Search first; edit an existing note rather than forking a near-duplicate.
- Record what you shipped and any deliberate NO-OPs in the task's artifacts via `update_task(id, artifacts: ...)`, and move the task to `done` with `move_task` when the commit is in.

## Report back

Your final message must contain: what you shipped (commit hashes), what you deliberately did not do and why, test results (pass/fail counts, any flaky reruns), the fresh-eyes audit findings and how you resolved them, the memory notes you wrote or edited (permalinks), and any tasks you created.
