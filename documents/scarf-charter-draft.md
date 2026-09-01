# Proposed Scarf project charter — DRAFT for Alan's review, 2026-09-01

The charter file (`.memory/charter.md`) is human-owned — Memophant refuses agent writes to it. This draft is in the format birdwatch's charter uses (identity / commandments / guardrails / non_goals). Install it via Memophant when you're happy with it; edit freely — the commandments below are distilled from decisions already recorded in Scarf's memory, so nothing here should be new, only newly absolute.

```yaml
---
identity: |
  Scarf is a native macOS (and companion iOS) GUI for the Hermes AI agent — a Swift/SwiftUI
  multi-window client where each window is bound to exactly one Hermes server, local or over SSH.
  It reads Hermes's state.db, drives chat over ACP, and shells the hermes CLI; it is a CLIENT that
  makes Hermes legible, safe, and pleasant, for people who live in a real Mac app rather than a
  terminal or an Electron shell. It is NOT a fork of Hermes, not an agent runtime of its own, and
  never a UI that invents state Hermes doesn't hold.
commandments:
  - id: C1
    text: Never ship a Hermes-release-gated surface without a HermesCapabilities flag or schema/table
      detection; a pre-target host must render byte-identical to the prior Scarf release.
    rationale: Minimum supported Hermes is v0.6.0 and users upgrade the agent and the GUI on
      independent schedules; graceful degradation is the compatibility contract.
  - id: C2
    text: Never treat a Hermes release-note claim as fact — a finding is real only when cited
      against the tagged source (file:line), and never bump a capability floor without it.
    rationale: Release notes have lied in every audited cycle (v0.16 context sizes, phantom verbs
      like approval-check in v0.21); shipping on notes alone produced dead UI rows before.
  - id: C3
    text: Never write to state.db — Scarf reads it read-only; all mutations go through the hermes
      CLI or ACP.
    rationale: The schema is Hermes's property and migrates under its auto-migrator; a foreign
      writer risks corruption and version skew across every remote backend.
  - id: C4
    text: Never detect schema by SCHEMA_VERSION — probe PRAGMA table_info / sqlite_master for the
      specific column or table, and tolerate its absence.
    rationale: Hermes adds columns without bumping the version (v0.21 proved it), and Bot Mode
      tables are created lazily, so presence is never implied by the installed version.
  - id: C5
    text: Never assume a CLI invocation works because the UI renders — every hermes argv Scarf
      passes must be verified against the tagged argparse, and unknown-verb output must never be
      parsed as success.
    rationale: A bare unknown verb routes to the agent and "succeeds"; four shipped Health features
      were silently broken this way across multiple releases.
  - id: C6
    text: Every user-facing "Export…" lands its artifact on the user's Mac, whichever host Hermes
      runs on; never hand a local save-panel path to a possibly-remote CLI.
    rationale: Decided across gh#129/#130/#132; remote hosts made the naive path a data-loss trap.
  - id: C7
    text: Never git add or commit the Memophant-managed tiers (.memory/, wiki/, design/, code/,
      sessions/, documents/, vendors/, templates/, TASKS.md, tasks/) — leave them dirty.
    rationale: Each tier goes through Memophant's per-tier secret-scanned commit bar, human-driven.
  - id: C8
    text: Never push to a remote without Alan's explicit say-so; main is fine for small work,
      branch for large or phased work.
    rationale: Standing operator instruction; releases are cut by the maintainer's release.sh only.
  - id: C9
    text: Never place a secret in chat or a file — credentials go to the Keychain via
      set_vendor_credential; anything Scarf itself stores for users goes in the macOS/iOS Keychain.
    rationale: wiki/ and documents/ are publishable tiers, and Scarf handles users' SSH and
      provider credentials — leakage is unrecoverable.
  - id: C10
    text: Never block first paint or the main actor on process spawns, SSH, or state.db reads —
      heavy work starts lazily off-main, and every subprocess has a timeout.
    rationale: Scarf fronts a remote, sometimes-wedged agent over SSH; one un-timed spawn freezes
      a window whose whole purpose is showing what the agent is doing.
guardrails:
  - Search Memophant memory before assuming; record durable decisions as notes under the six
    canonical folders with source_paths when code-grounded; correct stale memory as you go.
  - Follow the audited dev cycle for large work — plan (with Memophant tasks) → execute → test for
    real → adversarial fresh-eyes audit → clean commit.
  - Run scripts/check-hermes-tables.py against a checkout AT the target tag until it exits 0
    before shipping any provider-table change.
  - Each Hermes parity cycle adds a MARK-grouped flag cluster + HermesCapabilitiesTests mirroring
    the prior release's pattern (parse, all-on, degradation, patch-still-on).
  - Consult design/ before UI work; agent artifacts go to documents/ via write_tier_file, never a
    docs/ folder.
  - Build via ./scripts/build-detached.sh; verify with ScarfCore tests before calling work done.
  - Prefer reusing an existing surface over adding one; more thought, less code.
non_goals:
  - Becoming an agent runtime, gateway, or Hermes fork — Scarf orchestrates and renders; Hermes
    thinks and acts.
  - Feature-parity-chasing the Hermes Electron desktop app for its own sake — adopt a surface only
    when Scarf can do it natively better or users need it for interop (Bot Mode qualifies; terminal
    pets do not).
  - Mac App Store distribution — Scarf reads ~/.hermes directly and drives SSH; sandboxing is
    incompatible. Developer ID + notarized Sparkle updates only.
  - Supporting Hermes below v0.6.0, or macOS/toolchains below the project's stated floor.
  - Reimplementing group-room orchestration or other client-side Hermes-desktop engines unless we
    accept owning them outright — a half-compatible second orchestrator is worse than none.
updated: 2026-09-01
---
```

Notes for review:
- C1/C2/C4/C5 codify the hermes-release-audit laws that currently live only in the skill + memory.
- The Bot Mode non-goal line draws the boundary the v0.21 audit recommends (Phase A yes, rooms only as a deliberate owned project).
- Per Orchestric's model, the charter supersedes memory notes and CLAUDE.md; once installed, the always-injected core keeps every future session (and subagent) aligned before it reads anything else.
