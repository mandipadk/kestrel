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
- [ ] OWNER: install TestFlight build on iPhone, add iPhone + Mac from the Kestrel page; then confirm both show "Connected now"
- [ ] Server IP still appears in kestrelctl default + security-review default (and history); move to /var/lib/kestrel/endpoint when allowed
- [ ] Remaining advisories needing manual bumps: sqlx 0.7 -> 0.8 (major), rsa (no fix, Marvin), rustls 0.21 line via an old dep
- [ ] Firewall: exempt lo from the per-source hashlimit (next root change)
- [ ] Mac: a signed/notarized installer would remove the one Terminal step
