#!/bin/zsh
# Build a Universal app. --release also notarizes, staples, and archives it.
# SIGN_ID and NOTARY_PROFILE may override the local signing credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

release="${1:-}"
sign_id="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
if [[ "$release" == "--release" && ( -z "$sign_id" || "$sign_id" == "-" ) ]]; then
    echo "A release requires a Developer ID Application identity." >&2
    exit 1
fi

swift build -c release --product MacMiga --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacMiga"
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

cp "$bin" "$app/Contents/MacOS/MacMiga"
cp Bundle/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
if [[ -n "$sign_id" && "$sign_id" != "-" ]]; then
    codesign --force --options runtime --timestamp --sign "$sign_id" "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
architectures="$(lipo -archs "$app/Contents/MacOS/MacMiga")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
    echo "Release binary is not Universal: $architectures" >&2
    exit 1
}
echo "Built $app"

if [[ "$release" == "--release" ]]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
    archive=".build/MacMiga-${version}-universal.zip"
    rm -f "$archive"
    ditto -c -k --keepParent "$app" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "${NOTARY_PROFILE:-App Store Connect Profile}" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --verbose=2 --type execute "$app"
    rm -f "$archive"
    ditto -c -k --keepParent "$app" "$archive"
    (cd .build && shasum -a 256 "${archive:t}" > SHA256SUMS.txt)
    echo "Notarized and stapled: $archive"
fi
