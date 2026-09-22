#!/bin/bash
#
# make-ui-fixture.sh — build a throwaway, SEEDED Hermes home for Scarf's UI tests.
#
# Why this exists
# ---------------
# `ScarfUITestCase.makeIsolatedHermesHome()` mints an EMPTY throwaway home, so a
# section sweep only ever proves that empty states render. This script builds the
# same shape of home and then seeds it with REAL data by driving the installed
# `hermes` CLI with `HERMES_HOME` pointed at it — sessions land in that home's own
# state.db, cron jobs in its cron/jobs.json, kanban cards in its kanban.db.
#
# Seeding through the CLI (rather than checking in a state.db) keeps the schema
# matched to the Hermes the app actually faces, and honours charter C3: Scarf never
# writes state.db; hermes does.
#
# Every argv below is verified against the installed CLI's argparse — charter C5 —
# with the proving `--help` excerpts recorded in scripts/ui-fixture/VERBS.md.
#
# Usage
# -----
#   scripts/ui-fixture/make-ui-fixture.sh <dest-dir>
#   scripts/ui-fixture/make-ui-fixture.sh --dry-run <dest-dir>     # verify verbs only
#   scripts/ui-fixture/make-ui-fixture.sh --self-check <dest-dir>  # seed + prove ~/.hermes untouched
#
# There is deliberately no --keep-going: any failed verb aborts non-zero, naming it.
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
MARKER_FILENAME=".scarf-test-home-marker"   # HermesProfileResolver.testHomeMarkerFilename

# ---------------------------------------------------------------- seeded ids
#
# FIXED ids so the UI tests can address a row exactly
# (`sessions.row.<id>`, `chat.session.<id>`) instead of matching on a title
# that the accessibility layer may truncate. These literals are duplicated
# in `scarf/scarfUITests/CostRenderingUITests.swift` and
# `ChatJourneyUITests.swift` — the UI-test bundle links neither this script
# nor ScarfCore, so there is nowhere shared to put them. Change them here
# and there together.
COST_UNKNOWN_ID="uicost-unknown-0001"     # cost_status='unknown', estimated 0.0, real tokens
COST_NULL_ID="uicost-nullstatus-0002"     # cost_status NULL, no amount at all
COST_AMOUNT_ID="uicost-amount-0003"       # cost_status='estimated', positive amount
COST_AMOUNT_USD="1.23"                    # renders as "$1.23" (Sessions) / "$1.2300 est." (detail)

BADGE_SESSION_A="uibadge-acp-0001"        # ACP chat WITH live kanban tasks
BADGE_SESSION_B="uibadge-acp-0002"        # ACP chat WITH live kanban tasks
BADGE_SESSION_EMPTY="uibadge-acp-0003"    # ACP chat with NONE — the badge must show 0
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"

MODE="seed"   # seed | dry-run | self-check
DEST=""

die() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }

usage() {
    sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------------------------------------------------------------- args

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    MODE="dry-run"; shift ;;
        --self-check) MODE="self-check"; shift ;;
        -h|--help)    usage 0 ;;
        --keep-going) die "--keep-going is not supported: a failed verb must fail the build." ;;
        -*)           die "unknown option: $1" ;;
        *)
            [ -n "$DEST" ] && die "unexpected extra argument: $1"
            DEST="$1"; shift ;;
    esac
done

[ -n "$DEST" ] || usage 2

[ -x "$HERMES_BIN" ] || die "hermes CLI not found or not executable at $HERMES_BIN (override with HERMES_BIN=…)"

# Used ONLY against this fixture's own throwaway databases — see the
# "seed: cost states" and "seed: chat-scoped kanban" steps for why the CLI
# cannot produce those rows. Never pointed at the real home.
#
# Deliberately NOT invoked with `-readonly`, even for the PRAGMA probes:
# Hermes leaves both databases in WAL mode, and a read-only open has to
# create the `-shm` shared-memory file, so `sqlite3 -readonly kanban.db`
# fails outright with "unable to open database file (14)". The probe would
# then return empty and be indistinguishable from "the column is missing" —
# it aborted this script on its first run. Read-only inspection from
# OUTSIDE (a terminal, a test) should copy the db or checkpoint it first.
SQLITE_BIN="${SQLITE_BIN:-/usr/bin/sqlite3}"
[ -x "$SQLITE_BIN" ] || SQLITE_BIN="$(command -v sqlite3 || true)"
[ -n "$SQLITE_BIN" ] && [ -x "$SQLITE_BIN" ] || die "sqlite3 not found (override with SQLITE_BIN=…)"

