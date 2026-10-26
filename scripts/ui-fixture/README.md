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

On Hermes v0.22.x, `hermes -z` starts a gateway daemon in the fixture home. The
script stops it (`gateway stop`, plus `--yes` where the CLI has it) at the end of
seeding and before clearing a reused fixture dir, so a rerun into the same dir works
and no daemon outlives the build (see `VERBS.md`).

Charter C3 — Scarf never writes `state.db` — is intact: the app under test stays
read-only, every mutation the CLI can express goes through the CLI, and the two
exceptions above are this script writing the throwaway home it just built, never
the real one (see "The two rows the CLI cannot make"). Never check a `state.db`
into the repo; rebuild the fixture instead.

## Running the UI plans in a Tart VM

`scripts/ui-gate-vm.sh` runs the Smoke / Full / Live plans inside a headless Tart
virtual Mac, so the tests never take this Mac's screen, keyboard or pointer:

```bash
scripts/ui-gate-vm.sh --hermes-tag v0.22.5 --plans Smoke,Full,Live
scripts/ui-gate-vm.sh --hermes-tag v2026.9.24 --plans Smoke --no-build
```

- It **builds once on the host** (`build-for-testing`, signed the way `ui-gate.sh`
  signs) into `build/ui-gate-vm/derived`, then runs each plan's `.xctestrun` with
  `test-without-building` in the guest, one plan at a time, with per-test and
  per-plan time bounds.
- The guest is a long-lived, already-running clone of ScarfRack's UI-test image
  (`--reuse scarf-ui` by default); the script never starts or stops a VM. It takes
  the clone's lock exactly as ScarfRack's `tools/ui-test/run.sh` does and waits up
  to 20 minutes for another run to finish. It needs ScarfRack's
  `tools/fresh-mac-rig/lib.sh` (`SCARF_VM_RIG_LIB`), which holds the VM's
  login — none of it is in this repo.
- **The clone's display must be tall enough.** The tests pin Scarf's window at
  1800 × 1300 pt and fail any test whose window is under 1500 × 1200, and AppKit
  keeps a window inside the screen less the menu bar and the Dock. A 1920x1200
  display leaves 1920 × 1080, so the script checks the guest's visible frame first
  and stops before copying anything in. Give the clone at least 1920x1440 while it
  is stopped (`tart set scarf-ui --display 1920x1440`).
