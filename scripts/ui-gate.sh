#!/usr/bin/env bash
#
# ui-gate.sh — Scarf's full UI release gate.
#
# Plans: Full = scarfTests + every scarfUITests suite (the Live-gated ones skip
# themselves); Live = ONLY the Live-gated suites (ChatJourneyUITests,
# LiveGateUITests) with SCARF_UITEST_LIVE=1. Live deliberately does not re-run
# Full: a second 12-minute pass doubled the exposure to runner-side failures
# ("Lost connection to the application" → "Not authorized for performing UI
# testing actions" cascading through every later test) for no extra coverage.
# A new Live-only suite must be added to Live.xctestplan's selectedTests.
#
# Builds a throwaway seeded Hermes fixture home (scripts/ui-fixture/make-ui-fixture.sh),
# then runs the Full and Live xctestplans (unless overridden) against ONE DerivedData
# directory so the app only builds once, and writes a pass/fail summary.
#
# Usage:
#   scripts/ui-gate.sh [--smoke-only] [--skip-live] [--derived-data <path>]
#                       [--keep-fixture] [--summary <file>]
#
#   --smoke-only        Run only the Smoke plan (fast sanity: section sweep). Skips Full/Live.
#   --skip-live          Run Full but skip Live (no real credentials / provider keys needed).
#   --derived-data DIR  Reuse this DerivedData dir instead of a fresh TMPDIR one.
#   --keep-fixture       Don't delete the seeded fixture home on exit.
#   --summary FILE       Write the markdown summary here (default: stdout).
#
# Exits non-zero if the fixture build fails or any run test plan fails.
#
# Verdicts per plan: PASS; FAIL (tests ran and some failed); RUNNER-FAILED —
# the run failed having executed NOTHING (no "Executed N tests" line at all)
# with the runner-side wedge in the log ("Timed out while enabling automation
# mode" / "Not authorized for performing UI testing actions"). That is an
# environment failure and says nothing about the code, so it is reported
# apart from FAIL — in the plan's row and, when no plan genuinely failed, on
# the Overall line. It still exits non-zero: the gate was not cleared.
#   scripts/ui-gate.sh --classify <log-file> <exit-status>
# prints that verdict for an existing log and nothing else (used by
# scripts/tests/test_ui_gate_classify.py).
#
set -euo pipefail

if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null)" in
    */Xcode*.app/Contents/Developer) : ;;
    *) for _xc in /Applications/Xcode.app /Applications/Xcode-*.app; do
         [ -x "$_xc/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$_xc"; break; }
       done ;;
  esac
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/scarf/scarf.xcodeproj"
SCHEME="scarf"

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------- log parsing / verdict ----------
# XCTest prints one "Executed N tests…" line per class/bundle and a final
# total; the total is the LAST line and may read "with 1 test skipped and
# 5 failures", so the pattern must allow the skipped clause or it picks a
# per-class line and under-reports (seen: "14 executed / 2 failed" for a
# run that was really 28 / 5).
xctest_total_line() {
  grep -oE "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?" "$1" | tail -n1 || true
}

# The runner-side failures that mean NO test ever ran. The first is the one
# the gate keeps hitting; the second is how the same wedge reports itself
# once the harness has given up on the app.
RUNNER_FAILURE_RE='Timed out while enabling automation mode|Not authorized for performing UI testing actions'

# PASS / FAIL / RUNNER-FAILED for one finished plan. RUNNER-FAILED is a
# failing run that executed NOTHING because the test runner never came up —
# it says nothing about the code under test, so it must not read as a FAIL
# that someone will go hunting for a broken assertion in. Still non-zero:
# the gate has not been cleared either way.
classify_verdict() {
  local status="$1" log_file="$2"
  if [[ "$status" -eq 0 ]]; then printf 'PASS\n'; return 0; fi
  if [[ -z "$(xctest_total_line "$log_file")" ]] \
     && grep -qE "$RUNNER_FAILURE_RE" "$log_file" 2>/dev/null; then
    printf 'RUNNER-FAILED\n'
    return 1
  fi
  printf 'FAIL\n'
  return 1
}

