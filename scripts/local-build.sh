#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$REPO_ROOT/scarf/scarf.xcodeproj"
SCHEME="${SCHEME:-scarf}"
CONFIG="${CONFIG:-Debug}"
DERIVED_DATA="$REPO_ROOT/build/DerivedData"
PACKAGE_RESOLVED_REL="scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PACKAGE_RESOLVED="$REPO_ROOT/$PACKAGE_RESOLVED_REL"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup_generated_files() {
  if [[ "${REMOVE_GENERATED_PACKAGE_RESOLVED:-0}" == "1" && -f "$PACKAGE_RESOLVED" ]]; then
    rm -f "$PACKAGE_RESOLVED"
    rmdir "$REPO_ROOT/scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" 2>/dev/null || true
    rmdir "$REPO_ROOT/scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata" 2>/dev/null || true
  fi
}
trap cleanup_generated_files EXIT

log "Detecting architecture"
case "$(uname -m)" in
  arm64) BUILD_ARCH="arm64" ;;
  x86_64) BUILD_ARCH="x86_64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
log "Using architecture: $BUILD_ARCH"

log "Checking Xcode command line tools"
command -v xcode-select >/dev/null 2>&1 || die "xcode-select not found; install Xcode or Xcode command line tools"
if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode command line tools not selected. Run: xcode-select --install"
fi

command -v xcrun >/dev/null 2>&1 || die "xcrun not found; install Xcode or Xcode command line tools"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode"

log "Checking Metal toolchain"
if ! xcrun metal --version >/dev/null 2>&1 && ! xcrun -f metal >/dev/null 2>&1; then
  if [[ -t 0 && -z "${CI:-}" ]]; then
    printf 'Metal toolchain is missing. Install it now with xcodebuild -downloadComponent MetalToolchain? [y/N] '
    read -r reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      xcodebuild -downloadComponent MetalToolchain
      if xcrun metal --version >/dev/null 2>&1 || xcrun -f metal >/dev/null 2>&1; then
        log "Metal toolchain installed"
      else
        die "Metal toolchain still not available after install"
      fi
    else
      cat >&2 <<'EOF'
error: Metal toolchain missing.

Install it when you are ready with:
  xcodebuild -downloadComponent MetalToolchain
EOF
      exit 1
    fi
  else
    cat >&2 <<'EOF'
error: Metal toolchain missing.

Install it with:
  xcodebuild -downloadComponent MetalToolchain
EOF
    exit 1
  fi
fi

log "Resolving Swift packages"
if [[ ! -e "$PACKAGE_RESOLVED" ]] && ! git -C "$REPO_ROOT" ls-files --error-unmatch "$PACKAGE_RESOLVED_REL" >/dev/null 2>&1; then
  REMOVE_GENERATED_PACKAGE_RESOLVED=1
fi
xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT"

log "Building unsigned $CONFIG app"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  -arch "$BUILD_ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIG/scarf.app"
[[ -d "$APP_PATH" ]] || die "build completed, but app bundle was not found at $APP_PATH"

printf '\nBuild complete:\n  %s\n\n' "$APP_PATH"

if [[ -t 0 && -z "${CI:-}" ]]; then
  read -r -p "Copy to /Applications? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    rm -rf "/Applications/scarf.app"
    ditto "$APP_PATH" "/Applications/scarf.app"
    echo "Installed to /Applications/scarf.app"
  fi
fi
