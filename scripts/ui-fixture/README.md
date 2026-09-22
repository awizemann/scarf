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
| Sessions — cost states | 3 rows with FIXED ids pinning the three cost presentations (see below) | direct write to the fixture `state.db` |
| Chats — kanban badge | 3 `source='acp'` chats with FIXED ids; two own a `running` + a `review` task, one owns none | `kanban create` + `claim` + `request-review`, then a direct `session_id` stamp |
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

## The two rows the CLI cannot make

Two things in the table above are written straight into the fixture's **own**
databases, with the reasoning recorded at each step in the script. Both are
consumed by UI tests that address rows by a **fixed id**
(`sessions.row.<id>`, `chat.session.<id>`), so the ids are duplicated in
`scarf/scarfUITests/CostRenderingUITests.swift` and `ChatJourneyUITests.swift` —
change them in all three places together.

**Cost states** — `CostRenderingUITests` needs one session per branch of
`SessionCostDisplay`:

| id | `cost_status` | `estimated_cost_usd` | must render |
| --- | --- | --- | --- |
| `uicost-unknown-0001` | `'unknown'` | `0.0` (with real tokens) | `—` |
| `uicost-nullstatus-0002` | `NULL` | none | `—` |
| `uicost-amount-0003` | `'estimated'` | `1.23` | `$1.23` |

No hermes verb sets those columns: they are written only by the agent's own
usage accounting (`hermes_state_usage.py:275`), and `hermes sessions` exposes
list/export/rename/delete/import only. Driving real turns instead would make the
fixture non-deterministic in exactly the dimension under test — which status
Hermes lands on depends on whether the configured model has a pricing entry.

**Chat-scoped kanban** — the Live badge journey needs tasks stamped with a chat's
ACP session id. `tasks.session_id` is documented in Hermes's own source as
"originating `HERMES_SESSION_ID`; NULL from CLI/dashboard"
(`hermes_cli/kanban_db.py:730`): `create` has no `--session` flag (only `list`
does), and `HERMES_SESSION_ID` is read by the in-agent tool path, not the CLI. So
the statuses come from the CLI and only the stamp is a direct `UPDATE`.

A third trap surfaced here, alongside the two `VERBS.md` already records:
`kanban create --initial-status running` prints "(running, …)" and the row lands
in **`ready`**, exactly as `--initial-status blocked` does. `kanban claim` is the
transition that actually reaches `running`.

Charter C3 binds *Scarf*, which stays read-only on every host. This is the fixture
builder writing the throwaway home it created two steps earlier — a directory the
safety checks prove is not, and is not inside, the real `~/.hermes`. The schema
still comes from Hermes (the CLI created the tables), and the cost INSERT names
only columns a `PRAGMA table_info` probe found, per charter C4.

> `sqlite3 -readonly` **fails** on both fixture databases — Hermes leaves them in
> WAL mode and a read-only open must create the `-shm` file, so you get
> `unable to open database file (14)`. Inspect a copy with
> `?immutable=1`, or checkpoint first.

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

Charter C3 — Scarf never writes `state.db` — is intact: the app under test stays
read-only, every mutation the CLI can express goes through the CLI, and the two
exceptions above are this script writing the throwaway home it just built, never
the real one (see "The two rows the CLI cannot make"). Never check a `state.db`
into the repo; rebuild the fixture instead.
