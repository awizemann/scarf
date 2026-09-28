---
id: t-d83fc37d
title: B13 Env-first platform settings: forms show/write values Hermes reads from .env first
status: done
added: 2026-09-27
---

## Description

After B12 (current phases done). Same bug as S07-F4 Mattermost (fixed in B05) across other platform forms: Hermes reads .env before config.yaml for these keys, so Scarf's toggle is inert and the form shows the wrong value when .env holds the variable. Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md § B13. Scope list + Hermes citations + lessons from the reverted B05 attempt are in that section.

## Plan



## Artifacts

Step 0: Hermes docs + pre-v2026.7.30 wizards put these in .env (DingTalk dropped). Fixed Discord, Telegram, Matrix, Ntfy, Slack/Mattermost allowlists + iOS rows; per-band flags; .env line removed only after config set succeeds; allowlist never emptied while .env holds entries. Round-trip through Hermes loader. scarfTests 1917 pass (B13 branch). Merged to main locally.

