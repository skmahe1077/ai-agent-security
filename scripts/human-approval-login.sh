#!/usr/bin/env bash
# Run ONCE before a demo window, in the green room. Declares "a human is
# present for the next 30 minutes, call them X" to the storefront -- NOT a
# real IdP login, and NOT cryptographically verified in this build (no
# Vault OBO here -- see app/storefront/static/index.html's comment on the
# approval card for the honest version of what this does and doesn't
# guarantee). The cached name is forwarded as a plain X-Approved-By header
# on the agent's retry when a refund/scale is approved, and recorded in
# the refunds row for audit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

name="${1:-}"
if [ -z "$name" ]; then
  read -r -p "Approver's display name (shown in the Agentic Workflow, not cryptographically verified): " name
fi
[ -n "$name" ] || die "need a name"

resp="$(curl -s -X POST "$STOREFRONT_URL/api/admin/human-token" \
  -H 'content-type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"display_name": sys.argv[1]}))' "$name")")"

echo "$resp"
log "cached. Approve as '$name' is live in the Agentic Workflow for the next 30 minutes."
warn "re-run this script if the demo runs long -- the cache expires, and Approve will show as disabled once it does."
