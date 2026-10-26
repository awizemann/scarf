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
#                         [--only Class[/test]]…
#
#   --hermes-tag TAG   Hermes tag to install in the guest (v0.22.5, v2026.9.24, …).
#                      Must exist in the Hermes checkout ($SCARF_VM_HERMES_SRC,
#                      default ~/.hermes/hermes-agent).
#   --plans LIST       Comma-separated test plans, run one at a time in this order
#                      (default Smoke,Full,Live).
#   --reuse NAME       The running Tart clone to use (default scarf-ui: Scarf's own
#                      clone of ScarfRack's UI-test image, with a display tall
#                      enough for the window the tests pin). This script never
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
#
# Credentials: a SANITIZED copy of the source home's config.yaml / .env /
# auth.json is built in a private host scratch dir: every messaging-platform /
# gateway variable (names derived from the tag's own Hermes source) is dropped
# from .env, and so is every other credential-looking variable the tag's model
# provider registry (hermes_cli/auth.py) doesn't name; top-level platform sections and `platforms` blocks are
# removed from config.yaml, and gateway.multiplex_profiles is set false. Only
# model-provider credentials enter the guest, and they are deleted on every
# exit, pass or fail, then searched for in the guest to prove it. Only NAMES are
# ever printed.
#
# Sharing the clone: the same lock as ScarfRack's tools/ui-test/run.sh
# ($RIG_HOME/locks/<clone>.lock, made with mkdir; a dead holder's lock is taken
# over; give up after 20 minutes). Only this run's own guest folders are removed.
#
# Results: build/ui-gate-vm/results/<stamp>/ — summary.md, one .xcresult and
# one .log per plan, plus the setup and fixture logs. Exits non-zero when any
# plan is not PASS. Verdicts are scripts/ui-gate.sh's (--classify): PASS, FAIL,
# RUNNER-FAILED.
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
    --only)
      case "${2:-}" in *[!A-Za-z0-9_/]*|"") die "--only takes Class or Class/test" ;; esac
      ONLY+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ -n "$HERMES_TAG" ]] || die "--hermes-tag is required (see --help)"
case "$REUSE" in *[!A-Za-z0-9_-]*|"") die "--reuse takes a clone's name" ;; esac
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
for f in config.yaml .env auth.json; do
  [[ -f "$SOURCE_HOME/$f" ]] || die "$SOURCE_HOME/$f is missing (set SCARF_VM_SOURCE_HOME)"
done
need_tart

# A Python with PyYAML, used only on the host to sanitize config.yaml.
PY=""
for cand in "${SCARF_VM_PYTHON:-}" python3 "$HERMES_SRC/venv/bin/python"; do
  [[ -n "$cand" ]] || continue
  if "$cand" -B -c 'import yaml' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[[ -n "$PY" ]] || die "no python3 with PyYAML found (set SCARF_VM_PYTHON)"

