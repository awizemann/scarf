#!/usr/bin/env bash
#
# ui-gate-vm.sh — run Scarf's XCUITest plans inside a Tart virtual Mac instead
# of on this Mac's screen.
#
# The UI plans take the keyboard, the pointer and the front window for as long
# as they run. This script builds on the host once (build-for-testing, signed
# exactly as scripts/ui-gate.sh signs), copies the products into a long-lived
# headless Tart clone (`scarf-ui` by default), installs the requested
# Hermes tag there, seeds the fixture home there with
# scripts/ui-fixture/make-ui-fixture.sh, runs each plan with
# `xcodebuild test-without-building`, and brings the result bundles back.
#
# Usage:
#   scripts/ui-gate-vm.sh --hermes-tag <tag> [--plans Smoke,Full,Live]
#                         [--reuse scarf-ui] [--no-build] [--keep-results]
#                         [--with-unit-tests] [--skip-display-check]
#                         [--only Class[/test]]… [--allow-oauth-provider]
#
#   --hermes-tag TAG   Hermes tag to install in the guest (v0.22.5, v2026.9.24, …).
#                      Must exist in the Hermes checkout ($SCARF_VM_HERMES_SRC,
#                      default ~/.hermes/hermes-agent).
#   --plans LIST       Comma-separated test plans, run one at a time in this order
#                      (default Smoke,Full,Live).
#   --reuse NAME       The running Tart clone to use. Only scarf-ui (the default:
#                      Scarf's own clone of ScarfRack's UI-test image, with a
#                      display tall enough for the window the tests pin) is
#                      accepted; see "Sharing the clone". This script never
#                      starts, stops or deletes a VM.
#   --no-build         Run what the last build in build/ui-gate-vm/derived made.
#   --keep-results     Keep every earlier results folder (default: the last ten).
#   --ui-only          Run only the scarfUITests target of each plan (the default):
#                      Full's ~2,000 scarfTests unit tests run headless on the host
#                      and need no VM, and leaving them out keeps the clone's hold short.
#   --with-unit-tests  Run each plan whole, scarfTests included.
#   --only X           Run only this scarfUITests class or test (Class or
#                      Class/testName); may be given more than once.
#   --skip-display-check  Run even when the guest's screen is smaller than the
#                      window the UI tests pin (every UI test then fails its
#                      window-size check; useful only to exercise the script).
#   --allow-oauth-provider  When the active provider signs in with OAuth, copy
#                      its one auth.json entry in (otherwise the run stops).
#   --credentials-only Build the guest's credentials on the host, print the
#                      NAMES that would go in, delete them, and stop (no VM).
#
# Environment:
#   SCARF_VM_RIG_LIB      ScarfRack's tools/fresh-mac-rig/lib.sh (gssh, wait_ssh,
#                         make_askpass, GUEST_USER, RIG_HOME…). Default
#                         ~/Developer/ScarfRack/tools/fresh-mac-rig/lib.sh. The VM's
#                         login lives there, never in this repo.
#   SCARF_VM_HERMES_SRC   Hermes git checkout holding the tags (default ~/.hermes/hermes-agent).
#   SCARF_VM_SOURCE_HOME  Hermes home whose model credentials the run borrows
#                         (default ~/.hermes).
#   SCARF_VM_UV           uv binary copied into the guest (default: `command -v uv`).
#   SCARF_VM_SSH_WAIT     seconds to wait for the clone to answer over SSH (default 600).
#   SCARF_VM_EXTRA_ENV    extra .env variable names to copy in (space/comma list),
#                         on top of the active provider's key.
#
# Credentials: an ALLOW-LIST, built in a private host scratch dir. The guest's
# config.yaml is written from scratch with only model.provider / default /
# model / base_url / api_mode (no api_key, MCP servers, auxiliary, delegation,
# TTS, custom providers or platforms) and gateway.multiplex_profiles false. Its
# .env holds only the key variable(s) the tag's provider registry
# (hermes_cli/auth.py _REGISTRY_ROWS; for OpenRouter, which has no row, the
# OPENROUTER_* names its _openrouter_auto_detected reads) names for the
# ACTIVE provider — taken from .env, or from an API-key entry in auth.json's
# credential pool — plus any names in SCARF_VM_EXTRA_ENV. GITHUB_TOKEN,
# GH_TOKEN, HF_TOKEN, CLAUDE_CODE_OAUTH_TOKEN and AWS_* never go in. auth.json never goes in: an OAuth
# provider stops the run unless --allow-oauth-provider, which copies that one
# provider's entry (a guest refresh can rotate the token and sign this Mac out).
# Every copied value is deleted on every exit, pass or fail, then searched for
# in the guest to prove it. Only NAMES are ever printed.
#
# Sharing the clone: a kernel-held lock — flock(2) on
# $RIG_HOME/locks/<clone>.lockf, held by this script's own fd 9, so the kernel
# releases it the moment the run exits or is killed (no stale locks, no
# takeover). A second run waits up to 20 minutes. It does NOT interoperate
# with ScarfRack's mkdir lock, so only Scarf's own clone (scarf-ui) may be
# used: ScarfRack's clones (ui-dev, …) are not supported. Only this run's own
# guest folders are removed.
#
# Results: build/ui-gate-vm/results/<stamp>/ — summary.md, one .xcresult and
# one .log per plan, plus the setup and fixture logs. Exits non-zero when any
# plan is not PASS. Verdicts are scripts/ui-gate.sh's (--classify): PASS, FAIL,
# RUNNER-FAILED. A test that "crashed with signal kill" (in this VM, macOS's
# low-disk purge terminating the test runner) is rerun ONCE, alone
# (-only-testing:Class/test), and the rerun decides it; both attempts are in
# summary.md (<plan>-rerunN.log / .xcresult). No other failure is ever rerun.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/scarf/scarf.xcodeproj"
SCHEME="scarf"

RIG_LIB="${SCARF_VM_RIG_LIB:-$HOME/Developer/ScarfRack/tools/fresh-mac-rig/lib.sh}"
if [[ ! -f "$RIG_LIB" ]]; then
  printf '[ERR] ScarfRack rig helpers not found at %s — set SCARF_VM_RIG_LIB to its tools/fresh-mac-rig/lib.sh\n' "$RIG_LIB" >&2
  exit 1
fi
# lib.sh needs bash (BASH_SOURCE) and sets HERE, GUEST_USER, RIG_HOME, SSH_OPTS
# and the gssh/gscp helpers. Its log/die are replaced by ours below.
# shellcheck source=/dev/null
. "$RIG_LIB"

# lib.sh gives SSH 5 s to connect; a busy guest (a fresh boot, or Xcode
# starting) can take longer just to send its banner, and a failed gssh ends the run.
SSH_OPTS=("${SSH_OPTS[@]/ConnectTimeout=5/ConnectTimeout=30}")

log()  { printf '\033[1;34m%s ==> %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- args ----------
HERMES_TAG=""
PLANS_ARG="Smoke,Full,Live"
REUSE="scarf-ui"
BUILD=1
KEEP_RESULTS=0
UI_ONLY=1
DISPLAY_CHECK=1
ALLOW_OAUTH=0
CREDS_ONLY=0
LOCK_TEST=""
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hermes-tag) HERMES_TAG="${2:?--hermes-tag needs a tag}"; shift 2 ;;
    --plans) PLANS_ARG="${2:?--plans needs a list}"; shift 2 ;;
    --reuse) REUSE="${2:?--reuse needs a clone name}"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --keep-results) KEEP_RESULTS=1; shift ;;
    --ui-only) UI_ONLY=1; shift ;;
    --with-unit-tests) UI_ONLY=0; shift ;;
    --skip-display-check) DISPLAY_CHECK=0; shift ;;
    --allow-oauth-provider) ALLOW_OAUTH=1; shift ;;
    --credentials-only) CREDS_ONLY=1; BUILD=0; shift ;;
    --lock-test) LOCK_TEST="${2:?}"; HERMES_TAG="${HERMES_TAG:-none}"; shift 2 ;;
    --only)
      case "${2:-}" in *[!A-Za-z0-9_/]*|"") die "--only takes Class or Class/test" ;; esac
      ONLY+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,88p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ -n "$HERMES_TAG" ]] || die "--hermes-tag is required (see --help)"