# ---------------------------------------------------------------- paths & safety

# Resolve DEST to an absolute path WITHOUT requiring it to exist yet: resolve the
# deepest existing ancestor (which collapses symlinks, per the repo's
# resolve-symlinks-don't-just-normalize convention) and re-append the tail.
resolve_abs() {
    local target="$1" tail="" parent
    case "$target" in /*) ;; *) target="$PWD/$target" ;; esac
    while [ ! -d "$target" ]; do
        tail="/$(basename "$target")$tail"
        parent="$(dirname "$target")"
        [ "$parent" = "$target" ] && break
        target="$parent"
    done
    printf '%s\n' "$(cd "$target" 2>/dev/null && pwd -P)$tail"
}

DEST_ABS="$(resolve_abs "$DEST")"
[ -n "$DEST_ABS" ] || die "could not resolve destination path: $DEST"

# The real ~/.hermes, symlinks collapsed. If it doesn't exist there is nothing to
# protect, but we still refuse the literal path.
REAL_HERMES_RAW="${HERMES_REAL_HOME:-$HOME/.hermes}"
if [ -d "$REAL_HERMES_RAW" ]; then
    REAL_HERMES="$(cd "$REAL_HERMES_RAW" && pwd -P)"
else
    REAL_HERMES="$REAL_HERMES_RAW"
fi

case "$DEST_ABS" in
    "$REAL_HERMES"|"$REAL_HERMES"/*)
        die "refusing to build a fixture at $DEST_ABS — that is (or is inside) the real Hermes home $REAL_HERMES" ;;
esac
[ "$DEST_ABS" = "/" ] && die "refusing to use / as a fixture home"
[ "$DEST_ABS" = "$(cd "$HOME" && pwd -P)" ] && die "refusing to use \$HOME as a fixture home"

# ---------------------------------------------------------------- real-home digests

# Files the UI is most likely to write behind our back. Digest them before and
# after so --self-check can prove the real home was never a write target.
REAL_HOME_WATCHED=(
    "$REAL_HERMES/scarf/projects.json"
    "$REAL_HERMES/cron/jobs.json"
    "$REAL_HERMES/state.db"
    "$REAL_HERMES/kanban.db"
    "$REAL_HERMES/config.yaml"
)

digest_watched() {
    local f
    for f in "${REAL_HOME_WATCHED[@]}"; do
        if [ -f "$f" ]; then
            printf '%s  %s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" \
                                  "$(stat -f '%m' "$f")" "$f"
        else
            printf 'ABSENT  -  %s\n' "$f"
        fi
    done
}

BEFORE_DIGEST=""
if [ "$MODE" = "self-check" ]; then
    BEFORE_DIGEST="$(digest_watched)"
fi

# ---------------------------------------------------------------- verb verification (C5)

# Every verb this script uses, proved present in the installed CLI's argparse
# before we run any of it. `hermes <verb> --help` exits 0 and prints a usage line
# only for a REAL subcommand; an unknown verb routes to the agent, so we also
# require the expected "usage: hermes <verb>" prefix rather than trusting exit 0.
verify_verb() {
    local out
    if ! out="$("$HERMES_BIN" "$@" --help 2>&1)"; then
        die "verb verification failed: 'hermes $* --help' exited non-zero"
    fi
    case "$out" in
        "usage: hermes $*"*) : ;;
        *) die "verb verification failed: 'hermes $* --help' did not print 'usage: hermes $*' (unknown verb?)" ;;
    esac
}

# A flag must appear in its subcommand's own help text.
verify_flag() {
    local flag="$1"; shift
    local out
    out="$("$HERMES_BIN" "$@" --help 2>&1)" || die "verb verification failed: 'hermes $* --help'"
    case "$out" in
        *"$flag"*) : ;;
        *) die "verb verification failed: 'hermes $*' has no $flag flag in its argparse" ;;
    esac
}

# NOTE: verification runs BEFORE HERMES_HOME is exported, so these `--help` calls
# see the real home. That is deliberate — pointing them at a not-yet-built fixture
# would trigger a full first-run bootstrap per call — and it is safe: `--help` is
# pure argparse, and --self-check takes its BEFORE digest ahead of this pass, so a
# write here would be caught.
verify_all_verbs() {
    step "Verifying every verb/flag against the installed CLI's argparse"
    note "hermes: $("$HERMES_BIN" --version 2>&1 | head -1)"

    # Top-level -z (one-shot prompt) is an option on the root parser, not a verb.
    local root
    root="$("$HERMES_BIN" --help 2>&1)"
    case "$root" in
        *"-z PROMPT"*) : ;;
        *) die "verb verification failed: root parser has no -z PROMPT option" ;;
    esac

    verify_verb sessions list

    verify_verb cron create
    verify_flag "--name"    cron create
    verify_flag "--deliver" cron create
    verify_verb cron pause
    verify_verb cron list
    verify_flag "--all"     cron list

    verify_verb kanban init
    verify_verb kanban create
    verify_flag "--body"    kanban create
    verify_flag "--initial-status" kanban create
    verify_verb kanban block
    verify_verb kanban claim
    verify_verb kanban request-review
    verify_flag "--force"   kanban request-review
    verify_verb kanban list
    verify_flag "--session" kanban list

    verify_verb project create
    verify_flag "--description" project create
    verify_verb project list

    verify_verb skills repair-official
    verify_flag "--restore" skills repair-official
    verify_flag "--yes"     skills repair-official
    verify_verb skills list

    note "all verbs and flags verified"
}

verify_all_verbs

if [ "$MODE" = "dry-run" ]; then
    printf '\n%s: --dry-run OK — every verb verified, nothing seeded.\n' "$SCRIPT_NAME" >&2
    exit 0
fi

# ---------------------------------------------------------------- build the home

step "Preparing fixture home: $DEST_ABS"

if [ -e "$DEST_ABS" ]; then
    [ -d "$DEST_ABS" ] || die "$DEST_ABS exists and is not a directory"
    # Rerunning into an existing directory is allowed only when it is empty or is
    # unmistakably one of ours (carries the sentinel marker). Anything else could
    # be a real directory the caller mistyped, and we will not wipe it.
    if [ -n "$(ls -A "$DEST_ABS" 2>/dev/null)" ] && [ ! -f "$DEST_ABS/$MARKER_FILENAME" ]; then
        die "$DEST_ABS is non-empty and carries no $MARKER_FILENAME — refusing to overwrite a directory this script did not create"
    fi
    note "reusing existing fixture dir (clearing it)"
    # Contents only; never the directory itself (it may be a caller-made mktemp -d).
    find "$DEST_ABS" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
else
    mkdir -p "$DEST_ABS"
fi

for sub in scarf cron sessions logs; do
    mkdir -p "$DEST_ABS/$sub"
done

# The sentinel HermesProfileResolver requires before it honours SCARF_HERMES_HOME.
# Must exist before the app (or anything else) reads the override.
: > "$DEST_ABS/$MARKER_FILENAME"

# Copy — never symlink — credentials and model config, so a write can't follow the
# link back into the real home. Mirrors ScarfUITestCase.makeIsolatedHermesHome().
for f in config.yaml auth.json .env; do
    if [ -f "$REAL_HERMES/$f" ]; then
        cp "$REAL_HERMES/$f" "$DEST_ABS/$f"
        note "copied $f"
    else
        note "skipped $f (absent in $REAL_HERMES)"
    fi
done

export HERMES_HOME="$DEST_ABS"

# Read-back helper. NOTE: `hermes … | grep -q …` is a trap under `set -o pipefail`
# — grep exits on the first match, hermes takes SIGPIPE, and the pipeline reports
# 141, so a *successful* assertion fails. Every verification below therefore
# captures the whole output first and greps the variable.
capture() {
    local out
    set +e
    out="$("$HERMES_BIN" "$@" 2>&1)"
    set -e
    printf '%s' "$out"
}

assert_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
        *"$needle"*) : ;;
        *) printf '%s\n' "$haystack" >&2; die "$what" ;;
    esac
}

# Every seeding call goes through this: on failure it names the verb and aborts.
run_verb() {
    local label="$1"; shift
    local out rc
    set +e
    out="$("$HERMES_BIN" "$@" 2>&1)"
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        printf '%s\n' "$out" >&2
        die "verb failed (exit $rc): hermes $*   [$label]"
    fi
    printf '%s' "$out"
}

# ---------------------------------------------------------------- seed: sessions

step "Seeding sessions (real one-shot chats — these spend tokens)"
for n in 1 2 3; do
    out="$(run_verb "session $n" -z "Reply with exactly: FIXTURE-$n")"
    note "session $n: $(printf '%s' "$out" | tail -1)"
done

sessions_out="$(capture sessions list)"
session_count="$(printf '%s\n' "$sessions_out" | grep -c '^Reply with exactly' || true)"
[ "$session_count" -ge 3 ] || { printf '%s\n' "$sessions_out" >&2; die "expected 3 seeded sessions, 'hermes sessions list' shows $session_count"; }
note "sessions in state.db: $session_count"

# ---------------------------------------------------------------- seed: cost states

# Three sessions pinning the three cost presentations Scarf must tell apart
# (`SessionCostDisplay`, ScarfCore): `cost_status = 'unknown'` with the
# placeholder 0.0 and REAL token counts, `cost_status` left NULL with no
# amount at all, and a positive `estimated_cost_usd` with
# `cost_status = 'estimated'`. `CostRenderingUITests` reads them back off
# the Sessions table, the session detail and the Insights Total Cost card,
# and finds them by the FIXED ids below (`sessions.row.<id>`).
#
# WHY THIS WRITES THE DATABASE DIRECTLY. There is no hermes verb that sets
# a session's cost columns: `cost_status` / `estimated_cost_usd` are written
# only by the agent's own usage-accounting path
# (`hermes_state_usage.py:275` `update_token_counts`, reached from a priced
# turn), and `hermes sessions --help` exposes list/show/rename/delete/export
# only (`sessions import` reads a foreign Claude/Codex transcript and is not
# a cost writer either). Driving real turns instead would make the fixture non-deterministic
# in exactly the dimension under test — which of the four statuses Hermes
# lands on depends on whether the configured model has a pricing entry.
#
# Charter C3 ("never write state.db") binds SCARF, which stays read-only on
# every host; this is the fixture builder writing the THROWAWAY home it just
# created two steps ago, which the safety checks at the top of this script
# prove is not (and is not inside) the real `~/.hermes`. The schema itself
# still comes from Hermes: the table was created by the CLI above, and the
# INSERT below names only columns a PRAGMA probe found (charter C4) — a
# column this Hermes does not have is simply dropped from the statement.
step "Seeding the three cost-state sessions (direct FIXTURE state.db write — no CLI verb sets cost columns)"

STATE_DB="$DEST_ABS/state.db"
[ -f "$STATE_DB" ] || die "no state.db at $STATE_DB after seeding sessions — the CLI did not create it"

# Charter C4: probe for the column, never infer it from a version string.
has_session_column() {
    local col="$1" out
    out="$("$SQLITE_BIN" "$STATE_DB" "PRAGMA table_info(sessions);" 2>/dev/null || true)"
    case "$out" in
        *"|$col|"*) return 0 ;;
        *) return 1 ;;
    esac
}

if ! has_session_column cost_status; then
    die "this Hermes's sessions table has no cost_status column, so the fixture cannot pin the cost states the UI gate asserts. Upgrade the installed hermes (the column arrived with the v0.7 schema)."
fi

# Newest-first so the three land at the top of the Sessions table: the list
# is a LazyVStack and a row below the fold has no element to assert on.
COST_BASE_TS="$(date +%s)"

# id | title | model | msgs | in | out | estimated | actual | cost_status
seed_cost_session() {
    local id="$1" title="$2" msgs="$3" tin="$4" tout="$5" est="$6" status="$7"
    local cols="id, source, model, started_at, last_activity_at, message_count, tool_call_count, input_tokens, output_tokens, title"
    local vals="'$id', 'cli', 'fixture/cost-model', $COST_BASE_TS, $COST_BASE_TS, $msgs, 0, $tin, $tout, '$title'"
    if has_session_column estimated_cost_usd; then
        cols="$cols, estimated_cost_usd"; vals="$vals, $est"
    fi
    cols="$cols, cost_status"; vals="$vals, $status"
    "$SQLITE_BIN" "$STATE_DB" \
        "INSERT OR REPLACE INTO sessions ($cols) VALUES ($vals);" \
        || die "could not seed cost-state session $id into the fixture state.db"
    note "$id ($title)"
}

# 1. Hermes priced the turn, found no rate, and stored the PLACEHOLDER zero
#    next to real token counts. Must render "—", never "$0.00".
seed_cost_session "$COST_UNKNOWN_ID" "UICOST Unknown Status" 6 4210 1180 0.0 "'unknown'"
# 2. A session that never completed a priced turn on a CURRENT host: the
#    column exists and Hermes left it NULL, with no amount at all. Also "—".
seed_cost_session "$COST_NULL_ID" "UICOST Null Status" 3 0 0 "NULL" "NULL"
# 3. A real estimate. Must render the formatted amount, not the dash.
seed_cost_session "$COST_AMOUNT_ID" "UICOST Estimated Amount" 9 51200 8400 "$COST_AMOUNT_USD" "'estimated'"

cost_rows="$("$SQLITE_BIN" "$STATE_DB" \
    "SELECT id || '|' || COALESCE(cost_status,'NULL') || '|' || COALESCE(estimated_cost_usd,'NULL') FROM sessions WHERE id LIKE 'uicost-%' ORDER BY id;")"
[ "$(printf '%s\n' "$cost_rows" | grep -c '^uicost-')" -eq 3 ] \
    || { printf '%s\n' "$cost_rows" >&2; die "expected 3 uicost-* rows in the fixture state.db"; }
printf '%s\n' "$cost_rows" | while IFS= read -r line; do note "$line"; done

# ---------------------------------------------------------------- seed: cron (PAUSED)

step "Seeding cron jobs (created, then paused)"
seed_cron_job() {
    local name="$1" schedule="$2" prompt="$3" out job_id
    out="$(run_verb "cron create ($name)" cron create "$schedule" "$prompt" --name "$name" --deliver local)"
    job_id="$(printf '%s' "$out" | sed -n 's/^Created job: \([0-9a-f][0-9a-f]*\).*/\1/p' | head -1)"
    [ -n "$job_id" ] || { printf '%s\n' "$out" >&2; die "could not parse job id out of 'hermes cron create' output [$name]"; }
    run_verb "cron pause ($name)" cron pause "$job_id" >/dev/null
    note "$name -> $job_id (paused)"
}
seed_cron_job "Fixture Morning Digest" "every 2h"  "Say FIXTURE-CRON-1"
seed_cron_job "Fixture Link Check"     "every 30m" "Say FIXTURE-CRON-2"

