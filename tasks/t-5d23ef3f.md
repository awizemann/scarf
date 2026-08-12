---
id: t-5d23ef3f
title: P3b: Settings — secrets.bitwarden.encrypted_cache + secrets.command.* + telemetry.shared_metrics + database.* knobs
status: done
added: 2026-08-12
---

## Description

Phase 3 items 5+6 from t-1cc0a505. secrets.bitwarden.encrypted_cache.{enabled,max_stale_seconds} + secrets.command.* (any-CLI vault helper) extending the existing Bitwarden settings group; telemetry.shared_metrics.enabled (privacy toggle, default false); database.{journal_mode,wal_autocheckpoint,journal_size_limit} (advanced, remote/container servers). Gate on isV020OrLater; verify keys against ~/.hermes/hermes-agent (v2026.8.3) config_defaults.py. Tests required. Plan: documents/hermes-leftovers-2026-08-12-plan.md.

## Plan



## Artifacts



