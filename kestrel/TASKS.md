# Kestrel tasks (want fec5092f)

- [x] Fork geph5 at ~/code/kestrel (Frankfurt), upstream remote, branch `kestrel`
- [x] Per-device ed25519 gate in exit + client; fail closed with no broker
- [x] kestrelctl add/list/revoke/rotate
- [x] Lockdown test (local 8/8, live 7/7)
- [x] Root install (owner approved): kestrel user, firewall, geph-exit, timers
- [ ] Oracle security list: open TCP 443 ingress (owner, OCI console) — SYNs from outside never arrive
- [ ] Firewall: exempt lo from hashlimit (next root change)
- [ ] Status page (launch on Chicago, private): devices, usage, add/revoke, config download, reports
- [ ] MacBook client: build geph5-client for macOS (needs macOS runner) + instructions
- [ ] iPhone app: SwiftUI + PacketTunnel using geph5-client FFI; build/sign on macOS runner with owner's Apple dev account
- [ ] Run sync.sh once by hand; run security-review.sh once by hand
- [ ] Final report