# `cron list --all` is the only listing that includes disabled jobs.
cron_out="$(capture cron list --all)"
paused_count="$(printf '%s\n' "$cron_out" | grep -c '\[paused\]' || true)"
[ "$paused_count" -eq 2 ] || { printf '%s\n' "$cron_out" >&2; die "expected 2 paused cron jobs, 'hermes cron list --all' shows $paused_count"; }
note "paused cron jobs: $paused_count"

# ---------------------------------------------------------------- seed: kanban

step "Seeding kanban cards"
run_verb "kanban init" kanban init >/dev/null

kanban_create() {
    local title="$1" body="$2" out id
    out="$(run_verb "kanban create ($title)" kanban create "$title" --body "$body")"
    id="$(printf '%s' "$out" | grep -oE 't_[0-9a-f]+' | head -1)"
    [ -n "$id" ] || { printf '%s\n' "$out" >&2; die "could not parse task id out of 'hermes kanban create' output [$title]"; }
    printf '%s' "$id"
}

card1="$(kanban_create "Fixture: wire up the sweep"   "Seeded by make-ui-fixture.sh")"
card2="$(kanban_create "Fixture: blocked on review"   "Seeded by make-ui-fixture.sh")"
card3="$(kanban_create "Fixture: triage the backlog"  "Seeded by make-ui-fixture.sh")"

