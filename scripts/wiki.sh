#!/usr/bin/env bash
#
# Scarf wiki helper — wraps the local .wiki-worktree/ clone with a secret-scan.
#
# Usage:
#   ./scripts/wiki.sh status                 # git status inside .wiki-worktree/
#   ./scripts/wiki.sh pull                   # fetch + fast-forward; aborts if dirty
#   ./scripts/wiki.sh new <Page-Name>        # create Page-Name.md with stub template
#   ./scripts/wiki.sh stub-check             # list pages still containing the TODO stub
#   ./scripts/wiki.sh commit "<msg>"         # secret-scan, then git add -A && git commit
#   ./scripts/wiki.sh push                   # secret-scan again, then git push
#   ./scripts/wiki.sh touch <Page-Name>      # bump "Last updated" line to today
#   ./scripts/wiki.sh --help                 # this help
#
# The secret-scan has two tiers:
#   - Hard patterns (tokens, keys, private-key headers): block with non-zero exit.
#   - Soft keywords (password, api_key, secret, bearer, authorization:, .env):
#     warn and require --force-terms on commit/push to proceed.
#
# A user-maintained blocklist lives at scripts/wiki-blocklist.txt (gitignored).
# One pattern per line — blank lines and lines starting with # are ignored.
# Matches are treated as HARD blocks. Use this for personal IPs, hostnames, etc.
#
# Bootstrap (one-time):
#   1. In GitHub repo Settings → Features → Wikis, enable Wikis and restrict
#      editing to collaborators.
#   2. Visit https://github.com/awizemann/scarf/wiki and save any first page
#      via the UI (this is what creates the underlying .wiki.git repo).
#   3. From repo root:
#        git clone git@github.com:awizemann/scarf.wiki.git .wiki-worktree
#
# Recovery: if .wiki-worktree/ is deleted, re-run step 3. Remote is authoritative.

set -euo pipefail

# ---------- config ----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIKI_DIR="$REPO_ROOT/.wiki-worktree"
WIKI_REMOTE="git@github.com:awizemann/scarf.wiki.git"
BLOCKLIST="$REPO_ROOT/scripts/wiki-blocklist.txt"
STUB_MARKER='> **TODO: document.**'
MAINTENANCE_PAGE="Wiki-Maintenance.md"

# ---------- helpers ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

need_worktree() {
  [[ -d "$WIKI_DIR/.git" ]] || die "no wiki clone at $WIKI_DIR
  Run: git clone $WIKI_REMOTE .wiki-worktree
  (See --help for bootstrap steps.)"
}

in_wiki() { (cd "$WIKI_DIR" && "$@"); }

today() { date +%Y-%m-%d; }

# ---------- secret-scan ----------
#
# scan_hard:   exits non-zero if any hard pattern or user-blocklist pattern matches.
# scan_soft:   warns (returns 1) if any soft keyword matches, else 0. The caller
#              decides whether to bail based on --force-terms.
#
# All scans ignore the .git directory of the wiki clone.

hard_regex='(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|ghs_[A-Za-z0-9]{30,}|ghu_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|ghr_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|BEGIN OPENSSH PRIVATE KEY)'
# Soft tier targets KEY=value / KEY: value patterns where the key name suggests
# a secret. Catches accidental .env paste; ignores legitimate mentions of the
# words "password" / "secret" in prose.
soft_regex='([Pp]assword|[Aa]pi[_-]?[Kk]ey|[Ss]ecret[_-][Kk]ey|[Tt]oken|[Aa]uth[_-]?[Tt]oken|[Bb]earer)[[:space:]]*[=:][[:space:]]*['"'"'"]?[A-Za-z0-9_+./-]{8,}'

