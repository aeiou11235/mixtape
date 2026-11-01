#!/bin/bash
# Builds build/Mixtape.app (ad-hoc signed, universal: Apple Silicon + Intel, macOS 14.4+).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Mixtape.app
BIN="$APP/Contents/MacOS/Mixtape"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --show-sdk-path --sdk macosx)"
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -target $ARCH-apple-macos14.4 -sdk "$SDK" \
        Sources/*.swift -o "build/Mixtape-$ARCH"
done
lipo -create build/Mixtape-arm64 build/Mixtape-x86_64 -output "$BIN"
rm build/Mixtape-arm64 build/Mixtape-x86_64

cp Info.plist "$APP/Contents/Info.plist"
# Share links: the upload address and key come from Share/app.env, which stays out of git.
if [ -f Share/app.env ]; then
    . Share/app.env
    # Builds to give away (MIXTAPE_PUBLIC=1, as package.sh makes them) carry the public key,
    # whose links run out after a week; this Mac's own build keeps its links.
    # It is called "Mixtape Master", so the two can't be mixed up.
    if [ "${MIXTAPE_PUBLIC:-0}" = 1 ]; then
        MIXTAPE_SHARE_KEY=$MIXTAPE_SHARE_KEY_PUBLIC
    else
        /usr/libexec/PlistBuddy -c "Set :CFBundleName Mixtape Master" -c "Set :CFBundleDisplayName Mixtape Master" "$APP/Contents/Info.plist"
    fi
    /usr/libexec/PlistBuddy -c "Add :MixtapeShareUpload string $MIXTAPE_SHARE_UPLOAD" -c "Add :MixtapeShareKey string $MIXTAPE_SHARE_KEY" "$APP/Contents/Info.plist"
fi
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/startbild.jpg Resources/aeiou-logo.png "$APP/Contents/Resources/"   # the About screen
cp Player/player.html "$APP/Contents/Resources/player.html"   # the web-page player for "Send as Web Page"
cp Resources/emboss-glyphs.json "$APP/Contents/Resources/"    # the label-tape letters, for the app and the web page
# The share server plays every link with its own copy of the player, so links sent earlier get fixes too.
python3 -c 'import json,sys; t=open("Player/player.html").read(); g=json.dumps(json.load(open("Resources/emboss-glyphs.json")),ensure_ascii=False,separators=(",",":")); open("Share/php/player.html","w").write(t.replace("__GLYPHS_JSON__",g))'
[ -d Share/deploy/mixtape.toyko.online ] && cp Share/php/player.html Share/php/index.php Share/php/.htaccess Share/deploy/mixtape.toyko.online/

# App and document icon, rendered from the cassette itself.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$BIN" --icon build/icon.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc, but identified by bundle ID rather than by hash, so macOS keeps the
# microphone and system-audio permissions across rebuilds.
codesign --force --sign - --identifier app.mixtape.deck -r='designated => identifier "app.mixtape.deck"' "$APP"
echo "Built $APP"
