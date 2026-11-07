---
id: t-ea88fc8c
title: UI-gate failures on on-screen runs (resolved: run in Tart VM)
status: done
added: 2026-11-07
priority: high
---

## Description

On-screen runs on this Mac hit host-only issues with Hermes v0.23.0: copied fixture homes carry absolute venv paths in installs/<key>/facts.json (pm/environments.py:306-329), files copied by the sandboxed xctrunner get com.apple.quarantine so Gatekeeper blocks venv .so files, and the gateway (launchd + osascript, gateway_launchd_runtime.py:96-124) starts in 29s–4min inside the runner container, missing the 60s deadline. Decision (Alan, 2026-11-07): don't adapt the harness to this environment; run the full gate in the Tart VM on the other Mac. Workarounds reverted. Kept: c9d9d683 (approvals merge, cron stderr in assertion). Local ~/.hermes pinned to tag v0.23.0 (2bd378ed).

## Plan



## Artifacts