case "$REUSE" in *[!A-Za-z0-9_-]*|"") die "--reuse takes a clone's name" ;; esac
# The lock below is Scarf's own (flock), not ScarfRack's mkdir lock, so a clone
# ScarfRack also drives (ui-dev, …) could be used by both at once.
[[ "$REUSE" == scarf-ui ]] || die "--reuse $REUSE: only Scarf's own clone, scarf-ui, is supported (its lock doesn't interoperate with ScarfRack's, whose clones such as ui-dev are ScarfRack's)"

# ---------- the clone's lock ----------
# flock(2) on fd 9 of THIS shell: the kernel holds it for as long as the fd is
# open in this process (or a child that inherited it) and drops it on exit,
# crash or kill -9. Python only makes the flock call on the inherited fd.
LOCKFILE="$RIG_HOME/locks/$REUSE.lockf"
take_clone_lock() {
  local waited=0
  mkdir -p "$(dirname "$LOCKFILE")"
  exec 9>>"$LOCKFILE"
  local rc
  while :; do
    rc=0
    /usr/bin/python3 -I -c 'import fcntl, sys
try: fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit(1)' || rc=$?
    [[ $rc -eq 0 ]] && break
    # 1 = held by another run; anything else (no python3, bad fd) is a real error.
    [[ $rc -eq 1 ]] || die "could not take the $REUSE lock (python3 flock exited $rc)"
    [[ $waited -lt 1200 ]] || die "$REUSE has been in use for 20 minutes ($(head -1 "$LOCKFILE" 2>/dev/null || echo "by another run")): giving up"
    [[ $waited -ne 0 ]] || log "$REUSE is in use ($(head -1 "$LOCKFILE" 2>/dev/null || echo "by another run")): waiting for it"
    sleep 5; waited=$((waited + 5))
  done
  echo "Scarf ui-gate-vm (pid $$) from $REPO_ROOT since $(date +%H:%M)" >"$LOCKFILE" 2>/dev/null || true
}
# Long-lived children close fd 9 (the plan's ssh, its bound watcher). Other
# children inherit it, so after a kill -9 of this script the lock stays held
# until the one running then finishes (the setup and fixture ssh have no host
# time limit, so that can be minutes, while the guest is still busy anyway).
if [[ -n "$LOCK_TEST" ]]; then   # hidden: take the lock, hold it, exit (tests the lock alone)
  take_clone_lock; log "lock-test: holding $LOCKFILE for ${LOCK_TEST}s (pid $$)"; sleep "$LOCK_TEST" 9>&-; log "lock-test: done"; exit 0
fi
IFS=',' read -r -a PLANS <<<"$PLANS_ARG"
for plan in "${PLANS[@]}"; do
  case "$plan" in Smoke|Full|Live) ;; *) die "unknown plan: $plan (Smoke, Full or Live)" ;; esac
  [[ -f "$REPO_ROOT/scarf/${plan}.xctestplan" ]] || die "missing test plan: scarf/${plan}.xctestplan"
done

HERMES_SRC="${SCARF_VM_HERMES_SRC:-$HOME/.hermes/hermes-agent}"
SOURCE_HOME="${SCARF_VM_SOURCE_HOME:-$HOME/.hermes}"
UV_BIN="${SCARF_VM_UV:-$(command -v uv || true)}"
GUEST_DEV="/Volumes/My Shared Files/xcode/Contents/Developer"

command -v xcodebuild >/dev/null || die "xcodebuild not found"
[[ -x "$UV_BIN" ]] || die "uv not found (set SCARF_VM_UV)"
git -C "$HERMES_SRC" rev-parse -q --verify "refs/tags/$HERMES_TAG" >/dev/null \
  || die "tag $HERMES_TAG not found in $HERMES_SRC (set SCARF_VM_HERMES_SRC)"
for f in config.yaml .env; do
  [[ -f "$SOURCE_HOME/$f" ]] || die "$SOURCE_HOME/$f is missing (set SCARF_VM_SOURCE_HOME)"
done
[[ $CREDS_ONLY -eq 1 ]] || need_tart

# A Python with PyYAML, used only on the host to sanitize config.yaml.
PY=""
for cand in "${SCARF_VM_PYTHON:-}" python3 "$HERMES_SRC/venv/bin/python"; do
  [[ -n "$cand" ]] || continue
  if "$cand" -B -c 'import yaml' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[[ -n "$PY" ]] || die "no python3 with PyYAML found (set SCARF_VM_PYTHON)"

# The clone must already be up; this script never boots one.
[[ $CREDS_ONLY -eq 1 ]] || tart list | awk -v n="$REUSE" '$2 == n && $NF == "running" { ok = 1 } END { exit !ok }' \
  || die "Tart clone $REUSE is not running (start it with ScarfRack's tools/ui-test/clone.sh start $REUSE)"

# ---------- the Hermes version the guest must report ----------
# vX.Y.Z → X.Y.Z. A calendar tag (vYYYY.M.D) reports the version in that tag's
# pyproject.toml (hermes_cli/version_info.py `_calver_release_version`).
case "$HERMES_TAG" in
  v20[0-9][0-9].*)
    EXPECT_VERSION="$(git -C "$HERMES_SRC" show "$HERMES_TAG:pyproject.toml" | sed -n 's/^version *= *"\(.*\)"/\1/p' | head -1)" ;;
  v[0-9]*) EXPECT_VERSION="${HERMES_TAG#v}" ;;
  *) die "can't tell which version $HERMES_TAG reports" ;;
esac
[[ -n "$EXPECT_VERSION" ]] || die "could not read the version of $HERMES_TAG"

# The newest Python the tag allows (requires-python), e.g. ">=3.11,<3.15" → 3.14.
REQUIRES_PY="$(git -C "$HERMES_SRC" show "$HERMES_TAG:pyproject.toml" | sed -n 's/^requires-python *= *"\(.*\)"/\1/p' | head -1)"
py_allowed() {   # $1 = 3.N; true when it satisfies every >= / < clause of REQUIRES_PY
  local v="$1" clause op bound
  IFS=',' read -r -a clauses <<<"$REQUIRES_PY"
  for clause in "${clauses[@]}"; do
    clause="${clause// /}"
    case "$clause" in
      ">="*) op=ge; bound="${clause#>=}" ;;
      "<"*)  op=lt; bound="${clause#<}" ;;
      *) continue ;;
    esac
    local lowest; lowest="$(printf '%s\n%s\n' "$v" "$bound" | sort -V | head -1)"
    if [[ $op == ge && "$lowest" != "$bound" && "$v" != "$bound" ]]; then return 1; fi
    if [[ $op == lt && ( "$lowest" != "$v" || "$v" == "$bound" ) ]]; then return 1; fi
  done
  return 0
}
GUEST_PY=""
for v in 3.14 3.13 3.12 3.11; do if py_allowed "$v"; then GUEST_PY="$v"; break; fi; done
[[ -n "$GUEST_PY" ]] || die "no Python in 3.11–3.14 satisfies $HERMES_TAG's requires-python ($REQUIRES_PY)"

