#!/usr/bin/env bash
# Stands up the whole stack from nothing: AWS infra (EKS/VPC + the AWS
# Load Balancer Controller + ArgoCD) via Terraform, then everything else
# -- SPIRE, CloudNativePG, Kyverno, Envoy Gateway, OPA, every policy -- via
# ArgoCD from this same Git repo. See k8s/argocd/README.md for exactly
# which parts of the system are GitOps-managed and which are applied
# directly (Secrets, and the few Deployments carrying an
# ${IMAGE_REGISTRY}/${IMAGE_TAG} placeholder that doesn't exist in Git
# until this script's own build step runs).
#
# Just two `terraform apply`s: one targeted apply (EKS has to exist
# before the kubernetes/helm providers can evaluate at all), one full
# apply, done. Everything else is ArgoCD, not Terraform.
#
# NOT YET RUN END-TO-END AGAINST A LIVE CLUSTER as of this writing --
# written carefully and cross-checked against the Helm charts
# (`helm template`) and Rego (`opa eval`) during planning, but expect to
# debug real issues on the first real run. Keep this comment's honesty
# intact if you fix something here -- add to docs/RUNBOOK.md's gotchas
# section instead of silently patching.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IMAGE_REGISTRY="${IMAGE_REGISTRY:?set IMAGE_REGISTRY to an ECR repo URI, e.g. 123456789012.dkr.ecr.eu-west-1.amazonaws.com/kubecon-agent-demo}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)}"
LEGACY_DB_PASSWORD="${LEGACY_DB_PASSWORD:?set LEGACY_DB_PASSWORD -- becomes mahi_legacy's real password, see app/db/04_legacy_role.sql}"
STOREFRONT_DB_PASSWORD="${STOREFRONT_DB_PASSWORD:?set STOREFRONT_DB_PASSWORD -- becomes mahi_storefront's real password, see app/db/05_storefront_role.sql}"
NAME="${NAME:-kubecon-agent-demo}"
ALB_INBOUND_CIDRS="${ALB_INBOUND_CIDRS:-0.0.0.0/0}"
AGENT_ENGINE="${AGENT_ENGINE:-deterministic}"

log "Phase 0 -- credentials and repo sanity"
aws sts get-caller-identity >/dev/null || die "run 'aws sso login' (or equivalent) first"
if grep -rl '${GIT_REPO_URL}' "$REPO_ROOT/k8s/argocd" >/dev/null 2>&1; then
  die "k8s/argocd/**/*.yaml still has a literal \${GIT_REPO_URL} placeholder. This is a ONE-TIME repo setup step, not a per-run env var: GIT_REPO_URL never changes once the repo exists, so ArgoCD's own git-sync would fight a runtime envsubst on every reconcile. Fix once: \`grep -rl '\\\${GIT_REPO_URL}' k8s/argocd | xargs sed -i '' \"s|\\\${GIT_REPO_URL}|\$(git -C '$REPO_ROOT' remote get-url origin)|g\"\`, commit, push."
fi

log "Phase A -- AWS infra (VPC, EKS, IRSA roles) -- no helm/argocd resources yet"
terraform -chdir="$TF_DIR" init
# The kubernetes/helm Terraform providers (versions.tf) derive their
# config from module.eks's outputs, unknown on an empty-state plan -- EKS
# has to exist before those providers can be evaluated at all. gp2_default MUST
# be in this phase too: SPIRE's and CloudNativePG's PVCs (both ArgoCD-
# managed, synced in Phase C below) stay Pending forever without it.
terraform -chdir="$TF_DIR" apply -auto-approve \
  -target=module.vpc -target=module.eks -target=module.ebs_csi_irsa \
  -target=kubernetes_annotations.gp2_default

eval "$(tf_output eks_update_kubeconfig_command)"

log "Phase B -- the AWS Load Balancer Controller + ArgoCD itself"
terraform -chdir="$TF_DIR" apply -auto-approve
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s

log "Phase C -- data namespace + DB bootstrap SQL + agent/refund login-role Secrets"
# These three steps have to land BEFORE ArgoCD's cnpg-resources Application
# (bootstrapped in Phase D) ever syncs the CloudNativePG Cluster CR --
# postInitApplicationSQLRefs only runs once, at cluster creation, and the
# managed.roles Secrets should exist before the operator's first
# reconcile rather than erroring and retrying.
kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace nimbus --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace agents --dry-run=client -o yaml | kubectl apply -f -

SQL_DIR="$(mktemp -d)"
cp "$REPO_ROOT/app/db/01_schema.sql" "$REPO_ROOT/app/db/02_seed.sql" "$REPO_ROOT/app/db/03_group_roles.sql" "$SQL_DIR/"
LEGACY_DB_PASSWORD="$LEGACY_DB_PASSWORD" envsubst '${LEGACY_DB_PASSWORD}' < "$REPO_ROOT/app/db/04_legacy_role.sql" > "$SQL_DIR/04_legacy_role.sql"
STOREFRONT_DB_PASSWORD="$STOREFRONT_DB_PASSWORD" envsubst '${STOREFRONT_DB_PASSWORD}' < "$REPO_ROOT/app/db/05_storefront_role.sql" > "$SQL_DIR/05_storefront_role.sql"
kubectl -n data create configmap mahi-db-bootstrap --from-file="$SQL_DIR" --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$SQL_DIR"

