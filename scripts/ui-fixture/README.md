# UI-test fixture home

`make-ui-fixture.sh` builds a **throwaway, seeded Hermes home** for Scarf's XCUITest
release gate.

`ScarfUITestCase.makeIsolatedHermesHome()` already mints an isolated home, but an
empty one — a section sweep against it only proves that empty states render. This
script builds the same shape of home and then seeds it with real data by driving the
installed `hermes` CLI with `HERMES_HOME` pointed at it.

## Run it

```bash
scripts/ui-fixture/make-ui-fixture.sh "$(mktemp -d)/fixture-home"
```

It prints the fixture path on stdout (progress goes to stderr), so it composes:

```bash
FIXTURE="$(scripts/ui-fixture/make-ui-fixture.sh "$(mktemp -d)/fixture-home")"
```

Point the app at it the way the UI tests do — both variables, because
`SCARF_HERMES_HOME` redirects Scarf's own file I/O and `HERMES_HOME` redirects the
`hermes` CLI that `LocalTransport` spawns:

```bash
SCARF_HERMES_HOME="$FIXTURE" HERMES_HOME="$FIXTURE" …
```

Other modes:

| flag | what it does |
| --- | --- |
| `--dry-run` | Verifies every verb and flag against the installed CLI's argparse and stops. Seeds nothing, spends nothing. |
| `--self-check` | Full seed, then digests five paths in the real `~/.hermes` before and after and fails if any changed. |

`HERMES_BIN` overrides the CLI path (default `~/.local/bin/hermes`).

There is deliberately **no `--keep-going`**: any failed verb aborts non-zero and
names the verb.

## What it seeds

| surface | what lands | how |
| --- | --- | --- |
| Sessions | 3 real one-shot chats (`FIXTURE-1/2/3`) in the fixture's own `state.db` | `hermes -z …` |
| Cron | 2 jobs, both **paused**, `--deliver local` | `cron create` + `cron pause` |
| Kanban | 3 cards, one moved to **blocked** | `kanban init` / `create` / `block` |
| Projects | 1 project (`fixture-project`) | `project create` |
| Skills | 1 installed official skill (`openhue`), from the local optional-skills tree — no network | `skills repair-official --restore --yes` |
| Memory | `memories/MEMORY.md` + `memories/USER.md` | plain file writes — Hermes has **no** CLI verb that creates a memory (see `VERBS.md`) |

Plus the structure `ScarfUITestCase` expects: `scarf/ cron/ sessions/ logs/`, the
sentinel `.scarf-test-home-marker`, and **copies** (never symlinks) of the real
home's `config.yaml`, `auth.json`, `.env`.

Every argv is verified against the installed CLI's argparse before use — charter C5
— with the proving `--help` excerpts recorded in [`VERBS.md`](./VERBS.md), including
two live traps: `kanban create --initial-status` is silently ignored, and
`skills install` exits 0 when it resolves nothing.

## Cost

**It spends a few cents of real tokens per run.** The three sessions are genuine
model calls against the credentials copied from your `~/.hermes` — that is the
point: the state.db rows have the schema and shape the app actually faces. The
prompts are deliberately trivial (`Reply with exactly: FIXTURE-1`). Nothing else in
the script calls a model. Use `--dry-run` when you only want to check the CLI
surface.

Measured wall time on an M-series Mac: **~25s cold, ~45s including `--self-check`.**

## Safety

The fixture home is the only write target. The script refuses to run when the
destination *is*, or is *inside*, the real `~/.hermes` (symlinks resolved), or is
`$HOME` or `/`. Rerunning into an existing directory clears it **only** if it is
empty or carries `.scarf-test-home-marker`; any other non-empty directory is
refused rather than wiped.

Charter C3 — Scarf never writes `state.db` — is intact: every mutation here goes
through the `hermes` CLI, and never against the real home. Never check a `state.db`
into the repo; rebuild the fixture instead.
