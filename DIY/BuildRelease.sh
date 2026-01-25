#!/bin/bash
#
# Build Disk Inventory Y (Swift version) for Release
#

set -e

cd "$(dirname "$0")"

echo "Building Disk Inventory Y (Swift)..."

xcodebuild -project DiskInventoryX.xcodeproj \
           -scheme DiskInventoryX \
           -configuration Release \
           -derivedDataPath build \
           CODE_SIGN_IDENTITY="-" \
           CODE_SIGNING_REQUIRED=NO \
           clean build

# Rename to Disk Inventory Y
rm -rf "build/Build/Products/Release/Disk Inventory Y.app"
mv "build/Build/Products/Release/DiskInventoryX.app" "build/Build/Products/Release/Disk Inventory Y.app"

# Update Info.plist with new name
/usr/libexec/PlistBuddy -c "Set :CFBundleName 'Disk Inventory Y'" "build/Build/Products/Release/Disk Inventory Y.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Disk Inventory Y'" "build/Build/Products/Release/Disk Inventory Y.app/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'Disk Inventory Y'" "build/Build/Products/Release/Disk Inventory Y.app/Contents/Info.plist"

# Re-sign the app
codesign --force --sign - "build/Build/Products/Release/Disk Inventory Y.app"

echo ""
echo "Build complete!"
echo "App location: build/Build/Products/Release/Disk Inventory Y.app"

# Verify architecture
echo ""
echo "Architecture:"
lipo -info "build/Build/Products/Release/Disk Inventory Y.app/Contents/MacOS/DiskInventoryX"
