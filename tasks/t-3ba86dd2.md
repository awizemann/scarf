---
id: t-3ba86dd2
title: Fix three more config defaults Scarf reads wrong
status: todo
added: 2026-09-09
---

## Description

Found during P13 (t-8d2a8e04) while verifying every `bool(_:default: true)` and picker default against `hermes_cli/config_defaults.py` at v2026.9.7. Out of P13's scope (its item list named three specific default drifts); each of these needs its own floor/window walk plus UI plumbing, and each flips a control users can currently see.

1. `approvals.mode` — Scarf parses `default: "manual"` (`HermesConfig+YAML.swift`, the `approvalMode:` line). Upstream default is **`smart`**, and it CHANGED: `manual` at every tag through v2026.7.7.2 (v0.18.2), `smart` from v2026.7.20 (v0.19.0) onward (`hermes_cli/config.py:2676` there, `hermes_cli/config_defaults.py` after the v2026.7.30 split; `smart` at v2026.9.7). A changed default means a SENTINEL + `displayApprovalMode(capabilities:)` resolving nil -> `isV019OrLater ? .smart : .manual`, mirroring `displayCheckpointsEnabled`. Note the reader's own fallback is `manual` (`tools/approval_context.py:236`) but is unreachable, since `_load_config_impl` deep-merges DEFAULT_CONFIG under the user file.

2. `approvals.timeout` — Scarf parses `default: 60`. Upstream is 60 through v2026.7.20 (v0.19.0) and **300** from v2026.7.30 (v0.19.1) on. Same shape: 0-sentinel + display resolver, like `displayGatewayTurnLeaseTimeout`.

3. `telegram.require_mention` — Scarf parses `default: true`; the key has NO `config_defaults.py` entry at v2026.9.7 and its reader defaults it FALSE: `plugins/platforms/telegram/adapter.py:5030` `self._extra_bool("require_mention", "TELEGRAM_REQUIRE_MENTION", "false")`. Walk it across tags before flipping — the toggle in TelegramSetupView renders ON today for every user whose config omits the key. A verified NOT-boolTrueDefault comment is already in place at the parse line so the next reader does not re-litigate the boolish half.

Each fix needs a test in the pattern of `HermesConfigReadCorrectnessP13Tests` (cite the target tag AND the floor/flip tag) plus, for 1 and 2, a `HermesCapabilitiesTests` case for the resolver.

## Plan



## Artifacts



