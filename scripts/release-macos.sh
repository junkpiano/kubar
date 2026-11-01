#!/bin/sh
# Build, sign (Developer ID), notarize and staple Kubar.dmg. Run on a Mac with Xcode.
# TEAM_ID=XXXXXXXXXX scripts/release-macos.sh
# Needs a "Developer ID Application" certificate in the keychain and a notarytool profile:
#   xcrun notarytool store-credentials kubar --apple-id <id> --team-id "$TEAM_ID" --password <app-specific>
set -eu
: "${TEAM_ID:?set TEAM_ID to your Apple Developer Team ID}"
PROFILE=${NOTARY_PROFILE:-kubar}
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

xcodebuild -project Kubar.xcodeproj -scheme Kubar -configuration Release \
  -archivePath "$OUT/Kubar.xcarchive" DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Kubar.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT"

mkdir "$OUT/dmg" && cp -R "$OUT/Kubar.app" "$OUT/dmg/" && ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname Kubar -srcfolder "$OUT/dmg" -format UDZO -ov "$OUT/Kubar.dmg"
codesign --sign "Developer ID Application" --timestamp "$OUT/Kubar.dmg"

xcrun notarytool submit "$OUT/Kubar.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Kubar.dmg"
spctl --assess --type open --context context:primary-signature -v "$OUT/Kubar.dmg"
echo "$OUT/Kubar.dmg"
