#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"
app="$script_dir/build/Release/Disk Inventory Xs.app"
contents="$app/Contents"

swift build --package-path "$repo_dir" -c release
binary_dir="$(swift build --package-path "$repo_dir" -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_dir/DiskInventoryXs" "$contents/MacOS/Disk Inventory Xs"
cp "$script_dir/Info.plist" "$contents/Info.plist"

plutil -replace CFBundleExecutable -string "Disk Inventory Xs" "$contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.derlien.DiskInventoryX" "$contents/Info.plist"
plutil -replace CFBundleName -string "Disk Inventory Xs" "$contents/Info.plist"
plutil -replace CFBundleIconFile -string "AppIcon.png" "$contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "14.0" "$contents/Info.plist"

cp "$script_dir/Assets.xcassets/AppIcon.appiconset/DIXIcon 256@2.png" \
  "$contents/Resources/AppIcon.png"

codesign --force --deep --options runtime \
  --entitlements "$script_dir/DiskInventoryX.entitlements" \
  --sign "${SIGN_IDENTITY:--}" \
  "$app"

codesign --verify --deep --strict "$app"
echo "$app"
