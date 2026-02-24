#!/bin/bash
#
# Build Disk Inventory X (Swift version) for Release
#

set -e

cd "$(dirname "$0")"

echo "Building Disk Inventory X (Swift)..."

xcodebuild -project DiskInventoryX.xcodeproj \
           -scheme DiskInventoryX \
           -configuration Release \
           -derivedDataPath build \
           clean build

echo ""
echo "Build complete!"
echo "App location: build/Build/Products/Release/DiskInventoryX.app"

# Verify universal binary
echo ""
echo "Architecture:"
lipo -info "build/Build/Products/Release/DiskInventoryX.app/Contents/MacOS/DiskInventoryX"