# The clone must already be up; this script never boots one.
tart list | awk -v n="$REUSE" '$2 == n && $NF == "running" { ok = 1 } END { exit !ok }' \
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
LOCK=""; GUEST_UP=0; GUEST_HOME=""; GUEST_HAD_HERMES=1; STARTED_AT="$(date +%s)"
gssh_in() {   # gssh with this process's stdin (lib.sh's gssh reads /dev/null)
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=none \
    ssh "${SSH_OPTS[@]}" "$GUEST_USER@$VM_IP" "$@"
}
# A guest command run by bash, not the login shell: the guest's zsh aborts a
# whole command line on a glob that matches nothing.
gbash() { gssh_in "bash -s" <<<"$1"; }
cleanup() {
  local status=$?
  trap '' INT TERM
  if [[ $GUEST_UP -eq 1 ]]; then
    log "cleaning $REUSE"
    # The guest helper stops the fixture's gateway and every process of this run,
    # removes the hermes shim, the run dir, the result bundles and test homes.
    gssh "bash ~/$GW/guest.sh '$GUEST_HOME/$GW' cleanup $GUEST_HAD_HERMES" >>"$RESULT/cleanup.log" 2>&1 \
      || gbash "d=~/$GW; pkill -f \"\$d/\" ; rm -rf ~/$GW ~/$GUEST_RESULTS-* ; grep -q 'scarf-ui-gate-vm $STAMP' ~/.local/bin/hermes 2>/dev/null && rm -f ~/.local/bin/hermes; true" >>"$RESULT/cleanup.log" 2>&1 || true
    verify_guest_clean || status=1
  fi
  [[ -z "$LOCK" ]] || rm -rf "$LOCK"
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
  left="$(gbash "ls -d ~/$GW ~/$GUEST_RESULTS-* 2>/dev/null; grep -l 'scarf-ui-gate-vm' ~/.local/bin/hermes 2>/dev/null; true")"
  mins=$(( ( $(date +%s) - STARTED_AT ) / 60 + 5 ))
  found=""
  if [[ -s "$SCRATCH/secret-values" ]]; then
    found="$(gssh_in "grep -rlsF -f /dev/stdin ~/work ~/results ~/.hermes ~/.local \"\$(getconf DARWIN_USER_TEMP_DIR)\" ~/Library/Containers 2>/dev/null | head -20; true" <"$SCRATCH/secret-values" || echo "(could not search)")"
  fi
  local envs
  envs="$(gssh "find ~ \"\$(getconf DARWIN_USER_TEMP_DIR)\" -mmin -$mins \( -name .env -o -name auth.json \) -not -path '*/Library/Caches/*' 2>/dev/null | head -20; true")"
  {
    echo "leftover paths: ${left:-none}"
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
for plan in "${PLANS[@]}"; do
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

log "sanitizing a copy of $SOURCE_HOME's credentials"
cat >"$SCRATCH/sanitize.py" <<'PY'
# sanitize.py <hermes-src> <source-home> <dest> <secret-values-out>
# Prints NAMES only. Never prints a value.
import json, pathlib, re, shutil, sys, yaml
src, home, dst, values_out = map(pathlib.Path, sys.argv[1:5])
dst.mkdir(parents=True, exist_ok=True)
# Every env var name the tag's gateway / platform code reads.
code = [src / "gateway/config_env.py", src / "gateway/platform_env.py"]
for root in (src / "plugins/platforms", src / "gateway/platforms"):
    if root.is_dir():
        code += sorted(p for p in root.rglob("*") if p.suffix in (".py", ".yaml", ".yml"))
names = set()
pat = re.compile(r"""["']([A-Z][A-Z0-9]*_[A-Z0-9_]+)["']""")
for f in code:
    try:
        names |= set(pat.findall(f.read_text(errors="ignore")))
    except OSError:
        pass
plats = set()
for root in (src / "plugins/platforms", src / "gateway/platforms"):
    if root.is_dir():
        plats |= {p.stem for p in root.iterdir() if (p.is_dir() or p.suffix == ".py") and not p.stem.startswith("_")}
plats |= {"slack", "discord", "telegram", "mattermost", "matrix", "whatsapp", "signal", "email", "sms",
          "homeassistant", "home_assistant", "bluebubbles", "imessage", "teams", "feishu", "dingtalk",
          "wecom", "weixin", "qqbot", "line", "irc", "google_chat", "webhook", "webhooks", "api_server"}
prefixes = {p.upper() for p in plats} | {"GATEWAY", "API_SERVER", "WEBHOOK", "MSGRAPH", "HASS", "TWILIO",
                                         "IMAP", "SMTP", "QQ", "WHATSAPP", "HOMEASSISTANT"}
# Model-provider credential names: the ones the tag's provider registry reads.
provider_names = set()
try:
    provider_names = set(pat.findall((src / "hermes_cli/auth.py").read_text(errors="ignore")))
except OSError:
    pass
secretish = re.compile(r"KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|COOKIE|SESSION")
# config.yaml: top-level platform sections and every `platforms` block go.
cfg = yaml.safe_load((home / "config.yaml").read_text()) or {}
removed = [k for k in list(cfg) if k in plats or k == "platforms"]
for k in removed:
    del cfg[k]
gw = cfg.get("gateway")
if not isinstance(gw, dict):
    gw = cfg["gateway"] = {}
if "platforms" in gw:
    del gw["platforms"]; removed.append("gateway.platforms")
gw["multiplex_profiles"] = False
(dst / "config.yaml").write_text(yaml.safe_dump(cfg, sort_keys=False))
# .env: platform / gateway variables go; of the credential-looking rest, only
# model-provider keys stay (tool keys, passwords and the like never go in).
keep_lines, dropped, kept, values, not_model = [], [], [], [], []
for line in (home / ".env").read_text().splitlines():
    m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)", line)
    if m:
        name = m.group(1)
        if name in names or any(name.startswith(p + "_") for p in prefixes):
            dropped.append(name); continue
        if secretish.search(name) and name not in provider_names:
            not_model.append(name); continue
        kept.append(name)
        v = m.group(2).strip().strip("'\"")
        if len(v) >= 12:
            values.append(v)
    keep_lines.append(line)
