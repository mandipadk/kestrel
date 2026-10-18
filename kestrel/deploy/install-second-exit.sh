#!/usr/bin/env bash
# One-time root setup for a second Kestrel exit (Chicago). Idempotent.
#   install-second-exit.sh <city> <country code>
# Frankfurt stays the authority: this exit runs Frankfurt's release
# (follow.sh, daily) and its device list (pull-devices.sh, every minute).
# Expects the repo cloned at ~ubuntu/kestrel-exit, and ubuntu able to
# `ssh frankfurt`. Prints this exit's public key at the end.
set -euo pipefail
CITY=${1:?usage: install-second-exit.sh <city> <country code>}
COUNTRY=${2:?usage: install-second-exit.sh <city> <country code>}
SRC=$(cd "$(dirname "$0")" && pwd)
K=$(cd "$SRC/.." && pwd)
as_ubuntu() { sudo -u ubuntu -H "$@"; }

id kestrel >/dev/null 2>&1 || useradd --system --home-dir /var/lib/kestrel --shell /usr/sbin/nologin kestrel
usermod -aG kestrel ubuntu
install -d -o ubuntu -g kestrel -m 0755 /opt/kestrel /opt/kestrel/releases
install -d -o root -g kestrel -m 0750 /etc/kestrel
install -d -o kestrel -g kestrel -m 2770 /var/lib/kestrel /var/lib/kestrel/reports
if [[ ! -f /etc/kestrel/exit.yaml ]]; then
  sed -e "s/^country: .*/country: $COUNTRY/" -e "s/^city: .*/city: $CITY/" "$SRC/exit.yaml" > /etc/kestrel/exit.yaml
  chown root:kestrel /etc/kestrel/exit.yaml; chmod 0640 /etc/kestrel/exit.yaml
fi
if [[ ! -s /var/lib/kestrel/signing.key ]]; then
  head -c 32 /dev/urandom > /var/lib/kestrel/signing.key
fi
chown kestrel:kestrel /var/lib/kestrel/signing.key; chmod 0640 /var/lib/kestrel/signing.key

# the device list and the live-test probe key come from Frankfurt
as_ubuntu "$K/pull-devices.sh"
as_ubuntu ssh -o BatchMode=yes frankfurt cat /var/lib/kestrel/probe.yaml > /var/lib/kestrel/probe.yaml
chown ubuntu:kestrel /var/lib/kestrel/probe.yaml; chmod 0600 /var/lib/kestrel/probe.yaml
chown kestrel:kestrel /var/lib/kestrel/devices.json; chmod 0660 /var/lib/kestrel/devices.json

# the release Frankfurt runs
if [[ ! -e /opt/kestrel/current ]]; then
  SHA=$(as_ubuntu ssh -o BatchMode=yes frankfurt 'basename "$(readlink -f /opt/kestrel/current)"')
  [[ $SHA =~ ^[0-9a-f]{12}$ ]]
  install -d -o ubuntu -g kestrel -m 0755 "/opt/kestrel/releases/$SHA"
  for b in geph5-exit geph5-client kestrelctl; do
    as_ubuntu scp -q -o BatchMode=yes "frankfurt:/opt/kestrel/releases/$SHA/$b" "/opt/kestrel/releases/$SHA/$b"
  done
  chmod 0755 /opt/kestrel/releases/$SHA/*
  ln -sfn "releases/$SHA" /opt/kestrel/current
  ln -sfn "releases/$SHA" /opt/kestrel/last-good
  chown -h ubuntu:kestrel /opt/kestrel/current /opt/kestrel/last-good
fi

install -o root -g root -m 0755 "$SRC/kestrel-firewall" /usr/local/sbin/kestrel-firewall
install -o root -g root -m 0440 "$SRC/sudoers" /etc/sudoers.d/kestrel
visudo -cf /etc/sudoers.d/kestrel
for u in geph-exit.service kestrel-devices.service kestrel-devices.timer kestrel-follow.service kestrel-follow.timer; do
  install -o root -g root -m 0644 "$SRC/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now geph-exit.service kestrel-devices.timer kestrel-follow.timer
sleep 3
systemctl --no-pager --lines=5 status geph-exit.service || true
/usr/local/sbin/kestrel-firewall check
echo "exit public key: $(/opt/kestrel/current/kestrelctl --signing-secret /var/lib/kestrel/signing.key pubkey)"
