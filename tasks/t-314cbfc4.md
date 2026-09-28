---
id: t-314cbfc4
title: B02 Models & providers: hide unroutable providers, Nous date, Anthropic OAuth, DeepSeek aliases
status: done
added: 2026-09-27
priority: urgent
---

## Description

Wave 1. Findings: S06-F1 (P1 — Alan: hide providers Hermes 0.21.5 can't route; preflight warns on an existing unroutable provider), S06-F2 (Nous updated_at fractional seconds), S06-F3 (double browser tab on Anthropic OAuth), S06-F4 (deepseek aliases → deepseek-flash). Correct .memory/decisions/aggregator-providers-must-skip-the-model-provider-mismatch.md:31. Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md.

## Plan

- S06-F1: add a Hermes-routable provider set derived from v2026.9.24 source (registry + aliases + openrouter/custom + direct-API expansions); filter the model picker's provider list to it; ModelPreflight warns when config names an unroutable provider. Add a check-hermes-tables.py lane to keep it in sync. C1: filtering only applies when capability says the host is on the version the set was derived for (or set matches older hosts too). Blast radius: ModelCatalogService (Mac+iOS share ScarfCore), ModelPickerSheet, ModelPreflight callers, iOS model picker if any.
- S06-F2: parse auth.json updated_at with fractional seconds (reuse NousModelCatalogService.parseISODate).
- S06-F3: skip Scarf's auto-open for anthropic OAuth on local Mac (Hermes opens itself).
- S06-F4: deepseek-chat/reasoner -> deepseek-flash.
- Tests: ScarfCore ModelCatalog/Preflight suites, NousSubscription date parse, OAuth auto-open decision.
- Memory: fix decisions/aggregator-providers-must-skip-the-model-provider-mismatch.md:31; search mistral/deepseek/keepalive notes + wiki.

## Artifacts

Merged into fix/hermes-v0215-blind as fe972d0e (commits 56587dfc, fddff810, ccaa817b, 3f427542). Orchestrator audit: tables lanes=8/8 OK; ScarfCore B02 suites 56/56 pass; memory note architecture/hermes-routable-provider-table-gates-the-model-picker reviewed (needed, anchored). Carried to B12: iOS preflight has no can't-route warning; ModelCatalogService.provider(for:)/model(providerID:modelID:) lack capabilities (no callers); release-note line for <v0.21.4 hosts keeping full list; kimi-coding plugin skipped by static lane (aliases may be missing).

