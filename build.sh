#!/usr/bin/env bash
# Build Kestrel and assemble it into a macOS .app bundle.
# Usage:
#   ./build.sh              # release build, produces ./Kestrel.app
#   ./build.sh debug        # debug build
#   ./build.sh release run  # build release and launch the app
set -euo pipefail

CONFIG="${1:-release}"
ACTION="${2:-}"

case "$CONFIG" in
    debug|release) ;;
    *)
        echo "Unknown configuration: $CONFIG (expected 'debug' or 'release')" >&2
        exit 2
        ;;
esac

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXE_PATH="$BIN_PATH/Kestrel"

if [[ ! -x "$EXE_PATH" ]]; then
    echo "Built executable not found at $EXE_PATH" >&2
    exit 1
fi

APP_DIR="$ROOT_DIR/Kestrel.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$EXE_PATH" "$MACOS_DIR/Kestrel"
chmod +x "$MACOS_DIR/Kestrel"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc sign so TCC can attribute the screen-recording grant to a stable identity.
echo "==> Ad-hoc codesign"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built: $APP_DIR"

if [[ "$ACTION" == "run" ]]; then
    echo "==> Launching"
    open "$APP_DIR"
fi