# ---------- paths ----------
OUT="$REPO_ROOT/build/ui-gate-vm"
DERIVED="$OUT/derived"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
RESULT="$OUT/results/$STAMP"
mkdir -p "$RESULT"
if [[ $KEEP_RESULTS -eq 0 ]]; then
  ls -1dt "$OUT/results"/*/ 2>/dev/null | tail -n +11 | while IFS= read -r old; do
    case "$old" in "$OUT/results/"?*) rm -rf "$old" ;; esac
  done
fi
# Private host scratch: the sanitized credentials, the Hermes clone, the askpass.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/scarf-ui-gate-vm.XXXXXX")"
chmod 700 "$SCRATCH"
STAGE="$SCRATCH/stage"
mkdir -p "$STAGE/bin"
GW="work/scarf-$STAMP"          # the guest run dir, relative to the guest's $HOME
GUEST_RESULTS="results/scarf-$STAMP"

# ---------- cleanup on every exit ----------
GUEST_UP=0; GUEST_HOME=""; STARTED_AT="$(date +%s)"; TESTS_PID=""; WATCH_PID=""
gssh_in() {   # gssh with this process's stdin (lib.sh's gssh reads /dev/null)
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
    ssh "${SSH_OPTS[@]}" "$GUEST_USER@$VM_IP" "$@"
}
# A guest command run by bash, not the login shell: the guest's zsh aborts a
# whole command line on a glob that matches nothing.
gbash() { gssh_in "bash -s" <<<"$1"; }
# Guest bash that removes what any Scarf run leaves holding credential copies:
# the tests' per-test homes (copies of the fixture home, keys included) in the
# runner's temp dirs, and a ~/.hermes a run created (marked inside, see step 3).
# guest.sh's cleanup runs the same lines.
HERMES_MARK=".scarf-ui-gate-vm-created"
SWEEP='for d in "$(getconf DARWIN_USER_TEMP_DIR)" "$HOME"/Library/Containers/*/Data/tmp; do [ -d "$d" ] && find "$d" -maxdepth 1 -name "scarf-uitest-home-*" -exec rm -rf {} + 2>/dev/null; done; [ -f "$HOME/.hermes/'"$HERMES_MARK"'" ] && rm -rf "$HOME/.hermes"; true'
cleanup() {
  local status=$?
  trap '' INT TERM
  # An interrupted plan: stop its bound watcher and the ssh running the tests
  # (and their children) before the guest is cleaned under them.
  local p
  for p in $WATCH_PID $TESTS_PID; do
    pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true
  done
  if [[ $GUEST_UP -eq 1 ]]; then
    log "cleaning $REUSE"
    # The guest helper stops the fixture's gateway and every process of this run,
    # removes the hermes shim, the run dir, the result bundles and test homes.
    gssh "bash ~/$GW/guest.sh '$GUEST_HOME/$GW' cleanup" >>"$RESULT/cleanup.log" 2>&1 \
      || gbash "d=~/$GW; pkill -f \"\$d/\" ; r=\$(cd \$d 2>/dev/null && pwd -P) && pkill -f \"\$r/\" ; rm -rf ~/$GW ~/$GUEST_RESULTS-* ; grep -q 'scarf-ui-gate-vm $STAMP' ~/.local/bin/hermes 2>/dev/null && rm -f ~/.local/bin/hermes; $SWEEP" >>"$RESULT/cleanup.log" 2>&1 || true
    # Belt and braces: the sweep again, whichever path ran above.
    gbash "$SWEEP" >>"$RESULT/cleanup.log" 2>&1 || true
    verify_guest_clean || status=1
  fi
  exec 9>&- 2>/dev/null || true   # releases the clone's lock (exit would too)
  rm -rf "$SCRATCH"
  [[ ! -e "$SCRATCH" ]] || { warn "could not delete the host scratch dir $SCRATCH"; status=1; }
  log "results: $RESULT"
  exit "$status"
}
# Proves the guest holds nothing of this run: no run dir, no shim, and none of
# the copied credential VALUES anywhere a run writes (values go over stdin and
# only matching FILE NAMES come back).
verify_guest_clean() {
  local left mins found
  left="$(gbash "ls -d ~/$GW ~/$GUEST_RESULTS-* ~/.hermes/$HERMES_MARK 2>/dev/null; grep -l 'scarf-ui-gate-vm' ~/.local/bin/hermes 2>/dev/null; find \"\$(getconf DARWIN_USER_TEMP_DIR)\" ~/Library/Containers/*/Data/tmp -maxdepth 1 -name 'scarf-uitest-home-*' 2>/dev/null; true")"
  mins=$(( ( $(date +%s) - STARTED_AT ) / 60 + 5 ))
  found=""; local searched="searched for"
  if [[ ! -s "$SCRATCH/secret-values" ]]; then
    searched="NOT searched for (this run recorded no copied credential values)"
  else
    found="$(gssh_in "grep -rlsF -f /dev/stdin ~/work/ ~/results/ ~/.hermes ~/.local \"\$(getconf DARWIN_USER_TEMP_DIR)\" ~/Library/Containers 2>/dev/null | head -20; true" <"$SCRATCH/secret-values" || echo "(could not search)")"
  fi
  local envs
  envs="$(gssh "find ~ ~/work/ ~/results/ \"\$(getconf DARWIN_USER_TEMP_DIR)\" -mmin -$mins \( -name .env -o -name auth.json \) -not -path '*/Library/Caches/*' 2>/dev/null | head -20; true")"
  {
    echo "leftover paths: ${left:-none}"
    echo "copied credential values: $searched"
    echo "files holding a copied credential: ${found:-none}"
    echo ".env/auth.json written during the run: ${envs:-none}"
  } | tee "$RESULT/cleanup-verify.txt" >&2
  [[ -z "$left$found$envs" ]] || { warn "the guest is NOT clean — see $RESULT/cleanup-verify.txt"; return 1; }
  log "guest verified clean: run dir, shim and copied credentials gone"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- 1. build on the host ----------
if [[ $BUILD -eq 1 ]]; then
  # Same signing as scripts/ui-gate.sh (the project's automatic Apple Development
  # signing): UI tests need a signed build — with CODE_SIGNING_ALLOWED=NO the
  # runner never connects. The scheme lists the Smoke/Full/Live plans, so one
  # build-for-testing writes one .xctestrun per plan.
  RESOLVED="scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  if [[ ! -f "$REPO_ROOT/$RESOLVED" ]]; then
    MAIN_CHECKOUT="$(git -C "$REPO_ROOT" worktree list --porcelain | sed -n '1s/^worktree //p')"
    [[ -f "$MAIN_CHECKOUT/$RESOLVED" ]] || die "no pinned Package.resolved in $REPO_ROOT or $MAIN_CHECKOUT"
    mkdir -p "$(dirname "$REPO_ROOT/$RESOLVED")"; cp "$MAIN_CHECKOUT/$RESOLVED" "$REPO_ROOT/$RESOLVED"
  fi
  log "build-for-testing (log: $RESULT/build.log)"
  xcodebuild build-for-testing \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation -skipMacroValidation \
    >"$RESULT/build.log" 2>&1 || { grep -E "error:" "$RESULT/build.log" | head -20 >&2; die "build-for-testing failed (log: $RESULT/build.log)"; }
fi
[[ $CREDS_ONLY -eq 1 ]] || for plan in "${PLANS[@]}"; do
  ls "$DERIVED/Build/Products/${SCHEME}_${plan}_"*.xctestrun >/dev/null 2>&1 \
    || die "no ${SCHEME}_${plan}_*.xctestrun in $DERIVED/Build/Products: run without --no-build"
done

# ---------- 2. host-side staging ----------
log "staging Hermes $HERMES_TAG (reports $EXPECT_VERSION, Python $GUEST_PY)"
# A depth-1 clone of the tag, shipped with its .git: Hermes derives its version
# from git tags, so a plain archive would report "unknown". (A git bundle can't
# carry a shallow history, and a full one is ~1 GB.)
git clone -q --depth 1 --branch "$HERMES_TAG" "file://$HERMES_SRC" "$SCRATCH/hermes" 2>/dev/null \
  || die "could not clone $HERMES_TAG from $HERMES_SRC"
