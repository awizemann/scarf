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
    verify_verb kanban block
    verify_verb kanban list

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
