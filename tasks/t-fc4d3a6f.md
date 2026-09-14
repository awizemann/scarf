---
id: t-fc4d3a6f
title: Webhook subscribe/list ignore the disabled-platform gate
status: todo
added: 2026-09-13
---

## Description

Found during P54 (round-6 CLI verdict residue) while giving `webhook remove|test` verdicts; out of that task's named scope, so filed rather than fixed.

`webhook_command` (`hermes_cli/webhook.py:92-103` @ `v2026.9.7`) checks `_is_webhook_enabled()` and, when the platform is off in config, prints `_setup_hint()` (`:100`) and `return`s — the handler never dispatches. `webhook` is `_forward_command`ed WITHOUT `forward_return` (`hermes_cli/main.py:1755-1772`), so this exits 0. P54 taught `remove` and `test` about it via `HermesWebhookGate.disabledPrefix` ("Webhook platform is not enabled.", `webhook.py:70`), but two siblings on the same gate were left:

- `WebhooksViewModel.subscribe` (`scarf/scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift:~132-188`): on a webhook-disabled host `parseCreatedSecret` finds no `Secret:` line, so `subscribeFailureMessage` falls through to `lines.last` — which is the setup hint's LAST line, "Then start the gateway: hermes gateway run". Not a false success, but the banner blames the wrong thing and hides the real cause (the platform is off in config.yaml).
- `webhook list` (`:~80`, and the iOS read-only twin `scarf/Scarf iOS/Webhooks/WebhooksView.swift:107`): renders an empty list silently, indistinguishable from "no subscriptions yet".

Fix: reuse `HermesWebhookGate.disabledPrefix` (already in `ScarfCore/Services/HermesCLIOutcome.swift`) on both. `subscribe` should show `HermesWebhookGate.disabledNote`; the list panes should render an explanatory empty state rather than a bare empty list. Add the iOS twin (lesson 5: grep both targets).

Test with a verbatim `_setup_hint()` fixture, as `HermesWebhookVerdictsP54Tests` does.

## Plan



## Artifacts