mkdir -p "$STAGE/hermes"; mv "$SCRATCH/hermes/.git" "$STAGE/hermes/.git"
cp "$UV_BIN" "$STAGE/bin/uv"
cp "$REPO_ROOT/scripts/ui-fixture/make-ui-fixture.sh" "$STAGE/make-ui-fixture.sh"

log "building the guest's credentials from $SOURCE_HOME: the active model provider's key only"
cat >"$SCRATCH/sanitize.py" <<'PY'
# sanitize.py <hermes-src> <source-home> <dest> <secret-values-out> <allow-oauth 0|1> <extra-env-names>
# An ALLOW-LIST: the guest gets a config.yaml written from scratch with only the
# model selection, a .env with only the active provider's key variable(s) (as
# the tag's provider registry names them) plus SCARF_VM_EXTRA_ENV, and no
# auth.json unless --allow-oauth-provider. Prints NAMES only, never a value.
import ast, json, pathlib, re, sys, yaml
src, home, dst, values_out = map(pathlib.Path, sys.argv[1:5])
allow_oauth = sys.argv[5] == "1"
extra = [n for n in re.split(r"[\s,]+", sys.argv[6]) if n]
def die(msg):
    print("sanitize: " + msg, file=sys.stderr); sys.exit(1)
# Never copied, whatever the provider or the opt-in list says: broad tokens
# (GitHub, Hugging Face), cloud credentials, and CLAUDE_CODE_OAUTH_TOKEN (an
# OAuth token that rides on anthropic's API-key row).
FORBIDDEN = re.compile(r"^(GITHUB_TOKEN|GH_TOKEN|HF_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|AWS_.*)$")

cfg = yaml.safe_load((home / "config.yaml").read_text()) or {}
model = cfg.get("model")
if isinstance(model, str):
    model = {"default": model}
if not isinstance(model, dict):
    die("config.yaml has no model section")
provider = str(model.get("provider") or "").strip().lower()
if not provider:
    die("config.yaml sets no model.provider: the guest can't be given just one provider's key")

# The tag's provider registry, read from source (never imported): each
# _REGISTRY_ROWS entry is a tuple (id, name, base_url, env_vars[, base_url_env[, auth_type]])
# or a ProviderConfig(id, name, auth_type, …, api_key_env_vars=…) call.
tree = ast.parse((src / "hermes_cli/auth.py").read_text())
rows = None
for node in ast.walk(tree):
    targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
    if any(isinstance(t, ast.Name) and t.id == "_REGISTRY_ROWS" for t in targets) and isinstance(node.value, ast.Tuple):
        rows = node.value.elts
if rows is None:
    die("could not find _REGISTRY_ROWS in the tag's hermes_cli/auth.py")
def lit(n):
    try:
        return ast.literal_eval(n)
    except Exception:
        return None
registry = {}
for r in rows:
    if isinstance(r, ast.Tuple):
        v = [lit(e) for e in r.elts]
        registry[v[0]] = {"auth": v[5] if len(v) > 5 else "api_key", "env": tuple(v[3] or ())}
    elif isinstance(r, ast.Call):
        args = [lit(a) for a in r.args]; kw = {k.arg: lit(k.value) for k in r.keywords}
        registry[args[0]] = {"auth": kw.get("auth_type", args[2] if len(args) > 2 else None),
                             "env": tuple(kw.get("api_key_env_vars") or ())}
# A provider with no registry row (OpenRouter has its own rung in
# resolve_provider, at every supported tag) is resolved by auth.py's own
# function for it (`_openrouter_auto_detected`): of the key-shaped names that
# function reads, the ones named for the provider (OPENROUTER_*) — not the
# legacy OPENAI_API_KEY fallback, which belongs to another provider.
if provider not in registry:
    stem = re.sub(r"[^a-z0-9]+", "_", provider)
    prefix = stem.upper() + "_"
    found = set()
    for fn in ast.walk(tree):
        if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)) and stem in fn.name:
            found |= {c.value for c in ast.walk(fn) if isinstance(c, ast.Constant) and isinstance(c.value, str)
                      and re.fullmatch(r"[A-Z][A-Z0-9_]*_(API_KEY|TOKEN|KEY)", c.value) and c.value.startswith(prefix)}
    if found:
        registry[provider] = {"auth": "api_key", "env": tuple(sorted(found))}

entry = registry.get(provider)
oauth = False
if entry is None:
    if not extra:
        die(f"model.provider {provider!r} is not in {src.name}'s provider registry; name its key variable(s) in SCARF_VM_EXTRA_ENV")
    wanted = []
elif entry["auth"] == "api_key":
    wanted = [n for n in entry["env"] if n]
elif str(entry["auth"]).startswith("oauth"):
    if not allow_oauth:
        die(f"model.provider {provider!r} signs in with OAuth ({entry['auth']}): its credentials live in auth.json, "
            "and a guest holding the refresh token can rotate it and sign this Mac out. Switch the source home "
            "(SCARF_VM_SOURCE_HOME) to an API-key provider, or pass --allow-oauth-provider to copy that one entry anyway")
    oauth = True; wanted = []
else:
    die(f"model.provider {provider!r} authenticates via {entry['auth']}, which the VM run doesn't support")

# config.yaml from scratch: only what picks the model. No api_key, no
# mcp_servers / auxiliary / delegation / tts / custom_providers / platforms.
new_model = {k: model[k] for k in ("provider", "default", "model", "base_url", "api_mode") if model.get(k)}
dst.mkdir(parents=True, exist_ok=True)
(dst / "config.yaml").write_text(yaml.safe_dump({"model": new_model, "gateway": {"multiplex_profiles": False}}, sort_keys=False))

env = {}
for line in (home / ".env").read_text().splitlines():
    m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)", line)
    if m:
        env[m.group(1)] = (line, m.group(2).strip().strip("'\""))
copied, refused, missing, values = [], [], [], []
for name in wanted + [n for n in extra if n not in wanted]:
    if FORBIDDEN.match(name):
        refused.append(name); continue
    if name not in env or not env[name][1]:
        missing.append(name); continue
    copied.append(name); values.append(env[name][1])
# A key added with `hermes auth add <provider>` sits in auth.json's credential
# pool, not .env: an API-KEY pool entry (never an OAuth one) is written to the
# provider's first key variable instead, so auth.json itself stays home.
pooled = ""
if not oauth and wanted and not any(n in copied for n in wanted) and (home / "auth.json").is_file():
    try:
        pool = (json.loads((home / "auth.json").read_text()).get("credential_pool") or {}).get(provider) or []
    except ValueError:
        pool = []
    keys = [e for e in pool if isinstance(e, dict) and e.get("auth_type") == "api_key" and e.get("access_token")]
    keys.sort(key=lambda e: e.get("priority", 0) if isinstance(e.get("priority"), int) else 0)
    name = next((n for n in wanted if not FORBIDDEN.match(n)), None)
    if keys and name:
        env[name] = (f"{name}={keys[0]['access_token']}", keys[0]["access_token"])
        missing = [n for n in missing if n != name]
        copied.append(name); values.append(keys[0]["access_token"]); pooled = name
if not oauth and not any(n in copied for n in wanted) and entry is not None:
    die(f"none of {provider!r}'s key variables ({', '.join(wanted) or 'none'}) is set in {home}/.env"
        + (f" (never copied: {', '.join(refused)})" if refused else ""))
(dst / ".env").write_text("".join(env[n][0] + "\n" for n in copied))

