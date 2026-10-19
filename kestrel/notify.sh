#!/usr/bin/env bash
# notify.sh "<message>": report something Kestrel's automation did (a failed
# update, a security review, an alert) to the agent working on Kestrel (want
# fec5092f) via Switchback on Chicago, not to the owner's phone: the agent
# fixes what it can and tells the owner in its report. Gives up after 25
# seconds; nobody needs to answer it.
msg=${1:?message}
work=${KESTREL_WORK:-fec5092f}
echo "$(date -u +%FT%TZ) $msg" >> /var/lib/kestrel/reports/notifications.log 2>/dev/null
if [[ -d "$HOME/apps/switchback" && -x "$HOME/.local/bin/ask-me" ]]; then
  # already on the Switchback server (the second exit runs there)
  timeout 25 "$HOME/.local/bin/ask-me" "$msg" kestrel --work "$work" >/dev/null 2>&1 || true
else
  timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=10 chicago \
    "~/.local/bin/ask-me $(printf '%q' "$msg") kestrel --work $(printf '%q' "$work")" \
    >/dev/null 2>&1 || true
fi
