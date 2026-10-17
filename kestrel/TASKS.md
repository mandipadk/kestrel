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
- [ ] OWNER: Oracle security list ingress TCP 443 (SYNs from outside never arrive)
- [ ] OWNER: make repo public (GitHub Actions billing blocks private macOS runners). Server IP is in history of 2 commits (kestrelctl default, security-review default); my history rewrite was blocked. Current code still has it too; remove via /var/lib/kestrel/endpoint once allowed.
- [ ] OWNER: create App Store Connect app "Kestrel Private", bundle dev.mandip.kestrel, SKU kestrel
- [ ] After those: rerun apple workflow, fix compile errors, copy Mac binary to ~/sites/kestrel/dist/kestrel-client-macos, add devices (iphone, macbook), verify from outside
- [ ] Remaining advisories needing manual bumps: sqlx 0.7 -> 0.8 (major), rsa (no fix, Marvin), rustls 0.21 line via an old dep
- [ ] Firewall: exempt lo from the per-source hashlimit (next root change)
