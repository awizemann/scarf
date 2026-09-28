S08 · WORKS-WITH-ISSUES · 0/0/1/2 · no P0/P1
S09 · WORKS-WITH-ISSUES · 0/0/1/0 · no P0/P1
S01 · WORKS-WITH-ISSUES · 0/0/1/1 · no P0/P1 · note F2 (no Stop control in main chat) vs t-14157321 (Bot Chat Stop) — check overlap
S04 · WORKS-WITH-ISSUES · 0/1/1/1 · F1 P1 (remote sqlite JSON version gate) → verifier launched · F2 export lineage (auditor saw 1 line of t-86bb3d9f; verified from code)
S11 · WORKS-WITH-ISSUES · 0/0/2/2 +1 tracked · no P0/P1
S15 · WORKS-WITH-ISSUES · 0/0/2/3 · no P0/P1 · F1 scp quoting PLAUSIBLE (spot-check?) · handoff: IOSCronViewModel:490 exit-code-only pause/resume
S14 · WORKS-WITH-ISSUES · 0/1/1/1 · F1 P1 Python discovery vs bash launcher → verifier launched
S06 · WORKS-WITH-ISSUES · 0/1/0/3 · F1 P1 unroutable models.dev providers → verifier launched
S10 · WORKS-WITH-ISSUES · 0/0/2/2 · no P0/P1
VERDICT S04-F1 · CONFIRMED · P1 · version gate RemoteSQLiteBackend:385-418; local probes json1 (LocalSQLiteBackend:359); Hermes json_extract unconditional hermes_state_common.py:67-74; iOS shares; resume tip still OK, list+transcript truncated; fix: probe SELECT json_valid('{}')
S02 · WORKS-WITH-ISSUES · 0/0/1/3 · F1 P2 compacted history hidden (active=1 only) → sent to verifier for severity (possible upgrade)
S05 · WORKS-WITH-ISSUES · 0/0/1/2 · no P0/P1
VERDICT S14-F1 · DOWNGRADED P2 · mechanism confirmed (install.sh:2118-2176 bash launcher; discovery 3 strategies all miss); Voice opt-in → P2. Note: this Mac's ~/.local/bin/hermes is a hand-made test shim (#!/bin/sh)
S03 · WORKS-WITH-ISSUES · 0/1/2/2 · F1 P1 = DUPLICATE of S14-F1 (verified P2); S03 adds: Hermes Voice playback silently falls back to system voice (MessageSpeechService.swift:166-175) → merge into S14-F1 at P2
S07 · WORKS-WITH-ISSUES · 0/0/6/2 · no P0/P1
S13 · WORKS-WITH-ISSUES · 0/1/3/3 · F1 P1 kanban comments never show → verifier launched · F4 = dup of S03-F3 (platform_toolsets.cli vs acp)
VERDICT S06-F1 · CONFIRMED · P1 · live: 37/223 cache providers accepted by resolve_provider, 186 rejected (openai routes via custom so upper bound); preflight only checks non-empty; chat fails loudly "Unknown provider"; decision note aggregator-providers... repeats assumption
S12 · WORKS-WITH-ISSUES · 0/1/2/1 · F1 P1 remote template uninstall skips files (tilde paths) → verifier launched
VERDICT S02-F1 · CONFIRMED UPGRADED P1 · all transcript paths active=1 (HermesDataService:1355); Hermes default in_place compaction archives active=0 compacted=1; Hermes's own resume projection shows compacted (bug #92080); ACP replay suppressed and also active-only; summary row sub-claim refuted (display_kind hidden by design); decision note hermes-v0-18-compatibility-decisions.md:18 stale
VERDICT S13-F1 · CONFIRMED mechanism, DOWNGRADED P2 (live probe: no id in show --json; whole-array try? → 0 comments; events id 0 dup ForEach). Orchestrator note: judgment call — Comments is default tab and carries BLOCKED/CHANGES REQUESTED reasons; flag to Alan as possible P1
