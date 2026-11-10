#!/bin/bash
# Builds build/Appauled.app and build/Appauled.zip. No downloads, no dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Appauled.app"
CARTOON="$ROOT/Resources/tony-cartoon.png"   # made once by Image Playground, then reused

mkdir -p "$BUILD"

# Sign with Paul's own certificate when it's in the keychain. That gives every build the same
# identity, so macOS keeps Tony's permissions across updates and the app can verify its updates.
# Without it, fall back to a throwaway signature (the app runs, but can't update itself).
SIGN_NAME="Appauled Signing"
if security find-certificate -c "$SIGN_NAME" >/dev/null 2>&1; then SIGN="$SIGN_NAME"; else SIGN="-"; fi

# 1. Compile.
echo "→ Building app"
swift build -c release --package-path "$ROOT" --arch arm64
BIN="$(swift build -c release --package-path "$ROOT" --arch arm64 --show-bin-path)/Appauled"

# 2. Assemble the bundle.
echo "→ Assembling Appauled.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Appauled"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Version: the number in the VERSION file (what Tony sees in About), plus a build number from the clock.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN" --timestamp=none "$APP"

# 3. Cartoon Tony + icon (Image Playground runs on this Mac; falls back to the photo).
echo "→ Drawing icon (cartoon Tony via Image Playground)"
# Image Playground only runs in a foreground app, so launch the bundle normally.
rm -f "$BUILD/icon-1024.png"
# A finished icon in Resources wins (Paul, appalled at a receipt, drawn by an image model);
# otherwise the app draws its own.
if [ -f "$ROOT/Resources/icon-1024.png" ]; then cp "$ROOT/Resources/icon-1024.png" "$BUILD/icon-1024.png"; fi
[ -f "$BUILD/icon-1024.png" ] || open -W -n "$APP" --args --make-icon "$BUILD/icon-1024.png" --cartoon "$ROOT/Resources/tony-avatar.png" || true
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
# The banner pictures: a dozen starters, and Tony's photo, which every new drawing is made from.
cp "$ROOT/Resources/tony.jpg" "$APP/Contents/Resources/tony.jpg"
if [ -f "$ROOT/Resources/paul.jpg" ]; then cp "$ROOT/Resources/paul.jpg" "$APP/Contents/Resources/paul.jpg"; fi
cp "$ROOT/Resources/tony-avatar.png" "$APP/Contents/Resources/tony-avatar.png"
if [ -f "$ROOT/Resources/paul-avatar.png" ]; then cp "$ROOT/Resources/paul-avatar.png" "$APP/Contents/Resources/paul-avatar.png"; fi
mkdir -p "$APP/Contents/Resources/Starters" && cp "$ROOT/Resources/Starters/"* "$APP/Contents/Resources/Starters/"
mkdir -p "$APP/Contents/Resources/Art" && cp "$ROOT/Resources/Art/"* "$APP/Contents/Resources/Art/"

# 4. Re-sign after adding resources. First drop "downloaded from the internet" marks and other
#    Finder leftovers that source files may carry; they don't belong in a shipped app.
xattr -cr "$APP"
codesign --force --sign "$SIGN" --timestamp=none "$APP"

# 5. Zip for AirDrop / USB.
rm -f "$BUILD/Appauled.zip"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$BUILD/Appauled.zip"

echo "✓ Built $APP (signed: $SIGN)"
echo "✓ Zipped $BUILD/Appauled.zip (version $VERSION)"
if [ ! -f "$CARTOON" ]; then
  echo "ℹ︎ No cartoon yet (Apple Intelligence unavailable here). The app will make one on first launch."
fi
