# RUNBOOK

**Honesty note up front**: this repo has been built carefully -- every Helm chart version, image
tag, Rego rule, and Kustomize/ArgoCD pattern in it was checked against a real source (`helm
search repo --versions`, `helm pull`, `opa eval` against real fixtures, the actual Go source of
Envoy Gateway's CRDs, `jmespath` library tests for the Kyverno expressions) rather than assumed.
**It has since been run end-to-end against a real EKS cluster twice** (2026-10-31, then again
from a full teardown/rebuild on 2026-11-02) -- every `scripts/03-verify.sh` check passes (15/15)
both times. The real issues each run found are in "confirmed gotchas" below, with what actually
happened and the fix now in Git. The "anticipated gotchas" section after it is what's left:
informed predictions for areas that run cleanly worked but haven't been stress-tested (chart
version bumps, a rehearsal on a different AWS account, etc).

## Confirmed gotchas (found on the first live run, 2026-10-31)

1. **ArgoCD's Helm-chart CRD sync hits a real regression on large CRDs**
   (argoproj/argo-cd#28421) -- `cloudnative-pg-operator`, `kyverno-controller`, and
   `envoy-gateway-controller` all failed sync with `metadata.annotations: Too long: may not be
   more than 262144 bytes` on their biggest CRDs (`clusters.postgresql.cnpg.io`,
   `clusterpolicies.kyverno.io`, `httproutes.gateway.networking.k8s.io`, etc). Neither
   `ServerSideApply=true`/`Replace=true` nor Helm's `source.helm.skipCrds` nor a per-Application
   `ignoreDifferences` on the CRD's annotations stopped it -- ArgoCD's sync path does a one-time
   bootstrap client-side-apply (writing the full oversized `last-applied-configuration`
   annotation) for any CRD it doesn't yet recognize as ArgoCD-managed, regardless of those
   settings. The fix that actually works: `resource.exclusions` in `k8s/argocd/
   argocd-cm-patch.yaml` removes `CustomResourceDefinition` from ArgoCD's pipeline entirely. CRD
   schemas are applied once, out-of-band: `helm template <chart> --include-crds | kubectl apply
   --server-side --force-conflicts`. ArgoCD still manages every non-CRD resource in those charts
   normally.
2. **OPA crash-looped with `rego_type_error: multiple default rules ... found`** --
   `k8s/gateway/opa-deployment.yaml` ran `opa run /policy` against the whole ConfigMap-mounted
   directory. ConfigMap volumes expose each key through both a `..data` symlink directory and a
   top-level symlink of the same name into it; OPA's directory walk followed both paths to the
   same inode and loaded `authz.rego` twice under different module paths, which it then rejected
   outright. Fixed by pointing OPA at the single file (`/policy/authz.rego`), not the directory.
3. **The ECR repositories are not Terraform-managed** and don't exist on a fresh AWS account --
   `scripts/01-provision.sh`'s Phase E (`docker push`) fails with `RepositoryNotFoundException`
   until `aws ecr create-repository` is run for each of `storefront`/`agent`/`mahi-tools` first.
   See the README's prerequisites.
4. **The SPIRE chart prefixes every `clusterSPIFFEIDs.*` key** from `k8s/spire/values.yaml` with
   `<namespace>-<releaseName>-` -- the live resource is `spire-mgmt-spire-ai-order-agent`, not the
   bare `ai-order-agent` several scripts originally assumed. Fixed in `scripts/03-verify.sh` (match
   by name suffix) and `scripts/demo-beat2.sh` (resolve the real name at run time before the
   on-stage `kubectl delete clusterspiffeid` command).
5. **`kubectl run --rm` appends `pod "..." deleted` to stdout on the same line as the wrapped
   command's own output**, with no separating newline -- a status-code check in
   `scripts/03-verify.sh` anchored at end-of-line (`grep -qE '^(401|403)$'`) always failed
   regardless of the real response. Anchor at start-of-line only when checking output from a
   `kubectl run --rm` pod.

## Confirmed gotchas (found on a full teardown/rebuild, 2026-11-02)

The fixes above all held up on this second run with zero changes needed. Two new, previously
unseen issues showed up -- both because the first live run never actually started from a
*completely* empty cluster (it inherited some state from manual debugging along the way).

6. **`resource.exclusions` (gotcha #1 above) stops ArgoCD from installing CRDs at all on a fresh
   cluster, not just from mishandling large ones.** On 2026-10-31 this was never noticed because
   by the time `resource.exclusions` was added, every affected chart's CRDs already existed on
   that cluster (applied manually during the same debugging session) -- `resource.exclusions`
   only ever had to stop ArgoCD from *re-applying* CRDs that were already correct. On a genuinely
   fresh cluster there's nothing to fall back on: `spire-crds`, `cloudnative-pg-operator`,
   `kyverno-controller`, and `envoy-gateway-controller` all report `Synced/Healthy` immediately
   with precisely nothing to do, while the actual CRDs (`clusterspiffeids.spire.spiffe.io`,
   `clusters.postgresql.cnpg.io`, `clusterpolicies.kyverno.io`,
   `httproutes.gateway.networking.k8s.io`, etc.) never get created, and every controller that
   depends on them crash-loops with "no matches for kind ... in version ...". **Fixed**:
   `scripts/01-provision.sh`'s new Phase D.5 renders and server-side-applies all four charts' CRDs
   directly (`helm template <chart> --include-crds | kubectl apply --server-side
   --force-conflicts`) immediately after the ArgoCD bootstrap, before waiting on any controller.
   This has to run on *every* fresh provision now, not just once ever -- it is a permanent
   consequence of keeping `resource.exclusions`, not a one-time bootstrap step.
7. **The `spire-mgmt` namespace was never actually created by anything persisted in this repo.**
   It only existed on the first live run because of a one-off manual `kubectl create namespace`
   made during that session's debugging and never written down anywhere. On the from-scratch
   rebuild, the `spire` Application's sync failed outright with `namespaces "spire-mgmt" not
   found`, plus a cascading `no endpoints available for service
   "spire-controller-manager-webhook"` once retried, since nothing in the namespace had started
   yet. `spire-crds.yaml` already had `syncOptions: [CreateNamespace=true]`, but that Application's
   entire resource set is CRDs -- now excluded from ArgoCD's pipeline by gotcha #6's fix above, so
   it has nothing left to sync and `CreateNamespace` never fires. **Fixed**: added
   `CreateNamespace=true` to `k8s/argocd/apps/spire.yaml` instead, which still manages real
   namespaced resources (Deployments, StatefulSets, ServiceAccounts) and so still triggers
   namespace creation correctly.

## Provisioning order, and why it's still phased

Terraform only needs two applies, not one, for a specific reason: the
`kubernetes`/`helm` Terraform providers (`terraform/versions.tf`) derive their configuration from
`module.eks`'s outputs, which don't exist on an empty-state plan. EKS has to exist before those
providers can be evaluated at all -- Phase A targets just `module.vpc`/`module.eks`/
`module.ebs_csi_irsa`/`kubernetes_annotations.gp2_default`; Phase B is the full, untargeted apply
(the AWS Load Balancer Controller + ArgoCD).

From there, **everything else is ArgoCD, not Terraform or hand-run Helm** -- SPIRE, the
CloudNativePG operator and `Cluster`, Kyverno and every policy, Envoy Gateway and OPA. See
`k8s/argocd/README.md` for the exact boundary between what's GitOps-managed and what
`scripts/01-provision.sh` applies directly (Secrets, and the few Deployments whose image tag
doesn't exist in Git until that script's own build step runs).

One ordering constraint worth calling out explicitly: `scripts/01-provision.sh` creates the
`data` namespace, the `mahi-db-bootstrap` ConfigMap (the real SQL, envsubst'd), and the two
agent-login-role password Secrets **before** bootstrapping ArgoCD -- not after. CloudNativePG's
`postInitApplicationSQLRefs` only runs once, at the Cluster's creation, so that ConfigMap has to
exist before ArgoCD's `cnpg-resources` Application ever gets a chance to create the `Cluster`
resource. Reordering this is the single most likely way a fresh provision breaks in a way that's
confusing to debug (CloudNativePG will just silently skip the bootstrap SQL if the ConfigMap
didn't exist at creation time, not error loudly).

## Known EKS/Terraform gotchas (fixes already applied here)

Infrastructure-layer findings that are well-documented failure modes of this exact
module/addon combination -- the fixes are already applied in this repo's Terraform, not
something to rediscover on a fresh provision:

1. **EKS addon ordering deadlock.** `bootstrap_self_managed_addons = false` means nodes get no
   default networking at all until `vpc-cni`/`kube-proxy` install -- but the EKS Terraform
   module's default addon ordering waits for the node group to succeed FIRST. Fixed by marking
   `vpc-cni`/`kube-proxy` `before_compute = true` in `terraform/eks.tf`.
2. **`gp2` is not actually the EKS cluster-default StorageClass**, despite shipping on every
   cluster. Any PVC without an explicit `storageClassName` (SPIRE's, CloudNativePG's) hangs
   `Pending` forever without the `kubernetes_annotations.gp2_default` resource in
   `terraform/eks.tf` -- already applied, in Phase A specifically (not deferred to the full apply),
   because SPIRE's PVC is created before the full apply ever runs.
3. **`docker build` on Apple Silicon needs `--platform linux/amd64`** for `t3.large` x86_64 nodes,
   or every pod crashes with "exec format error." Already in `scripts/01-provision.sh`.
4. **`spiffe-helper` versions before 0.12.2 have a concurrent-map-write crash** in daemon mode
   with JWT SVIDs -- exactly this configuration. Pinned to `0.12.2` in both agent manifests.
5. **Teardown hazards** -- see `scripts/destroy.sh`'s own header comment (ALB/Ingress ordering,
   StatefulSet PVCs not deleted by Helm uninstall, PVC deletion not meaning the EBS volume is
   gone yet).

## Fragile points (confirmed working as-implemented on the 2026-10-31 live run -- don't break these)

Each of these worked correctly on the real cluster without needing a fix, but stays fragile to a
future edit -- worth knowing what to watch if any of these files change.

1. **The SPIRE chart's `global.spire.jwtIssuer` must exactly match Envoy Gateway's
   `SecurityPolicy.spec.jwt.providers[].issuer`** (`k8s/spire/values.yaml` vs.
   `k8s/gateway/security-policy.yaml`) -- currently both hardcoded to the same literal string by
   hand. If either is ever edited independently, every JWT-SVID gets refused with no obviously-
   related error message. Keep these two files' trust-domain-and-issuer strings in sync by eye
   until there's a reason to template them.
2. **`kustomize.buildOptions: --load-restrictor LoadRestrictionsNone`** (`k8s/argocd/
   argocd-cm-patch.yaml`) has to actually take effect on `argocd-repo-server` before the `gateway`
   Application's build will succeed -- `01-provision.sh` restarts that Deployment after patching
   the ConfigMap, but if ArgoCD ever changes how it watches `argocd-cm` for live reload, this step
   may need revisiting.
3. **CloudNativePG's `Cluster` Ready condition** (`kubectl wait --for=condition=Ready
   cluster/mahistores-db`) reported readiness correctly and the webhook's TLS cert self-resolved
   once the operator pod stabilized -- if a future run sees a persistent `x509: certificate signed
   by unknown authority` on the `mcluster.cnpg.io` webhook, check `cnpg-system` pod restart counts
   before assuming something else is wrong.
4. **Envoy Gateway's remote JWKS over plain HTTP** (`k8s/gateway/security-policy.yaml`'s
   `remoteJWKS.uri: http://...`) is a deliberate simplification (matching SPIRE's own OIDC
   Discovery Provider being configured with `tls.spire.enabled: false`) but is less load-bearing
   documentation than the HTTPS path the upstream docs describe -- if JWT validation fails
   mysteriously, check this first, specifically whether Envoy actually fetched the JWKS at all
   (`kubectl -n envoy-gateway-system logs deploy/<proxy-deployment-name>`).
5. **The OPA policy ConfigMap's name must stay `mahi-opa-policy`** across `k8s/gateway/
   kustomization.yaml`'s `configMapGenerator` and `k8s/gateway/opa-deployment.yaml`'s volume
   reference -- `disableNameSuffixHash: true` keeps this stable across edits, but if that option
   is ever removed, OPA's pod spec needs the new hashed name too, or it mounts a stale
   ConfigMap.
6. **mahi-tools' `agent_order_login`/`agent_refund_login` Secrets must exist in BOTH the `data`
   namespace (for CloudNativePG's `managed.roles`) and the `agents` namespace (for mahi-tools'
   own Deployment)**, with identical passwords -- `scripts/01-provision.sh` generates each
   password once and writes both copies in the same step; if these ever drift (e.g. one Secret
   edited by hand), mahi-tools will fail to authenticate while CloudNativePG reports the role as
   healthy, a confusing split.

## Verification checklist

Run `scripts/03-verify.sh`. It checks, independently (one failure doesn't hide the shape of the
others):

1. SPIRE is up and both `ClusterSPIFFEID`s are registered.
2. The OIDC Discovery Provider's JWKS endpoint is reachable in-cluster.
3. Envoy Gateway's proxy Deployment and OPA both exist and are healthy; an unauthenticated call to
   the gateway (no SVID at all) is refused with 401/403.
4. CloudNativePG's cluster is Ready; `agent_order_login` can connect and is refused on `customers`
   (the Postgres backstop, independent of whatever OPA or the gateway decided).
5. The secure agent reports a real SPIFFE identity and has no secret material in its environment.
6. The public storefront ALB responds.
7. **No `Enterprise`/`AuthConfig`/licence string anywhere in `k8s/` or `policy/`** -- the OSS-only
   constraint, checked mechanically, not just asserted.

Beyond the script, worth doing by hand at least once per rehearsal:

- **Negative test**: run an agent under the wrong ServiceAccount (or delete a `ClusterSPIFFEID`)
  and confirm no SVID gets issued -- proves identity is enforced, not decorative.
- Ask `order-agent` directly for a refund (bypass the storefront's dispatcher, talk to its own
  `/chat`) and confirm a clean `denied` event from OPA, not a 500.
- `kubectl apply` a non-compliant agent pod (see `scripts/demo-beat4.sh`'s Part B) and confirm
  Kyverno rejects it at admission.
- `kubectl edit` a Kyverno policy or the OPA policy ConfigMap by hand and confirm ArgoCD reverts
  it (`argocd app sync kyverno-policies` or `gateway` to force it immediately rather than waiting
  out the default ~3-minute resync).
- Run all four beats back-to-back, twice, with `scripts/reset.sh` between runs.

## Cost

eu-west-1, on-demand: EKS control plane ~$0.10/hr + 3× `t3.large` ~$0.25/hr + single NAT gateway
~$0.048/hr + ALB ~$0.025/hr + EBS (SPIRE + CloudNativePG PVCs) ~$0.003/hr ≈ **$0.43/hr ≈ $10/day**.
No KMS key anywhere in this stack -- no 7-day pending-deletion tail to remember after teardown.

## Teardown

**Run `scripts/destroy.sh` after every rehearsal.** It is not optional -- this stack bills by the
hour whether or not anyone is using it. See that script's own header comment for the specific
hazards (ALB/Ingress ordering, StatefulSet PVCs surviving Helm uninstall, PVC deletion not
meaning the EBS volume is gone yet) it exists to avoid.
