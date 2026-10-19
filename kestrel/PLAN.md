# Kestrel round 6: finish the move to the new apps, a disguised link, Shield you can fix from the device

Proposed 2026-10-19 (waiting for the owner's go-ahead). Round 5's plan: `PLAN-round5.md`.

## What the live exits show today (2026-10-19 16:00 UTC)

- Both exits up; Frankfurt on a05a98a, Chicago on 1b99bda (takes a05a98a at 05:40). Upstream quiet
  since 02b7831 (Oct 18). Nightly sync, Chicago follow and the weekly review all passing.
- **Chicago has never carried one of the owner's devices** (its log since install: only
  lockdown-probe and ci-ios). A 1.3 app learns the exit list from its first report, but saves it to
  the engine only once the tunnel is off, so a tunnel left on keeps using Frankfurt alone.
- **The old command-line Mac client is still running.** Device "macbook" (round 1, plain link,
  classical handshake, no Shield) connects ~3 times an hour and carried 465 MB since the exit restarted at 07:31; the Mac app
  ("macbook-test", stealth + quantum-safe) was last on at 14:00. The old client is a KeepAlive
  LaunchAgent that also points the Mac's proxies at itself (127.0.0.1:9909/9910), so browsers on
  the Mac probably bypass the app. The app's notice asks the owner to run `kestrel off` in
  Terminal; it hasn't happened, and the owner shouldn't need a terminal.
- iPhone last seen Oct 18 ~20:00, before iPhone 1.2; not yet quantum-safe.
- Frankfurt refused 192 handshakes from strangers in 24 h; Chicago blocks scanners every ~15 min.
  Both answer them because the plain link must stay on for "macbook".

## 1. Finish the move (fix-ups, no new decisions)

- **Mac 1.4 removes the old client itself:** "Replace the old Kestrel command" in the panel: stops
  the LaunchAgent, removes `~/.kestrel` and `~/.local/bin/kestrel`, turns the 9909/9910 proxies off
  (one macOS admin prompt). Needs the main app out of the sandbox (Developer ID allows it; the
  tunnel extension stays sandboxed). CI test: install the round-1 client on the runner first
  (control: proxies on), run the cleanup, check agent gone, proxies off, page loads.
- **New exit lists apply while connected:** the app sends a learnt list to the running engine
  (control message) instead of waiting for the tunnel to go off; the next session races both exits.
  Engine test: start with Frankfurt only, learn [Chicago, Frankfurt], a new session lands on the
  faster exit without a restart (control: 1.3 stays on Frankfurt).
- **Then close the old doors** once the exits see no plain or classical device for a day:
  revoke "macbook", `kestrel_allow_plain: false` (exits stop answering anyone without the key:
  no ping echo, nothing to scan), `kestrel_require_pq: true`. The page says when it's safe.
- **Failover 11-14 s -> ~3 s:** a 1 s keepalive on the session; three misses mark the exit dead
  and the race starts at once. live-exits-test.sh 30 runs, target < 5 s every time.
- **Exit watch:** each exit checks the other every 5 minutes with a real device handshake and a
  page fetch (lockdown-probe key); the page shows a 30-day uptime strip per exit; down > 10 min
  reports to this work (notify.sh), not the phone.
- Old to-dos: server IP out of kestrelctl/security-review defaults; loopback out of the hashlimit.

## 2. Disguised link: Kestrel keeps working where VPNs are blocked

**Why.** Kestrel's only way in is two fixed IP addresses and a random-looking stream. Hotel,
airport, office and school networks often allow only web traffic, and national firewalls block
exactly this: China blocks "fully encrypted" traffic by its randomness (Wu et al., USENIX Security
2023), Russia and Iran block unknown protocols and VPN servers' addresses. Geph survives with
volunteer bridges from its broker; Kestrel has no broker, so today one blocked address means no
VPN. This is the feature Geph exists for, made personal.

**Design.**
- A WebSocket address on the owner's Cloudflare zone (`launch --public --cmd`, on Chicago): the
  device opens ordinary HTTPS to it (Apple's own TLS stack, so it looks like Safari), upgrades to
  a WebSocket, and inside runs the same stealth link to the exit. To the network it is a visit to
  a site on Cloudflare; blocking it means blocking a big share of the web.
- The address is a dumb pipe to the exit's port: the exit still checks the device key, the
  quantum-safe handshake and revocation, and refuses anything else. A stranger gets a 404 page.
  It forwards only to Kestrel's own exit, so it can't relay anything for anyone.
- Engine: "Automatic link": direct stealth first; if no handshake in 4 s (or the network looks
  hostile), the disguised path joins the race; the faster one wins and is remembered per network.
  Apps show "Link: direct / disguised" and can force disguised in Settings.
- Free: Cloudflare's free plan carries WebSockets; the shim is a few hundred lines on the server.
  Kept as a fallback (not the everyday path) to stay light on Cloudflare.
- The disguised address leads to the Chicago exit (where launch runs). If Chicago is down, the
  device still has its direct links; a second disguised address for Frankfurt can follow later.

**Tests.** Lockdown through the disguised address (no key, stranger key, revoked key refused;
404 for a browser). A "hostile network" netns: drop both exit IPs and every non-443 port, block
non-TLS first packets; pages + 25 MB load via the disguise (control: 1.3 engine fails). Apple CI
engine test over the disguised path. 30 runs of the fallback.

## 3. Shield you can fix from the device

**Why.** Every DNS blocker sometimes breaks a site (a login, a checkout, a link in an email).
Today the fix is the page or `kestrelctl allow` on the server, so in practice Shield gets paused.

**Design.** The exit keeps each device's last 50 blocked lookups (in memory, never written, gone on
restart). Apps: "Just blocked" list under Shield, newest first, with "Allow" per domain (this
device or all devices) and undo. The page gets the same list and the allow list editor.

**Tests.** Exit unit tests (ring buffer, allow wins, per-device isolation: one device can't see or
change another's); engine test: a blocked name resolves after Allow; app UI tests on screenshots.

## Order and release

1. Fix-ups (Mac 1.4, iPhone 1.3 with live exit lists, failover, exit watch) - exits first, apps
   after the full gate (vpn-path-test, live-exits 30x, CI install + update tests).
2. Shield "Just blocked" (exit + apps).
3. Disguised link (after the owner OKs a public Cloudflare address).
4. A day with no plain/classical device -> plain off, PQ required.

## Not now (and why)

- Home exit (sites that block datacenter addresses): needs hardware at home.
- Device-to-device network: the owner's servers already have private addresses through Switchback.
- Rotating IPv6 per site: Oracle needs each address assigned by hand (max 32); small gain.
- Kill switch, multi-hop, padding: reasons in PLAN-round5.md still hold.
