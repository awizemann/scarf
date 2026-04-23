#!/usr/bin/env bash
#
# Scarf templates catalog helper — runs the Python validator, renders the
# static site into .gh-pages-worktree/templates/, and (on `publish`)
# commits + pushes that subdir on the gh-pages branch.
#
# Usage:
#   ./scripts/catalog.sh check                # validate every template; no output
#   ./scripts/catalog.sh build                # validate + write templates/catalog.json + .gh-pages-worktree/templates/
#   ./scripts/catalog.sh preview [DIR]        # render self-contained preview; DIR defaults to /tmp/scarf-catalog-preview
#   ./scripts/catalog.sh publish              # secret-scan + commit + push gh-pages (templates subdir only)
#   ./scripts/catalog.sh serve  [PORT]        # serve .gh-pages-worktree/ on localhost:PORT (default 8000)
#   ./scripts/catalog.sh --help               # this help
#
# The secret-scan runs BEFORE publish and inspects the generated
# .gh-pages-worktree/templates/ tree — same hard-pattern regex as
# scripts/wiki.sh so template README/AGENTS content that accidentally
# leaks credentials gets blocked before it reaches the public site.
#
# Bootstrap (one-time): requires a .gh-pages-worktree/ clone of the
# gh-pages branch. The release script (scripts/release.sh) creates it on
# first use. If it's missing:
#     git worktree add .gh-pages-worktree gh-pages
#
# Recovery: if .gh-pages-worktree/ is deleted, re-run the command above.

set -euo pipefail

# ---------- config ----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHPAGES_DIR="$REPO_ROOT/.gh-pages-worktree"
CATALOG_SUBDIR="templates"
PY="${PYTHON:-python3}"
BUILDER="$REPO_ROOT/tools/build-catalog.py"

# ---------- helpers (same shape as scripts/wiki.sh so a reader doesn't
# have to learn two conventions) ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

need_builder() {
  [[ -f "$BUILDER" ]] || die "missing $BUILDER"
  command -v "$PY" >/dev/null 2>&1 || die "python3 not found (set \$PYTHON if needed)"
}

need_ghpages() {
  # `.git` is a directory in a regular clone but a pointer FILE in a
  # `git worktree add` worktree — `-e` covers both. The earlier `-d`
  # check falsely rejected worktrees, so the script's own error
  # message told users to re-run `git worktree add` on a worktree
  # that was already there and valid.
  [[ -e "$GHPAGES_DIR/.git" ]] || die "no gh-pages worktree at $GHPAGES_DIR
  Run: git worktree add .gh-pages-worktree gh-pages"
}

# ---------- secret-scan (mirrors scripts/wiki.sh hard-pattern set) ----------
hard_regex='(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|ghs_[A-Za-z0-9]{30,}|ghu_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|ghr_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|BEGIN OPENSSH PRIVATE KEY)'

scan_hard_ghpages() {
  # Scan the generated output, NOT the repo source — the validator
  # already scans bundle contents. This pass catches anything that leaked
  # through template.json fields or README prose.
  local hits
  hits="$(grep -rInE --exclude-dir=.git "$hard_regex" "$GHPAGES_DIR/$CATALOG_SUBDIR" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "hard-pattern secret match in rendered site — refusing to publish."
  fi
}

# ---------- commands ----------
cmd_check() {
  need_builder
  "$PY" "$BUILDER" --check --repo "$REPO_ROOT"
}

cmd_build() {
  need_builder
  "$PY" "$BUILDER" --build --repo "$REPO_ROOT"
}

cmd_preview() {
  need_builder
  local dir="${1:-/tmp/scarf-catalog-preview}"
  rm -rf "$dir"
  mkdir -p "$dir"
  "$PY" "$BUILDER" --preview "$dir" --repo "$REPO_ROOT"
  log "Preview rendered to $dir"
  log "Serve with:  (cd $dir && python3 -m http.server 8000)  then open http://localhost:8000/"
}

cmd_serve() {
  need_ghpages
  local port="${1:-8000}"
  log "Serving $GHPAGES_DIR on http://localhost:$port/"
  (cd "$GHPAGES_DIR" && "$PY" -m http.server "$port")
}

cmd_publish() {
  need_builder
  need_ghpages
  log "Validating"
  "$PY" "$BUILDER" --check --repo "$REPO_ROOT"
  log "Building"
  "$PY" "$BUILDER" --build --repo "$REPO_ROOT"

  log "Secret-scanning rendered site"
  scan_hard_ghpages

  log "Staging + committing gh-pages"
  (cd "$GHPAGES_DIR" && git add "$CATALOG_SUBDIR")
  if (cd "$GHPAGES_DIR" && git diff --cached --quiet); then
    log "No changes to publish."
    return 0
  fi
  local msg
  msg="catalog: rebuild at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (cd "$GHPAGES_DIR" && git commit -m "$msg")
  log "Pushing gh-pages"
  (cd "$GHPAGES_DIR" && git push origin gh-pages)
  log "Published."
}

cmd_help() {
  sed -n '1,30p' "$0" | sed -n '/^# Usage/,/^#$/p'
}

# ---------- dispatch ----------
sub="${1:-help}"
shift || true
case "$sub" in
  check)    cmd_check   "$@" ;;
  build)    cmd_build   "$@" ;;
  preview)  cmd_preview "$@" ;;
  serve)    cmd_serve   "$@" ;;
  publish)  cmd_publish "$@" ;;
  help|--help|-h) cmd_help ;;
  *) die "unknown command: $sub  (try --help)" ;;
esac
