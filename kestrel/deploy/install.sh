#!/usr/bin/env bash
# One-time root setup for Kestrel on this server. Idempotent.
# Expects a built release at /opt/kestrel/current (see kestrel/sync.sh --install-only).
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)

id kestrel >/dev/null 2>&1 || useradd --system --home-dir /var/lib/kestrel --shell /usr/sbin/nologin kestrel
usermod -aG kestrel ubuntu

install -d -o ubuntu -g kestrel -m 0755 /opt/kestrel /opt/kestrel/releases
install -d -o root -g kestrel -m 0750 /etc/kestrel
install -d -o kestrel -g kestrel -m 2770 /var/lib/kestrel /var/lib/kestrel/reports
[[ -f /etc/kestrel/exit.yaml ]] || install -o root -g kestrel -m 0640 "$SRC/exit.yaml" /etc/kestrel/exit.yaml
if [[ ! -s /var/lib/kestrel/signing.key ]]; then
  head -c 32 /dev/urandom > /var/lib/kestrel/signing.key
fi
chown kestrel:kestrel /var/lib/kestrel/signing.key
chmod 0640 /var/lib/kestrel/signing.key
[[ -f /var/lib/kestrel/devices.json ]] || echo '{"devices":[]}' > /var/lib/kestrel/devices.json
chown kestrel:kestrel /var/lib/kestrel/devices.json
chmod 0660 /var/lib/kestrel/devices.json

if [[ ! -e /opt/kestrel/current ]]; then
  REPO=$(cd "$SRC/../.." && pwd)
  SHA=$(git -C "$REPO" rev-parse --short=12 HEAD)
  install -d -o ubuntu -g kestrel -m 0755 "/opt/kestrel/releases/$SHA"
  for b in geph5-exit geph5-client kestrelctl; do
    install -o ubuntu -g kestrel -m 0755 "$REPO/target/release/$b" "/opt/kestrel/releases/$SHA/$b"
  done
  ln -sfn "releases/$SHA" /opt/kestrel/current
  ln -sfn "releases/$SHA" /opt/kestrel/last-good
  chown -h ubuntu:kestrel /opt/kestrel/current /opt/kestrel/last-good
fi

install -o root -g root -m 0755 "$SRC/kestrel-firewall" /usr/local/sbin/kestrel-firewall
install -o root -g root -m 0440 "$SRC/sudoers" /etc/sudoers.d/kestrel
visudo -cf /etc/sudoers.d/kestrel

for u in geph-exit.service geph-upstream-sync.service geph-upstream-sync.timer geph-security-review.service geph-security-review.timer; do
  install -o root -g root -m 0644 "$SRC/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now geph-exit.service
systemctl enable --now geph-upstream-sync.timer geph-security-review.timer
sleep 3
systemctl --no-pager --lines=5 status geph-exit.service || true
/usr/local/sbin/kestrel-firewall check
