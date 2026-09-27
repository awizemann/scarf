---
id: t-86bb3d9f
title: R15 Touched-surface re-audit and follow-up phases
status: done
added: 2026-09-26
---

## Description

Whole-surface audit of every file touched (not only the diff); new findings → new phases via the same process; then merge fix/hermes-v0215-audit to main locally (no push).

Carry-over items reported by phase agents (triage in R15, fix via same process):
- R02: local default-bot context drift when host sticky active_profile changes after pinning (pre-existing).
- R01: pre-0.20.6 MCP detail view shows "(all)" for a blank include item (display only).
- R03: nvidia natively uses vendor/model ids — may need the preflight skip; CredentialPoolsView ~1194 write plan without capabilities.
- R06: SSH round-trip count on very large skill trees (single `find` fast path).
- R07: polling a stopped named profile costs up to 2 extra SSH round trips; SSH host starting with `-` unguarded in terminal command; remote hermes path with spaces / fish shell break terminal + chat-pane commands.
- R08: /scarf-* remote bootstrap per-command failures only logged (accepted).
- R09: Bot CLI path doesn't call notePromptWire (/help to a bot keeps literal keys); plugin response_transformed resend appends instead of replacing; related open tasks t-25748a3b, t-15013d78; analytics ChatInputMode.quickCommand name misleading.
- R11: Chat pane loads only a chain's tip transcript (RichChatViewModel ~2845/2962/3381); ACP provenance update ignored (active highlight lost after mid-chat rotation); chain delete/export act on tip only (export could use --lineage logical); tip projection adds up to 3 serial queries per refresh; usage fetch capped at 2000 rows incl. subagents.
- R12: Hermes threat scan blocks template memory entries whose id contains system/secret/hidden/ignore/override (tools/threat_patterns.py:31); template memory block over Hermes's char limit trips outside-edit check; legacy [tmpl:] jobs still multi-attribute; ProjectDoctorService.swift:360 path-reuse check skips new [tmpl:] [proj:] names; template-author template version not bumped (Alan's call); catalog.sh build modified .gh-pages-worktree/templates (left alone); installer cron naming lacks integration test.
- R05: (see its final report).

## Plan

Integration 8b311060 (R01–R17 merged). 171 touched production files split into 8 areas (scratchpad/audit/T1..T8). 8 read-only auditors audit the WHOLE content of each touched file against Hermes v2026.9.24 (brief: scratchpad/audit/R15-BRIEF.md). Findings → verify P0/P1 → fix phases via the same process → final gate (full scarfTests serial + Smoke UI) → merge to main locally.

## Artifacts

documents/audits/hermes-v0.21.5-full-app-audit/r15-touched-surface-audit/ (8 area reports + P1-verification). Fixed via R18a/b/c + R19; final gate green; merged to main as 3a9da0b8.