- **…and room on its boot volume.** Under its low-disk threshold — 10 GiB free
  on `scarf-ui`'s 44 GB boot container (`deleted` logs `lowDiskThreshold:
  10737418240`) — macOS purges caches each time APFS reports low disk, and the
  purge terminates the sandboxed test runner to empty its container caches
  (runningboardd: `CacheDeleteAppContainerCaches requesting termination
  assertion for com.scarfUITests.xctrunner`). The test in flight then reports
  **"Test crashed with signal kill"**. The script reruns each such test **once,
  alone** (`-only-testing:scarfUITests/Class/test`), and the rerun decides it:
  `summary.md` lists both attempts (`<plan>-rerunN.log` / `.xcresult`), and a plan
  whose only failures were kills that passed alone — and whose first run
  executed its tests to XCTest's closing totals — reads `PASS (on rerun: N
  killed)`. No other failure is ever rerun. The summary also records the boot
  volume's free space before and after each plan, how often the purge fired, and
  how many times it terminated the runner (`<plan>.guest-purge.log`).
- The boot container can't grow (its recovery partition sits after it), so
  `scarf-ui` gets a second disk for the run's files, below. Everything the run
  installs or writes that can move — uv, its Python, the venv, uv/pip/XDG caches,
  `TMPDIR`, DerivedData and logs, result bundles — lives under `~/work` and
  `~/results` on that disk. Only the runner's container (its per-test copies of
  the fixture home) stays on the boot volume. The script needs 5 GB free where
  `~/work` lives and warns when the boot volume has under 11 GB.
- Only the `scarfUITests` target of each plan runs by default (`--ui-only`); Full's
  unit tests run headless on the host. `--with-unit-tests` runs the plans whole, and
  `--only Class[/test]` (repeatable) narrows a run to one class or test.
- **Hermes in the guest**: the host's `uv` is copied in, installs a managed
  Python the tag allows, and installs Hermes from the tag's `uv.lock` (`uv sync
  --frozen --extra acp`, editable) from a depth-1 clone
  of the tag shipped with its `.git` (Hermes derives its version from git tags).
  The script checks `hermes --version` reports the tag's version, and puts a
  `~/.local/bin/hermes` shim in the guest for the run.
- **Credentials — an allow-list, the active model provider's key only.** The
  guest's `config.yaml` is written from scratch with just `model.provider`,
  `default`/`model`, `base_url` and `api_mode` (no `api_key`, MCP servers,
  auxiliary/delegation/TTS settings, custom providers or platforms). Its `.env`
  holds only the key variable(s) the tag's provider registry
  (`hermes_cli/auth.py` `_REGISTRY_ROWS`; for OpenRouter, which has no row, the
  `OPENROUTER_*` names its own `_openrouter_auto_detected` reads) names for the **active**
  provider — from `~/.hermes/.env`, or from an API-key entry in `auth.json`'s
  credential pool — and any names you list in `SCARF_VM_EXTRA_ENV`.
  `GITHUB_TOKEN`, `GH_TOKEN`, `HF_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` and `AWS_*`
  never go in. `auth.json`
  never goes in: if the active provider signs in with OAuth the run stops,
  because a guest holding the refresh token can rotate it and sign this Mac out;
  `--allow-oauth-provider` copies that one provider's entry anyway, with a
  warning. `sanitize.txt` in the results lists the NAMES that went in;
  `--credentials-only` prints them for a tag without touching the VM. The
  fixture is then seeded in the guest with `make-ui-fixture.sh`.
- **Cleanup on every exit**: the fixture's gateway is stopped, the run's
  processes (an interrupted plan's ssh and bound watcher included), guest
  folders and shim are removed, the lock is released, the host scratch copy is
  deleted, and the guest is searched for every copied key value to prove none
  is left. Every run — at its start, in its normal cleanup and in the fallback
  cleanup — also sweeps the tests' per-test homes (`scarf-uitest-home-*`, copies
  of the fixture home, keys included) from the runner's temp dirs, and removes a
  `~/.hermes` that a run created: when the guest has none, the run creates it
  with a `.scarf-ui-gate-vm-created` marker inside, and only a marked one is
  ever deleted.
- **Lock**: ScarfRack's `$RIG_HOME/locks/<clone>.lock`, made with `mkdir` and
  given its pid at once. A dead holder's lock, or a pid-less one older than
  60 s, is taken over only under a second mutex (`<clone>.lock.takeover`): the
  lock is re-checked inside it, renamed to a unique name, and deleted only if it
  is the very directory judged stale (same inode); otherwise it is put back.

Results land in `build/ui-gate-vm/results/<stamp>/`: `summary.md` (verdicts as
`ui-gate.sh --classify` gives them: PASS / FAIL / RUNNER-FAILED, plus reruns of
killed tests), one `.xcresult` and `.log` per plan and per rerun, the guest's
purge log per plan, and the setup, fixture and cleanup logs.

### Setting up `scarf-ui` (one time)

```bash
# Host: clone ScarfRack's UI-test image, give it a tall display and a work disk.
tart clone scarfrack-uitest-27 scarf-ui
tart set scarf-ui --display 1920x1440 --no-display-refit
mkdir -p ~/.tart/scarf-ui-logs && mkfile -n 40g ~/.tart/scarf-ui-logs/scarf-work.img
# Boot it headless with the host's Xcode shared read-only and the work disk attached:
tart run scarf-ui --no-graphics --no-audio \
  --dir=xcode:/Applications/Xcode-beta.app:ro \
  --disk="$HOME/.tart/scarf-ui-logs/scarf-work.img" &

# Guest (over SSH, once): format the extra disk and move ~/work and ~/results onto it.
diskutil list external                       # find the 40 GB disk, e.g. disk8
diskutil eraseDisk APFS ScarfWork disk8
mkdir -p /Volumes/ScarfWork/work /Volumes/ScarfWork/results
rm -rf ~/work ~/results
ln -s /Volumes/ScarfWork/work ~/work
ln -s /Volumes/ScarfWork/results ~/results
```

Every later boot needs the same `--disk=` flag, or `~/work` points at nothing.

Then give the boot volume headroom (in the guest, once; it went from 9.6 to
11.9 GB free). Its big items can't go with SIP on: the Preboot volume's Rosetta
cryptex (7.7 GB) and the mobile assets under `/System/Library/AssetsV2` (3.5 GB)
are SIP-restricted.

```bash
sudo mdutil -a -i off                       # no Spotlight indexing of any volume
sudo rm -rf /System/Volumes/Data/.Spotlight-V100/Store-V2 ~/Library/Metadata/CoreSpotlight/*
SU=/Library/Preferences/com.apple.SoftwareUpdate   # no background update downloads
for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates \
         ConfigDataInstall CriticalUpdateInstall; do sudo defaults write $SU $k -bool false; done
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
sudo log erase --all                        # old unified logs
sudo rm -rf /Library/Caches/com.apple.iconservices.store ~/Library/Caches/* \
  /Library/Logs/DiagnosticReports/* ~/Library/Developer/Xcode/DerivedData/scarf-*
# Let macOS purge what it can: briefly fill the disk, then delete the file.
dd if=/dev/zero of=/private/var/tmp/fill bs=1m count=8800; sleep 120; rm /private/var/tmp/fill
```

