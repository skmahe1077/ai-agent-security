#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts/*.sh files.
#
# Ported from agentic-security-runtime-demo's scripts/lib/common.sh. Kept
# verbatim: log/warn/die, tf_output, the storefront_url fallback-to-localhost
# pattern. Dropped: vault_env/vault_root_token/vault_portforward_stop -- this
# demo has no Vault, so there is no imperative root-token dance to read back.
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

# Generic port-forward-then-poll-then-trap helper, parameterized instead of
# hardcoded to Vault the way the old repo's vault_env() was. Used to reach
# OPA, the OIDC Discovery Provider, or anything else internal during
# scripted verification.
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
