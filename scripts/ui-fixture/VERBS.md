# Verified `hermes` CLI surface used by `make-ui-fixture.sh`

Charter **C5**: *never assume a CLI invocation works because the UI renders — every
`hermes` argv must be verified against the tagged argparse, and unknown-verb output
must never be parsed as success.*

Everything below was captured from the **installed** CLI on 2026-09-08:

```
$ ~/.local/bin/hermes --version
Hermes Agent v0.21.0 (2026.8.31) · upstream 1cb3ab61
Install directory: /Users/awizemann/.hermes/hermes-agent
Install method: git
```

The script re-proves this list at runtime (`verify_all_verbs`) before it seeds
anything — `--dry-run` runs exactly that pass and stops. The runtime check requires
each `hermes <verb> --help` to print a `usage: hermes <verb>` line, not merely to
exit 0, because a bare unknown verb routes to the agent and "succeeds".

---

## Root parser — one-shot prompt (`-z`)

```
$ hermes --help
usage: hermes [-h] [--version] [-z PROMPT] [--usage-file PATH] [-m MODEL]
              ...
```

`-z` is an option on the **root** parser, not a subcommand. Used as
`hermes -z "Reply with exactly: FIXTURE-1"` — a real model call that creates a real
session row in the fixture home's `state.db`.

## `sessions list`

```
$ hermes sessions list --help
usage: hermes sessions list [-h] ...
```

Read-back only. Output is a fixed-width table whose header is
`Title  Workspace  Last Active  ID`; the script counts rows beginning
`Reply with exactly`.

## `cron create` / `cron pause` / `cron list --all`

```
$ hermes cron create --help
usage: hermes cron create [-h] [--name NAME] [--deliver DELIVER]
                          [--failure-deliver FAILURE_DELIVER]
                          [--repeat REPEAT] [--skill SKILLS] [--script SCRIPT]
                          [--no-agent] [--monitor-script MONITOR_SCRIPT]
                          [--monitor-url MONITOR_URL] [--workdir WORKDIR]
                          [--model MODEL] [--provider MODEL_PROVIDER]
                          [--reasoning-effort REASONING_EFFORT] [--continuity]
                          schedule [prompt]

positional arguments:
  schedule              Schedule like '30m', 'every 2h', or '0 9 * * *'
  prompt                Optional self-contained prompt or task instruction

options:
  --name NAME           Optional human-friendly job name
  --deliver DELIVER     Delivery target: origin, local, telegram, discord,
                        signal, platform:chat_id, or bot-chat[:profile] ...
```

```
$ hermes cron pause --help
usage: hermes cron pause [-h] job_id

positional arguments:
  job_id      Job ID to pause
```

```
$ hermes cron list --help
usage: hermes cron list [-h] [--all]

options:
  --all       Include disabled jobs
```

- `--deliver local` is used so a fixture job can never message a real platform.
- **`cron create` has no `--paused`/`--disabled` flag** — the only way to seed a
  paused job is create-then-`cron pause`, which is what the script does.
- `cron create` prints `Created job: <12 hex chars>`; that line is the sole handle
  and the script fails loudly if it cannot parse it.
- Paused jobs are **invisible to plain `cron list`** — the read-back must pass
  `--all`.

## `kanban init` / `kanban create` / `kanban block` / `kanban list`

```
$ hermes kanban init --help
usage: hermes kanban init [-h] ...
    init                Create kanban.db if missing (idempotent)
```

```
$ hermes kanban create --help
usage: hermes kanban create [-h] [--body BODY] [--assignee ASSIGNEE]
                            ...
                            [--initial-status {blocked,running}] [--json]
                            title

positional arguments:
  title                 Task title

options:
  --body BODY           Optional opening post
```

```
$ hermes kanban block --help
usage: hermes kanban block [-h] ...
    block               Mark one or more tasks blocked
```

**Gotcha — re-verified on 0.21.0, unchanged from 0.20: `--initial-status` is
accepted and silently ignored.** Observed directly:

```
$ hermes kanban create "Fixture card blocked" --initial-status blocked
Created t_7800fe06  (blocked, assignee=-)

$ hermes kanban list
▶ t_f724e0f0  ready     (unassigned)   Fixture card one
▶ t_7800fe06  ready     (unassigned)   Fixture card blocked   ← NOT blocked
```

The **creation banner lies** — it echoes the requested status, and the row lands in
`ready`. A follow-up `hermes kanban block <id>` does work:

```
$ hermes kanban block t_7800fe06
Blocked t_7800fe06
$ hermes kanban list
⊘ t_7800fe06  blocked   (unassigned)   Fixture card blocked
```

So the script never passes `--initial-status`, and asserts the blocked column from
`kanban list` rather than trusting the create output.

`kanban create` prints `Created t_<8 hex>`; the script parses that id (and asserts
it found one). `--json` exists but its object is printed *after* a first-run gateway
advisory, so the plain form plus a `t_[0-9a-f]+` match is the sturdier parse.

## `project create` / `project list`

```
$ hermes project create --help
usage: hermes project create [-h] [--slug SLUG] [--primary PATH]
                             [--description DESCRIPTION] [--icon ICON]
                             [--color COLOR] [--board SLUG] [--use]
                             name [folders ...]
```

`hermes project create "Fixture Project" --description "…"` prints
`Created project fixture-project (p_…)`; read back with `project list`.

## `skills repair-official` / `skills list`

```
$ hermes skills repair-official --help
usage: hermes skills repair-official [-h] [--restore] [--yes] name

Repair official optional skill provenance. By default, only backfills hub
metadata for exact matches. Pass --restore to replace missing or mutated
active copies from optional-skills/ ...

options:
  --restore   Restore from official optional source, backing up existing
              matching copies
  --yes, -y   Skip confirmation prompt when using --restore
```

`hermes skills repair-official openhue --restore --yes` installs from the **local**
`<install-dir>/optional-skills/smart-home/openhue` tree — no network, no registry
lookup, deterministic, and it lands with `source=official trust=official` in
`skills list`.

**Why not `skills install`.** `hermes skills install <identifier> --yes` is a hub
verb that resolves identifiers **fuzzily and exits 0 when it finds no exact match**:

```
$ hermes skills install hello-test --yes
Resolving 'hello-test'...
No exact match for 'hello-test'. Did you mean one of these?
  Hello Test — hello-test
$ echo $?
0
```

Nothing was installed and the exit code says success — exactly the C5 failure shape.
It also needs the network and a third-party registry to be up. Rejected for the
fixture.

## `hermes memory` — no create verb (memories are seeded as files)

```
$ hermes memory --help
usage: hermes memory [-h] {setup,status,off,reset} ...

Set up and manage external memory provider plugins. ... Built-in memory
(MEMORY.md/USER.md) is always active.

positional arguments:
    setup               Interactive provider selection and configuration
    status              Show current memory provider config
    off                 Disable external provider (built-in only)
    reset               Erase all built-in memory (MEMORY.md and USER.md)
```

There is **no CLI verb that creates a memory.** `hermes memory` manages *external
provider plugins*; built-in memory is two plain markdown files at
`$HERMES_HOME/memories/MEMORY.md` and `USER.md`, which Scarf's own Memory section
reads and edits directly (`MemoryView.swift:514-523`). The fixture therefore writes
those two files itself — the same way the app does — rather than inventing a verb.

---

## Shell gotcha worth keeping (not a Hermes issue)

Under `set -o pipefail`, `hermes … | grep -q needle` reports **141**: `grep -q`
exits on the first match, `hermes` takes SIGPIPE, and the pipeline's status becomes
the signal. A *passing* assertion fails the script. Every read-back in
`make-ui-fixture.sh` captures the full output into a variable first and matches
against that. This bit the first working version, on the `skills list` check only,
because the smaller outputs happened to be fully flushed before grep exited — i.e.
it is a size-dependent, intermittent failure.
