# RUNBOOK

**Honesty note up front**: this repo has been built carefully -- every Helm chart version, image
tag, Rego rule, and Kustomize/ArgoCD pattern in it was checked against a real source (`helm
search repo --versions`, `helm pull`, `opa eval` against real fixtures, the actual Go source of
Envoy Gateway's CRDs, `jmespath` library tests for the Kyverno expressions) rather than assumed.
But it has **not yet been run end-to-end against a live cluster**. Treat the "anticipated
gotchas" section below as exactly that -- informed predictions, not confirmed war stories. When
you hit a real one, move it into "confirmed gotchas" with the date and what actually happened.

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

## Anticipated gotchas (not yet confirmed live -- watch for these first)

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
3. **CloudNativePG's exact `Cluster` Ready-condition semantics** haven't been exercised against a
   real instance yet -- `kubectl wait --for=condition=Ready cluster/mahistores-db` is the
   documented pattern, but if the operator reports readiness differently than expected, watch
   `kubectl -n data describe cluster mahistores-db` rather than trusting the wait silently hanging.
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
