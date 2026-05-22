#!/bin/sh
#
# Build a release of Disk Inventory Xs with a consistent code signature.
#
# Why this exists (issue #2):
#   The embedded TreeMapView.framework was ad-hoc signed at build time while
#   the .app was signed with a real Apple identity. Hardened Runtime refused
#   to load the framework because the Team IDs did not match, and the .app
#   crashed during dyld setup before reaching main().
#
# What this script does:
#   1. Build TreeMapView.framework from treemap/ (so we never ship a stale
#      pre-built binary).
#   2. Copy the freshly-built framework into src/Frameworks/ where the app's
#      project references it.
#   3. Build the app.
#   4. Re-sign the embedded framework and then the .app with the same
#      identity, using Hardened Runtime. This is explicit so we do not
#      depend on Xcode's CodeSignOnCopy behavior for nested binaries.
#   5. Verify the signature is internally consistent.
#
# Override the signing identity by exporting SIGN_IDENTITY before running:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./BuildRelease.sh
# The default is "-" (ad-hoc), which is enough to fix the crash for local
# builds but is not suitable for distribution. See NOTARIZATION.md for the
# distribution recipe.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TREEMAP_PROJECT="$REPO_ROOT/treemap/TreeMapView.xcodeproj"
APP_PROJECT="$SCRIPT_DIR/Disk Inventory X.xcodeproj"
FRAMEWORKS_DIR="$SCRIPT_DIR/Frameworks"
ENTITLEMENTS="$SCRIPT_DIR/Disk Inventory X.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Build with ad-hoc signing regardless of project settings; we re-sign with
# the real identity at the end. This means BuildRelease.sh works on machines
# that don't have the project's hard-coded development team certificate.
XCODEBUILD_SIGN_FLAGS="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES"

# Build arm64-only. The "s" in "Disk Inventory Xs" is for Silicon.
XCODEBUILD_ARCH_FLAGS="ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=NO"

echo "==> Building TreeMapView.framework"
rm -rf "$REPO_ROOT/treemap/build"
# shellcheck disable=SC2086
xcodebuild \
    -project "$TREEMAP_PROJECT" \
    -configuration Release \
    $XCODEBUILD_SIGN_FLAGS \
    $XCODEBUILD_ARCH_FLAGS \
    build

FRAMEWORK_BUILT_DIR="$(xcodebuild -project "$TREEMAP_PROJECT" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {print $2; exit}')"
FRAMEWORK_BUILT="$FRAMEWORK_BUILT_DIR/TreeMapView.framework"

if [ ! -d "$FRAMEWORK_BUILT" ]; then
    echo "error: framework not found at $FRAMEWORK_BUILT" >&2
    exit 1
fi

echo "==> Staging framework into $FRAMEWORKS_DIR/"
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$FRAMEWORKS_DIR/TreeMapView.framework"
cp -R "$FRAMEWORK_BUILT" "$FRAMEWORKS_DIR/"

echo "==> Building app"
rm -rf "$SCRIPT_DIR/build"
# shellcheck disable=SC2086
xcodebuild \
    -project "$APP_PROJECT" \
    -configuration Release \
    $XCODEBUILD_SIGN_FLAGS \
    $XCODEBUILD_ARCH_FLAGS \
    build

APP_BUILT_DIR="$(xcodebuild -project "$APP_PROJECT" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {print $2; exit}')"
APP_BUILT="$APP_BUILT_DIR/Disk Inventory X.app"

if [ ! -d "$APP_BUILT" ]; then
    echo "error: app not found at $APP_BUILT" >&2
    exit 1
fi

echo "==> Re-signing with identity: $SIGN_IDENTITY"
# Sign inner-out: framework first, then the .app.
codesign --force --options runtime \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUILT/Contents/Frameworks/TreeMapView.framework"

codesign --force --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUILT"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUILT"

echo "==> Done"
echo "    $APP_BUILT"
echo
echo "Framework Team ID:"
codesign -dvv "$APP_BUILT/Contents/Frameworks/TreeMapView.framework" 2>&1 | grep -E "TeamIdentifier|Authority|Signature" || true
echo "App Team ID:"
codesign -dvv "$APP_BUILT" 2>&1 | grep -E "TeamIdentifier|Authority|Signature" || true
