#!/bin/zsh
# Builds the release app and wraps it in MacMiga.app with its icon.
# Usage: Bundle/make-app.sh   → .build/MacMiga.app
set -e
cd "$(dirname "$0")/.."

swift build -c release --product MacMiga

app=.build/MacMiga.app
work=.build/icon
rm -rf "$app" "$work"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$work/AppIcon.iconset"

swift Bundle/MakeIcon.swift "$work/AppIcon.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$work/AppIcon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
    sips -z $((s * 2)) $((s * 2)) "$work/AppIcon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

cp .build/release/MacMiga "$app/Contents/MacOS/MacMiga"
cp Bundle/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
