---
id: t-3ee1a4a9
title: Confirm swift-stats production retention + installs table for privacy policy
status: done
added: 2026-10-05
---

## Description

The corrected PRIVACY_POLICY.md (2026-10-05) says raw analytics events are deleted after 90 days, and that the backend also keeps the first day each hashed install ID was seen (swift-stats backends/cloudflare migrations/0005_installs.sql), removable with admin.mjs delete-install. Alan to confirm the live retention_days for project "scarf" on api.swiftstats.co, whether migration 0005 is applied in production, and how long Cloudflare invocation logs (observability.logs.invocation_logs = true in wrangler.prod.toml) keep client IPs. Adjust the policy (all three copies) if any of these differ.

## Plan



## Artifacts

2026-10-05: read-only D1 query (wrangler d1 execute stats --remote from ~/Developer/swiftstats.co): projects.retention_days for 'scarf' = 90; the installs table exists (2,710 scarf installs). Policy wording firmed up in the host-key slice. Cloudflare invocation-log retention for client IPs isn't verified; the policy says Cloudflare may log them briefly.

