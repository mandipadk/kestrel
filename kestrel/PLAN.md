# Kestrel round 5: a second exit, and a quantum-safe tunnel

Research notes: see "Why these two" below. Chosen 2026-10-18.

## 1. Two exits: Chicago and Frankfurt, nearest by default, automatic failover

**Why.** The owner is in the US; Chicago to Frankfurt is ~95 ms per round trip and every page pays it
several times (DNS, TCP, TLS). One free VM is also a single point of failure. A Chicago exit makes
everyday browsing fast and lets either exit cover for the other. Free (Oracle Always Free, 10 TB/month).

**Design.**
- Chicago runs the same geph5-exit build as an unprivileged `kestrel` user, its own signing key,
  its own Shield list, the same firewall (only SSH + TCP 443 in; rate limits; mail ports blocked).
  Extra on Chicago: an nft rule that drops anything the `kestrel` user sends to loopback, private,
  link-local or metadata addresses (Chicago hosts the owner's own services on localhost).
- One device list. Frankfurt stays the authority (`devices.json`, public keys only). Every
  add/revoke/rotate pushes the list to Chicago before it reports success; an hourly check repairs drift.
  An exit whose list is older than it should be refuses everyone (fails closed).
- Devices carry both exits (endpoint + exit public key + city) in their config; setup codes gain an
  exits list (old apps keep working on Frankfurt).
- Engine: an ordered exit list. "Automatic" tries the nearest exit first and the other after a short
  head start, keeps whichever finishes the handshake first, and on a dead session reconnects the same
  way, so a failed exit is replaced within seconds. "Chicago" or "Frankfurt" pins one.
- Apps: an Exit choice (Automatic, Chicago, Frankfurt) in Settings; the panel shows which exit you're
  on. Page: both exits' health, device sessions per exit, upkeep for both.
- Upkeep: the daily sync builds once (both are arm64), deploys to Frankfurt then Chicago, each gated
  on its own lockdown + page test, each rolled back on its own. Security review covers both.

## 2. Quantum-safe tunnel (hybrid X25519 + ML-KEM-768)

**Why.** Today the tunnel's keys come from X25519 alone; traffic recorded now could be decrypted by a
future quantum computer ("harvest now, decrypt later"). Apple (iOS 26 TLS), Cloudflare, Mullvad and
Signal moved to hybrid post-quantum key exchange. Small change, clean extension point.

**Design.** A new hello variant carries an X25519 key and an ML-KEM-768 encapsulation key; the exit
answers with its X25519 key and the KEM ciphertext; the session keys come from both secrets
(blake3 over X25519 || ML-KEM). The device signs the whole hello and the exit signs its answer, so the
KEM can't be stripped in transit. Exits keep accepting the old hello until every device reports
quantum-safe, then `kestrel_require_pq: true` refuses classical handshakes. The page and apps show
"quantum-safe" per device.

## Testing before anything ships (the bar from 2026-10-18)

- Unit: hybrid handshake round trip; tampered KEM key or ciphertext fails; classical refused when PQ is
  required; device list push/stale-list fail-closed.
- Lockdown test, run against each exit: strangers and revoked keys refused, on both links and both
  handshakes; from Chicago's exit, localhost (incl. 127.0.0.1:7700), private and metadata addresses
  unreachable.
- Packet path test (`vpn-path-test.py`) through each exit, and a failover run: one exit made
  unreachable mid-test, pages keep loading via the other within 10 s.
- Apple CI: engine tests with both exits (page over each, failover with one dead exit), install test,
  update test. Each new test run first against the old build as a control.
- Releases go out only after all of the above, 30 runs of the failover test, and a day on the live
  exits.

## Not now (and why)

- Kill switch (includeAllNetworks): Apple bugs leave devices offline (IVPN removed theirs; Mullvad
  documents App Store update lockups). Revisit as an opt-in toggle later.
- Multi-hop: both hops would be the same owner on the same cloud, so no split of trust; just latency.
- DAITA-style padding: high cost on iPhone, little gain against a single-user obfuscated link.
- Domain bypass: no Apple per-domain API; the US exit removes most of the need.

## Tasks
- [ ] PQ: ml-kem hello variant in misc-rpc, exit and client; unit tests; lockdown checks
- [ ] Engine: exit list, nearest-first race, failover, pin; config + setup code v2
- [ ] Second exit locally (Frankfurt, port 8443) to develop and test failover before Chicago exists
- [ ] Chicago: OWNER Oracle ingress TCP 443 (errand); OWNER root install script (power sudo)
- [ ] Device list push + stale fail-closed; kestrelctl multi-exit
- [ ] Sync/deploy/review for two exits; page shows both
- [ ] Apps: exit picker, current exit, quantum-safe badge; CI tests + controls
- [ ] Release: exits first (old apps unaffected), then apps