# NOTE (verified on 0.21.0, same as 0.20): `kanban create --initial-status blocked`
# PRINTS "(blocked, …)" but the row lands in `ready`. The only way to get a card
# that is really blocked is a second `kanban block` call.
run_verb "kanban block" kanban block "$card2" >/dev/null
note "cards: $card1 (ready), $card2 (blocked), $card3 (ready)"

kanban_out="$(capture kanban list)"
card_count="$(printf '%s\n' "$kanban_out" | grep -c 'Fixture:' || true)"
[ "$card_count" -eq 3 ] || { printf '%s\n' "$kanban_out" >&2; die "expected 3 kanban cards, 'hermes kanban list' shows $card_count"; }
blocked_ok="$(printf '%s\n' "$kanban_out" | grep -c "$card2 *blocked" || true)"
[ "$blocked_ok" -eq 1 ] || { printf '%s\n' "$kanban_out" >&2; die "kanban card $card2 is not in the blocked column"; }

# ---------------------------------------------------------------- seed: chat-scoped kanban

# Three ACP chats for the Live-plan badge journey: two that each own a
# `running` + a `review` task (so `SessionInfoBar`'s Kanban chip must read
# 2 — `KanbanChatBadgeState.liveStatuses` is {running, blocked, review}),
# and one that owns none (the chip must read 0, not the previous chat's
# number). The whole point of the badge fix is that switching chats RESETS
# the count, so the fixture needs both shapes.
#
# The STATUSES come from the CLI: `kanban create --initial-status running`
# and `kanban request-review --force`, both verified above.
#
# The SESSION STAMP cannot. `tasks.session_id` is documented in Hermes's own
# source as "originating HERMES_SESSION_ID; NULL from CLI/dashboard"
# (`hermes_cli/kanban_db.py:730` @ v2026.9.21), and `kanban.py`'s create
# handler (`:370`) never passes `session_id` to `kb.create_task` — there is
# no `--session` flag on `create` (only on `list`, which is how Scarf
# filters), and `HERMES_SESSION_ID` is read only by the in-agent tool path
# (`tools/kanban_tools.py:1032`), not by the CLI. So the stamp is a direct
# UPDATE on the fixture's own throwaway kanban.db. Same reasoning as the
# cost rows above: the CLI created the schema, we only set one column.
step "Seeding chat-scoped kanban tasks (statuses via the CLI, session stamp via the fixture kanban.db)"

