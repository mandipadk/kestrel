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

## What Kestrel adds to Geph

- **Shield.** The exit stops ads, trackers and malware for every device (the oisd "big" list,
  ~234k domains, refreshed daily and cached in `/var/lib/kestrel/shield-list.txt`). Blocked
  lookups get NXDOMAIN straight away; blocked connections by name are refused. Counts per device
  per hour, top blocked domains, on/off per device (`kestrelctl shield <dev> on|off`), an allow
  list (`kestrelctl allow <domain>`, `shield-allow.txt`), and a one-hour pause from the apps.
- **Stealth link.** Devices reach the exit over sosistab3 keyed by the exit's public key (which
  only devices hold), so the link is random-looking bytes and the device name never crosses the
  wire in clear. Plain and stealth clients share port 443 (`kestrel/stealth.rs` tells them apart).
  Once every device is on the stealth link, set `kestrel_allow_plain: false` in
  `/etc/kestrel/exit.yaml` and probes get no reply at all (not even Geph's ping echo).
- **Sentinel.** The exit notes each device's network (ASN and country, not the address) and
  whether it came in hidden. If a revoked or replaced key tries again, it records an alert; the
  status page lists it and pushes a note to the owner's phone.
- **In-tunnel report.** A device can open `status.kestrel.internal` (or `shield-pause`,
  `shield-resume`) through its own tunnel to get its own Shield numbers; the engine exposes it as
  the `kestrel_exit` control method, which the apps use.
- **Apps.** iPhone and Mac (SwiftUI, packet-tunnel extension, shared code in `apps/shared`),
  with Shield, the link state, connect-automatically except on trusted Wi-Fi, and setup by
  `kestrel1:` link or code. Both go to TestFlight from `.github/workflows/apple.yml`, which also
  tests the engine against the live exit and keeps screenshots of every screen.

Not built yet, worth doing: a second exit in Chicago with a switcher in the apps (needs root
there and an Oracle ingress rule).

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
| `binaries/geph5-exit/src/kestrel/shield.rs` | Shield: lists, NXDOMAIN answers, per-device counts |
| `binaries/geph5-exit/src/kestrel/stealth.rs` | stealth and plain links on one port |
| `apps/ios`, `apps/mac`, `apps/shared` | the iPhone and Mac apps |
| `apps/mac-cli` | the old command-line Mac client (replaced by the app) |

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
