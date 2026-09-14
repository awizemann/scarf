---
id: t-54ec6eb3
title: Full re-walk of every HermesCapabilities floor
status: todo
added: 2026-09-12
---

## Description

P49's light re-walk sampled 20 flags across 13 MARK groups in `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift` and found two wrong (a 10% error rate, matching round 5's own sample). Both failures were CONSUMER-FREE flags whose docs claimed "kept because the floor is source-verified":

- `hasInsightsCommand` — `hermes insights` is `hermes_cli/main.py:4634` at v2026.3.30 = **0.6.0**, i.e. below Scarf's supported minimum. Deleted in P49 (commit c718237d).
- `hasDashboardCommand` — `def cmd_dashboard` is `hermes_cli/main.py:4458` at v2026.4.13 = **0.9.0**, absent at v2026.4.8 = 0.8.0. Re-floored 0.16 → 0.9 in P49.

Remaining work: walk the ~85 flags P49 did NOT sample, opening each cited file at its floor tag and the tag before (`git -C ~/.hermes/hermes-agent show <tag>:<path>` — a grep is not a walk, per the capability-gating note). Prioritise the flags whose doc says "No consumer yet" — that is where a wrong floor survives, because nothing renders it. For any flag whose surface exists at or below v2026.3.30 (0.6.0), the P15/P23 rule applies: delete it rather than re-floor it. Every correction ships with an assertion in `HermesCapabilitiesTests` naming the floor tag and the tag before.

Also worth folding in: doc comments that cite a line number without naming the tag (`hasPeerRunCommands` cites `subcommands/peer.py:432-434`, `hasCronDoctor` cites `subcommands/cron.py:184` — both are v2026.9.7 numbers and correct there, but `cron doctor` sits at `:325` at v2026.8.31, so an un-tagged citation reads as a floor claim it is not).

See the "Whole-surface remediation — P49" section of `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md` for the 20 flags already confirmed, so they need not be redone.

## Plan



## Artifacts