auth_note = "not copied"
if oauth:
    store = json.loads((home / "auth.json").read_text())
    one = {"version": store.get("version"), "active_provider": provider, "providers": {}, "credential_pool": {}}
    for sect in ("providers", "credential_pool"):
        if isinstance(store.get(sect), dict) and provider in store[sect]:
            one[sect][provider] = store[sect][provider]
    if not one["providers"] and not one["credential_pool"]:
        die(f"auth.json holds no entry for {provider!r}")
    (dst / "auth.json").write_text(json.dumps(one, indent=2))
    def leaves(o):
        if isinstance(o, dict):
            for v in o.values(): yield from leaves(v)
        elif isinstance(o, list):
            for v in o: yield from leaves(v)
        elif isinstance(o, str):
            yield o
    # Every string in the copied entry is searched for after the run; very
    # short ones (ids like "oauth") would match everything.
    values += [s for s in leaves(one) if len(s) >= 6]
    auth_note = f"{provider!r} entry only (OAuth: the guest could rotate this Mac's refresh token)"
for f in dst.iterdir():
    f.chmod(0o600)
# Every copied value is searched for in the guest after the run: each .env value
# whatever its length (empty ones are never copied), and the auth.json strings
# kept above (6 characters or more).
values_out.write_text("".join(v + "\n" for v in sorted(set(v for v in values if v))))
values_out.chmod(0o600)
print(f"provider: {provider} ({entry['auth'] if entry else 'not in the registry'})")
print("config.yaml: model." + ", model.".join(new_model) + " | gateway.multiplex_profiles: false")
print(".env copied:", " ".join(copied) or "nothing",
      f"({pooled} from auth.json's {provider} API-key pool entry)" if pooled else "")
if missing: print(".env not set:", " ".join(missing))
if refused: print(".env never copied:", " ".join(refused))
print("auth.json:", auth_note)
PY
"$PY" -B "$SCRATCH/sanitize.py" "$SCRATCH/hermes" "$SOURCE_HOME" "$STAGE/source-home" "$SCRATCH/secret-values" \
  "$ALLOW_OAUTH" "${SCARF_VM_EXTRA_ENV:-}" | tee "$RESULT/sanitize.txt" >&2 || die "could not build the guest's credentials from $SOURCE_HOME"
[[ $ALLOW_OAUTH -eq 0 ]] || warn "--allow-oauth-provider: the guest holds an OAuth credential; a refresh there can rotate the token and sign this Mac out"
rm -rf "$SCRATCH/hermes"
if [[ $CREDS_ONLY -eq 1 ]]; then
  log "--credentials-only: nothing copied anywhere; the host copy is deleted on exit"
  exit 0
fi

# The guest-side helper. One file, subcommands; run with bash in the guest.
cat >"$STAGE/guest.sh" <<'GUEST'
#!/bin/bash
# guest.sh <run-dir> <setup|fixture|plan|cleanup> … — ui-gate-vm.sh's guest half.
set -euo pipefail
W="$1"; CMD="$2"; shift 2
STAMP="${W##*/scarf-}"
export DEVELOPER_DIR="/Volumes/My Shared Files/xcode/Contents/Developer"
# No Homebrew, no CLT in the guest: git comes from the shared Xcode.
export PATH="$W/venv/bin:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Everything uv, pip, xcodebuild and Hermes cache, install or put in TMPDIR
# stays under the run dir, so it is removed with it and kept off the boot
# volume when ~/work lives on another disk (see the README). What can't move:
# the test runner's container (its per-test copies of the fixture home).
export UV_CACHE_DIR="$W/uv/cache" UV_PYTHON_INSTALL_DIR="$W/uv/python" UV_PYTHON_BIN_DIR="$W/uv/bin" \
       UV_TOOL_DIR="$W/uv/tools" UV_NO_CONFIG=1 UV_PYTHON_PREFERENCE=only-managed \
       PIP_CACHE_DIR="$W/pip-cache" XDG_CACHE_HOME="$W/xdg/cache" XDG_DATA_HOME="$W/xdg/data" \
       XDG_STATE_HOME="$W/xdg/state" TMPDIR="$W/tmp"
mkdir -p "$TMPDIR"
UV="$W/bin/uv"; HB="$W/venv/bin/hermes"; FIXTURE="$W/fixture/fixture-home"
SHIM="$HOME/.local/bin/hermes"; SHIM_MARK="scarf-ui-gate-vm $STAMP"
case "$CMD" in
setup)
  py="$1"; expect="$2"
  if [ -e "$SHIM" ] && ! grep -q "scarf-ui-gate-vm" "$SHIM" 2>/dev/null; then
    echo "a hermes that is not ours is at $SHIM: refusing to replace it" >&2; exit 1
  fi
  git -C "$W/hermes" reset -q --hard
  git -C "$W/hermes" describe --tags --exact-match HEAD
  "$UV" python install "$py"
  # The tag's own uv.lock (frozen), editable, with the acp extra: a plain
  # `pip install -e '.[acp]'` re-resolves and can hit pins the lock settles.
  UV_PROJECT_ENVIRONMENT="$W/venv" "$UV" sync -q --project "$W/hermes" --frozen --extra acp --python "$py"
  got="$("$HB" --version 2>&1 | head -1)"
  echo "hermes --version: $got"
  case "$got" in
    "Hermes Agent v$expect "*|"Hermes Agent v$expect") ;;
    *) echo "expected 'Hermes Agent v$expect …'" >&2; exit 1 ;;
  esac
  # Scarf looks for hermes at ~/.local/bin/hermes first (HermesPathSet).
  mkdir -p "$HOME/.local/bin"
  cat >"$SHIM" <<EOF
#!/bin/sh
# $SHIM_MARK — removed when the run ends
DEVELOPER_DIR="$DEVELOPER_DIR"; export DEVELOPER_DIR
PATH="$W/venv/bin:\$DEVELOPER_DIR/usr/bin:\$PATH"; export PATH
XDG_CACHE_HOME="$W/xdg/cache"; XDG_DATA_HOME="$W/xdg/data"; XDG_STATE_HOME="$W/xdg/state"
PIP_CACHE_DIR="$W/pip-cache"; TMPDIR="$W/tmp"; export XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME PIP_CACHE_DIR TMPDIR
exec "$HB" "\$@"
EOF
  chmod 755 "$SHIM"
  ;;
fixture)
  mkdir -p "$W/fixture"
  HERMES_BIN="$HB" HERMES_REAL_HOME="$W/source-home" bash "$W/make-ui-fixture.sh" "$FIXTURE"
  ;;
plan)
  plan="$1"; xctestrun="$2"; bundle="$3"; per_test="$4"; per_test_max="$5"; shift 5
  cd "$W"
  TEST_RUNNER_SCARF_UITEST_FIXTURE="$FIXTURE" \
  xcodebuild test-without-building \
    -xctestrun "$W/Products/$xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$bundle" \
    -derivedDataPath "$W/derived" \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "$per_test" \
    -maximum-test-execution-time-allowance "$per_test_max" "$@"
  ;;
