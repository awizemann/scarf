---
title: Hermes Release Audit Process
type: note
permalink: scarf/conventions/hermes-release-audit-process
tags: [hermes, process, audit, versioning, capability-gating]
created: 2026-06-21
updated: 2026-09-08
reviewed: 2026-09-08
reviewed_by: claude-opus-5
---

The repeatable process for auditing a new Hermes release against Scarf. Canonical procedure lives in the repo skill `.claude/skills/hermes-release-audit/SKILL.md`; this note is the memory-backend-discoverable summary. Done thirteen times (v0.11 → v0.21.1).

## Observations

- [gotcha] **A removal needs an upper bound, not a floor.** A patch tag can re-add a surface an earlier release deleted: `plugins/web/tavily/` was removed at v0.21.0 and restored at v0.21.1, so `hasTavilyWebBackend { !isV021OrLater }` hid a live backend on every later host. Model a removal as a WINDOW (`semver == 0.21.0`) until a later tag confirms it stayed gone, and re-check every previously-modelled removal each cycle. #gating
- [gotcha] **A modularization moves files, so "absent at the old tag" cannot be read from a path.** v0.21.1 split `hermes_cli/main.py` into `hermes_cli/subcommands/<verb>.py`; `git show <old-tag>:<new-path>` fails and a naive floor check reports the surface as new. Four v0.21.1-looking surfaces were actually v0.15–v0.18. Walk the SYMBOL across every tag over every location it has had (`git log -S<needle> -- <old> <new>`, then `git tag --contains <commit>`), and gate at the true floor — gating an old surface at the new release hides something the host already has. #verify #gating

- [law] **Release notes lie — verify every claim against the tagged Hermes source (`file:line`).** Documented burns: v0.16 "MiniMax 1M" (real 512K); v0.17 framed `/version` as new (predated it), `/billing` + MCP elicitation as universal (both gateway/CLI-only, never reach the ACP client), and listed "cron per-job profile" in both shipped AND reverted lists. #verify
- [law] **Everything new is capability-gated; pre-target hosts render byte-identical.** Min supported Hermes v0.6.0. Gate on the minor (`>= X.Y.0`), group flags by release in `HermesCapabilities.swift`, add an `isVXYOrLater` predicate. Never throw on unknown CLI subcommand / missing column / new wire field. #gating
- [method] **Acquire source at the exact tag, non-destructively.** `git fetch --no-tags origin tag vYYYY.M.D` in `~/.hermes/hermes-agent`, then `git worktree add --detach ~/.hermes/hermes-agent-vX-audit v<new>`. Never disturb the user's checked-out copy. Confirm semver in `pyproject.toml`. Clean up with `git worktree remove`. #source
- [method] **The per-surface diff is the highest-leverage tool**: `git -C ~/.hermes/hermes-agent diff v<prev>..v<new> -- <subpath>`. Empty diff = byte-stable surface = no Scarf change. For a large release, fan out one read-only agent per surface, each grounding findings in source `file:line`. #diff
- [surfaces] The integration surfaces to sweep: (1) state.db schema → HermesDataService vs hermes_state.py; (2) ACP wire → ACPClient/ACPMessages vs acp_adapter/; (3) CLI verbs → all runHermes sites vs cli.py/subcommands argparse; (4) config.yaml keys → HermesConfig+YAML/setSetting vs config schema; (5) models/providers → ModelCatalogService vs hermes_cli/{providers,models,xai_retirement}.py; (6) gateway platforms → GatewayPlatformSettings vs plugins/platforms + gateway/config.py; (7) MCP/Skills/Curator; (8) security/managed-scope/cron. #surfaces
- [meta] **Audit the argv, not just the UI.** Grep every `hermes` invocation and confirm each verb/flag against the new argparse. This pass caught 4 pre-existing Health bugs in the v0.17 cycle that survived prior audits (a feature can ship and look wired while every invocation silently fails). Separate "the upgrade forces this" from "pre-existing bug found while in here". #cli-audit
- [meta] **Live-confirm high-impact findings with safe probes only** (`--help`/`--version`/explicit dry-run). Never run a bare unknown verb (routes to an agent, burns a turn) or anything that downloads/mutates. The installed binary's version string can lag its actual commit (`git describe`). #confirm
- [persist] On each cycle, write a `decisions/hermes-vX-compatibility-decisions` note (what shipped + why, incl. the deliberate NO-OPs so the next audit doesn't re-litigate them) and an `integration/hermes-vX-wire-verification` note; update the version-target notes + `wiki/Hermes-Version-Compatibility.md` (this wiki page drifts — was two cycles stale at v0.17); then hand to the `scarf-release-prep` skill for the cut. #persist

## Relations
- relates_to [[Hermes Version Management]]
- relates_to [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes Version Management]]
- relates_to [[Hermes v0.21.1 Audit Findings]]
