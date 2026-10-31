#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts/*.sh files: log/warn/die,
# tf_output, and the storefront_url fallback-to-localhost pattern (so a
# trimmed local stack keeps working unmodified for offline UI development).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Pulls a terraform output into the current shell. Fails loudly if
# `terraform apply` hasn't produced it yet -- better than silently
# continuing with an empty value.
tf_output() {
  local name="$1"
  local val
  val="$(terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null || true)"
  [ -n "$val" ] || die "terraform output '$name' is empty -- has 'terraform apply' run in $TF_DIR?"
  printf '%s' "$val"
}

# Polls until a resource EXISTS -- not until it's ready. Needed before
# `kubectl rollout status` / `kubectl wait --for=condition=...`, both of
# which error immediately with NotFound if the resource doesn't exist
# yet rather than waiting for it to appear. Confirmed the hard way on the
# first live provisioning run: ArgoCD needs real time to clone this repo
# and sync before anything it manages (SPIRE, CloudNativePG, Kyverno,
# Envoy Gateway) exists at all, and `set -euo pipefail` turned that gap
# into an immediate script abort.
wait_for_resource() {
  local kind="$1" name="$2" ns="$3" timeout="${4:-180}"
  local i=0
  until kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -lt "$timeout" ] || die "$kind/$name never appeared in namespace $ns within ${timeout}s -- check 'kubectl -n argocd get applications' for a sync error"
    sleep 1
  done
}

# Generic port-forward-then-poll-then-trap helper, parameterized so it
# works for any in-cluster Service -- OPA, the OIDC Discovery Provider, or
# anything else internal during scripted verification.
PF_PID=""
portforward_stop() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true; }

# portforward <namespace> <service> <local_port>:<remote_port> <health_path>
# Exports nothing itself -- callers read from 127.0.0.1:<local_port>.
portforward() {
  local ns="$1" svc="$2" ports="$3" health="$4"
  local local_port="${ports%%:*}"

  portforward_stop
  kubectl -n "$ns" port-forward "svc/$svc" "$ports" >/dev/null 2>&1 &
  PF_PID=$!
  trap portforward_stop EXIT

  local i=0
  until curl -sf "http://127.0.0.1:${local_port}${health}" >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -lt 30 ] || die "port-forward to svc/$svc in namespace $ns never came up"
    sleep 1
  done
}

# The storefront's public ALB hostname, once provisioned; falls back to
# localhost so a trimmed local stack (CloudNativePG + storefront +
# agent-insecure via docker-compose or kind) keeps working unmodified for
# offline UI development.
storefront_url() {
  local host
  host="$(kubectl --request-timeout=3s -n nimbus get ingress storefront -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [ -n "$host" ]; then
    printf 'http://%s' "$host"
  else
    printf 'http://localhost:8000'
  fi
}
: "${STOREFRONT_URL:=$(storefront_url)}"