cleanup)
  if [ -x "$HB" ] && [ -d "$FIXTURE" ]; then
    argv=(gateway stop)
    case "$("$HB" gateway stop --help 2>&1 || true)" in *"--yes"*) argv+=(--yes) ;; esac
    HERMES_HOME="$FIXTURE" "$HB" "${argv[@]}" 2>&1 | tail -1 || true
  fi
  # Everything this run started: hermes (gateways included) runs from $W/venv,
  # the app and the runner from $W/Products.
  # ~/work may be a symlink to another disk: match the resolved path too.
  RW="$(cd "$W" 2>/dev/null && pwd -P || echo "$W")"
  for sig in TERM KILL; do
    for d in "$W" "$RW"; do
      pkill -"$sig" -f "$d/venv/" 2>/dev/null || true
      pkill -"$sig" -f "$d/Products/" 2>/dev/null || true
    done
    [ "$sig" = KILL ] || sleep 2
  done
  if [ -f "$SHIM" ] && grep -q "$SHIM_MARK" "$SHIM"; then rm -f "$SHIM"; fi
  rmdir "$HOME/.local/bin" "$HOME/.local" 2>/dev/null || true
  # The tests' throwaway homes (copies of the fixture, credentials included).
  for d in "$(getconf DARWIN_USER_TEMP_DIR)" "$HOME"/Library/Containers/*/Data/tmp; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -name 'scarf-uitest-home-*' -exec rm -rf {} + 2>/dev/null || true
  done
  # A ~/.hermes this run's app or CLI created (the guest had none before).
  # A ~/.hermes this or an earlier run created (ui-gate-vm.sh marks it inside).
  [ -f "$HOME/.hermes/.scarf-ui-gate-vm-created" ] && rm -rf "$HOME/.hermes"
  rm -rf "$W" "$HOME/results/scarf-$STAMP"-*
  echo "cleaned scarf-$STAMP"
  ;;
*) echo "unknown command $CMD" >&2; exit 2 ;;
esac
GUEST
chmod 755 "$STAGE/guest.sh"

# ---------- 3. lock the clone ----------
make_askpass "$SCRATCH"
take_clone_lock
# A just-booted clone accepts the connection but can take minutes to answer
# (first-login work pins its CPUs), so the wait is generous.
SSH_WAIT="${SCARF_VM_SSH_WAIT:-600}"
wait_ssh "$REUSE" "$SSH_WAIT" || die "$REUSE did not answer over SSH within ${SSH_WAIT}s"
GUEST_HOME="$(gssh 'echo $HOME')"
[[ "$GUEST_HOME" == /* ]] || die "could not read the guest's home"

# Leftovers of an earlier Scarf run that was killed before its cleanup (they
# can hold copied credentials). Only Scarf's own folders: ~/work/* belongs to
# every project that uses the clone. Xcode's system-log archives go too, as
# ScarfRack's run does.
gbash "for d in ~/work/scarf-*; do [ -d \"\$d\" ] || continue; pkill -f \"\$d/\" ; r=\$(cd \"\$d\" && pwd -P) && pkill -f \"\$r/\" ; rm -rf \"\$d\"; done; rm -rf ~/results/scarf-* /var/tmp/test-session-systemlogs-*; grep -q scarf-ui-gate-vm ~/.local/bin/hermes 2>/dev/null && rm -f ~/.local/bin/hermes; $SWEEP" >/dev/null 2>&1 || true
# The UI tests pin Scarf's window at {{40, 140}, {1800, 1300}} and fail any
# test whose window comes up under 1500 × 1200 pt (ScarfUITestCase
# .minimumWindowSize / requireTestWindowSize). AppKit keeps a window inside the
# screen's VISIBLE frame (the screen less the menu bar and the Dock), so a guest
# whose visible frame is under that fails every test on the environment: check
# before anything is copied in. (A 1920x1200 display leaves 1920 × 1080.)
MIN_VIS_W=1500; MIN_VIS_H=1200
SCREEN="$(gssh "osascript -l JavaScript -e 'ObjC.import(\"AppKit\"); var s = \$.NSScreen.mainScreen; [s.frame.size.width, s.frame.size.height, s.visibleFrame.size.width, s.visibleFrame.size.height].join(\" \")'" 2>/dev/null || true)"
if [[ "$SCREEN" =~ ^[0-9.]+\ [0-9.]+\ [0-9.]+\ [0-9.]+$ ]]; then
  read -r SCREEN_W SCREEN_H VIS_W VIS_H <<<"$SCREEN"
  SCREEN_W=${SCREEN_W%.*}; SCREEN_H=${SCREEN_H%.*}; VIS_W=${VIS_W%.*}; VIS_H=${VIS_H%.*}
  echo "guest screen: ${SCREEN_W} x ${SCREEN_H} pt, visible ${VIS_W} x ${VIS_H} pt" | tee "$RESULT/guest-display.txt" >&2
  if [[ $VIS_W -lt $MIN_VIS_W || $VIS_H -lt $MIN_VIS_H ]]; then
    if [[ $DISPLAY_CHECK -eq 1 ]]; then
      die "$REUSE's usable screen is ${VIS_W} x ${VIS_H} pt (of ${SCREEN_W} x ${SCREEN_H}); Scarf's UI tests need a window of at least ${MIN_VIS_W} x ${MIN_VIS_H} pt, so every test would fail its window-size check. Give the clone a taller display while it is stopped (e.g. tart set $REUSE --display 1920x1440), or pass --skip-display-check"
    fi
    warn "$REUSE's usable screen is ${VIS_W} x ${VIS_H} pt, under the ${MIN_VIS_W} x ${MIN_VIS_H} the UI tests need: expect window-size failures"
  fi
else
  warn "could not read $REUSE's screen size; running anyway"
fi
# Free space where the run's files go (~/work may be a symlink to another
# disk), and on the boot volume, which holds what the run can't move: the test
# runner's container (its copies of the fixture home) and Xcode's logs.
gb_free() { gssh "mkdir -p $1 && df -g \"\$(cd $1 && pwd -P)\" | awk 'NR == 2 { print \$4 }'" 2>/dev/null || true; }
FREE_GB="$(gb_free '~/work')"
BOOT_GB="$(gb_free '/')"
case "$FREE_GB$BOOT_GB" in ''|*[!0-9]*) die "could not read the free space in $REUSE" ;; esac
echo "free: ${FREE_GB} GB where ~/work lives, ${BOOT_GB} GB on the boot volume" | tee "$RESULT/guest-disk.txt" >&2
[[ $FREE_GB -ge 5 ]] || die "$REUSE has $FREE_GB GB free where ~/work lives, under the 5 GB a run needs"
# Under its low-disk threshold (10 GiB free on scarf-ui's 44 GB boot container:
# deleted logs "lowDiskThreshold: 10737418240"), macOS purges caches every time
# APFS reports low disk, and that purge TERMINATES the sandboxed test runner to
# empty its container caches (runningboardd: "CacheDeleteAppContainerCaches
# requesting termination assertion for com.scarfUITests.xctrunner"): the test in
# flight reports "Test crashed with signal kill" and the next one starts in a new
# runner. Such tests are rerun once, alone (step 6). df -g counts GiB and
# rounds down, so 11 means at least 1 GiB above the threshold.
[[ $BOOT_GB -ge 11 ]] || warn "$REUSE's boot volume has $BOOT_GB GB free: near or under its 10 GB low-disk threshold, macOS's purge kills the test runner mid-test (\"Test crashed with signal kill\"; such tests get one rerun) — free space in the guest (see scripts/ui-fixture/README.md)"

# ---------- 4. copy in ----------
log "copying the products, uv, Hermes and the sanitized home into $REUSE:~/$GW"
GUEST_UP=1
# Anything the run's app or CLI writes to the real ~/.hermes must go with the
# run, even after a crash: when the guest has none, the run creates it with a
# marker inside, and every sweep removes a marked ~/.hermes. A ~/.hermes
# without the marker is never touched.
gbash "[ -e ~/.hermes ] || { mkdir -m 700 ~/.hermes && echo 'scarf-ui-gate-vm $STAMP' >~/.hermes/$HERMES_MARK; }" >/dev/null 2>&1 \
  || die "could not prepare ~/.hermes in $REUSE"
tar -C "$DERIVED/Build" -cf - Products -C "$STAGE" . | \
  gssh_in "mkdir -p ~/results ~/$GW && chmod 700 ~/$GW && tar -C ~/$GW -xf -" \
  || die "could not copy into $REUSE"
rm -rf "$STAGE/source-home"

# ---------- 5. Hermes and the fixture in the guest ----------
log "installing Hermes $HERMES_TAG in the guest (log: $RESULT/guest-setup.log)"
gssh "bash ~/$GW/guest.sh '$GUEST_HOME/$GW' setup '$GUEST_PY' '$EXPECT_VERSION'" >"$RESULT/guest-setup.log" 2>&1 \
  || { tail -20 "$RESULT/guest-setup.log" >&2; die "Hermes install in the guest failed"; }
grep '^hermes --version' "$RESULT/guest-setup.log" >&2 || true

log "seeding the fixture home in the guest (log: $RESULT/fixture.log)"
gssh "bash ~/$GW/guest.sh '$GUEST_HOME/$GW' fixture" >"$RESULT/fixture.log" 2>&1 \
  || { tail -20 "$RESULT/fixture.log" >&2; die "fixture build in the guest failed"; }

# macOS's own banners (Software Update, "See what's new") cover the top-right of
# the window until dismissed: the delivered notifications are deleted from their
# store, retried while it is still locked after a boot (as ScarfRack's run does).
NOTES='~/Library/Group\ Containers/group.com.apple.usernoted/db2/db'
clear_banners() {
  local left="" _
  for _ in $(seq 1 30); do
    left="$(gssh "sqlite3 $NOTES 'delete from record;' && killall usernoted NotificationCenter 2>/dev/null; sleep 3; sqlite3 $NOTES 'select count(*) from record;'" 2>&1 | tail -1 || true)"
    [[ "$left" != 0 ]] || return 0
    sleep 2
  done
  die "macOS notifications in $REUSE could not be cleared ($left): a banner would cover the window"
}

# ---------- 6. the plans, one at a time ----------
# Per-test bound: 5 minutes by default, 10 at most (a Live chat turn against a
# real model is the slowest). Per-plan bound below; past half of it the log says so.
PER_TEST=300; PER_TEST_MAX=600
ONLY_ARGS=""; [[ $UI_ONLY -eq 0 ]] || ONLY_ARGS="-only-testing:scarfUITests"
if [[ ${#ONLY[@]} -gt 0 ]]; then
  ONLY_ARGS=""
  for o in "${ONLY[@]}"; do ONLY_ARGS="$ONLY_ARGS -only-testing:scarfUITests/$o"; done
fi
plan_limit_min() { case "$1" in Smoke) echo 20 ;; Full) echo 90 ;; Live) echo 45 ;; esac; }
GIT_HASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# One xcodebuild run in the guest, bounded. Sets STATUS, WALL and TIMED_OUT.
# $1 plan, $2 .xctestrun, $3 guest bundle path, $4 host log, $5 bound (s), $6… -only-testing args
run_in_guest() {
  local plan="$1" xctestrun="$2" bundle="$3" logf="$4" limit="$5" t0; shift 5
  t0=$SECONDS; STATUS=0; TIMED_OUT=0
  # Globals, so an interrupted run's cleanup can stop both (and their children).
  gssh "bash ~/$GW/guest.sh '$GUEST_HOME/$GW' plan '$plan' '$xctestrun' '$bundle' $PER_TEST $PER_TEST_MAX $*" >"$logf" 2>&1 9>&- &
  TESTS_PID=$!
  ( exec 9>&-; sleep "$limit" && kill "$TESTS_PID" ) >/dev/null 2>&1 & WATCH_PID=$!
  wait "$TESTS_PID" || STATUS=$?
  WALL=$((SECONDS - t0))
  if kill -0 "$WATCH_PID" 2>/dev/null; then pkill -P "$WATCH_PID" 2>/dev/null || true; kill "$WATCH_PID" 2>/dev/null || true
  else
    warn "$plan passed its $((limit / 60))-minute bound and was stopped"
    # The guest's processes show the resolved path (~/work may be a symlink).
    gbash "d=~/$GW; pkill -f \"\$d/Products/\"; r=\$(cd \$d 2>/dev/null && pwd -P) && pkill -f \"\$r/Products/\"; true" >/dev/null 2>&1 || true
    STATUS=1; TIMED_OUT=1
  fi
  TESTS_PID=""; WATCH_PID=""
}
# Reads a result bundle's summary. Sets COUNTS, FAILED_NAMES (markdown lines),
# KILLED (tests whose every failure is "crashed with signal kill", as
# Class/test) and OTHER_FAILED (how many tests failed any other way).
# $1 host .xcresult, $2 summary.json to write
read_results() {
  COUNTS="no result bundle"; FAILED_NAMES=""; KILLED=(); OTHER_FAILED=0; NUMS=(0 0 0 0)
  [[ -d "$1" ]] || return 0
  xcrun xcresulttool get test-results summary --path "$1" >"$2" 2>/dev/null || true
  local parsed
  parsed="$(/usr/bin/python3 -I -c '
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    print("C\tsummary unreadable"); sys.exit()
print("C\t%s executed / %s passed / %s failed / %s skipped" % (s.get("totalTestCount", "?"), s.get("passedTests", "?"),
      s.get("failedTests", "?"), s.get("skippedTests", "?")))
n = lambda k: s.get(k) if isinstance(s.get(k), int) else -1
print("N\t%d %d %d %d" % (n("totalTestCount"), n("passedTests"), n("failedTests"), n("skippedTests")))
kinds = {}
for f in s.get("testFailures", []):
    n = f.get("testIdentifierString") or f.get("testName", "?")
    text = (f.get("failureText") or "").splitlines()
    text = text[0][:200] if text else ""
    if n not in kinds:
        kinds[n] = []
        print("F\t  - %s: %s" % (n, text))
    kinds[n].append("crashed with signal kill" in text)
for n, k in kinds.items():
    # Only a test that failed by the kill alone is retried; a parenthesized
    # identifier is the Class/test() XCTest reports.
    if all(k) and "/" in n:
        print("K\t%s" % n.replace("()", ""))
    else:
        print("O\t%s" % n)
' "$2")"
  COUNTS="$(printf '%s\n' "$parsed" | sed -n 's/^C	//p')"
  # shellcheck disable=SC2207
  NUMS=($(printf '%s\n' "$parsed" | sed -n 's/^N	//p')); [[ ${#NUMS[@]} -eq 4 ]] || NUMS=(-1 -1 -1 -1)
  FAILED_NAMES="$(printf '%s\n' "$parsed" | sed -n 's/^F	//p')"
  while IFS= read -r k; do [[ -z "$k" ]] || KILLED+=("$k"); done < <(printf '%s\n' "$parsed" | sed -n 's/^K	//p')
  OTHER_FAILED="$(printf '%s\n' "$parsed" | grep -c '^O	' || true)"
}
gb_boot() { gssh "df -k / | awk 'NR == 2 { printf \"%.1f\", \$4 / 1048576 }'" 2>/dev/null || echo "?"; }
# macOS's low-disk purge in the guest since $1 (guest clock): how often it
# fired, and how many times it terminated the test runner. Raw lines → $2.
purge_report() {
  gbash "log show --start '$1' --style compact --predicate '(process == \"deleted\" AND eventMessage CONTAINS \"processLowDiskVolume\") OR (process == \"runningboardd\" AND eventMessage CONTAINS \"scarfUITests.xctrunner\" AND (eventMessage CONTAINS \"CacheDelete\" OR eventMessage CONTAINS \"Terminating with context\"))' 2>/dev/null | grep '^20'; true" >"$2" 2>/dev/null || true
  PURGES="$(grep -c 'CD_LOWDISK_EVENT' "$2" || true)"
  RUNNER_KILLS="$(grep -c 'Terminating with context' "$2" || true)"
}

declare -a ROWS=() FAILURES=() NOTES_OUT=()
OVERALL=0; SAW_RUNNER=0; SAW_FAIL=0
for plan in "${PLANS[@]}"; do
  clear_banners
  XCTESTRUN="$(cd "$DERIVED/Build/Products" && ls "${SCHEME}_${plan}_"*.xctestrun | head -1)"
  BUNDLE_GUEST="$GUEST_HOME/$GUEST_RESULTS-$plan.xcresult"
  PLAN_LOG="$RESULT/$plan.log"
  LIMIT=$(( $(plan_limit_min "$plan") * 60 ))
  BOOT_BEFORE="$(gb_boot)"; GUEST_T0="$(guest_now 2>/dev/null || true)"
  log "running $plan in $REUSE (bound $((LIMIT / 60)) min; log: $PLAN_LOG)"
  # shellcheck disable=SC2086
  run_in_guest "$plan" "$XCTESTRUN" "$BUNDLE_GUEST" "$PLAN_LOG" "$LIMIT" $ONLY_ARGS
  PLAN_WALL=$WALL; PLAN_TIMED_OUT=$TIMED_OUT
  [[ $WALL -le $((LIMIT / 2)) ]] || warn "$plan took $((WALL / 60)) minutes, past half its bound"
  gscp_out "$BUNDLE_GUEST" "$RESULT/$plan.xcresult" || warn "no result bundle came back for $plan"

  VERDICT="$("$REPO_ROOT/scripts/ui-gate.sh" --classify "$PLAN_LOG" "$STATUS" 2>/dev/null || true)"
  [[ -n "$VERDICT" ]] || VERDICT=FAIL
  read_results "$RESULT/$plan.xcresult" "$RESULT/$plan.summary.json"
  RESULT_CELL="$VERDICT"

  # A test "crashed with signal kill" is, in this VM, almost always macOS's
  # low-disk purge terminating the runner (runningboardd:
  # "CacheDeleteAppContainerCaches requesting termination assertion for
  # com.scarfUITests.xctrunner"), not the test. Each such test runs ONCE more,
  # alone, and its verdict is the rerun's. Any other failure is never rerun.
  RERUN_LINES=""; RECOVERED=0
  if [[ ${#KILLED[@]} -gt 0 ]]; then
    i=0
    for t in "${KILLED[@]}"; do
      i=$((i + 1))
      clear_banners
      RB_GUEST="$GUEST_HOME/$GUEST_RESULTS-$plan-rerun$i.xcresult"; RB="$RESULT/$plan-rerun$i.xcresult"
      log "rerunning $t alone ($plan; it crashed with signal kill; log: $RESULT/$plan-rerun$i.log)"
      run_in_guest "$plan" "$XCTESTRUN" "$RB_GUEST" "$RESULT/$plan-rerun$i.log" $((PER_TEST_MAX + 300)) "-only-testing:scarfUITests/$t"
      gscp_out "$RB_GUEST" "$RB" >/dev/null 2>&1 || true
      SAVED=("$COUNTS" "$FAILED_NAMES" "$OTHER_FAILED"); SAVED_KILLED=("${KILLED[@]}"); SAVED_NUMS=("${NUMS[@]}")
      read_results "$RB" "$RESULT/$plan-rerun$i.summary.json"
      # A pass counts only when the test really ran (an identifier XCTest can't
      # match runs nothing and still exits 0).
      if [[ $STATUS -eq 0 && ${NUMS[0]} -ge 1 && ${NUMS[1]} -ge 1 && ${NUMS[2]} -eq 0 ]]; then
        RECOVERED=$((RECOVERED + 1)); outcome="PASS"
      else
        outcome="FAIL — $(printf '%s\n' "$FAILED_NAMES" | head -1 | sed 's/^[^:]*: //')"
        [[ -n "$FAILED_NAMES" ]] || outcome="FAIL (exit $STATUS, $COUNTS)"
      fi
      RERUN_LINES="$RERUN_LINES
  - $t(): run 1 crashed with signal kill; run 2, alone: $outcome (${WALL}s, $plan-rerun$i.log)"
      COUNTS="${SAVED[0]}"; FAILED_NAMES="${SAVED[1]}"; OTHER_FAILED="${SAVED[2]}"; KILLED=("${SAVED_KILLED[@]}"); NUMS=("${SAVED_NUMS[@]}")
    done
    # The plan passes on its reruns only when the kills were its ONLY failures,
    # every one passed alone, and the first run itself went the distance: it
    # executed tests, its counts add up, its failures are exactly the kills, and
    # XCTest printed its closing totals (a runner that died before running the
    # plan never gets there), within the bound.
    FIRST_RUN_WHOLE=0
    if [[ ${NUMS[0]} -ge 1 && $(( NUMS[1] + NUMS[2] + NUMS[3] )) -eq ${NUMS[0]} && ${NUMS[2]} -eq ${#KILLED[@]} ]] \
       && grep -qE "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?" "$PLAN_LOG"; then
      FIRST_RUN_WHOLE=1
    fi
    if [[ "$VERDICT" == FAIL && $OTHER_FAILED -eq 0 && $RECOVERED -eq ${#KILLED[@]} && $PLAN_TIMED_OUT -eq 0 && $FIRST_RUN_WHOLE -eq 1 ]]; then
      VERDICT=PASS; RESULT_CELL="PASS (on rerun: ${#KILLED[@]} killed)"
    fi
  fi
  if [[ "$VERDICT" != PASS ]]; then
    OVERALL=1
    if [[ "$VERDICT" == RUNNER-FAILED ]]; then SAW_RUNNER=1; else SAW_FAIL=1; fi
  fi
  purge_report "$GUEST_T0" "$RESULT/$plan.guest-purge.log"
  NOTES_OUT+=("- $plan: boot volume ${BOOT_BEFORE} GB free before, $(gb_boot) GB after; macOS low-disk purges: ${PURGES:-?}, runner terminations by the purge: ${RUNNER_KILLS:-?} ($plan.guest-purge.log)")
  ROWS+=("| $plan | $RESULT_CELL | $COUNTS | ${PLAN_WALL}s |")
  [[ -z "$FAILED_NAMES" ]] || FAILURES+=("$(printf '**%s failures (first run)**\n\n%s\n' "$plan" "$FAILED_NAMES")")
  [[ -z "$RERUN_LINES" ]] || FAILURES+=("$(printf '**%s reruns** (\"crashed with signal kill\" only — the guest'"'"'s low-disk purge terminating the runner; each test once, alone; the rerun decides)\n%s\n' "$plan" "$RERUN_LINES")")
  log "$plan: $RESULT_CELL — $COUNTS (${PLAN_WALL}s)"
done

{
  echo "# UI Gate (Tart VM) Summary"
  echo
  echo "- Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  echo "- Git commit: $GIT_HASH"
  echo "- VM: $REUSE"
  echo "- Scope: $([[ $UI_ONLY -eq 1 ]] && echo "UI tests only (-only-testing:scarfUITests)" || echo "whole plans, unit tests included")"
  echo "- Hermes: $HERMES_TAG ($(grep '^hermes --version' "$RESULT/guest-setup.log" | sed 's/^hermes --version: //'), Python $GUEST_PY)"
  echo
  echo "| Plan | Result | Tests (first run) | Wall time |"
  echo "| --- | --- | --- | --- |"
  for row in "${ROWS[@]}"; do printf '%s\n' "$row"; done
  echo
  for f in ${FAILURES[@]+"${FAILURES[@]}"}; do printf '%s\n\n' "$f"; done
  echo "Guest disk:"
  echo
  for n in ${NOTES_OUT[@]+"${NOTES_OUT[@]}"}; do printf '%s\n' "$n"; done
  echo
  if [[ $OVERALL -eq 0 ]]; then echo "Overall: PASS"
  elif [[ $SAW_RUNNER -eq 1 && $SAW_FAIL -eq 0 ]]; then echo "Overall: RUNNER-FAILED"
  else echo "Overall: FAIL"; fi
} >"$RESULT/summary.md"
cat "$RESULT/summary.md"
exit "$OVERALL"
