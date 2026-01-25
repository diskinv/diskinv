#!/bin/bash
#
# Build Disk Inventory X (Objective-C version) for Release
#

set -e

cd "$(dirname "$0")"

echo "Building Disk Inventory X..."

xcodebuild -project "Disk Inventory X.xcodeproj" \
           -scheme "Disk Inventory X" \
           -configuration Release \
           -derivedDataPath build \
           CODE_SIGN_IDENTITY="-" \
           CODE_SIGNING_REQUIRED=NO \
           clean build

echo ""
echo "Build complete!"
echo "App location: build/Build/Products/Release/Disk Inventory X.app"