# Two internal, machine-generated passwords -- nobody types these, they
# only exist so mahi-tools and CloudNativePG agree on the same two login
# roles' credentials. One value, two Secrets each (data + agents
# namespaces) -- see k8s/cnpg/agent-db-secrets.yaml's header comment.
AGENT_ORDER_DB_PASSWORD="$(openssl rand -base64 24)"
AGENT_REFUND_DB_PASSWORD="$(openssl rand -base64 24)"
export AGENT_ORDER_DB_PASSWORD AGENT_REFUND_DB_PASSWORD
envsubst '${AGENT_ORDER_DB_PASSWORD} ${AGENT_REFUND_DB_PASSWORD}' < "$REPO_ROOT/k8s/cnpg/agent-db-secrets.yaml" | kubectl apply -f -
envsubst '${AGENT_ORDER_DB_PASSWORD} ${AGENT_REFUND_DB_PASSWORD}' < "$REPO_ROOT/k8s/mahi-tools/db-secrets.yaml" | kubectl apply -f -

log "Phase D -- bootstrap ArgoCD (app-of-apps); everything else now syncs from Git"
kubectl apply -f "$REPO_ROOT/k8s/argocd/app-of-apps.yaml"
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p "$(cat "$REPO_ROOT/k8s/argocd/argocd-cm-patch.yaml")"
# argocd-cm's own controller pod needs to pick up the patch before the
# `gateway` Application's Kustomize build will succeed -- a plain
# rollout restart, not a new release.
kubectl -n argocd rollout restart deployment/argocd-repo-server
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=120s

log "waiting for the controllers ArgoCD just installed (SPIRE, CloudNativePG, Kyverno, Envoy Gateway) -- can take several minutes on a cold cluster"
kubectl -n spire-mgmt rollout status statefulset/spire-server --timeout=300s
kubectl -n spire-mgmt rollout status daemonset/spire-agent --timeout=300s
kubectl -n cnpg-system rollout status deployment/cnpg-cloudnative-pg --timeout=300s
kubectl -n kyverno rollout status deployment/kyverno-admission-controller --timeout=300s
kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=300s

log "waiting for the CloudNativePG cluster to finish bootstrapping (runs app/db/*.sql exactly once)"
kubectl -n data wait --for=condition=Ready cluster/mahistores-db --timeout=300s

log "waiting for Envoy Gateway's actual proxy Deployment (created by the Gateway resource, not the controller itself)"
PROXY_DEPLOY=""
for i in $(seq 1 30); do
  PROXY_DEPLOY="$(kubectl -n envoy-gateway-system get deploy \
    -l "gateway.envoyproxy.io/owning-gateway-namespace=agents,gateway.envoyproxy.io/owning-gateway-name=mahi-gateway" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$PROXY_DEPLOY" ] && break
  sleep 5
done
[ -n "$PROXY_DEPLOY" ] || die "Envoy Gateway never created a proxy Deployment for mahi-gateway -- check 'kubectl -n agents get gateway mahi-gateway -o yaml' for a Scheduled/Accepted condition"
kubectl -n envoy-gateway-system rollout status "deployment/$PROXY_DEPLOY" --timeout=180s

log "Phase E -- build and push images"
aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE_REGISTRY%%/*}"
# --platform linux/amd64 is NOT optional on Apple Silicon -- a plain
# `docker build` produces an arm64 image, which crashes every pod on
# these x86_64 EKS nodes with "exec format error".
docker build --platform linux/amd64 -f "$REPO_ROOT/app/storefront/Dockerfile" -t "$IMAGE_REGISTRY/storefront:$IMAGE_TAG" "$REPO_ROOT"
docker build --platform linux/amd64 -f "$REPO_ROOT/app/agent/Dockerfile" -t "$IMAGE_REGISTRY/agent:$IMAGE_TAG" "$REPO_ROOT"
docker build --platform linux/amd64 -f "$REPO_ROOT/app/mahi-tools/Dockerfile" -t "$IMAGE_REGISTRY/mahi-tools:$IMAGE_TAG" "$REPO_ROOT"
docker push "$IMAGE_REGISTRY/storefront:$IMAGE_TAG"
docker push "$IMAGE_REGISTRY/agent:$IMAGE_TAG"
docker push "$IMAGE_REGISTRY/mahi-tools:$IMAGE_TAG"

log "Phase F -- deploy the app (NOT via ArgoCD -- see k8s/argocd/README.md)"
export IMAGE_REGISTRY IMAGE_TAG NAME ALB_INBOUND_CIDRS LEGACY_DB_PASSWORD STOREFRONT_DB_PASSWORD AGENT_ENGINE

for f in "$REPO_ROOT"/k8s/agents/*.yaml "$REPO_ROOT"/k8s/mahi-tools/deployment.yaml "$REPO_ROOT"/k8s/storefront/*.yaml; do
  envsubst < "$f" | kubectl apply -f -
done
kubectl -n agents rollout status deployment/agent-secure --timeout=120s
kubectl -n agents rollout status deployment/order-agent --timeout=120s
kubectl -n agents rollout status deployment/mahi-tools --timeout=120s
kubectl -n nimbus rollout status deployment/agent-insecure --timeout=120s
kubectl -n nimbus rollout status deployment/storefront --timeout=120s

log "waiting for the storefront ALB to come up (2-4 min is normal)"
for i in $(seq 1 60); do
  ALB_HOST="$(kubectl -n nimbus get ingress storefront -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$ALB_HOST" ] && curl -sf -o /dev/null "http://$ALB_HOST/api/products" && break
  sleep 5
done
[ -n "${ALB_HOST:-}" ] || warn "ALB did not come up within 5 minutes -- check 'kubectl -n nimbus describe ingress storefront'"

log "Phase G -- go/no-go gate"
"$REPO_ROOT/scripts/03-verify.sh"

log "done. storefront: http://${ALB_HOST:-<pending>}  (narrow ALB_INBOUND_CIDRS before the talk, not after)"
log "argocd: kubectl -n argocd port-forward svc/argocd-server 8080:80 -- admin / \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