# Internal entry point for scripts/tests/test_ui_gate_classify.py: classify
# a fabricated log without building or running anything.
if [[ "${1:-}" == "--classify" ]]; then
  [[ $# -eq 3 ]] || die "usage: $0 --classify <log-file> <exit-status>"
  [[ -f "$2" ]] || die "no such log file: $2"
  classify_verdict "$3" "$2" && exit 0 || exit 1
fi

# ---------- arg parsing ----------
SMOKE_ONLY=0
SKIP_LIVE=0
KEEP_FIXTURE=0
DERIVED_DATA=""
SUMMARY_FILE=""
_prev=""
for arg in "$@"; do
  case "$_prev" in
    --derived-data) DERIVED_DATA="$arg"; _prev=""; continue ;;
    --summary) SUMMARY_FILE="$arg"; _prev=""; continue ;;
  esac
  case "$arg" in
    --smoke-only) SMOKE_ONLY=1 ;;
    --skip-live) SKIP_LIVE=1 ;;
    --keep-fixture) KEEP_FIXTURE=1 ;;
    --derived-data) _prev="$arg" ;;
    --derived-data=*) DERIVED_DATA="${arg#--derived-data=}" ;;
    --summary) _prev="$arg" ;;
    --summary=*) SUMMARY_FILE="${arg#--summary=}" ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_cmd xcodebuild
require_cmd python3
[[ -f "$PROJECT/project.pbxproj" ]] || die "scarf.xcodeproj not found at $PROJECT"

if [[ -n "$SUMMARY_FILE" ]]; then
  SUMMARY_DIR="$(dirname "$SUMMARY_FILE")"
  [[ -d "$SUMMARY_DIR" ]] || die "summary directory does not exist: $SUMMARY_DIR"
fi

for plan in Smoke Full Live; do
  [[ -f "$REPO_ROOT/scarf/${plan}.xctestplan" ]] || die "missing test plan: scarf/${plan}.xctestplan"
done

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/scarf-ui-gate.XXXXXX")"
LOG_DIR="$RUN_TMP/logs"
mkdir -p "$LOG_DIR"
if [[ -z "$DERIVED_DATA" ]]; then
  DERIVED_DATA="$RUN_TMP/DerivedData"
fi
mkdir -p "$DERIVED_DATA"

