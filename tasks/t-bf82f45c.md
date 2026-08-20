---
id: t-bf82f45c
title: F3: Audit fixes — MCP catalog data, personalities, curator polish, test honesty
status: done
added: 2026-08-20
---

## Description

Fresh-eyes audit fixes (branch feat/hermes-v0204-parity). (a) OptionalMCPCatalog.swift: asana/atlassian/paypal/square transports .sse→.http (manifests declare type: http; Hermes writes no transport key and uses streamable-HTTP — Scarf's transport: sse routes a different client that hard-fails with strict_redirect_headers); figma description restore verbatim (ends "via https://mcp.figma.com/mcp (OAuth)."); n8n needs BOTH N8N_BASE_URL and N8N_API_KEY — make requiredEnvVar plural or add the second; gate OptionalMCPCatalogPickerView on isV0204OrLater (roster is a v0.20.4 snapshot). (b) HermesPersonalities.swift:117-120: handle tone/style — compose preview like render_personality_prompt (system_prompt + "Tone: …" + "Style: …"); a tone/style-only user entry must not blank-override a built-in's identity; add test. Also honor hasBuiltinPersonalitiesInCode where the capability is reachable: on pre-0.20.4 hosts prefer config-parsed entries (a user who deleted a built-in from config.yaml genuinely removed it) — union statics only at 0.20.4+; if capabilities aren't reachable in the parse layer, thread the flag from the call sites. (c) Curator: parsePurge sentinel is lowercase "curator: no archived skills older than Nd." — fix case-sensitive literal so effectiveDays parses (CuratorService.swift:540); fix two stale docstrings claiming ISO when column (real output is relative "3d ago"); remove dead branches :438 and :554; add a test that garbled purge output keeps the destructive button disabled. (d) Test honesty: replace tautology tests in HermesMCPServerV0204Tests.swift (synthesized-Equatable self-asserts) with malformed identity_header YAML shape tests matching Hermes validation (unknown value_from → Hermes drops header, Scarf coerces .static — align or document; static without value; truthy scalar strict_redirect_headers).

## Plan



## Artifacts



