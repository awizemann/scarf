---
title: argparse: `--` protects positionals only — user text needs `--flag=value`
type: note
permalink: scarf/conventions/argparse-protects-positionals-only-user-text-needs-flag
tags: [cli, argv, hermes, verification, cron, kanban]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesCLIOption.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/KanbanCreateRequest.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/KanbanFilters.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/FleetApplyPlan.swift, scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift]
source_paths_inferred: false
source_sha: 720dbdc26d8e55d9c470297b4108454262ab4d45
created: 2026-09-11
updated: 2026-09-11
reviewed: 2026-09-13
reviewed_by: claude-opus-5
---

Found in the round-4 whole-surface audit, fixed in P42. Scarf had spent several phases carefully placing `--` before the positionals of `cron create`, `kanban create`, `kanban comment` and friends — correct work that protected only half the argv. Every free-text OPTION value was still a separate token, and still aborted the verb.

`HermesCLIOption` (ScarfCore/Parsing) is now the single place the spelling is decided, with `contains`/`index`/`value`/`values` to read an argv back in either form, so tests assert what an option CARRIES rather than its neighbour's index.

## Observations
- [gotcha] `--` ends the OPTIONS, so it protects positionals and nothing else. `parse_args(["--name", "-nightly", "--", sched])` is still `error: argument --name: expected one argument`, exit 2 — argparse tests `-nightly` for option-ness before `--name` is ever given a value. Any free-text field a user types into is a live exit-2 whenever its value starts with a dash #cli #argv
- [convention] The fix is the single-token `--flag=value` form: argparse's `_parse_optional` splits on the FIRST `=` and hands the remainder over WITHOUT testing it for option-ness, so any value round-trips — including the empty string, which several `cron edit` flags use as their documented clear gesture. Scarf spells every user-text option this way via `HermesCLIOption.joined` #cli
- [constraint] The `=` form is valid ONLY for a plain single-value option (`store`, or `append`, which splits identically per occurrence). It is NOT valid for `nargs='+'` (kanban's `--ids`, `kanban_parser.py:64`), where it could carry only the first element — those stay two tokens, and positionals still need `--` #cli
- [gotcha] The two guards are independent and BOTH are needed: `kanban complete` and `kanban archive` take `nargs` positional ids and had no `--` at all while `unblock` did, so a dash-leading id was exit 2 even after every option became one token #argv
- [convention] A test that asserts an option's presence with `argv.contains("--flag")` breaks the moment the spelling changes and pins nothing useful. Assert the VALUE (`HermesCLIOption.value(of:in:)`); assert the literal token only when the spelling itself is the subject #testing

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]
