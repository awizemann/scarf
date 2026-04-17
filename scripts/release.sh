#!/usr/bin/env bash
#
# Scarf release pipeline — local, manual, repeatable.
#
# Usage:   ./scripts/release.sh 1.7.0
#
# Prerequisites (one-time setup):
#   1. Developer ID Application cert installed in login Keychain.
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#   2. App Store Connect API key stored for notarytool as profile "scarf-notary":
#        xcrun notarytool store-credentials "scarf-notary" \
#          --key ~/.private/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#   3. Sparkle EdDSA keypair generated (private key in Keychain item "https://sparkle-project.org"):
#        ./scripts/sparkle/generate_keys      # or similar, from Sparkle SPM artifacts
#   4. gh-pages branch exists with an appcast.xml and GitHub Pages enabled.
#   5. gh CLI authed: `gh auth status`.
#   6. GH_PAGES_WORKTREE env var pointing at a gh-pages checkout, OR let the
#      script create one automatically at .gh-pages-worktree/ via `git worktree add`.
#
set -euo pipefail

# ---------- config ----------
VERSION="${1:?usage: ./scripts/release.sh <marketing-version>  e.g. 1.7.0}"
TEAM_ID="3Q6X2L86C4"
BUNDLE_ID="com.scarf.app"
SCHEME="scarf"
PROJECT="scarf/scarf.xcodeproj"
NOTARY_PROFILE="scarf-notary"
SIGNING_IDENTITY="Developer ID Application"
APPCAST_URL="https://awizemann.github.io/scarf/appcast.xml"
DOWNLOAD_URL_BASE="https://github.com/awizemann/scarf/releases/download"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/scarf.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
RELEASE_DIR="$REPO_ROOT/releases/v${VERSION}"
GH_PAGES_WORKTREE="${GH_PAGES_WORKTREE:-$REPO_ROOT/.gh-pages-worktree}"

# ---------- helpers ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------- preflight ----------
log "Preflight checks"
require_cmd xcodebuild
require_cmd xcrun
require_cmd ditto
require_cmd gh

cd "$REPO_ROOT"

# git must be clean and on main
if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree not clean — commit or stash first"
fi
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$CUR_BRANCH" == "main" ]] || die "not on main (on $CUR_BRANCH)"

# identity present
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "'$SIGNING_IDENTITY' certificate not in Keychain — create at developer.apple.com"

# notary profile present (can't list, only test by dry-running submit help)
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not set up — see script header"

# locate sign_update (ships with Sparkle SPM artifacts)
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f -perm +111 2>/dev/null | head -n1 || true)"
[[ -x "${SIGN_UPDATE:-}" ]] || die "sign_update not found — build the project once in Xcode so Sparkle artifacts resolve, then re-run"

# ---------- bump version ----------
log "Bumping version to $VERSION"
PBXPROJ="$PROJECT/project.pbxproj"
# CURRENT_PROJECT_VERSION (build number) bumps by 1 from existing
CUR_BUILD="$(awk -F'= ' '/CURRENT_PROJECT_VERSION/ {gsub(/[; ]/,"",$2); print $2; exit}' "$PBXPROJ")"
NEW_BUILD=$((CUR_BUILD + 1))
sed -i '' -E "s/MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PBXPROJ"
git add "$PBXPROJ"
git commit -m "chore: Bump version to ${VERSION}"

# ---------- build ----------
log "Clean build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Archive (universal arm64+x86_64)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  archive

log "Export signed .app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_DIR/Scarf.app"
[[ -d "$APP_PATH" ]] || die "exported app not found at $APP_PATH (expected Scarf.app — confirm PRODUCT_NAME)"

# ---------- verify signature ----------
log "Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
# spctl will fail here (not yet notarized) — that's fine, we check after stapling
spctl --assess --type execute --verbose "$APP_PATH" || true

# ---------- notarize ----------
log "Zip for notarization"
NOTARIZE_ZIP="$BUILD_DIR/Scarf-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

log "Submit to notarytool (blocking)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --timeout 30m

log "Staple notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

log "Final gatekeeper assessment"
spctl --assess --type execute --verbose "$APP_PATH"

# ---------- package distribution artifacts ----------
log "Package distribution zips"
mkdir -p "$RELEASE_DIR"
UNIVERSAL_ZIP="$RELEASE_DIR/Scarf-v${VERSION}-Universal.zip"
ditto -c -k --keepParent "$APP_PATH" "$UNIVERSAL_ZIP"

# ---------- sign appcast entry ----------
log "Sign appcast entry with EdDSA"
# sign_update prints: sparkle:edSignature="..." length="..."
SIG_OUTPUT="$("$SIGN_UPDATE" "$UNIVERSAL_ZIP")"
ED_SIGNATURE="$(echo "$SIG_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
FILE_LENGTH="$(echo "$SIG_OUTPUT" | sed -nE 's/.*length="([^"]+)".*/\1/p')"
[[ -n "$ED_SIGNATURE" && -n "$FILE_LENGTH" ]] || die "sign_update did not produce signature: $SIG_OUTPUT"

# ---------- update appcast on gh-pages ----------
log "Update appcast.xml on gh-pages worktree"
if [[ ! -d "$GH_PAGES_WORKTREE" ]]; then
  git worktree add "$GH_PAGES_WORKTREE" gh-pages
fi
(
  cd "$GH_PAGES_WORKTREE"
  git pull --ff-only origin gh-pages
  PUB_DATE="$(LC_TIME=en_US.UTF-8 date -u +"%a, %d %b %Y %H:%M:%S +0000")"
  DOWNLOAD_URL="$DOWNLOAD_URL_BASE/v${VERSION}/Scarf-v${VERSION}-Universal.zip"
  NEW_ITEM=$(cat <<EOF
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${NEW_BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.6</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure url="${DOWNLOAD_URL}"
                 sparkle:edSignature="${ED_SIGNATURE}"
                 length="${FILE_LENGTH}"
                 type="application/octet-stream" />
    </item>
EOF
)
  # Insert new item after <language>en</language> line
  python3 - "$NEW_ITEM" <<'PY'
import sys, pathlib
new_item = sys.argv[1]
p = pathlib.Path("appcast.xml")
xml = p.read_text()
marker = "<language>en</language>"
if marker not in xml:
    sys.exit("appcast.xml missing <language>en</language> marker")
xml = xml.replace(marker, marker + "\n" + new_item, 1)
p.write_text(xml)
PY
  git add appcast.xml
  git commit -m "release: v${VERSION}"
  git push origin gh-pages
)

# ---------- github release ----------
log "Create GitHub release and upload artifacts"
gh release create "v${VERSION}" \
  --title "Scarf v${VERSION}" \
  --notes "Release notes: https://github.com/awizemann/scarf/releases/tag/v${VERSION}" \
  "$UNIVERSAL_ZIP"

log "Tag main and push"
git tag "v${VERSION}"
git push origin main --tags

log "Release v${VERSION} complete"
log "  Download:  $DOWNLOAD_URL_BASE/v${VERSION}/Scarf-v${VERSION}-Universal.zip"
log "  Appcast:   $APPCAST_URL"
