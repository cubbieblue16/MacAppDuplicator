#!/bin/bash
# Renders App/Icon/AppIcon.svg to App/Resources/AppIcon.icns and the AppIcon.appiconset.
# Uses rsvg-convert when installed, otherwise Tools/render-svg.swift (AppKit) + /usr/bin/sips.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$REPO/App/Icon/AppIcon.svg"
RES="$REPO/App/Resources"
APPICONSET="$RES/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mad-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MASTER="$WORK/master-1024.png"
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 -o "$MASTER" "$SVG"
else
  # AppKit renders the SVG with a real alpha channel. (qlmanage flattens the area
  # outside the icon body to opaque white, which shipped in 0.8.1 and earlier.)
  swift "$REPO/Tools/render-svg.swift" "$SVG" "$MASTER" 1024
fi

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$APPICONSET" "$RES"

# name:pixels pairs for the iconset (iconutil) and the asset catalog (same PNGs).
declare -a ENTRIES=(
  "icon_16x16:16" "icon_16x16@2x:32"
  "icon_32x32:32" "icon_32x32@2x:64"
  "icon_128x128:128" "icon_128x128@2x:256"
  "icon_256x256:256" "icon_256x256@2x:512"
  "icon_512x512:512" "icon_512x512@2x:1024"
)
for entry in "${ENTRIES[@]}"; do
  name="${entry%%:*}"; px="${entry##*:}"
  if [ "$px" = "1024" ]; then
    cp "$MASTER" "$ICONSET/$name.png"
  else
    /usr/bin/sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
  fi
  cp "$ICONSET/$name.png" "$APPICONSET/$name.png"
done

/usr/bin/iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$RES/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "wrote $RES/AppIcon.icns and $APPICONSET"
