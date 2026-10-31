#!/usr/bin/env bash
# The go/no-go gate. Run this before building anything else on top of a
# freshly provisioned stack, and again the morning of the talk.
#
# Each check is independent and prints PASS/FAIL rather than stopping at
# the first failure, so one failure doesn't hide the shape of the others.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PASS=0
FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/tmp/verify_check.log 2>&1; then
    printf '  \033[1;32mPASS\033[0m  %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  \033[1;31mFAIL\033[0m  %s\n' "$name"
    sed 's/^/        /' /tmp/verify_check.log
    FAIL=$((FAIL+1))
  fi
}

log "1. SPIRE is up and issuing identities"
check "spire-server StatefulSet ready" bash -c '
  n=$(kubectl -n spire-mgmt get statefulset spire-server -o jsonpath="{.status.readyReplicas}")
  [ -n "$n" ] && [ "$n" -gt 0 ]
'
check "spire-agent DaemonSet ready" bash -c '
  n=$(kubectl -n spire-mgmt get daemonset spire-agent -o jsonpath="{.status.numberReady}")
  [ -n "$n" ] && [ "$n" -gt 0 ]
'
check "both ClusterSPIFFEIDs registered" bash -c '
  # The spire chart prefixes each clusterSPIFFEIDs.* key from
  # k8s/spire/values.yaml with "<namespace>-<releaseName>-" (confirmed
  # live: spire-mgmt-spire-ai-order-agent, not ai-order-agent) -- match on
  # the stable key-name suffix rather than assuming the bare key is the
  # resource name.
  n=$(kubectl get clusterspiffeid -o name | grep -cE "(ai-order-agent|ai-support-agent-secure)$")
  [ "$n" -eq 2 ]
'

log "2. the OIDC Discovery Provider -- what Envoy Gateway's SecurityPolicy trusts"
check "JWKS endpoint reachable" bash -c '
  kubectl run -n spire-mgmt verify-jwks --rm -i --restart=Never --image=curlimages/curl:8.11.0 --command -- \
    curl -sf http://spire-spiffe-oidc-discovery-provider.spire-mgmt.svc.cluster.local/keys >/dev/null
'

log "3. Envoy Gateway + OPA are reachable and wired together"
PROXY_DEPLOY="$(kubectl -n envoy-gateway-system get deploy -l 'gateway.envoyproxy.io/owning-gateway-namespace=agents,gateway.envoyproxy.io/owning-gateway-name=mahi-gateway' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
check "Envoy Gateway proxy Deployment exists" bash -c "[ -n '$PROXY_DEPLOY' ]"
check "OPA Deployment ready" bash -c '
  n=$(kubectl -n agents get deployment opa -o jsonpath="{.status.readyReplicas}")
  [ -n "$n" ] && [ "$n" -gt 0 ]
'
check "mahi-gateway-stable Service resolves to the proxy pods" bash -c '
  kubectl -n envoy-gateway-system get endpoints mahi-gateway-stable -o jsonpath="{.subsets[0].addresses[0].ip}" | grep -qE "^[0-9]"
'
check "an unauthenticated call to the gateway is refused (no SVID at all)" bash -c '
  # -n default, not -n agents -- Kyverno'"'"'s require-spiffe-identity and
  # require-nonroot policies apply to agents/nimbus and reject a bare
  # curl pod with no SPIFFE CSI volume outright (confirmed live: the
  # admission webhook denies it before this test ever runs). The Service
  # FQDN is reachable cluster-wide regardless of the caller'"'"'s namespace,
  # so default avoids that admission check while still exercising the
  # real gateway path.
  kubectl run -n default verify-noauth --rm -i --restart=Never --image=curlimages/curl:8.11.0 --command -- \
    curl -s -o /dev/null -w "%{http_code}" http://mahi-gateway-stable.envoy-gateway-system.svc.cluster.local:8080/tools/lookup_order \
    -X POST -H "Content-Type: application/json" -d "{}" | grep -qE "^(401|403)$"
'

log "4. CloudNativePG cluster is Ready and the two agent login roles exist"
check "mahistores-db cluster Ready" kubectl -n data wait --for=condition=Ready cluster/mahistores-db --timeout=10s
check "agent_order_login can connect" bash -c '
  PW=$(kubectl -n data get secret agent-order-db-creds -o jsonpath="{.data.password}" | base64 -d)
  kubectl -n data run verify-pg-order --rm -i --restart=Never --image=postgres:16 --env="PGPASSWORD=$PW" --command -- \
    psql -h mahistores-db-rw.data.svc.cluster.local -U agent_order_login -d mahistores -c "SELECT 1" >/dev/null
'
check "agent_order_login is refused on customers (Postgres backstop)" bash -c '
  PW=$(kubectl -n data get secret agent-order-db-creds -o jsonpath="{.data.password}" | base64 -d)
  ! kubectl -n data run verify-pg-order-pii --rm -i --restart=Never --image=postgres:16 --env="PGPASSWORD=$PW" --command -- \
    psql -h mahistores-db-rw.data.svc.cluster.local -U agent_order_login -d mahistores -c "SELECT * FROM customers" >/dev/null 2>&1
'

log "5. end-to-end: the secure agent actually has a SPIFFE identity, no secret material in env"
check "agent-secure reports a real SPIFFE identity" bash -c '
  resp=$(kubectl -n agents exec deploy/agent-secure -c agent -- python3 -c "import urllib.request;print(urllib.request.urlopen(\"http://localhost:8000/status\").read().decode())")
  echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d[\"identity\"] and d[\"identity\"][\"spiffe_id\"], d"
'
check "no PASS/SECRET env vars in agent-secure" bash -c '
  ! kubectl -n agents exec deploy/agent-secure -c agent -- env | grep -iE "pass|secret"
'

log "6. the public storefront ALB is reachable"
check "storefront responds" curl -sf -o /dev/null "$STOREFRONT_URL/api/products"

log "7. open-source only -- no Enterprise/commercial references anywhere in the manifests"
check "no Enterprise/AuthConfig/license strings in k8s/ or policy/" bash -c '
  ! grep -rEl "Enterprise|entExtAuth|AuthConfig|EnterpriseAgentgatewayPolicy" "'"$REPO_ROOT"'/k8s" "'"$REPO_ROOT"'/policy" >/dev/null 2>&1
'

echo
log "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || die "fix the failures above before relying on this stack for a rehearsal"
