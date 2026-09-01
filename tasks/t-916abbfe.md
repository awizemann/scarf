---
id: t-916abbfe
title: v0.21 W2: Health/version + gateway status parsing
status: done
added: 2026-09-01
priority: high
---

## Description

HealthViewModel: offline --version now emits NO update line — treat absence as unknown, not up-to-date; match "Update available" prefix to catch singular "1 commit behind" and count-less shapes (:176,:349,:755); remove/gate web_extract health check row (:261 — coordinate with W1, W1 owns Settings files, W2 owns HealthViewModel entirely). GatewayViewModel.swift:124-125 pre-existing bug: markers "service is loaded"/"stale" never match — re-anchor on real output: "✓ Gateway is running (PID:", "✗ Gateway is not running", "(Running manually", "To install as a service:". Verify against v2026.8.31 source at ~/.hermes/hermes-agent-v0.21.0-audit (hermes_cli/gateway.py:8898-9010, _startup_fast.py:238-249, banner.py:344-380).

## Plan



## Artifacts