KANBAN_DB="$DEST_ABS/kanban.db"
[ -f "$KANBAN_DB" ] || die "no kanban.db at $KANBAN_DB after 'hermes kanban init'"

kanban_has_session_column="$("$SQLITE_BIN" "$KANBAN_DB" "PRAGMA table_info(tasks);" 2>/dev/null | grep -c '|session_id|' || true)"
[ "$kanban_has_session_column" -ge 1 ] \
    || die "this Hermes's kanban tasks table has no session_id column, so a chat-scoped board cannot be seeded (the column arrived with the v0.15 session filter Scarf gates the chip on)."

# Create a task and CLAIM it, which is what actually reaches the `running`
# column. `create --initial-status running` does NOT: exactly as the memory
# note already records for `--initial-status blocked`, the CLI prints
# "(running, …)" and the row lands in `ready` (re-verified on 0.21.4 — the
# first run of this step seeded two `ready` rows and the badge would have
# counted 1, not 2). `claim` is the atomic ready -> running transition and
# prints the resolved workspace path.
kanban_create_claimed() {
    local title="$1" out id
    # NOT `run_verb … | grep`: `die` inside a pipeline runs in a subshell and
    # would not abort this script. Capture first, parse the variable — the
    # same trap `capture()` documents for `hermes … | grep -q`.
    out="$(run_verb "kanban create ($title)" kanban create "$title" \
        --body "Seeded for the chat badge journey" --initial-status running)"
    id="$(printf '%s' "$out" | grep -oE 't_[0-9a-f]+' | head -1)"
    [ -n "$id" ] || { printf '%s\n' "$out" >&2; die "could not parse a task id out of 'hermes kanban create' [$title]"; }
    run_verb "kanban claim ($title)" kanban claim "$id" >/dev/null
    printf '%s' "$id"
}

