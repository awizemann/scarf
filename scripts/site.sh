#!/usr/bin/env bash
#
# Scarf landing-site helper — builds the marketing landing page from
# site/landing/ and (on `publish`) commits + pushes to gh-pages.
#
# Usage:
#   ./scripts/site.sh check               # validate that all required files exist
#   ./scripts/site.sh build               # render to .gh-pages-worktree/ root (with token substitution)
#   ./scripts/site.sh preview [PORT]      # build + serve on localhost:PORT (default 8000) + open browser
#   ./scripts/site.sh serve   [PORT]      # serve .gh-pages-worktree/ without rebuilding (default 8000)
#   ./scripts/site.sh publish             # check + build + secret-scan + commit + push gh-pages (root files only)
#   ./scripts/site.sh --help              # this help
#
# Path discipline. This script ONLY touches root-level landing files plus the
# top-level assets/ directory on gh-pages. It NEVER touches:
#   - appcast.xml         (owned by scripts/release.sh)
#   - templates/          (owned by scripts/catalog.sh)
# All three publishers stay on disjoint paths.
#
# Bootstrap (one-time): a .gh-pages-worktree/ clone of the gh-pages branch.
# scripts/release.sh creates it on first use. If missing:
#     git worktree add .gh-pages-worktree gh-pages
#
# Token substitution. index.html and sitemap.xml.tmpl are run through a
# minimal {{TOKEN}} replacement at build time:
#   {{VERSION}}        — current Scarf version (read from appcast.xml on
#                         gh-pages, or "unreleased" if not found)
#   {{LASTMOD}}        — today's date in YYYY-MM-DD
#   {{TEMPLATE_URLS}}  — <url> entries for every template in
#                         templates/catalog.json (only used in sitemap.xml.tmpl)

set -euo pipefail

# ---------- config ----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHPAGES_DIR="$REPO_ROOT/.gh-pages-worktree"
SRC_DIR="$REPO_ROOT/site/landing"
PY="${PYTHON:-python3}"

# Files we OWN on gh-pages root. Anything else stays untouched.
OWNED_ROOT_FILES=(
  index.html
  styles.css
  app.js
  llms.txt
  robots.txt
  sitemap.xml
  manifest.webmanifest
  favicon.ico
  apple-touch-icon.png
)

# ---------- helpers (same shape as scripts/catalog.sh) ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

need_src() {
  [[ -d "$SRC_DIR" ]] || die "missing $SRC_DIR"
  for f in index.html styles.css app.js llms.txt robots.txt sitemap.xml.tmpl manifest.webmanifest favicon.ico apple-touch-icon.png; do
    [[ -e "$SRC_DIR/$f" ]] || die "missing required source file: $SRC_DIR/$f"
  done
  [[ -d "$SRC_DIR/assets" ]] || die "missing $SRC_DIR/assets/"
}

need_ghpages() {
  [[ -e "$GHPAGES_DIR/.git" ]] || die "no gh-pages worktree at $GHPAGES_DIR
  Run: git worktree add .gh-pages-worktree gh-pages"
}

# ---------- token resolvers ----------

