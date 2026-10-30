#!/bin/bash
# Builds the app and the disk image to send around, and puts them in a folder on the Desktop.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
cp build/icon.png Distribution/icon.png 2>/dev/null || true
sips -z 80 80 build/icon.png --out Distribution/icon-small.png >/dev/null
GUIDE="build/Zuerst lesen – Read me first.pdf"
xcrun swift Distribution/html2pdf.swift Distribution/guide.html "$GUIDE" 2>/dev/null
rm -f Distribution/icon.png

STAGE=build/dmg
rm -rf "$STAGE" build/Mixtape.dmg
mkdir -p "$STAGE"
ditto build/Mixtape.app "$STAGE/Mixtape.app"
ln -s /Applications "$STAGE/Programme (Applications)"
cp "$GUIDE" "$STAGE/"
hdiutil create -volname "Mixtape" -srcfolder "$STAGE" -format UDZO -ov build/Mixtape.dmg >/dev/null

OUT="$HOME/Desktop/Mixtape zum Verschicken"
mkdir -p "$OUT"
cp build/Mixtape.dmg "$GUIDE" "Distribution/Nachricht an Freunde.txt" "$OUT/"
echo "Packaged into $OUT"