# Create a running + a review task and stamp both with $1.
seed_chat_tasks() {
    local session_id="$1" label="$2" running review
    running="$(kanban_create_claimed "Fixture: $label running")"
    review="$(kanban_create_claimed "Fixture: $label review")"
    [ -n "$running" ] && [ -n "$review" ] || die "could not parse the seeded task ids for $label"
    # `request-review` is the only verb that reaches the `review` column;
    # --force because the task carries no active review run of its own.
    run_verb "kanban request-review ($label)" kanban request-review "$review" \
        --summary "Seeded in review so the chat badge has something waiting on a human" --force >/dev/null
    "$SQLITE_BIN" "$KANBAN_DB" \
        "UPDATE tasks SET session_id = '$session_id' WHERE id IN ('$running', '$review');" \
        || die "could not stamp session_id=$session_id onto $running/$review"
    note "$label: $running (running) + $review (review) -> session $session_id"
}

seed_chat_tasks "$BADGE_SESSION_A" "chat A"
seed_chat_tasks "$BADGE_SESSION_B" "chat B"

# The three chats themselves. Same direct-write reasoning as the cost rows:
# no CLI verb mints a session with a CHOSEN id, and the Live journey has to
# know the id in advance to click `chat.session.<id>` and to stamp the board.
step "Seeding the ACP chats the badge journey switches between"
BADGE_BASE_TS="$(( $(date +%s) - 600 ))"
seed_badge_session() {
    local id="$1" title="$2"
    "$SQLITE_BIN" "$STATE_DB" \
        "INSERT OR REPLACE INTO sessions (id, source, model, started_at, last_activity_at, message_count, tool_call_count, title) \
         VALUES ('$id', 'acp', 'fixture/chat-model', $BADGE_BASE_TS, $BADGE_BASE_TS, 2, 0, '$title');" \
        || die "could not seed ACP chat $id into the fixture state.db"
    note "$id ($title)"
}
seed_badge_session "$BADGE_SESSION_A"     "UIBADGE Chat With Tasks A"
seed_badge_session "$BADGE_SESSION_B"     "UIBADGE Chat With Tasks B"
seed_badge_session "$BADGE_SESSION_EMPTY" "UIBADGE Chat Without Tasks"

