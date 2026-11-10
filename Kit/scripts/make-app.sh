#!/bin/bash
#
# Builds "Disk Inventory X.app" from the DiskInventoryX executable target:
# release build, Info.plist, icon, the original's images, ad-hoc signature.
#
#   scripts/make-app.sh [--scratch-path DIR] [--out DIR] [--package-path DIR]
#
# Defaults: build products in Kit/.build, the app in Kit/build/.
#
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$KIT/.build"
OUT="$KIT/build"
PACKAGE="$KIT"
while [ $# -gt 0 ]; do
    case "$1" in
        --scratch-path) SCRATCH="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --package-path) PACKAGE="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

swift build -c release --package-path "$PACKAGE" --scratch-path "$SCRATCH" --product DiskInventoryX
BIN="$(swift build -c release --package-path "$PACKAGE" --scratch-path "$SCRATCH" --show-bin-path)/DiskInventoryX"

APP="$OUT/Disk Inventory X.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Disk Inventory X"
cp "$KIT/App/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$KIT"/App/Resources/* "$APP/Contents/Resources/"
iconutil -c icns "$KIT/App/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
