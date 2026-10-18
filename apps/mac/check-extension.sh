#!/bin/bash
# Checks a built Kestrel.app the way macOS's sysextd will when it installs
# the tunnel, so a broken system extension fails CI instead of the owner's Mac.
#
#   check-extension.sh <path to Kestrel.app>
set -uo pipefail

APP=${1:?usage: check-extension.sh <Kestrel.app>}
ID=dev.mandip.kestrel.tunnel
EXT="$APP/Contents/Library/SystemExtensions/$ID.systemextension"
PROVIDER=KestrelTunnel.PacketTunnelProvider
NE=packet-tunnel-provider-systemextension
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failed=0

ok() { echo "ok    $1"; }
bad() { echo "::error::$1"; echo "FAIL  $1"; failed=1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# where macOS looks: <app>/Contents/Library/SystemExtensions/<bundle id>.systemextension
[[ -d "$EXT" ]] && ok "extension sits in Contents/Library/SystemExtensions as $ID.systemextension" \
  || { bad "no $ID.systemextension in $APP/Contents/Library/SystemExtensions"; exit 1; }

INFO="$EXT/Contents/Info.plist"
[[ $(plist "$INFO" CFBundlePackageType) == SYSX ]] && ok "package type SYSX" \
  || bad "extension package type is '$(plist "$INFO" CFBundlePackageType)', macOS needs SYSX to give it a category"
# network extensions also need a usage description in their own Info.plist
[[ -n $(plist "$INFO" NSSystemExtensionUsageDescription) ]] && ok "extension has NSSystemExtensionUsageDescription" \
  || bad "extension Info.plist has no NSSystemExtensionUsageDescription; sysextd refuses network extensions without it"
[[ $(plist "$INFO" CFBundleIdentifier) == "$ID" ]] && ok "bundle id $ID" \
  || bad "extension bundle id is '$(plist "$INFO" CFBundleIdentifier)'"
BIN="$EXT/Contents/MacOS/$(plist "$INFO" CFBundleExecutable)"
[[ -x "$BIN" ]] && ok "executable $(basename "$BIN")" || bad "extension executable $BIN missing"

# NetworkExtension > NEProviderClasses > packet-tunnel, pointing at a class the binary has
CLASS=$(plist "$INFO" "NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel")
[[ "$CLASS" == "$PROVIDER" ]] && ok "packet-tunnel provider class $CLASS" \
  || bad "NetworkExtension > NEProviderClasses > com.apple.networkextension.packet-tunnel is '$CLASS', want $PROVIDER"
MODULE=${PROVIDER%%.*}; NAME=${PROVIDER#*.}
MANGLED="_TtC${#MODULE}${MODULE}${#NAME}${NAME}"
# release binaries are stripped, but the Objective-C runtime name stays in __objc_classname
if grep -aq "$MANGLED" "$BIN"; then ok "binary defines $PROVIDER ($MANGLED)"
else bad "the extension binary has no Objective-C class $MANGLED for $PROVIDER"; fi
MACH=$(plist "$INFO" NetworkExtension:NEMachServiceName)
[[ -n "$MACH" ]] && ok "NEMachServiceName $MACH" || bad "no NetworkExtension > NEMachServiceName"

# entitlements as signed, and as allowed by each embedded profile
ents() { codesign -d --entitlements :- "$1" 2>/dev/null > "$2"; }
ents "$APP" "$TMP/app.plist"
ents "$EXT" "$TMP/ext.plist"
# PlistBuddy, since plutil key paths split the dots in entitlement names
has_ne() { plist "$1" com.apple.developer.networking.networkextension | grep -qx "[[:space:]]*$NE"; }
for who in app ext; do
  has_ne "$TMP/$who.plist" && ok "$who signed with networkextension = [$NE]" \
    || bad "$who is not signed with com.apple.developer.networking.networkextension = [$NE]"
done
[[ $(plist "$TMP/app.plist" com.apple.developer.system-extension.install) == true ]] \
  && ok "app may install system extensions" || bad "app lacks com.apple.developer.system-extension.install"
[[ $(plist "$TMP/ext.plist" com.apple.security.app-sandbox) == true ]] \
  && ok "extension sandboxed" || bad "extension is not sandboxed"
APP_GROUPS=$(plist "$TMP/ext.plist" com.apple.security.application-groups | grep -v '[{}]' | xargs)
prefixed=0
for g in $APP_GROUPS; do [[ "$MACH" == "$g"* ]] && prefixed=1; done
(( prefixed )) && ok "NEMachServiceName is under app group ($APP_GROUPS)" \
  || bad "NEMachServiceName $MACH does not start with one of the extension's app groups ($APP_GROUPS)"
for who in "$APP" "$EXT"; do
  PROFILE="$who/Contents/embedded.provisionprofile"
  if [[ -f "$PROFILE" ]] && security cms -D -i "$PROFILE" > "$TMP/profile.plist" 2>/dev/null; then
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$TMP/profile.plist" > "$TMP/allowed.plist"
    has_ne "$TMP/allowed.plist" && ok "$(basename "$who") profile allows $NE" \
      || bad "$(basename "$who")'s provisioning profile does not allow $NE"
  else
    bad "$(basename "$who") has no readable embedded.provisionprofile"
  fi
done

# signatures: Developer ID, one team, hardened runtime, valid
for who in "$APP" "$EXT"; do
  codesign -dvv "$who" > "$TMP/sig.txt" 2>&1
  grep -q '^Authority=Developer ID Application:' "$TMP/sig.txt" && ok "$(basename "$who") signed with Developer ID" \
    || bad "$(basename "$who") is not signed with a Developer ID Application certificate"
  grep -q 'flags=.*runtime' "$TMP/sig.txt" && ok "$(basename "$who") hardened runtime" \
    || bad "$(basename "$who") lacks the hardened runtime"
  grep '^TeamIdentifier=' "$TMP/sig.txt" >> "$TMP/teams.txt"
done
[[ $(sort -u "$TMP/teams.txt" | wc -l) -eq 1 ]] && ok "one team: $(head -1 "$TMP/teams.txt" | cut -d= -f2)" \
  || bad "app and extension are signed by different teams"
codesign --verify --deep --strict "$APP" 2>/dev/null && ok "signature verifies (deep, strict)" || bad "codesign --verify failed"

exit $failed
