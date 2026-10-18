#!/bin/bash
# Updates an older Kestrel with Sparkle, the way the owner's Mac will, and
# checks that a feed someone has tampered with is refused.
#
#   test-update.sh <new Kestrel.app> <sparkle-cli> <feed url> <tampered feed url>
#
# The "older Kestrel" is the new app with its build number set to 1 and
# re-signed with the same Developer ID, so Sparkle sees a real update from
# the same team.
set -euo pipefail

NEW=${1:?usage}; CLI=${2:?usage}; FEED=${3:?usage}; TAMPERED=${4:?usage}
WANT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$NEW/Contents/Info.plist")
WORK=$(mktemp -d)
OLD="$WORK/Kestrel.app"
ditto "$NEW" "$OLD"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1" -c "Set :CFBundleShortVersionString 1.0" "$OLD/Contents/Info.plist"
codesign --force --sign "Developer ID Application" --options runtime --timestamp \
  --preserve-metadata=entitlements,requirements,flags "$OLD"
codesign --verify --strict "$OLD"
version() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$OLD/Contents/Info.plist"; }
cli() { "$CLI" "$OLD" --user-agent-name "Kestrel CI" --verbose "$@"; }

echo "== a feed changed after it was signed is refused"
rc=0; cli --check-immediately --feed-url "$TAMPERED" || rc=$?
[[ $(version) == 1 ]] || { echo "::error::Sparkle installed an update from a tampered feed"; exit 1; }
echo "ok    tampered feed refused (sparkle-cli exit $rc), still build 1"

echo "== the real feed offers build $WANT"
cli --probe --feed-url "$FEED" || { echo "::error::Sparkle found no update in $FEED"; exit 1; }
echo "ok    update found"

echo "== and installs it"
cli --check-immediately --feed-url "$FEED"
[[ $(version) == "$WANT" ]] || { echo "::error::after updating, the app is build $(version), want $WANT"; exit 1; }
codesign --verify --deep --strict "$OLD"
spctl --assess --type execute -vv "$OLD"
echo "ok    updated from build 1 to $WANT; signature and Gatekeeper pass"
rm -rf "$WORK"
