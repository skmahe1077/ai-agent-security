#!/usr/bin/env bash
# Beat 2 -- verified identity, no credential to steal. ~5 min on stage.
#
# The "money shot" here is structurally different from the inherited
# Vault talk's: that demo could force an instant `sys/leases/revoke` on
# command. There is no equivalent instant-kill here BY DESIGN -- the only
# thing standing in for a credential is the SVID itself, and SPIRE's own
# renewal clock (not this script, not the storefront) is what controls
# its lifetime. The honest version of this beat is slower but arguably
# stronger: delete the ClusterSPIFFEID and nothing issues a new SVID --
# the agent goes inert over its remaining TTL (up to 300s) with NOTHING
# left to revoke, because there was never a separate credential behind
# the identity to begin with.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

chat() { curl -s -X POST "$STOREFRONT_URL/api/support/chat" -H 'content-type: application/json' -d "$1"; }
show() { python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'reply' in d:
    print('agent says:', d['reply'])
for e in d.get('events', []):
    print('  -', e['type'], '-', e['message'])
"
}

log "no secret anywhere in this pod -- just a SPIFFE identity"
kubectl -n agents exec deploy/agent-secure -c agent -- env 2>/dev/null | grep -iE 'pass|secret' \
  && die "found a secret in the env -- that should not be there" \
  || echo "  (confirmed: no PASS/SECRET env vars)"
kubectl -n agents exec deploy/agent-secure -c agent -- cat /svids/jwt_svid.token 2>/dev/null | cut -d. -f2 | base64 -d 2>/dev/null \
  || warn "(no cluster reachable -- this step is EKS-only)"
echo

log "Idhazhini asks to refund order #1045"
chat '{"customer_id":1,"agent":"secure","message":"please refund order #1045","thread_id":"beat2"}' | show
echo

log "same agent, denied: order #1046 belongs to Ilan, not the customer chatting"
chat '{"customer_id":1,"agent":"secure","message":"please refund order #1046","thread_id":"beat2"}' | show
echo

log "same agent, denied: this role has no grant on customers at all"
chat '{"customer_id":1,"agent":"secure","message":"what is the phone number for customer 2","thread_id":"beat2"}' | show
echo

log "the money shot -- there is no credential left to steal, because there never was one separate from the identity"
echo "  Open the Identity card in the browser -- the SVID countdown is already live, ticking toward 0 from up to 300s."
echo "  In a second terminal, say the line, then run:"
echo "      kubectl delete clusterspiffeid ai-order-agent"
echo "  Confirm it's gone:"
echo "      kubectl get clusterspiffeid"
warn "this does NOT instantly kill the current SVID -- SPIRE simply stops renewing it. The agent goes inert over its remaining TTL, with nothing left for anyone (including the presenter) to separately revoke. Reapply k8s/spire/values.yaml's ClusterSPIFFEIDs afterward to restore it for the next rehearsal."
