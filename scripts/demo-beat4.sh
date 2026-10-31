#!/usr/bin/env bash
# Beat 4 -- the gateway catches what admission control can't. ~3 min on
# stage. Two deliberate mistakes, each caught by a different layer.
# Unlike beats 1-3, this one is presenter-terminal throughout -- both
# halves are genuinely git-commit / kubectl actions, not UI clicks (see
# app.js's comment on why there's no button for this).
#
# This script WALKS you through it rather than fully scripting it: part A
# needs a real `git commit && git push` between two of its steps, which
# this script cannot (and should not) do on your behalf.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

chat_direct() {
  # Bypasses the storefront's _resolve() dispatcher entirely -- talks
  # straight to one agent's own /chat, so a refund attempt genuinely
  # exercises THAT identity's own gateway call, not whichever backend the
  # storefront would have routed to.
  local svc="$1" msg="$2"
  kubectl -n agents port-forward "svc/$svc" 18080:8000 >/tmp/pf.log 2>&1 &
  local pf_pid=$!
  trap 'kill '"$pf_pid"' 2>/dev/null || true' RETURN
  for i in $(seq 1 20); do curl -sf http://127.0.0.1:18080/healthz >/dev/null 2>&1 && break; sleep 0.5; done
  curl -s -X POST http://127.0.0.1:18080/chat -H 'content-type: application/json' \
    -d "{\"customer_id\":1,\"message\":\"$msg\",\"thread_id\":\"beat4\"}"
  kill "$pf_pid" 2>/dev/null || true
}
show() { python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'reply' in d:
    print('agent says:', d['reply'])
for e in d.get('events', []):
    print('  -', e['type'], '-', e['message'])
"
}

log "PART A -- widen a Postgres role in Git. OPA still denies the refund."
echo
log "confirm the baseline: order-agent's OWN identity, asked directly for a refund, is denied"
chat_direct order-agent "please refund order #1042" | show
echo
echo "  Now, in your editor: open k8s/cnpg/cluster.yaml, find agent_order_login's"
echo "  inRoles list, and add mahi_refund_grp alongside mahi_order_grp -- the exact"
echo "  mistake beat 4 is about: granting order-agent's login role money-privilege"
echo "  it was never supposed to have."
echo
echo "      git add k8s/cnpg/cluster.yaml"
echo "      git commit -m 'widen order-agent db role (DELIBERATE MISTAKE for beat 4)'"
echo "      git push"
echo
read -r -p "Press Enter once you've pushed, and ArgoCD's cnpg-resources Application shows Synced (or run: argocd app sync cnpg-resources) ... "
echo
log "confirm the Postgres privilege really did widen"
echo "  kubectl -n data exec -it mahistores-db-1 -- psql -U postgres -c \"\\du agent_order_login\""
echo "  (expect to see it listed as a member of mahi_refund_grp now)"
echo
log "THE POINT -- ask order-agent's identity for a refund again. Still denied."
chat_direct order-agent "please refund order #1042" | show
warn "OPA's rule (policy/rego/authz.rego) checks the SPIFFE identity calling POST /tools/issue_refund, never whatever Postgres privilege that identity's role happens to hold right now. A git-committed mistake didn't open anything."
echo
echo "  Revert when done: git revert HEAD && git push (or just edit the file back and commit)."
echo

log "PART B -- deploy a non-compliant agent pod. Kyverno rejects it at admission."
cat <<'EOF' > /tmp/beat4-bad-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: beat4-noncompliant
  namespace: agents
  labels:
    app: beat4-noncompliant
spec:
  containers:
    - name: agent
      image: python:3.12-slim
      command: ["sleep", "3600"]
      env:
        - name: STATIC_DB_PASSWORD
          value: "this-should-never-be-allowed-here"
EOF
log "attempting to apply a pod with a plain static DB password and no SPIFFE volume..."
kubectl apply -f /tmp/beat4-bad-pod.yaml && warn "this should have been rejected -- check require-spiffe-identity ClusterPolicy is actually synced" \
  || log "rejected at admission, as expected -- it never even started."
rm -f /tmp/beat4-bad-pod.yaml

echo
log "say the line: OPA and Kyverno just caught two completely different mistakes -- a widened database privilege, and a non-compliant pod -- without either one trusting the agent, the deployer, or each other. Neither is the whole story alone: Part A shows policy on every call beats whatever privilege happens to exist underneath it; Part B shows a bad deployment never even gets to make a call. That is defense in depth, demonstrated live, not asserted on a slide."