# Pull current version from appcast.xml on gh-pages (preferred — reflects
# what's actually shipped). Fall back to "unreleased".
resolve_version() {
  if [[ -f "$GHPAGES_DIR/appcast.xml" ]]; then
    APPCAST="$GHPAGES_DIR/appcast.xml" "$PY" -c '
import os, re
src = open(os.environ["APPCAST"], "r", encoding="utf-8").read()
# Sparkle uses <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>.
# Take the first match (newest entry — appcast is reverse-chronological).
m = re.search(r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>", src)
print(m.group(1) if m else "unreleased")
'
  else
    echo "unreleased"
  fi
}

# Render <url> entries for each template in catalog.json. The catalog lives
# at templates/catalog.json on gh-pages (built by scripts/catalog.sh).
resolve_template_urls() {
  local catalog="$GHPAGES_DIR/templates/catalog.json"
  if [[ ! -f "$catalog" ]]; then
    return 0
  fi
  "$PY" - <<'PY' "$catalog"
import json, sys, datetime
catalog = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
today = datetime.date.today().isoformat()
out = []
for tpl in catalog.get("templates", []):
    slug = tpl.get("slug") or tpl.get("id") or ""
    if not slug:
        continue
    out.append(
        f'  <url>\n'
        f'    <loc>https://awizemann.github.io/scarf/templates/{slug}/</loc>\n'
        f'    <lastmod>{today}</lastmod>\n'
        f'    <changefreq>monthly</changefreq>\n'
        f'    <priority>0.6</priority>\n'
        f'  </url>'
    )
print("\n".join(out))
PY
}

# Apply {{TOKEN}} substitution: substitute_tokens VERSION LASTMOD TEMPLATE_URLS SRC_FILE DEST_FILE
substitute_tokens() {
  local version="$1"
  local lastmod="$2"
  local template_urls="$3"
  local src_file="$4"
  local dest_file="$5"
  VERSION="$version" LASTMOD="$lastmod" TEMPLATE_URLS="$template_urls" \
    SRC="$src_file" DEST="$dest_file" \
    "$PY" -c '
import os
src_path = os.environ["SRC"]
dest_path = os.environ["DEST"]
with open(src_path, "r", encoding="utf-8") as fh:
    text = fh.read()
text = text.replace("{{VERSION}}", os.environ["VERSION"])
text = text.replace("{{LASTMOD}}", os.environ["LASTMOD"])
text = text.replace("{{TEMPLATE_URLS}}", os.environ["TEMPLATE_URLS"])
with open(dest_path, "w", encoding="utf-8") as fh:
    fh.write(text)
'
}

# ---------- secret-scan (mirrors catalog.sh) ----------
hard_regex='(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|ghs_[A-Za-z0-9]{30,}|ghu_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|ghr_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|BEGIN OPENSSH PRIVATE KEY)'

scan_hard_source() {
  # Pre-build pass: scan source files (text only — image content is on the
  # author to review visually). Catches accidentally-pasted credentials.
  local hits
  hits="$(grep -rInE --exclude-dir=.git --include='*.html' --include='*.css' --include='*.js' --include='*.txt' --include='*.xml' --include='*.json' --include='*.tmpl' --include='*.webmanifest' "$hard_regex" "$SRC_DIR" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "hard-pattern secret match in source — refusing to build."
  fi
}

scan_hard_rendered() {
  # Post-build pass: scan the gh-pages tree we're about to publish, but
  # only the files we own (so we don't false-flag on appcast.xml or
  # templates/ which other scripts manage).
  local hits=""
  for f in "${OWNED_ROOT_FILES[@]}"; do
    [[ -f "$GHPAGES_DIR/$f" ]] || continue
    case "$f" in
      *.png|*.ico|*.jpg|*.jpeg|*.webp) continue ;;
    esac
    local h
    h="$(grep -InE "$hard_regex" "$GHPAGES_DIR/$f" 2>/dev/null || true)"
    [[ -n "$h" ]] && hits="$hits$h"$'\n'
  done
  if [[ -d "$GHPAGES_DIR/assets" ]]; then
    local h
    h="$(grep -rInE --include='*.html' --include='*.css' --include='*.js' --include='*.txt' --include='*.xml' --include='*.json' --include='*.tmpl' "$hard_regex" "$GHPAGES_DIR/assets" 2>/dev/null || true)"
    [[ -n "$h" ]] && hits="$hits$h"$'\n'
  fi
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "hard-pattern secret match in rendered site — refusing to publish."
  fi
}

# ---------- commands ----------

cmd_check() {
  need_src
  scan_hard_source
  log "Source files OK ($(ls -1 "$SRC_DIR" | wc -l | tr -d ' ') entries; assets/: $(find "$SRC_DIR/assets" -type f | wc -l | tr -d ' ') files)"
}

cmd_build() {
  need_src
  need_ghpages
  scan_hard_source

  local version lastmod template_urls
  version="$(resolve_version)"
  lastmod="$(date -u +%Y-%m-%d)"
  template_urls="$(resolve_template_urls)"

  log "Building (version=$version, lastmod=$lastmod)"

  # Static copies (no substitution needed)
  for f in styles.css app.js llms.txt robots.txt manifest.webmanifest favicon.ico apple-touch-icon.png; do
    cp "$SRC_DIR/$f" "$GHPAGES_DIR/$f"
  done

  # Token-substituted: index.html
  substitute_tokens "$version" "$lastmod" "$template_urls" \
    "$SRC_DIR/index.html" "$GHPAGES_DIR/index.html"

  # Token-substituted: sitemap.xml (rendered from .tmpl)
  substitute_tokens "$version" "$lastmod" "$template_urls" \
    "$SRC_DIR/sitemap.xml.tmpl" "$GHPAGES_DIR/sitemap.xml"

  # Sync assets/ — mirror the source tree
  rm -rf "$GHPAGES_DIR/assets"
  cp -R "$SRC_DIR/assets" "$GHPAGES_DIR/assets"

  log "Built into $GHPAGES_DIR/"
}

cmd_preview() {
  cmd_build
  local port="${1:-8000}"
  log "Built. Open http://localhost:$port/ in your browser."
  log "Press Ctrl-C to stop the server."
  cmd_serve "$port"
}

cmd_serve() {
  need_ghpages
  local port="${1:-8000}"
  log "Serving $GHPAGES_DIR on http://localhost:$port/"
  log "Open: http://localhost:$port/"
  (cd "$GHPAGES_DIR" && "$PY" -m http.server "$port")
}

cmd_publish() {
  need_src
  need_ghpages

  log "Validating source"
  scan_hard_source

  log "Building"
  cmd_build

  log "Secret-scanning rendered site"
  scan_hard_rendered

  log "Staging + committing gh-pages"
  (cd "$GHPAGES_DIR" && git add "${OWNED_ROOT_FILES[@]}" assets/)
  if (cd "$GHPAGES_DIR" && git diff --cached --quiet); then
    log "No changes to publish."
    return 0
  fi
  local msg
  msg="site: rebuild landing page at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (cd "$GHPAGES_DIR" && git commit -m "$msg")
  log "Pushing gh-pages"
  (cd "$GHPAGES_DIR" && git push origin gh-pages)
  log "Published."
}

cmd_help() {
  sed -n '1,32p' "$0" | sed -n '/^# Usage/,/^#$/p'
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
