# Kestrel

Kestrel is our private variation of [Geph5](https://github.com/geph-official/geph5):
a self-hosted exit on the Frankfurt server that only the owner's own devices can use.
No Geph broker, no Geph account, no paid plan.

## How it is locked down

- **No broker, ever.** The exit never registers anywhere. An exit with no broker refuses
  to start unless it has a device list (`kestrel_devices`), so it can never become an open
  proxy by misconfiguration.
- **Per-device keys.** Every device has its own ed25519 key. On each connection it signs its
  fresh X25519 hello plus a timestamp; the exit checks the key is enrolled, not revoked,
  and the signature is under 5 minutes old. A captured handshake is useless to replay.
  Anything else gets the connection closed with no reply.
- **Abuse limits.** Mail ports (25, 465, 587, 2525) are blocked in the exit and in the host
  firewall; private, loopback, link-local and cloud metadata addresses are unreachable;
  each device is rate limited (25 MB/s by default); 5 failed handshakes ban an address for
  15 minutes; the host firewall rate-limits new connections per source.
- **Firewall.** Only SSH and TCP 443 are open inbound (`/usr/local/sbin/kestrel-firewall`).

## Pieces

| Path | What |
| --- | --- |
| `libraries/geph5-misc-rpc/src/kestrel.rs` | device keys and the signed credential |
| `binaries/geph5-exit/src/kestrel.rs` | the gate, bans, per-device limits and usage |
| `binaries/kestrelctl` | add, list, revoke and rotate devices |
| `kestrel/lockdown-test.sh` | proves only enrolled devices get through |
| `kestrel/sync.sh` | daily: rebase on upstream, build, test, deploy or roll back |
| `kestrel/security-review.sh` | weekly: audits, firewall, lockdown and a code review |
| `kestrel/deploy/` | systemd units, firewall, config and one-time install |

## On the server

    systemctl status geph-exit                      # the exit (enabled, restarts itself)
    systemctl list-timers 'geph-*'                  # daily sync, weekly review
    /opt/kestrel/current/kestrelctl list            # devices
    /opt/kestrel/current/kestrelctl add ipad --out ipad.yaml
    /opt/kestrel/current/kestrelctl revoke ipad     # refused from its next connection
    kestrel/lockdown-test.sh --live                 # prove the lockdown on the live exit

Releases live in `/opt/kestrel/releases/<commit>`; `current` is what runs and `last-good`
is the last release that passed the live lockdown test. State is in `/var/lib/kestrel`.

## Our changes

Our commits sit on the `kestrel` branch on top of `upstream/master`
(`git log upstream/master..kestrel`). The daily sync rebases them.
