# Kestrel tasks (want fec5092f)

- [x] Fork geph5 at ~/code/kestrel (Frankfurt), upstream remote, branch `kestrel`; private mirror github.com/mandipadk/kestrel
- [x] Per-device ed25519 gate in exit + client; fail closed with no broker
- [x] kestrelctl add/list/revoke/rotate
- [x] Lockdown test (local 8/8, live 7/7)
- [x] Root install (owner approved): kestrel user, firewall, geph-exit, timers
- [x] Status page https://kestrel.mandip.dev (Chicago, ~/sites/kestrel; state in ~/.config/kestrel)
- [x] Sync pipeline run by hand: deployed 3dbb9a5, lockdown 8/8 + 7/7
- [x] Security review run by hand: bumped advisory crates, deployed a73c189; fixed Claude invocation (prompt on stdin)
- [x] App Store Connect key in GH secrets; bundle IDs dev.mandip.kestrel(.tunnel) registered with Network Extensions (team UK74VYMUP7)
- [x] iPhone app source (apps/ios) + Mac kit (apps/mac) + .github/workflows/apple.yml
- [x] OWNER did: Oracle 443 open, repo public, App Store app "Space: Kestrel" (6824089371)
- [x] Outside-in lockdown test from Chicago: enrolled key exits as Frankfurt; no key / stranger key refused
- [x] Apple CI green: Mac universal client (on the status page), iPhone build 3 VALID, internal TestFlight group "Owner" (all builds)
- [x] QR bug: page regex matched allow_direct; now YAML-parsed and validated (30/30 round-trip)
- [x] MacBook connected (exit log: device=macbook)
- [x] iPhone tunnel died at start: extension was linked with -lgeph5_client, which picks the cdylib; now links the .a by path. CI checks otool -L (system libs only) and runs EngineTests on the Simulator: DNS packets round-trip through the exit (device ci-ios). Build 7 in TestFlight.
- [x] iPhone connected after build 7 (exit counted 20 MB from "iphone")
- [ ] Server IP still appears in kestrelctl default + security-review default (and history); move to /var/lib/kestrel/endpoint when allowed
- [ ] Remaining advisories needing manual bumps: sqlx 0.7 -> 0.8 (major), rsa (no fix, Marvin), rustls 0.21 line via an old dep
- [ ] Firewall: exempt lo from the per-source hashlimit (next root change)
- [x] Mac: a signed/notarized installer would remove the one Terminal step

## Round 2 (2026-10-18): Mac app + big VPN features

