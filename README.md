# Who Let the Agent In?

Demo repo for the KubeCon + CloudNativeCon talk *"Who Let the Agent In? Securing Agentic AI with
Non-Human Identity in Cloud Native Infrastructure."* A small retail site, **Mahi Stores**, with an
AI support agent, shown as a live public website the audience watches on screen
(presenter-driven, audience doesn't browse it themselves).

**The pattern this demo proves out**: move from *trusted* agents to *verified* agents, with no
standing access to cloud native infrastructure. Two AI agent identities (`order-agent`,
`refund-agent`) never hold a database credential, a Kubernetes token with broad RBAC, or any
long-lived secret of any kind. Every tool call they make is verified, policy-checked, and
executed by something else on their behalf.

## Architecture

![Architecture diagram: audience through ALB into the EKS cluster, storefront and agent pods in namespace nimbus/agents, Envoy Gateway verifying JWTs and delegating to OPA, mahi-tools fanning out to CloudNativePG and the Kubernetes API, with Kyverno and ArgoCD as cross-cutting admission/GitOps controls](docs/images/architecture-diagram.png)

Every component is **Apache 2.0, open source, and CNCF-governed** -- SPIRE/SPIFFE, Open Policy
Agent, and Argo CD are CNCF graduated; Envoy (and Envoy Gateway, built on it) is CNCF graduated;
Kyverno is CNCF incubating; CloudNativePG is CNCF Sandbox (incubation under review). No licence
key, trial, or commercial tier anywhere in the stack -- the only non-OSS thing involved is AWS
itself, and the entire in-cluster blueprint runs identically on kind/k3d.

See `k8s/argocd/README.md` for exactly which parts of the system are GitOps-managed (policy,
database privilege, admission control -- the parts this talk is actually about) versus applied
directly by the provisioning script (Secrets; the handful of Deployments carrying an image tag
that doesn't exist in Git until the build that produces it runs).

## What's in the stack

The **application** -- storefront, chat UI, the two agent identities' business logic, the
Control Room-style "Agentic Workflow" panel -- is a small retail scenario purpose-built to make
the security story visible: two genuinely separate agent identities (read-only `order-agent` and
money-moving `refund-agent`), a legacy anti-pattern agent for contrast, and a real Kubernetes
operation (`scale_deployment`) alongside the refund flow so the gateway is visibly guarding the
cluster, not just application logic. The **security layer** underneath it is entirely CNCF
landscape: SPIRE, Envoy Gateway, OPA, Kyverno, CloudNativePG, and ArgoCD, plus a purpose-built
`mahi-tools` service that holds the only standing credentials in the system.

## Prerequisites

1. An AWS account with EKS/VPC/IAM/ECR permissions, authenticated in your shell (`aws sts
   get-caller-identity` should succeed).
2. This repo pushed to a real Git remote, with `${GIT_REPO_URL}` resolved to that remote's literal
   clone URL everywhere it appears under `k8s/argocd/` -- a **one-time** step, not a per-run
   variable (see `scripts/01-provision.sh`'s Phase 0 check, which refuses to run otherwise):
   ```bash
   grep -rl '${GIT_REPO_URL}' k8s/argocd | xargs sed -i '' "s|\${GIT_REPO_URL}|$(git remote get-url origin)|g"
   git add k8s/argocd && git commit -m "set GIT_REPO_URL for ArgoCD" && git push
   ```
3. `terraform`, `kubectl`, `helm`, `docker`, `aws` CLIs on your PATH.
4. A registry you can `docker push` to and the cluster can pull from. If using ECR, the three
   repositories are **not** Terraform-managed and must exist before Phase E of
   `scripts/01-provision.sh` runs:
   ```bash
   for repo in storefront agent mahi-tools; do
     aws ecr create-repository --repository-name "<name>/$repo" --region <region>
   done
   ```

Then:
```bash
export IMAGE_REGISTRY=<your ECR repo URI>
export LEGACY_DB_PASSWORD=<pick one -- becomes mahi_legacy's real password>
export STOREFRONT_DB_PASSWORD=<pick one -- becomes mahi_storefront's real password>
bash scripts/01-provision.sh
```

**This stack costs real money while it's up** (≈$0.43/hr -- see `docs/RUNBOOK.md`'s cost
breakdown). Run `scripts/destroy.sh` after every rehearsal. `scripts/03-verify.sh` is the
go/no-go gate -- run it after provisioning and again the morning of the talk.

This full stack has been provisioned end-to-end on a real EKS cluster, with every
`scripts/03-verify.sh` check passing (15/15). See `docs/RUNBOOK.md`'s "confirmed gotchas" for the
real issues that first live run found and fixed -- an ArgoCD CRD-sync regression, an OPA
ConfigMap-symlink crash, and the ECR-repo prerequisite above.

## The four beats

1. **Standing access is the problem** -- the legacy agent, a static password, refunds a stranger's
   order.
2. **Verified identity, no credential to steal** -- the real agent has no secret at all, only a
   SPIFFE identity that expires on its own.
3. **Policy on every call, and human intent** -- a large refund and a cluster-scaling request both
   pause for a human; approved or not, the gateway and OPA evaluate every single call.
4. **The gateway catches what admission control can't** -- widen a database role in Git, OPA still
   denies the call; deploy a non-compliant pod, Kyverno never lets it start.

Full presenter notes, talking points, and the promise→mechanism table: `docs/TALK-NOTES.md`.

## Docs

- `docs/RUNBOOK.md` -- provisioning order, anticipated gotchas, verification checklist, teardown.
- `docs/TALK-NOTES.md` -- the beats, what to say, what's real and what's an honest simplification.
- `docs/DEMO-SCRIPT.md` -- the full speakable script: every tool explained in the order the
  audience meets it, one request's end-to-end journey, then all four beats as continuous narration.
- `k8s/argocd/README.md` -- the GitOps boundary (what's in Git vs. applied directly).
