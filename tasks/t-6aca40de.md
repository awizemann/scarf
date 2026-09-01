---
id: t-6aca40de
title: v0.21 W5: provider tables
status: todo
added: 2026-09-01
priority: high
---

## Description

ModelCatalogService.swift: add overlay-only providers tencent-tokenplan (anthropic_messages, base https://api.lkeap.cloud.tencent.com/plan/anthropic, "Tencent TokenPlan") and nebius-token-factory (openai_chat, https://api.tokenfactory.nebius.com/v1, "Nebius Token Factory"); add aliases tokenplan/tencent-lkeap → tencent-tokenplan and nebius/nebius-tokenfactory/nebius-tf/token-factory/tokenfactory → nebius-token-factory (providerAliases:941). Neither is aggregator/keyless. Run scripts/check-hermes-tables.py ~/.hermes/hermes-agent-v0.21.0-audit until 0 FAILs (3 dormant-overlay WARNs acceptable). Invariant tests. Source: hermes_cli/providers.py:199-237,392-425,454-455.

## Plan



## Artifacts