FIXTURE_DIR=""
cleanup() {
  local status=$?
  if [[ $KEEP_FIXTURE -eq 0 && -n "$FIXTURE_DIR" && -d "$FIXTURE_DIR" ]]; then
    rm -rf "$FIXTURE_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

# ---------- fixture ----------
log "Building seeded fixture Hermes home"
FIXTURE_PARENT="$(mktemp -d "$RUN_TMP/fixture.XXXXXX")"
FIXTURE_DEST="$FIXTURE_PARENT/fixture-home"
FIXTURE_T0=$(date +%s)
if ! FIXTURE_DIR="$("$REPO_ROOT/scripts/ui-fixture/make-ui-fixture.sh" --self-check "$FIXTURE_DEST" 2> >(tee "$LOG_DIR/fixture.log" >&2))"; then
  die "fixture build failed — see $LOG_DIR/fixture.log"
fi
FIXTURE_T1=$(date +%s)
FIXTURE_WALL=$((FIXTURE_T1 - FIXTURE_T0))
log "Fixture ready at $FIXTURE_DIR (${FIXTURE_WALL}s)"

# ---------- plans to run ----------
PLANS=()
if [[ $SMOKE_ONLY -eq 1 ]]; then
  PLANS=(Smoke)
else
  PLANS=(Full)
  if [[ $SKIP_LIVE -eq 0 ]]; then
    PLANS+=(Live)
  fi
fi

GIT_HASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
HERMES_VERSION="$("$HERMES_BIN" --version 2>/dev/null | head -n1 || echo unknown)"

declare -a RESULT_LINES=()
OVERALL_STATUS=0
# Set when a plan died before running a single test. The gate still fails,
# but the overall line must not blame the code for it.
SAW_RUNNER_FAILURE=0
SAW_TEST_FAILURE=0

# Serial on purpose. The Full plan carries scarfTests as well as scarfUITests,
# and the unit half is only green SERIALLY: several suites share process-wide
# state (ChatViewModelStartLifecycleTests, MainActorBlockingWritesP11Tests and
# friends) and fail under Xcode's default parallel execution — on main too, not
# just on a branch (round-7 audit, 2026-09-13: 124 issues / 12 suites parallel,
# 0 serial). The 3.2.0 cut hit exactly that: 16/16 UI tests passed and the gate
# still said FAIL. `-parallel-testing-enabled NO` is the signal every report
# quotes; the UI plans are serial by nature so they lose nothing.
run_plan() {
  local plan="$1"
  local bundle="$RUN_TMP/${plan}.xcresult"
  local log_file="$LOG_DIR/${plan}.log"
  local t0 t1 wall status
  log "Running $plan plan"
  t0=$(date +%s)
  set +e
  TEST_RUNNER_SCARF_UITEST_FIXTURE="$FIXTURE_DIR" \
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -testPlan "$plan" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$bundle" \
    -skipPackagePluginValidation -skipMacroValidation \
    -parallel-testing-enabled NO \
    2>&1 | tee "$log_file" | grep --line-buffered -E "Test Suite|Test Case|error:|BUILD FAILED|BUILD SUCCEEDED|\*\* TEST (SUCCEEDED|FAILED) \*\*"
  status=${PIPESTATUS[0]}
  set -e
  t1=$(date +%s)
  wall=$((t1 - t0))

  # See `xctest_total_line` for why the total is parsed the way it is.
  # Swift Testing (the ScarfCore + scarfTests unit suites) reports
  # separately as "Test run with N tests in M suites passed|failed"; carry
  # that too so the unit total is visible.
  local executed failed unit_line
  unit_line="$(grep -oE "Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)" "$log_file" | tail -n1 || true)"
  local xctest_total
  xctest_total="$(xctest_total_line "$log_file")"
  executed="$(printf '%s' "$xctest_total" | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+" || true)"
  failed="$(printf '%s' "$xctest_total" | grep -oE "[0-9]+ failures?$" | grep -oE "[0-9]+" || true)"
  [[ -n "$executed" ]] || executed="?"
  [[ -n "$failed" ]] || failed="?"
  [[ -n "$unit_line" ]] || unit_line="unit: not reported"

  local verdict
  verdict="$(classify_verdict "$status" "$log_file" || true)"
  if [[ "$verdict" != "PASS" ]]; then
    OVERALL_STATUS=1
    if [[ "$verdict" == "RUNNER-FAILED" ]]; then
      SAW_RUNNER_FAILURE=1
      warn "$plan: the test runner never came up (no tests executed) — an environment failure, not a code failure. See $log_file."
    else
      SAW_TEST_FAILURE=1
    fi
  fi

  RESULT_LINES+=("| $plan | $verdict | UI: ${executed} executed / ${failed} failed; ${unit_line} | ${wall}s | \`$bundle\` |")
  log "$plan: $verdict (${wall}s) — log: $log_file, bundle: $bundle"
}

for plan in "${PLANS[@]}"; do
  run_plan "$plan"
done

# ---------- summary ----------
SUMMARY_CONTENT="$(cat <<EOF
# UI Gate Summary

- Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
- Git commit: $GIT_HASH
- Hermes version: $HERMES_VERSION
- Fixture build: ${FIXTURE_WALL}s (fixture removed unless --keep-fixture)
- DerivedData: $DERIVED_DATA

| Plan | Result | Tests | Wall time | Result bundle |
| --- | --- | --- | --- | --- |
$(printf '%s\n' "${RESULT_LINES[@]}")

Overall: $(if [[ $OVERALL_STATUS -eq 0 ]]; then echo "PASS"; elif [[ $SAW_RUNNER_FAILURE -eq 1 && $SAW_TEST_FAILURE -eq 0 ]]; then echo "RUNNER-FAILED"; else echo "FAIL"; fi)
EOF
)"

if [[ -n "$SUMMARY_FILE" ]]; then
  printf '%s\n' "$SUMMARY_CONTENT" > "$SUMMARY_FILE"
  log "Summary written to $SUMMARY_FILE"
else
  printf '%s\n' "$SUMMARY_CONTENT"
fi

exit $OVERALL_STATUS
