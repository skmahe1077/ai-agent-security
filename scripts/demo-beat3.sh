#!/usr/bin/env bash
# Beat 3 -- policy on every call, and human intent. ~4 min on stage.
# Pass an approver name as $1, defaulting to a generic one so the script
# still runs unattended during rehearsal.
#
# No Vault OBO in this build -- approval is a plain, recorded
# X-Approved-By header the storefront adds server-side once a human
# identity is cached (app/storefront/main.py's api_resume), forwarded by
# the agent to mahi-tools (session.py). Not cryptographically verified;
# say so plainly if asked. What IS real: OPA and mahi-tools both gate on
# the actual request every time, and the refunds row records
# issued_by/approved_by/correlation_id together.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

APPROVER="${1:-$(whoami)}"

chat() { curl -s -X POST "$STOREFRONT_URL/api/support/chat" -H 'content-type: application/json' -d "$1"; }
resume() { curl -s -X POST "$STOREFRONT_URL/api/support/resume" -H 'content-type: application/json' -d "$1"; }
show() { python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'reply' in d:
    print('agent says:', d['reply'])
for e in d.get('events', []):
    print('  -', e['type'], '-', e['message'])
"
}

log "human-approval-login: caching '$APPROVER' as the approver (NOT a real IdP login)"
"$(dirname "${BASH_SOURCE[0]}")/human-approval-login.sh" "$APPROVER"
echo

log "Ruba asks for a £450 refund on order #1044 -- well over the auto-approval limit"
chat '{"customer_id":3,"agent":"secure","message":"please refund order #1044","thread_id":"beat3"}' | show
echo

log "approving -- no name typed in, the Approve click just signals 'use the cached human credential now'"
resume '{"agent":"secure","thread_id":"beat3"}' | show
echo

log "the storefront's Agentic Workflow panel now shows the correlation -- not a log tail"
echo "  Approved by: $APPROVER   Workload: refund-agent's SPIFFE ID   Action: refund #1044"
echo
log 'say the line: "the action and the authorization are the same auditable event -- recorded in the refunds row itself."'
echo

log "now the Kubernetes op -- same gateway, same OPA, a real cluster action instead of a database row"
chat '{"customer_id":3,"agent":"secure","message":"the storefront is slow, scale it to 2 replicas","thread_id":"beat3-scale"}' | show
echo
log "...and again, over OPA's auto-approval ceiling"
chat '{"customer_id":3,"agent":"secure","message":"scale the storefront to 8 replicas","thread_id":"beat3-scale"}' | show
echo
log "approve it -- same mechanism, different resource"
resume '{"agent":"secure","thread_id":"beat3-scale"}' | show
echo "  watch it happen live: kubectl -n nimbus get deploy storefront -w"
