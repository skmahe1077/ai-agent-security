#!/usr/bin/env bash
# Beat 1 -- standing access is the problem. ~3 min on stage.
# $STOREFRONT_URL defaults to the live ALB (lib/common.sh's
# storefront_url(), via `kubectl get ingress`); this script only talks
# HTTP, so a `kubectl -n nimbus port-forward svc/storefront 8000:8000`
# with STOREFRONT_URL=http://localhost:8000 works identically if the ALB
# is ever torn down between rehearsals while a laptop demo is still
# needed. There is no docker-compose/local-stack equivalent in this repo
# -- every component here is a real cluster resource.
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

log "the support widget is talking to the LEGACY agent -- a static password, no identity"
kubectl get secret db-static-creds -n nimbus -o jsonpath='{.data.password}' 2>/dev/null | base64 -d \
  || die "db-static-creds not found in namespace nimbus -- run scripts/01-provision.sh (or just k8s/agents/agent-insecure.yaml) first"
echo

log "Idhazhini asks to refund her own order #1042"
chat '{"customer_id":1,"agent":"insecure","message":"please refund order #1042","thread_id":"beat1"}' | show
echo

log "...now the exact same chat, asked to refund order #1046 -- which belongs to Ilan, not Idhazhini"
chat '{"customer_id":1,"agent":"insecure","message":"please refund order #1046","thread_id":"beat1"}' | show
echo
warn "it worked. the credential belongs to the APP, not the task -- it has no idea whose order this is."
