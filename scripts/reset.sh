#!/usr/bin/env bash
# Between-rehearsals reset: orders back to pre-refund state, event log
# cleared. Safe to run as many times as you like.
#
# Dramatically simpler than the inherited Vault talk's reset.sh: there is
# no lease to revoke out of band and no agent-side cache to separately
# tell to forget it -- mahi-tools has no per-request credential state at
# all, and the agent's only "credential" (its SVID) is managed entirely
# by SPIRE on its own clock. Also unscales the storefront back to 1
# replica, in case beat 3's scale_deployment demo left it elsewhere.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log "resetting storefront demo state (orders, refunds, event log)"
curl -s -X POST "$STOREFRONT_URL/api/admin/reset" -H 'content-type: application/json' | python3 -m json.tool

if kubectl get deployment storefront -n nimbus >/dev/null 2>&1; then
  log "scaling storefront back to 1 replica"
  kubectl -n nimbus scale deployment/storefront --replicas=1
fi

log "done."
