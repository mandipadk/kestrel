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