# Counted off the STATUS COLUMN, not out of the listing's text: the seeded
# titles contain the words "running" and "review", so a grep over
# `kanban list` matched two rows that were both still `ready` and the check
# passed on a fixture the badge would have rendered as 1.
for sid in "$BADGE_SESSION_A" "$BADGE_SESSION_B"; do
    live="$("$SQLITE_BIN" "$KANBAN_DB" \
        "SELECT COUNT(*) FROM tasks WHERE session_id = '$sid' AND status IN ('running','blocked','review');")"
    [ "$live" -eq 2 ] || {
        "$SQLITE_BIN" "$KANBAN_DB" "SELECT id, status FROM tasks WHERE session_id = '$sid';" >&2
        die "session $sid owns $live live (running/blocked/review) tasks, expected 2 — KanbanChatBadgeState.liveStatuses is what the Live badge journey asserts"
    }
    # And prove the CLI's own session filter agrees, since that is the call
    # `KanbanChatBadgeViewModel` actually makes.
    scoped="$(capture kanban list --session "$sid")"
    # Rows are prefixed with a status glyph ("● t_6d0e2215  running …"), so
    # anchor on the id, not on the start of the line.
    listed="$(printf '%s\n' "$scoped" | grep -cE '\bt_[0-9a-f]+\b' || true)"
    [ "$listed" -eq 2 ] || { printf '%s\n' "$scoped" >&2; die "'hermes kanban list --session $sid' lists $listed rows, expected 2"; }
    note "kanban --session $sid: 2 live rows (running + review)"
