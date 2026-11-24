---
title: Hermes v0.23.4 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-23-4-compatibility-decisions
tags: [hermes-v0.23, compatibility]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesWebhookSubscribe.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: 2da6771e73dea8b429b364964a4eba7f850975e7
created: 2026-11-24
updated: 2026-11-24
---

Audit of v0.23.0 → v0.23.4 (2026-11-24), branch feat/hermes-v0234-parity. Full report: documents/reports/hermes-v0.23.4-audit.md. No state.db or ACP change; patch-level floors in HermesCapabilities `MARK: v0.23.1–v0.23.4 flags`.

## Observations
- [decision] Floors checked tag by tag: Yuanbao left core v0.23.1; webhook masked secret, --signature, cron wrap_response, restart-when-idle v0.23.2; cache_ttl auto default v0.23.3; profile list delete-incomplete rows v0.23.4 (parsed content-based, no gate) #hermes-v0.23
- [decision] Settings surfaces whose keys are older are still shown only from the release that made them matter (clarify timeout field from v0.23.1, cache_ttl 'auto' option from v0.23.3) so pre-target hosts render byte-identical (charter C1) #hermes-v0.23
- [constraint] Webhook re-subscribe omits --signature when the name exists and the picker is left on Generic, because Hermes keeps an existing route's pin only when the flag is absent (_route_signature) #webhooks
- [fact] Clarify timeout: legacy clarify.timeout wins over agent.clarify_timeout from v0.19.1 (resolve_clarify_timeout), <=0 = no limit; Scarf edits whichever key Hermes uses #settings
- [fact] No-ops verified: state.db DDL (moved to persistence/sqlite/_schema_ddl.py; new prompt_cache_clock column and resumable_subagents table unused), session source values, ACP wire, every Scarf CLI verb/flag, provider tables lanes=8/8 #hermes-v0.23

## Relations
- relates_to [[Hermes v0.22 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.23 gateways run from inline -c launchers; process matcher must recognise them]]
