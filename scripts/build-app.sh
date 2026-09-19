#!/bin/sh
# Builds TMflash.app (release, this Mac's architecture) into build/.
#   scripts/build-app.sh            build
#   scripts/build-app.sh install    build and copy to /Applications
# The app finds the TMsense firmware at the path recorded here (the sibling
# ../TMsense), or wherever you point it with "Change…".
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
TMSENSE=$(cd "$ROOT/../TMsense" 2>/dev/null && pwd || true)
VERSION=1.0.0

swift build -c release --product TMflash
swift build -c release --product tmflash-cli
BIN=$(swift build -c release --show-bin-path)

APP="$ROOT/build/TMflash.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TMflash" "$APP/Contents/MacOS/TMflash"
# The CLI ships inside the app too: TMflash.app/Contents/MacOS/tmflash-cli.
cp "$BIN/tmflash-cli" "$APP/Contents/MacOS/tmflash-cli"

# Icon, rendered by the app itself.
ICONSET="$ROOT/build/TMflash.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$BIN/TMflash" --icon "$ROOT/build/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ROOT/build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/TMflash.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TMflash</string>
  <key>CFBundleDisplayName</key><string>TMflash</string>
  <key>CFBundleIdentifier</key><string>hk.hkumyseat.tmflash</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>TMflash</string>
  <key>CFBundleIconFile</key><string>TMflash</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>TMSenseDir</key><string>$TMSENSE</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on this Mac (and required on Apple silicon).
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "install" ]; then
  rm -rf /Applications/TMflash.app
  cp -R "$APP" /Applications/TMflash.app
  echo "installed /Applications/TMflash.app"
fi
