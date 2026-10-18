#!/bin/bash
# Installs Kestrel for this Mac user: the client, this device's key, and the
# `kestrel` command (on, off, status). Nothing runs until `kestrel on`.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOME_DIR="$HOME/.kestrel"
BIN="$HOME/.local/bin"

[[ -f "$HERE/kestrel-client" ]] || { echo "kestrel-client is missing from this download."; exit 1; }
mkdir -p "$HOME_DIR" "$BIN"
chmod 700 "$HOME_DIR"
install -m 0755 "$HERE/kestrel-client" "$HOME_DIR/kestrel-client"
install -m 0600 "$HERE/kestrel.yaml" "$HOME_DIR/kestrel.yaml"
install -m 0755 "$HERE/kestrel" "$BIN/kestrel"
# Downloaded files are quarantined; this one is ours.
xattr -dr com.apple.quarantine "$HOME_DIR" "$BIN/kestrel" 2>/dev/null || true

cat > "$HOME/Library/LaunchAgents/dev.mandip.kestrel.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.mandip.kestrel</string>
  <key>ProgramArguments</key><array>
    <string>$HOME_DIR/kestrel-client</string><string>--config</string><string>$HOME_DIR/kestrel.yaml</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$HOME_DIR/client.log</string>
  <key>StandardOutPath</key><string>$HOME_DIR/client.log</string>
</dict></plist>
PLIST

if ! echo ":$PATH:" | grep -q ":$BIN:"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  export PATH="$BIN:$PATH"
fi
echo "Kestrel is installed. Turn it on with:  kestrel on"
echo "(open a new Terminal window first if 'kestrel' isn't found)"
