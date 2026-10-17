#!/usr/bin/env bash
# notify.sh "<message>": push a short note to the owner's phone (via Switchback
# on Chicago), linking to the Kestrel status page. Gives up after 25 seconds:
# the push goes out at once, and nobody needs to answer it.
msg=${1:?message}
link=${KESTREL_STATUS_URL:-https://kestrel.mandip.dev}
echo "$(date -u +%FT%TZ) $msg" >> /var/lib/kestrel/reports/notifications.log 2>/dev/null
timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=10 chicago \
  "~/.local/bin/ask-me $(printf '%q' "$msg") kestrel --link $(printf '%q' "$link") --label 'Open Kestrel'" \
  >/dev/null 2>&1 || true
