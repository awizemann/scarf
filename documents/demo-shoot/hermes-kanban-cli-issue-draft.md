# Draft issue for hermes-ai/hermes-agent — Kanban CLI argument bugs (v0.20.0)

**Title:** `kanban block` rejects its reason argument; `kanban create --initial-status` silently ignored (v0.20.0)

## Environment
Hermes v0.20.0 (v2026.8.3), macOS, CLI.

## Bug 1: `hermes kanban block <id> <reason>` fails to parse the reason

```
$ hermes kanban block t_51c298bd "Waiting on retention-policy decision"
error: unrecognized arguments: Waiting on retention-policy decision
```

The positional reason is consumed by the top-level parser, with or without `--` separation. Blocking without a reason works. The same parser structure likely affects other subcommands taking trailing positional text (`promote`, `schedule` reasons — untested).

## Bug 2: `hermes kanban create --initial-status running` is silently ignored

A card created with `--initial-status running` comes out `ready` with no warning. `hermes kanban claim <id>` is the only way to reach `running`. Either honor the flag or error on unsupported values — silent fallback misleads scripts.

## Observation (maybe intended): no CLI path to `review` status

`edit` only accepts `--result/--summary`; reachable statuses are done/running/blocked/todo/ready/triage/scheduled. If `review` is a real column, the CLI can't place cards there.

---
_Found 2026-08-13 while seeding a demo board from Scarf. Repro commands above are exact._
