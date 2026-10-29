#!/bin/bash
# Build MadMole.app, the native macOS (Apple Silicon) front end, with the Mole
# engine bundled inside it.
#
# Usage: scripts/build_app.sh [--install] [--dmg] [--debug]
#   --install   Copy the finished app to /Applications (replaces an older copy)
#   --dmg       Also create dist/MadMole.dmg
#   --debug     Build the Swift app in debug configuration
#
# Output: app/.build/MadMole.app (a hidden build folder, so repository checks
# never lint the engine copy inside the bundle).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
OUT_DIR="$APP_DIR/.build"
APP_NAME="MadMole"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
APP_VERSION="${MADMOLE_VERSION:-1.0.0}"
BUNDLE_ID="${MADMOLE_BUNDLE_ID:-com.madduck666.madmole}"
CONFIGURATION="release"
INSTALL=false
MAKE_DMG=false

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --dmg) MAKE_DMG=true ;;
        --debug) CONFIGURATION="debug" ;;
        -h | --help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (see --help)" >&2
            exit 1
            ;;
    esac
done

step() { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
fail() {
    printf '\033[1;31mError:\033[0m %s\n' "$1" >&2
    exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "MadMole.app can only be built on macOS."
command -v swift > /dev/null 2>&1 || fail "Swift is missing. Install Xcode or run: xcode-select --install"

ENGINE_VERSION=$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$ROOT_DIR/mole")
[[ -n "$ENGINE_VERSION" ]] || fail "Could not read VERSION from the mole router."

STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/madmole-build.XXXXXX")
cleanup() {
    rm -rf "$STAGE_DIR" # SAFE: private mktemp staging directory created by this script
}
trap cleanup EXIT

step "Building the Go helpers (status, analyze) for darwin/arm64"
mkdir -p "$STAGE_DIR/go"
if command -v go > /dev/null 2>&1; then
    (
        cd "$ROOT_DIR"
        CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o "$STAGE_DIR/go/analyze-go" ./cmd/analyze
        CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o "$STAGE_DIR/go/status-go" ./cmd/status
    )
elif [[ -x "$ROOT_DIR/bin/analyze-go" && -x "$ROOT_DIR/bin/status-go" ]]; then
    echo "Go is not installed; reusing bin/analyze-go and bin/status-go from make build."
    cp "$ROOT_DIR/bin/analyze-go" "$ROOT_DIR/bin/status-go" "$STAGE_DIR/go/"
else
    fail "Go is missing. Install it (brew install go) so the dashboard and disk analyzer can be built."
fi

step "Building the Swift app ($CONFIGURATION, arm64)"
swift build --package-path "$APP_DIR" -c "$CONFIGURATION" --arch arm64
BIN_PATH=$(swift build --package-path "$APP_DIR" -c "$CONFIGURATION" --arch arm64 --show-bin-path)
[[ -x "$BIN_PATH/$APP_NAME" ]] || fail "Swift build produced no $APP_NAME executable in $BIN_PATH"

step "Assembling $APP_NAME.app"
BUNDLE_STAGE="$STAGE_DIR/$APP_NAME.app"
CONTENTS="$BUNDLE_STAGE/Contents"
ENGINE_DIR="$CONTENTS/Resources/engine"
mkdir -p "$CONTENTS/MacOS" "$ENGINE_DIR/bin"
cp "$BIN_PATH/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"

# The engine: the router, its command scripts, the shared library and the Go
# helpers. Tests, docs and development files stay out of the bundle.
cp "$ROOT_DIR/mole" "$ENGINE_DIR/mole"
cp "$ROOT_DIR"/bin/*.sh "$ENGINE_DIR/bin/"
cp -R "$ROOT_DIR/lib" "$ENGINE_DIR/lib"
cp "$STAGE_DIR/go/analyze-go" "$STAGE_DIR/go/status-go" "$ENGINE_DIR/bin/"
cp "$ROOT_DIR/LICENSE" "$ENGINE_DIR/LICENSE"
chmod 755 "$ENGINE_DIR/mole" "$ENGINE_DIR"/bin/*.sh "$ENGINE_DIR/bin/analyze-go" "$ENGINE_DIR/bin/status-go"
find "$ENGINE_DIR" -name '.DS_Store' -type f -delete # SAFE: Finder metadata inside the private staging copy

sed -e "s/__APP_VERSION__/$APP_VERSION/g" \
    -e "s/__ENGINE_VERSION__/$ENGINE_VERSION/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    "$APP_DIR/Resources/Info.plist" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

step "Drawing the app icon"
ICON_PNG="$STAGE_DIR/icon_1024.png"
if swift "$APP_DIR/Scripts/make_icon.swift" "$ICON_PNG" > /dev/null 2>&1 && [[ -s "$ICON_PNG" ]]; then
    ICONSET="$STAGE_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
    done
    mkdir -p "$CONTENTS/Resources"
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
else
    echo "Icon generation failed; the app will use the default icon."
fi

step "Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$ENGINE_DIR/bin/analyze-go" "$ENGINE_DIR/bin/status-go"
codesign --force --sign - --timestamp=none "$CONTENTS/MacOS/$APP_NAME"
codesign --force --sign - --timestamp=none "$BUNDLE_STAGE"
codesign --verify --strict "$BUNDLE_STAGE"

mkdir -p "$OUT_DIR"
if [[ -d "$APP_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE" # SAFE: previous build output of this script inside app/.build
fi
ditto "$BUNDLE_STAGE" "$APP_BUNDLE"
echo "Built $APP_BUNDLE (engine $ENGINE_VERSION)"

if [[ "$MAKE_DMG" == "true" ]]; then
    step "Creating dist/$APP_NAME.dmg"
    DMG_ROOT="$STAGE_DIR/dmg"
    mkdir -p "$DMG_ROOT" "$DIST_DIR"
    ditto "$APP_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
    ln -s /Applications "$DMG_ROOT/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DIST_DIR/$APP_NAME.dmg" > /dev/null
    echo "Created $DIST_DIR/$APP_NAME.dmg"
fi

if [[ "$INSTALL" == "true" ]]; then
    step "Installing to /Applications"
    TARGET="/Applications/$APP_NAME.app"
    if [[ -d "$TARGET" ]]; then
        # Replace through the Trash so an older copy stays recoverable.
        osascript -e "tell application \"Finder\" to delete POSIX file \"$TARGET\"" > /dev/null ||
            fail "Could not move the old $TARGET to the Trash; remove it and retry."
    fi
    ditto "$APP_BUNDLE" "$TARGET"
    echo "Installed $TARGET"
    open "$TARGET"
fi

printf '\nDone. Open it with:\n  open "%s"\n' "$APP_BUNDLE"
