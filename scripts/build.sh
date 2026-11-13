#!/bin/bash
# Builds build/Spendthrift.app and build/Spendthrift.zip. No downloads, no dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Spendthrift.app"
CARTOON="$ROOT/Resources/tony-cartoon.png"

mkdir -p "$BUILD"

# Sign with your own certificate when it's in the keychain. That gives every build the same identity,
# so macOS keeps permissions such as Downloads access from one build to the next.
# Without it, fall back to a throwaway signature (the app runs; macOS asks again after each build).
SIGN_NAME="Spendthrift Signing"
if security find-certificate -c "$SIGN_NAME" >/dev/null 2>&1; then SIGN="$SIGN_NAME"; else SIGN="-"; fi

# 1. Compile.
echo "→ Building app"
swift build -c release --package-path "$ROOT" --arch arm64
BIN="$(swift build -c release --package-path "$ROOT" --arch arm64 --show-bin-path)/Spendthrift"

# 2. Assemble the bundle.
echo "→ Assembling Spendthrift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spendthrift"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# There are no version numbers: everyone builds their own, so a build is known by the day it was made.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(date +%Y.%m.%d)" -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN" --timestamp=none "$APP"

# 3. Icon.
rm -f "$BUILD/icon-1024.png"
if [ -f "$ROOT/Resources/icon-1024.png" ]; then cp "$ROOT/Resources/icon-1024.png" "$BUILD/icon-1024.png"; fi
if [ -f "$BUILD/icon-1024.png" ]; then
  ICONSET="$BUILD/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f "$CARTOON" ]; then cp "$CARTOON" "$APP/Contents/Resources/tony-cartoon.png"; fi
# The banner pictures: a dozen starters, and the main photo, which every new drawing is made from.
cp "$ROOT/Resources/tony.jpg" "$APP/Contents/Resources/tony.jpg"
if [ -f "$ROOT/Resources/paul.jpg" ]; then cp "$ROOT/Resources/paul.jpg" "$APP/Contents/Resources/paul.jpg"; fi
cp "$ROOT/Resources/tony-avatar.png" "$APP/Contents/Resources/tony-avatar.png"
mkdir -p "$APP/Contents/Resources/Starters" && cp "$ROOT/Resources/Starters/"* "$APP/Contents/Resources/Starters/"
mkdir -p "$APP/Contents/Resources/Art" && cp "$ROOT/Resources/Art/"* "$APP/Contents/Resources/Art/"

# 4. Re-sign after adding resources. First drop "downloaded from the internet" marks and other
#    Finder leftovers that source files may carry; they don't belong in a shipped app.
xattr -cr "$APP"
codesign --force --sign "$SIGN" --timestamp=none "$APP"

# 5. Zip for AirDrop / USB.
rm -f "$BUILD/Spendthrift.zip"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$BUILD/Spendthrift.zip"

echo "✓ Built $APP (signed: $SIGN)"
echo "✓ Zipped $BUILD/Spendthrift.zip"