done
scoped_empty="$(capture kanban list --session "$BADGE_SESSION_EMPTY")"
empty_rows="$(printf '%s\n' "$scoped_empty" | grep -cE '\bt_[0-9a-f]+\b' || true)"
[ "$empty_rows" -eq 0 ] || { printf '%s\n' "$scoped_empty" >&2; die "$BADGE_SESSION_EMPTY should own no tasks, sees $empty_rows"; }
note "kanban --session $BADGE_SESSION_EMPTY: 0 rows"

# ---------------------------------------------------------------- seed: project

step "Seeding a project"
run_verb "project create" project create "Fixture Project" --description "Seeded by make-ui-fixture.sh" >/dev/null
assert_contains "$(capture project list)" "fixture-project" \
    "'hermes project list' does not show the seeded fixture-project"
note "project: fixture-project"

# ---------------------------------------------------------------- seed: skill

step "Seeding an installed skill"
# `skills repair-official <name> --restore --yes` installs from the LOCAL
# optional-skills/ tree in the hermes install dir — no network, no registry
# lookup, deterministic. Deliberately NOT `skills install <hub-id>`: that verb
# resolves identifiers fuzzily and EXITS 0 when it finds no exact match, so it
# cannot be judged by its exit code (see VERBS.md).
run_verb "skills repair-official" skills repair-official openhue --restore --yes >/dev/null
assert_contains "$(capture skills list)" "openhue" \
    "'hermes skills list' does not show the seeded 'openhue' skill"
note "skill: openhue (official, offline source)"

# ---------------------------------------------------------------- seed: memories

step "Seeding built-in memories"
# There is NO CLI verb that CREATES a memory: `hermes memory` only exposes
# setup/status/off/reset (external providers). Built-in memory is two plain
# markdown files, which Scarf's Memory section reads and writes directly
# (MemoryView.swift), so the fixture writes them the same way. Verified against
# `hermes memory --help` — see VERBS.md.
mkdir -p "$DEST_ABS/memories"
cat > "$DEST_ABS/memories/MEMORY.md" <<'EOF'
# Memory

- The Scarf UI release gate runs against a throwaway Hermes home built by
  scripts/ui-fixture/make-ui-fixture.sh.
- FIXTURE-MEMORY-1: this file exists so the Memory section has content to render.
EOF
cat > "$DEST_ABS/memories/USER.md" <<'EOF'
# User

- FIXTURE-MEMORY-2: fixture user profile, seeded for UI tests. Not a real person.
EOF
note "memories/MEMORY.md, memories/USER.md"

# ---------------------------------------------------------------- self-check

if [ "$MODE" = "self-check" ]; then
    step "Self-check: proving the real Hermes home was never written"
    after_digest="$(digest_watched)"
    if [ "$BEFORE_DIGEST" = "$after_digest" ]; then
        note "unchanged: ${#REAL_HOME_WATCHED[@]} watched paths under $REAL_HERMES"
    else
        printf '%s: FAIL — the real Hermes home changed during this run:\n' "$SCRIPT_NAME" >&2
        diff <(printf '%s\n' "$BEFORE_DIGEST") <(printf '%s\n' "$after_digest") >&2 || true
        exit 1
    fi
    # The marker must exist, or the app will silently ignore SCARF_HERMES_HOME and
    # fall back to the real home — the single most dangerous failure mode here.
    [ -f "$DEST_ABS/$MARKER_FILENAME" ] || die "self-check: sentinel $MARKER_FILENAME missing from the fixture home"
    note "sentinel $MARKER_FILENAME present"
fi

# ---------------------------------------------------------------- done

step "Fixture ready"
printf '%s\n' "$DEST_ABS"