Picked (research notes in kestrel/README.md "What Kestrel adds"):
- [x] Shield: the exit blocks ads, trackers and malware for each device (oisd lists, refreshed daily), answers blocked lookups at once, counts per device (today, top domains); on/off per device
- [x] Stealth link: devices reach the exit over sosistab3 (looks like random bytes, probes get nothing back) on the same port 443; the exit tells which devices are hidden; old plain clients keep working until switched off
- [x] Sentinel: the exit notes each device's network (ASN, country) and any revoked or unknown key that tries to connect; the page shows it
- [x] Trusted networks: apps connect on their own except on Wi-Fi you mark as trusted
- [x] Mac app: SwiftUI app, menu bar, same look as iPhone; engine tests pass on the macOS runner against the live exit
- [x] OWNER changed plan: Mac ships as a Developer ID, notarized .dmg (system extension), not TestFlight; CI publishes it to the mac-latest release, the page links it
- [x] OWNER gave the Developer ID .p12 + password (~/.secrets/kestrel-developer-id)
- [x] OWNER put MAC_DEVID_P12 / MAC_DEVID_PASSWORD in gh secrets; apple run 39143593943 signed with Developer ID, notarization Accepted, stapled, Kestrel.dmg on mac-latest (page link returns 200)
- [x] Revoked 10 dead "Created via API" dev certs (owner approved); CI now signs with one lasting dev identity (IOS_DEV_P12, key in ~/.config/kestrel/ci-dev on Chicago); iPhone archive + TestFlight upload verified, no new cert made
- [x] iPhone: Shield, stealth, trusted networks, setup by link (kestrel1: URL scheme); 1.1 build in TestFlight
- [x] Status page: Shield report, network per device, Mac setup by code
- [x] Deploy via sync.sh --deploy-only; lockdown test; README
Suggested, not built: second exit in Chicago (needs root there + an Oracle port)
- [x] OWNER: Mac app refused to install its extension ("does not appear to belong to any extension categories"): extension Info.plist had no CFBundlePackageType; now SYSX (sysextd's "package type not `SYSX`" check, found on the runner). CI gate apps/mac/check-extension.sh checks package type, provider class, Mach service, entitlements, profiles, signatures, on the export and the stapled dmg
- [x] OWNER: Mac app looked like an iPhone app. Now a menu bar app (LSUIElement): Control Center style panel, setup window only until added, tabbed Settings; system font, native controls, kestrel accent; macOS 14+. Mockup: https://kestrel-mac-mockup.mandip.dev

## Round 3 (2026-10-18): Mac download and in-app updates
- [x] Page: Apps section with a direct Mac .dmg download (/download/mac) and the version from the appcast; no device needed
- [x] Sparkle EdDSA key made; private half in gh secret SPARKLE_ED_KEY (owner allowed), backup ~/.config/kestrel/sparkle on Chicago
- [x] Mac 1.2: Sparkle 2.10.0, signed feed required; Check for Updates in the panel, update settings in General, a quiet "ready" notice for scheduled finds
- [x] CI: sign dmg + feed, stage mac-b<N>, update test (old copy -> new; tampered feed refused), then mac-latest; keep 5 builds
- [x] OWNER: install 1.2 once by hand (1.1 has no updater); after that it updates itself
- [x] OWNER: 1.2 refused by sysextd: "network_extension category require the presence of NSSystemExtensionUsageDescription" (only the app had it). Now in the extension's plist; check-extension.sh checks it
- [x] CI install test: the notarized app, in /Applications on the runner, asks the real sysextd for the tunnel (build 27: validating_by_category -> activated_waiting_for_user). A control without the key got the owner's exact error (run 39157236592); control removed after

## Round 4 (2026-10-18): pages wouldn't load on the Mac
- [x] OWNER: Mac connected but no page loaded. Cause: upstream gives the engine's IP stack MTU 1450 only on iOS; macOS got 16384, so the Mac tunnel (MTU 1450) was handed packets up to 8232 bytes and macOS dropped them. DNS (small) worked, pages didn't. Not the stealth link.
- [x] Fix: kestrel_device.vpn_mtu (apps send 1450) and a 1450 default on macOS too (binaries/geph5-client/src/vpn.rs)
- [x] EngineTests.testAPageLoadsInPacketsThatFitTheTunnel: 20 kB over TCP through the engine, every packet <= 1450. Control run 39161619655 (test without fix): Mac failed with an 8232-byte packet
- [x] kestrel/vpn-path-test.py: the apps' packet path on Linux (TUN in a netns): 5 real pages, 25 MB download, MTU check; sync.sh runs it on the live exit before keeping a deploy (rollback otherwise)

## Round 5 (2026-10-19): a second exit, and a quantum-safe tunnel (plan: kestrel/PLAN-round5.md)
- [x] Quantum-safe handshake: X25519 + ML-KEM-768 hello, both sides sign; client refuses a classical answer to a PQ hello; `kestrel_require_pq` (off until every device is quantum-safe); old apps keep working (tested)
- [x] Engine: exit list, automatic race (active exit gets a 3 s head start), failover, pins; exits learnt from the report
- [x] Apps: Exit choice (Automatic, Chicago, Frankfurt), current exit, quantum-safe in the link line; CI engine tests with both exits
- [x] Firewall: the kestrel user reaches only the local resolver on loopback (replies to others allowed)
- [x] OWNER: Oracle ingress 443 on Chicago; root install (install-second-exit.sh). Chicago exit a35d443a…e41e, follows Frankfurt's release daily 05:40, pulls the device list every minute
- [x] exits.json on both exits; lockdown --live 19/19 on each; packet path through Chicago (5 pages, 25 MB at 107 Mbit/s from Frankfurt)
- [x] live-exits-test.sh against the live exits: automatic, both pins, a cut-off exit is left in 11-14 s (once 22 s), a pinned device does not fall over
- [x] conn-rate-test.sh: one device opens at most 7 new connections/min to an exit, even failing over (firewall limit 20/min per address)
- [x] Apple CI run 36 (both exits, testflight=false): all tests passed, nothing published
- [x] Found by the live runs: an exit counted a connection that hung up before its hello as a failed handshake, so a device dropping the exit it lost the race to (or changing networks) could get its address blocked for 15 min at its backup exit (Chicago blocked Frankfurt's address twice). Fix e9b655f: hang-ups don't count; addresses a device signed in from in the last day are never blocked. lockdown-test checks it over a non-loopback address (old build fails 4 checks); both exits on e9b655f
- [x] live-exits-test leaked its clients (started inside $(...)); fixed, checked after every run
- [x] kestrelctl's new default exit list made the local lockdown test refuse its throwaway exit (would have failed the 04:35 sync); the test now points it elsewhere
- [x] 30 live failover runs on e9b655f, 15 from each exit: 30/30 passed (12 checks each); the device moved in 11-14 s, 4 runs ~22 s; no client left behind; no block of our own addresses
- [x] Released: apps/HOLD removed; CI run 39 (Mac 1.3 build 39 on mac-latest, signed appcast, update test 1.2 -> 1.3; iPhone 1.2 uploaded to TestFlight). Frankfurt's 04:45 sync rebased on upstream 02b7831 and deployed 1b99bda (all gates passed)
- [ ] Failover is 11-14 s, not the planned 10 s (the open-response timeout is 10 s); a faster dead-session check would cut it
- [ ] kestrel_require_pq once every device reports quantum-safe

## Upkeep (2026-10-19): unanswered reports, advisories
- [x] OWNER: automation reports now go to the agent on want fec5092f (notify.sh: ask-me --work), not the owner's phone; tested end to end
- [x] The two "update stopped" reports (2026-10-18 20:09, 22:56) were runs started by hand: cargo not on PATH (sync.sh now sets it), then the loopback firewall rule blocking the exit's replies (fixed in 1357e61). Every update since passed all gates
- [x] rustls 0.23.40 -> 0.23.46 (4 advisories); exit deployed 1169fbe, apps in CI run 40 (Mac 1.3 build 40); apple.yml now also rebuilds on Cargo.lock
- [x] Security review raises only advisories not in kestrel/advisories-accepted.txt (each accepted one has its reason; an entry covers one crate version line). Remaining 8 RustSec + OSV notices accepted: rsa (no fix; broker login only), rustls 0.21 / webpki 0.101 (upstream broker only), sqlx 0.7 (SQLite only here; 0.8 is upstream's upgrade), unmaintained crates
- [x] The review's Claude summary never saved (it could edit, not write review.md); fixed. Its own to-dos done: rustls bump; IPv6-written loopback ([::ffff:127.0.0.1], [::1]) in the lockdown test (an exit without its allow.rs fix fails the check); "updated sqlx" no longer claimed when nothing moved
- [x] geph5-client unit tests had stopped compiling (Config gained kestrel_device); fixed (30 pass) and now part of the nightly gate
- [x] Weekly review rerun by hand (20261019T065942Z): 0 new advisories, all checks passed; its Claude pass found junk hellos didn't count toward the block (fixed, c91f81d) and unblocked IPv4 multicast (fixed with a unit test, 9c68661). Its summary still didn't save (an absolute path rule needs //): fixed, with a fallback to its last message; this run's summary backfilled on the page
- [x] The review's dependency step bumped sqlx (accepted advisory), which only reshuffled socket2/windows-sys (went out in app build 41): reverted; the step now bumps only crates with new advisories
- [x] Frankfurt on a05a98a (44/44 local, 20/20 live, page path ok); Chicago follows at its 05:40 run
- [ ] Owner's call: kestrel_allow_plain: false once every device is on the stealth link (the device "macbook" was last seen on the plain link)

## Round 6 (2026-10-19, owner said go): plan in kestrel/PLAN.md
Found on the live exits: Chicago has never carried an owner device (learnt exit lists wait for the tunnel to go off); the round-1 Mac command-line client ("macbook", plain, classical, no Shield) still runs and likely holds the Mac's proxies; iPhone not seen since before 1.2.
- [x] apps/HOLD in place (CI builds and tests, releases nothing)
- [x] Exit: Shield just-blocked (last 50 per device, memory only) and allow/unallow by request (this device / all devices); unit tests
- [x] Exit bug found by the new tests: Shield summary panicked if the clock stepped back an hour (subtract overflow); fixed + test
- [x] Engine: learns the exit list from the report (append-only, indexes stay), devices without a list restart on it, automatic re-race moves to the faster exit; 3 s ping timeout on Kestrel sessions; head start 1.5 s; unit tests
- [x] Engine: disguised link (stealth link in WebSocket over HTTPS, rustls + webpki roots, 20 s WS pings), auto joins after 4 s (at once if it worked last), link: direct|disguised; exits carry `disguise`; report says link
- [x] Edge shim (kestrel/edge, ~/sites/kestrel-edge on both servers): secret path (~/.config/kestrel/edge-path), 404 otherwise, only to 127.0.0.1:443, per-visitor limits by CF-Connecting-IP
- [x] Allow lists merge both ways between exits (allow-sync.py, three-way); exits reload device allows
- [x] Exit watch (watch.sh + kestrel-watch.timer), state.py summary, page uptime strip; exit notes disguised devices
- [x] Apps: Mac removes the old client (panel notice + --remove-old-client for CI); Just Blocked (Mac window, iPhone sheet); Always disguise setting; Mac 1.4 / iPhone 1.3; CI old-client test
- [ ] Unit tests green on Frankfurt; local lockdown; local disguise test over loopback + control with the old engine
- [ ] OWNER (root, sent): firewall loopback exemption + watch timer on both exits
- [ ] BLOCKED: public launch of kestrel-edge / kestrel-edge-fra (my session's safety check refuses public surfaces, even via power run)
- [ ] Deploy Frankfurt (sync.sh --deploy-only), Chicago follow --force; page relaunch
- [ ] Live: lockdown both, vpn-path, live-exits-test 30x (failover < 5 s target), conn-rate-test
- [ ] Apple CI on hold: green, screenshots reviewed; then release (remove HOLD)
- [ ] A day with no plain/classical device: revoke "macbook", kestrel_allow_plain: false, kestrel_require_pq: true