scan_hard() {
  local hits
  hits="$(cd "$WIKI_DIR" && grep -rInE --exclude-dir=.git "$hard_regex" . 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "hard-pattern secret match — aborting. Remove the above and retry."
  fi

  if [[ -f "$BLOCKLIST" ]]; then
    local pat
    while IFS= read -r pat; do
      [[ -z "$pat" || "$pat" =~ ^# ]] && continue
      local blocklist_hits
      blocklist_hits="$(cd "$WIKI_DIR" && grep -rInF --exclude-dir=.git -- "$pat" . 2>/dev/null || true)"
      if [[ -n "$blocklist_hits" ]]; then
        printf '%s\n' "$blocklist_hits" >&2
        die "user blocklist match on pattern \"$pat\" — aborting."
      fi
    done < "$BLOCKLIST"
  fi
}

scan_soft() {
  local hits
  # Exempt the maintenance page (it documents the forbidden terms on purpose).
  hits="$(cd "$WIKI_DIR" && grep -rInE --exclude-dir=.git --exclude="$MAINTENANCE_PAGE" "$soft_regex" . 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    warn "soft-keyword matches above. Review carefully. Pass --force-terms to proceed."
    return 1
  fi
  return 0
}

# ---------- commands ----------
cmd_status() {
  need_worktree
  in_wiki git status
}

cmd_pull() {
  need_worktree
  if [[ -n "$(in_wiki git status --porcelain)" ]]; then
    die "wiki has uncommitted changes — commit or stash before pulling."
  fi
  log "Pulling wiki"
  in_wiki git fetch origin
  in_wiki git merge --ff-only origin/master
  log "Up to date."
}

cmd_new() {
  need_worktree
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: wiki.sh new <Page-Name>"
  # Normalize spaces → dashes; strip .md if the user added it.
  name="${name%.md}"
  name="${name// /-}"
  local path="$WIKI_DIR/${name}.md"
  if [[ -e "$path" ]]; then
    die "already exists: $path"
  fi
  local title="${name//-/ }"
  cat > "$path" <<EOF
# ${title}

${STUB_MARKER} This page is a stub. See [Wiki Maintenance](Wiki-Maintenance).

---
_Last updated: $(today) — stub_
EOF
  log "Created $path"
}

cmd_stub_check() {
  need_worktree
  # Wiki-Maintenance.md documents the stub template in a code fence, so it
  # would always match the marker — exempt it.
  local matches count
  matches="$(cd "$WIKI_DIR" && grep -rlnF --exclude-dir=.git --exclude="$MAINTENANCE_PAGE" -- "$STUB_MARKER" . 2>/dev/null || true)"
  if [[ -z "$matches" ]]; then
    log "No stub pages remain."
    return 0
  fi
  count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  log "$count stub page(s):"
  printf '%s\n' "$matches" | sed 's|^\./||' | sort
}

cmd_touch() {
  need_worktree
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: wiki.sh touch <Page-Name>"
  name="${name%.md}"
  name="${name// /-}"
  local path="$WIKI_DIR/${name}.md"
  [[ -f "$path" ]] || die "no such page: $path"
  # Replace the YYYY-MM-DD portion of the Last updated line, keep whatever trails it.
  # Uses sed -i '' for BSD/macOS compatibility.
  sed -i '' -E "s/(_Last updated: )[0-9]{4}-[0-9]{2}-[0-9]{2}/\1$(today)/" "$path"
  log "Touched ${name}.md → $(today)"
}

cmd_commit() {
  need_worktree
  local msg="" force=0
  for arg in "$@"; do
    case "$arg" in
      --force-terms) force=1 ;;
      -*) die "unknown flag: $arg" ;;
      *) [[ -z "$msg" ]] && msg="$arg" || die "unexpected arg: $arg" ;;
    esac
  done
  [[ -n "$msg" ]] || die 'usage: wiki.sh commit "<message>" [--force-terms]'
  log "Secret-scan (hard patterns + blocklist)"
  scan_hard
  log "Secret-scan (soft keywords)"
  if ! scan_soft; then
    if [[ "$force" -eq 1 ]]; then
      warn "proceeding past soft-keyword matches (--force-terms)"
    else
      die "soft-keyword matches — re-run with --force-terms to proceed."
    fi
  fi
  in_wiki git add -A
  if [[ -z "$(in_wiki git status --porcelain)" ]]; then
    warn "nothing to commit"
    return 0
  fi
  in_wiki git commit -m "$msg"
  log "Committed: $msg"
}

cmd_push() {
  need_worktree
  local force=0
  for arg in "$@"; do
    case "$arg" in
      --force-terms) force=1 ;;
      *) die "unknown arg: $arg" ;;
    esac
  done
  log "Secret-scan before push (hard patterns + blocklist)"
  scan_hard
  log "Secret-scan before push (soft keywords)"
  if ! scan_soft; then
    if [[ "$force" -eq 1 ]]; then
      warn "proceeding past soft-keyword matches (--force-terms)"
    else
      die "soft-keyword matches — re-run with --force-terms to proceed."
    fi
  fi
  # Nothing to push?
  local ahead
  ahead="$(in_wiki git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)"
  if [[ "$ahead" -eq 0 ]]; then
    warn "nothing to push (0 commits ahead of origin)"
    return 0
  fi
  log "Pushing $ahead commit(s) to origin"
  in_wiki git push origin HEAD
  log "Pushed. Verify at https://github.com/awizemann/scarf/wiki"
}

cmd_help() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- dispatch ----------
sub="${1:-}"
shift || true
case "$sub" in
  status)     cmd_status "$@" ;;
  pull)       cmd_pull "$@" ;;
  new)        cmd_new "$@" ;;
  stub-check) cmd_stub_check "$@" ;;
  touch)      cmd_touch "$@" ;;
  commit)     cmd_commit "$@" ;;
  push)       cmd_push "$@" ;;
  -h|--help|help|"") cmd_help ;;
  *) die "unknown subcommand: $sub (run --help)" ;;
esac
