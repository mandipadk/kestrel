#!/bin/bash
# Checks that a built Kestrel.app can update itself: Sparkle is embedded and
# signed by our team, and the app trusts only our signed feed and key.
#
#   check-update.sh <path to Kestrel.app> <public EdDSA key, base64>
set -uo pipefail

APP=${1:?usage: check-update.sh <Kestrel.app> <public key>}
KEY=${2:?usage: check-update.sh <Kestrel.app> <public key>}
TEAM=UK74VYMUP7
FEED=https://github.com/mandipadk/kestrel/releases/download/mac-latest/appcast.xml
INFO="$APP/Contents/Info.plist"
FW="$APP/Contents/Frameworks/Sparkle.framework"
failed=0

ok() { echo "ok    $1"; }
bad() { echo "::error::$1"; echo "FAIL  $1"; failed=1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }

[[ $(plist "$INFO" SUFeedURL) == "$FEED" ]] && ok "feed $FEED" || bad "SUFeedURL is '$(plist "$INFO" SUFeedURL)', want $FEED"
[[ $(plist "$INFO" SUPublicEDKey) == "$KEY" ]] && ok "trusts the release key" \
  || bad "SUPublicEDKey doesn't match the key CI signs updates with"
[[ $(plist "$INFO" SURequireSignedFeed) == true ]] && ok "requires a signed feed" || bad "SURequireSignedFeed is not true"
[[ $(plist "$INFO" SUVerifyUpdateBeforeExtraction) == true ]] && ok "verifies updates before opening them" \
  || bad "SUVerifyUpdateBeforeExtraction is not true"
[[ $(plist "$INFO" CFBundleVersion) =~ ^[0-9]+$ ]] && ok "build number $(plist "$INFO" CFBundleVersion)" \
  || bad "CFBundleVersion '$(plist "$INFO" CFBundleVersion)' is not a whole number, so updates can't be ordered"

[[ -d "$FW" ]] && ok "Sparkle.framework embedded" || { bad "no Sparkle.framework in $APP/Contents/Frameworks"; exit 1; }
for code in "$FW" "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"; do
  name=${code#"$APP/"}
  [[ -e "$code" ]] || { bad "$name is missing"; continue; }
  [[ $(team "$code") == "$TEAM" ]] && ok "$name signed by $TEAM" || bad "$name is signed by '$(team "$code")', not $TEAM"
  codesign -dv "$code" 2>&1 | grep -q 'flags=.*runtime' && ok "$name has the hardened runtime" || bad "$name lacks the hardened runtime"
done
codesign --verify --deep --strict "$APP" && ok "whole bundle verifies" || bad "codesign --verify --deep --strict fails"

exit $failed