(dst / ".env").write_text("\n".join(keep_lines) + "\n")
shutil.copy2(home / "auth.json", dst / "auth.json")
def leaves(o):
    if isinstance(o, dict):
        for v in o.values(): yield from leaves(v)
    elif isinstance(o, list):
        for v in o: yield from leaves(v)
    elif isinstance(o, str):
        yield o
try:
    values += [s for s in leaves(json.loads((home / "auth.json").read_text())) if len(s) >= 24 and " " not in s]
except ValueError:
    pass
for f in ("config.yaml", ".env", "auth.json"):
    (dst / f).chmod(0o600)
values_out.write_text("".join(v + "\n" for v in sorted(set(values))))
values_out.chmod(0o600)
print("config.yaml removed:", ", ".join(removed) or "nothing", "| gateway.multiplex_profiles: false")
print(".env dropped (platform/gateway):", " ".join(dropped) or "nothing")
print(".env dropped (credential, not a model provider):", " ".join(not_model) or "nothing")
print(".env kept:", " ".join(kept) or "nothing")
PY
"$PY" -B "$SCRATCH/sanitize.py" "$SCRATCH/hermes" "$SOURCE_HOME" "$STAGE/source-home" "$SCRATCH/secret-values" \
  | tee "$RESULT/sanitize.txt" >&2 || die "could not sanitize $SOURCE_HOME"
rm -rf "$SCRATCH/hermes"

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
export UV_CACHE_DIR="$W/uv/cache" UV_PYTHON_INSTALL_DIR="$W/uv/python" UV_PYTHON_BIN_DIR="$W/uv/bin" \
       UV_TOOL_DIR="$W/uv/tools" UV_NO_CONFIG=1 UV_PYTHON_PREFERENCE=only-managed
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
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "$per_test" \
    -maximum-test-execution-time-allowance "$per_test_max" "$@"
  ;;
