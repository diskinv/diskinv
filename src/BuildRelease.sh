#!/bin/bash
#
# Build Disk Inventory X (Objective-C version) for Release
# Builds both the TreeMapView framework and the main app
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TREEMAP_DIR="$(dirname "$SCRIPT_DIR")/treemap"
BUILD_DIR="$SCRIPT_DIR/build"

echo "=== Building TreeMapView.framework ==="
cd "$TREEMAP_DIR"
xcodebuild -project "TreeMapView.xcodeproj" \
           -scheme "TreeMapView" \
           -configuration Release \
           -derivedDataPath "$BUILD_DIR" \
           CODE_SIGN_IDENTITY="-" \
           CODE_SIGNING_REQUIRED=NO \
           OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
           clean build

echo ""
echo "=== Building Disk Inventory X ==="
cd "$SCRIPT_DIR"
xcodebuild -project "Disk Inventory X.xcodeproj" \
           -scheme "Disk Inventory X" \
           -configuration Release \
           -derivedDataPath "$BUILD_DIR" \
           CODE_SIGN_IDENTITY="-" \
           CODE_SIGNING_REQUIRED=NO \
           OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
           build

echo ""
echo "=== Renaming to Disk Inventory Xs ==="
rm -rf "$BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app"
mv "$BUILD_DIR/Build/Products/Release/Disk Inventory X.app" "$BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app"

# Update the display name in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleName 'Disk Inventory Xs'" "$BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Disk Inventory Xs'" "$BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'Disk Inventory Xs'" "$BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app/Contents/Info.plist"

echo ""
echo "=== Re-signing framework ==="
codesign --force --sign - "$BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app/Contents/Frameworks/TreeMapView.framework"

echo ""
echo "=== Re-signing app ==="
codesign --force --sign - "$BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app"

echo ""
echo "Build complete!"
echo "App location: $BUILD_DIR/Build/Products/Release/Disk Inventory Xs.app"
