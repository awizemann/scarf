---
title: Hermes stores an UNKNOWN cost as 0.0 — cost_status is the only discriminator; SessionCostDisplay is Scarf's one cost rule
type: note
permalink: scarf/architecture/hermes-stores-an-unknown-cost-as-0-0-cost-status-is-the
tags: [hermes, state-db, cost, tokens, acp, display-fidelity]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesSession.swift, scarf/scarf/Features/Sessions/Views/SessionsView.swift, scarf/scarf/Features/Chat/Views/SessionInfoBar.swift]
source_paths_inferred: false
source_sha: 166b33e216979971fedcb1d210b0e765f6df0d8b
created: 2026-09-21
updated: 2026-09-21
---
Found validating t-b10d9fa6 against Hermes tag v2026.9.21 (v0.21.4) and the live `~/.hermes/state.db`; FIXED in t-fc311bef on branch `fix/unknown-session-cost` (2026-09-21).

Hermes's `cost_status` value set is declared exhaustively as `CostStatus = Literal["actual", "estimated", "included", "unknown"]` (`agent/usage_pricing.py:48` @ v2026.9.21). Three are produced in that file: `"unknown"` (`:550`, `amount_usd=None`, label "n/a"), `"included"` (`:565`, a true zero on a `subscription_included` route) and `"estimated"` (`:596`); `"actual"` is declared for a provider-reported cost.

Both persist paths collapse an unknown `amount_usd=None` to `0.0`: the `UPDATE sessions` statement built at `hermes_state_usage.py:29` (`estimated_cost_usd = COALESCE(?, 0)`, with `cost_status = COALESCE(?, cost_status)` at `:37`, executed by `update_token_counts` at `:274`), and the `session_model_usage` upsert at `:367` (`float(estimated_cost_usd or 0.0)`). So the stored number is identical for "don't know" and "genuinely free" — `cost_status` is the only discriminator.

Live evidence: every recent `source='acp'` session has real token counts with `estimated_cost_usd = 0.0` and `cost_status = 'unknown'` — the `:free` models have no pricing entry. Not ACP-specific; CLI and cron rows hit it too.

## Observations
- [fact] `SessionCostDisplay` (ScarfCore `Models/SessionCostDisplay.swift`) is THE one cost-presentation rule: `init(actualCostUSD:estimatedCostUSD:costStatus:)` returns `.amount(Double, isActual:)` / `.includedFree` / `.unknown` / `.legacy(amount:isActual:)`. Reach it via `HermesSession.costDisplay`; never re-derive a rule from the raw columns #cost
- [invariant] `.legacy` is the C1 escape hatch — a nil `cost_status` or an unrecognised future status with no positive amount carries the SAME raw `(displayCostUSD, costIsActual)` the surfaces read before, so an older host renders byte-identically.
- [correction] A nil `cost_status` is NOT only a pre-v0.7 host — that framing (repeated in `SessionCostDisplay.swift:44`, `SessionsView.swift:839`, `SessionDetailView.swift:79`, `SessionInfoBar.swift:364`, `InsightsView.swift:95`, `InsightsViewModel.swift:203`) is wrong. `hermes_state_usage.py:37` writes `cost_status = COALESCE(?, cost_status)` only from `update_token_counts` (`:275`, not `:274`), so any session that never completed a priced turn keeps `cost_status` NULL AND `estimated_cost_usd` NULL on a CURRENT host. Live v0.21.3 `~/.hermes/state.db` (2026-09-21): 9 of 43 sessions — 6 acp, 2 cron, 1 telegram, one of them 133 messages — are in exactly that state, and `sessionListPredicate` (`HermesDataService.swift:249`) does not filter them out. They take `.legacy(amount: nil)` and so STILL render a false `"$0.00"` in `SessionsView.costLabel`, while `SessionInfoBar`/`SessionDetailView` render nothing at all for the same row. The fix is honest for `'unknown'`; the nil-status hole is untouched #gotcha `SessionCostDisplayTests.nilStatusIsByteIdenticalToBefore` fails if anything routes a nil status into a new presentation #capability-gating
- [decision] A POSITIVE amount always wins over the status word, because Hermes only ever stores the placeholder ZERO for unknown — never a positive one. `'unknown'` + non-positive → `.unknown` → the em dash `"—"`, never `$0.00`; `'included'` → a genuine zero rendered WITHOUT the " est." marker #cost
- [fact] Consuming surfaces: `SessionsView.costLabel`/`costCell`, `SessionInfoBar`, `SessionDetailView`, and `InsightsView.totalCostCard` (which shows `"—"` when the sum is 0 with unknowns, and a "partial" tooltip whenever `InsightsViewModel.unknownCostSessionCount > 0`). Three Dashboard sites were deliberately left alone — they already render only when the figure is `> 0`, so they never assert a false zero #display-fidelity
- [gotcha] The em dash needs an accessibility label or VoiceOver says "cost —". Keys added to `Localizable.xcstrings` + `tools/translations/*.json` for all six locales: `cost unknown`, `Hermes recorded no cost for this session`, `Partial — Hermes recorded no cost for ^[%lld session](inflect: true)` #i18n #a11y

## Relations
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Localization Workflow]]
