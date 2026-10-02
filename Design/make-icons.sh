#!/bin/sh
# Regenerates the placeholder icons in Kubar/Assets.xcassets from the SVGs here. Needs rsvg-convert (brew install librsvg).
set -e
cd "$(dirname "$0")"
APP=../Kubar/Assets.xcassets/AppIcon.appiconset
BAR=../Kubar/Assets.xcassets/MenuBarIcon.imageset
mkdir -p "$APP" "$BAR"
for s in 16 32 64 128 256 512 1024; do rsvg-convert -w $s -h $s app-icon.svg -o "$APP/icon_$s.png"; done
for s in 18 36 54; do rsvg-convert -w $s -h $s menubar-icon.svg -o "$BAR/menubar_$s.png"; done
cat > "$APP/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$BAR/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "menubar_18.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "menubar_36.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "menubar_54.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