cleanup)
  had_hermes="${1:-1}"
  if [ -x "$HB" ] && [ -d "$FIXTURE" ]; then
    argv=(gateway stop)
    case "$("$HB" gateway stop --help 2>&1 || true)" in *"--yes"*) argv+=(--yes) ;; esac
    HERMES_HOME="$FIXTURE" "$HB" "${argv[@]}" 2>&1 | tail -1 || true
  fi
  # Everything this run started: hermes (gateways included) runs from $W/venv,
  # the app and the runner from $W/Products.
  pkill -f "$W/venv/" 2>/dev/null || true
  pkill -f "$W/Products/" 2>/dev/null || true
  sleep 2
  pkill -9 -f "$W/venv/" 2>/dev/null || true
  pkill -9 -f "$W/Products/" 2>/dev/null || true
  if [ -f "$SHIM" ] && grep -q "$SHIM_MARK" "$SHIM"; then rm -f "$SHIM"; fi
  rmdir "$HOME/.local/bin" "$HOME/.local" 2>/dev/null || true
  # The tests' throwaway homes (copies of the fixture, credentials included).
  for d in "$(getconf DARWIN_USER_TEMP_DIR)" "$HOME"/Library/Containers/*/Data/tmp; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -name 'scarf-uitest-home-*' -exec rm -rf {} + 2>/dev/null || true
  done
  # A ~/.hermes this run's app or CLI created (the guest had none before).
  [ "$had_hermes" = 1 ] || rm -rf "$HOME/.hermes"
  rm -rf "$W" "$HOME/results/scarf-$STAMP"-*
  echo "cleaned scarf-$STAMP"
  ;;
*) echo "unknown command $CMD" >&2; exit 2 ;;
esac
GUEST
chmod 755 "$STAGE/guest.sh"

# ---------- 3. lock the clone (ScarfRack's protocol) ----------
LOCKS="$RIG_HOME/locks"; mkdir -p "$LOCKS"
make_askpass "$SCRATCH"
WAITED=0
until mkdir "$LOCKS/$REUSE.lock" 2>/dev/null; do
  HOLDER="$(cat "$LOCKS/$REUSE.lock/pid" 2>/dev/null || true)"
  if [[ -n "$HOLDER" ]] && ! kill -0 "$HOLDER" 2>/dev/null; then rm -rf "$LOCKS/$REUSE.lock"; continue; fi
  [[ $WAITED -lt 1200 ]] || die "$REUSE has been in use for 20 minutes ($(cat "$LOCKS/$REUSE.lock/who" 2>/dev/null || echo "by another run")): giving up"
  [[ $WAITED -ne 0 ]] || log "$REUSE is in use ($(cat "$LOCKS/$REUSE.lock/who" 2>/dev/null || echo "another run")): waiting for it"
  sleep 10; WAITED=$((WAITED + 10))
done
LOCK="$LOCKS/$REUSE.lock"; echo $$ >"$LOCK/pid"; echo "Scarf ui-gate-vm from $REPO_ROOT since $(date +%H:%M)" >"$LOCK/who"
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
gbash "for d in ~/work/scarf-*; do [ -d \"\$d\" ] || continue; pkill -f \"\$d/\" ; rm -rf \"\$d\"; done; rm -rf ~/results/scarf-* /var/tmp/test-session-systemlogs-*; grep -q scarf-ui-gate-vm ~/.local/bin/hermes 2>/dev/null && rm -f ~/.local/bin/hermes; true" >/dev/null 2>&1 || true
GUEST_HAD_HERMES="$(gssh '[ -e ~/.hermes ] && echo 1 || echo 0')"
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
FREE_GB="$(gssh "df -g / | awk 'NR == 2 { print \$4 }'" 2>/dev/null || true)"
case "$FREE_GB" in ''|*[!0-9]*) die "could not read the free space in $REUSE" ;; esac
[[ $FREE_GB -ge 5 ]] || die "$REUSE has $FREE_GB GB free, under the 5 GB a run needs"
# Under roughly 15 GB free, macOS runs its critical cache purge every few
# minutes, and that purge TERMINATES the sandboxed test runner to empty its
# container caches (runningboardd: "CacheDeleteAppContainerCaches requesting
# termination assertion for com.scarfUITests.xctrunner"): the test in flight
# reports "Test crashed with signal kill" and the next one starts in a new runner.
[[ $FREE_GB -ge 15 ]] || warn "$REUSE has $FREE_GB GB free: under ~15 GB macOS's critical cache purge kills the test runner mid-test (\"Test crashed with signal kill\"); give the clone a larger disk"

# ---------- 4. copy in ----------
log "copying the products, uv, Hermes and the sanitized home into $REUSE:~/$GW"
GUEST_UP=1
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
declare -a ROWS=() FAILURES=()
OVERALL=0; SAW_RUNNER=0; SAW_FAIL=0
for plan in "${PLANS[@]}"; do
  clear_banners
  XCTESTRUN="$(cd "$DERIVED/Build/Products" && ls "${SCHEME}_${plan}_"*.xctestrun | head -1)"
  BUNDLE_GUEST="$GUEST_HOME/$GUEST_RESULTS-$plan.xcresult"
  PLAN_LOG="$RESULT/$plan.log"
  LIMIT=$(( $(plan_limit_min "$plan") * 60 ))
  log "running $plan in $REUSE (bound $((LIMIT / 60)) min; log: $PLAN_LOG)"
  T0=$SECONDS; STATUS=0
  gssh "bash ~/$GW/guest.sh '$GUEST_HOME/$GW' plan '$plan' '$XCTESTRUN' '$BUNDLE_GUEST' $PER_TEST $PER_TEST_MAX $ONLY_ARGS" >"$PLAN_LOG" 2>&1 &
  TESTS=$!
  ( sleep "$LIMIT" && kill "$TESTS" ) >/dev/null 2>&1 & WATCH=$!
  wait "$TESTS" || STATUS=$?
  WALL=$((SECONDS - T0))
  if kill -0 "$WATCH" 2>/dev/null; then pkill -P "$WATCH" 2>/dev/null || true; kill "$WATCH" 2>/dev/null || true
  else
    warn "$plan passed its $((LIMIT / 60))-minute bound and was stopped"
    gssh "pkill -f '$GUEST_HOME/$GW/Products/'" >/dev/null 2>&1 || true
    STATUS=1
  fi
  [[ $WALL -le $((LIMIT / 2)) ]] || warn "$plan took $((WALL / 60)) minutes, past half its bound"
  gscp_out "$BUNDLE_GUEST" "$RESULT/$plan.xcresult" || warn "no result bundle came back for $plan"

  VERDICT="$("$REPO_ROOT/scripts/ui-gate.sh" --classify "$PLAN_LOG" "$STATUS" 2>/dev/null || true)"
  [[ -n "$VERDICT" ]] || VERDICT=FAIL
  COUNTS="no result bundle"; FAILED_NAMES=""
  if [[ -d "$RESULT/$plan.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$RESULT/$plan.xcresult" >"$RESULT/$plan.summary.json" 2>/dev/null || true
    COUNTS="$(/usr/bin/python3 -I -c '
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    print("summary unreadable"); sys.exit()
print("%s executed / %s passed / %s failed / %s skipped" % (s.get("totalTestCount", "?"), s.get("passedTests", "?"),
      s.get("failedTests", "?"), s.get("skippedTests", "?")))
' "$RESULT/$plan.summary.json")"
    FAILED_NAMES="$(/usr/bin/python3 -I -c '
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    sys.exit()
seen = []
for f in s.get("testFailures", []):
    n = f.get("testIdentifierString") or f.get("testName", "?")
    if n not in seen:
        seen.append(n)
        print("  - %s: %s" % (n, (f.get("failureText") or "").splitlines()[0][:200] if f.get("failureText") else ""))
' "$RESULT/$plan.summary.json")"
  fi
  if [[ "$VERDICT" != PASS ]]; then
    OVERALL=1
    if [[ "$VERDICT" == RUNNER-FAILED ]]; then SAW_RUNNER=1; else SAW_FAIL=1; fi
  fi
  ROWS+=("| $plan | $VERDICT | $COUNTS | ${WALL}s |")
  KILLS="$(printf '%s\n' "$FAILED_NAMES" | grep -c 'crashed with signal kill' || true)"
  if [[ "$KILLS" -gt 0 ]]; then
    FAILED_NAMES="$FAILED_NAMES
  ($KILLS of these are \"crashed with signal kill\": check the guest's log for runningboardd \"CacheDeleteAppContainerCaches\" — macOS's low-disk purge killing the runner — before blaming the test)"
  fi
  [[ -z "$FAILED_NAMES" ]] || FAILURES+=("$(printf '**%s failures**\n\n%s\n' "$plan" "$FAILED_NAMES")")
  log "$plan: $VERDICT — $COUNTS (${WALL}s)"
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
  echo "| Plan | Result | Tests | Wall time |"
  echo "| --- | --- | --- | --- |"
  for row in "${ROWS[@]}"; do printf '%s\n' "$row"; done
  echo
  for f in ${FAILURES[@]+"${FAILURES[@]}"}; do printf '%s\n\n' "$f"; done
  if [[ $OVERALL -eq 0 ]]; then echo "Overall: PASS"
  elif [[ $SAW_RUNNER -eq 1 && $SAW_FAIL -eq 0 ]]; then echo "Overall: RUNNER-FAILED"
  else echo "Overall: FAIL"; fi
} >"$RESULT/summary.md"
cat "$RESULT/summary.md"
exit "$OVERALL"
