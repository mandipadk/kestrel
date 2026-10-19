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

## Round 5 (2026-10-19): a second exit, and a quantum-safe tunnel (plan: kestrel/PLAN.md)
- [x] Quantum-safe handshake: X25519 + ML-KEM-768 hello, both sides sign; client refuses a classical answer to a PQ hello; `kestrel_require_pq` (off until every device is quantum-safe); old apps keep working (tested)
- [x] Engine: exit list, automatic race (active exit gets a 3 s head start), failover, pins; exits learnt from the report
- [x] Apps: Exit choice (Automatic, Chicago, Frankfurt), current exit, quantum-safe in the link line; CI engine tests with both exits
- [x] Firewall: the kestrel user reaches only the local resolver on loopback (replies to others allowed)
- [x] OWNER: Oracle ingress 443 on Chicago; root install (install-second-exit.sh). Chicago exit a35d443a…e41e, follows Frankfurt's release daily 05:40, pulls the device list every minute
- [x] exits.json on both exits; lockdown --live 19/19 on each; packet path through Chicago (5 pages, 25 MB at 107 Mbit/s from Frankfurt)
- [x] live-exits-test.sh against the live exits: automatic, both pins, a cut-off exit is left in 11-14 s (once 22 s), a pinned device does not fall over
- [x] conn-rate-test.sh: one device opens at most 7 new connections/min to an exit, even failing over (firewall limit 20/min per address)
- [x] Apple CI run 36 (both exits, testflight=false): all tests passed, nothing published
- [ ] 30 live failover runs, then lift apps/HOLD (TestFlight + mac-latest)
- [ ] Failover is 11-14 s, not the planned 10 s (the open-response timeout is 10 s); a faster dead-session check would cut it
- [ ] kestrel_require_pq once every device reports quantum-safe
