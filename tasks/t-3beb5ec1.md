---
id: t-3beb5ec1
title: P7d Settings/catalog: WhatsApp decline key, threshold parse, picker aliases, MCP reload, a11y
status: done
added: 2026-09-26
---

## Description

Source: documents/plans/2026-09-26-p6-surface-audit-findings-and-fix-plan.md §P7d. (1) MED WhatsApp Decline Message is written to whatsapp.unauthorized_dm_decline_message; Hermes reads only top-level / gateway. (gateway/config.py:789, config_loader.py:103 _presence, run_inbound.py:140 @v2026.9.24) → read/write the global key, label it as applying to all platforms; read `decline` case-insensitively (Hermes _normalize_choice lowercases); below 0.21.4 show "not supported by this Hermes — behaves as pair" instead of a working choice. (2) LOW threshold_tokens `256_000` / `300000.0` parse to 0 (HermesConfig+YAML.swift:470) — mirror Python int() (strip `_`, truncate floats). (3) LOW ModelPickerSheet opens blank for alias providers (chatgpt on ≥0.21.4, kimi, moonshot) → canonicalise via canonicalProviderID(_, capabilities:) when no row matches. (4) LOW MCPServersView: reload with fresh capabilities when capabilitiesStore changes (first connect / upgrade re-detect). (5) LOW opencode-free offered below v0.20.5 (first at v2026.8.19 — verify) → isV0205OrLater && !isV0214OrLater. (6) LOW a11y: MCP test-result icon needs .accessibilityLabel. (7) LOW GeneralTab Excluded Providers help text claims Scarf's picker hides them — filter them in the picker or reword (prefer filtering if cheap, matching Hermes inventory.py).

## Plan



## Artifacts

Commits bc103414..1008f863. WhatsApp decline message moved to the global key Hermes reads (unreleased spelling, no migration); below 0.21.4 the option reads "not supported — behaves as pair"; Python-int threshold parse; picker canonicalises alias providers on open; MCP reloads on capability re-detect + a11y label; excluded-providers help reworded (filtering deferred — larger); opencode-free floor v0.20.5 (undetected hosts unchanged). ScarfCore 3729 pass, HermesP7dSettingsCatalogTests (8). Follow-ups: ModelPresetEditSheet may share the alias-blank bug; filter excluded_providers in Scarf's pickers.

