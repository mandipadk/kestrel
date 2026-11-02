#!/usr/bin/env bash
# Tests kestrel-firewall's reading of inbound rules (no root, changes nothing):
# a port is "open to the internet" only if an ACCEPT for anyone covers it.
set -uo pipefail
FW=$(dirname "$0")/deploy/kestrel-firewall
pass=0 fail=0
# the shape of Oracle's default INPUT chain, plus our jump and a few others
RULES='-P INPUT ACCEPT
-N KESTREL-IN
-N MAGPIE-IN
-N QUIET
-A INPUT -p udp -m udp --dport 22000 -j MAGPIE-IN
-A INPUT -p tcp -m tcp --dport 22000 -m conntrack --ctstate NEW -j MAGPIE-IN
-A INPUT -p tcp -m tcp --dport 443 -m conntrack --ctstate NEW -j KESTREL-IN
-A INPUT -p tcp -m tcp --dport 5000 -j QUIET
-A INPUT -p tcp -m tcp --dport 6000 -j LOG
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p udp -m udp --sport 123 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m multiport --dports 8000:8010,9000 -j ACCEPT
-A INPUT -s 10.0.0.0/8 -p tcp -m tcp --dport 2049 -j ACCEPT
-A INPUT -i tailscale0 -p tcp -m tcp --dport 7681 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A KESTREL-IN -i lo -j ACCEPT
-A KESTREL-IN -p tcp -m tcp --dport 443 -m hashlimit --hashlimit-above 20/minute --hashlimit-burst 40 --hashlimit-mode srcip --hashlimit-name kestrel_new -j DROP
-A KESTREL-IN -p tcp -m tcp --dport 443 -j ACCEPT
-A MAGPIE-IN -p tcp -m tcp --dport 22000 -m hashlimit --hashlimit-above 30/minute --hashlimit-mode srcip --hashlimit-name magpie -j DROP
-A MAGPIE-IN -j ACCEPT
-A QUIET -i lo -j ACCEPT
-A QUIET -j DROP'
expect() { # expect open|closed <proto> <port>
  local got=closed
  "$FW" accepts-test "$2" "$3" <<<"$RULES" && got=open
  if [[ $got == "$1" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL  $2/$3: $got, expected $1"; fi
}
expect open tcp 22        # NEW state is new connections
expect open tcp 22000     # through its own chain
expect open udp 22000
expect open tcp 443
expect closed tcp 5000    # its chain accepts loopback only
expect closed tcp 6000    # LOG is not a chain of ours
expect open tcp 8005      # inside a multiport range
expect open tcp 9000
expect closed tcp 8011
expect closed tcp 111     # only the established/related rule and the reject
expect closed udp 111
expect closed tcp 2049    # one source network only
expect closed tcp 7681    # one interface only
expect closed udp 123     # a source port, not a listening port
expect closed udp 41641
echo "firewall rules test: $pass passed, $fail failed"
[[ $fail == 0 ]]
