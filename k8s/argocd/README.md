# What is, and isn't, GitOps-managed here

Everything under `k8s/argocd/apps/` is a real ArgoCD `Application`, synced
from this Git repo (or a public Helm chart repo, with values pulled from
this Git repo) -- no manual `helm install` or `kubectl apply` for any of
it once `scripts/01-provision.sh` has bootstrapped ArgoCD itself.

**ArgoCD-managed (Git is the source of truth):**
- SPIRE (`spire-crds`, `spire` -- Helm, values from `k8s/spire/values.yaml`)
- CloudNativePG operator (Helm) + the `Cluster` CR, group roles' SQL
  bootstrap, and the two `managed.roles` login roles (`k8s/cnpg/`) --
  **this is where "revocation is a git commit" and beat 4's Postgres-
  privilege-widening demo actually happen**
- Kyverno (Helm) + every admission policy (`policy/kyverno/`)
- Envoy Gateway (Helm) + the Gateway/HTTPRoute/SecurityPolicy, OPA, and
  OPA's policy bundle generated straight from `policy/rego/*.rego`
  (`k8s/gateway/`) -- **this is where beat 4's "widen the policy in Git,
  OPA still denies" demo happens**
- `k8s/mahi-tools/rbac.yaml` (no deploy-time values -- safe to sync as-is)

**Deliberately NOT ArgoCD-managed** -- applied directly by
`scripts/01-provision.sh` via `envsubst | kubectl apply -f -`, and never
committed to Git in their substituted form:
- Every Secret in this repo (`db-static-creds`, `agent-order-db-creds`,
  `agent-refund-db-creds` in both namespaces, `storefront-db-creds`,
  `anthropic-api-key`) -- these carry real passwords, generated at
  provision time, which have no business in a public Git history even
  for a torn-down-daily demo.
- `k8s/agents/agent-secure-deployment.yaml`, `order-agent-deployment.yaml`,
  `agent-insecure.yaml`, `k8s/mahi-tools/deployment.yaml`,
  `k8s/storefront/deployment.yaml` -- each carries a `${IMAGE_REGISTRY}/
  ${IMAGE_TAG}` placeholder resolved at build time to a git-sha tag that
  does not exist until that build runs. GitOps-over-image-tags is a real,
  solved problem (ArgoCD Image Updater, Kustomize `images:` overrides) --
  deliberately not layered on for this demo, to keep the GitOps story
  focused on the two things the talk is actually about: policy and
  database privilege, not CI/CD plumbing.

This split is a deliberate scope decision, not an oversight: the parts of
this system that the abstract's "GitOps workflows" promise is actually
about -- who may call which tool, and what privilege an agent's identity
carries -- are 100% Git-backed and self-healing. Container build/deploy
is a separate, unglamorous, already-solved problem this demo doesn't need
to re-demonstrate.
