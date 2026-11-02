# TALK-NOTES

Pre-stage ritual: run `scripts/reset.sh` immediately before going on stage. Confirm the ALB is
healthy well before walking on (2-4 minutes of warm-up after any redeploy, not something to check
on the way to the podium). Have `scripts/record-demo.sh`'s output ready as a fallback video, with
the browser window as the primary frame.

## Promise → mechanism table

Keep this in view when cutting slides -- each promise from the abstract should land on-screen as
something that actually happened in the browser a moment earlier, not as a bullet point asserted
on its own.

| Promised | Demonstrated by |
|---|---|
| **Verify agent identity** | SPIRE's `ClusterSPIFFEID`s assign a SPIFFE identity per agent pod by namespace + pod label -- the identity exists before the agent ever calls the gateway, not minted on the fly. Beat 2 shows zero secret material in the pod's environment; the Identity card's live countdown is the SVID's own 300s TTL, not a cosmetic timer. |
| **Route agent actions through a controlled gateway** | Every single tool call either secure agent makes goes through Envoy Gateway -- beat 2's "no credential anywhere" claim and beat 4's "OPA still denies" claim are both really claims about this one chokepoint. |
| **Enforce least privilege** | Two genuinely separate Postgres login roles (`agent_order_login`/`agent_refund_login`), joined to two different group roles with different GRANTs, declared in Git (`k8s/cnpg/cluster.yaml`). order-agent's role has no INSERT on `refunds`, full stop -- enforced by PostgreSQL, re-checked on every query, not cached as a one-time decision. |
| **Bind every tool or API call to policy** | OPA's `extAuth` call happens on every request Envoy Gateway's `SecurityPolicy` sees -- not once at login. Beat 3's refund-threshold and replica-ceiling checks, and beat 4's identity-based `issue_refund` rule, are all the SAME mechanism applied to different requests. |
| **Require approval for risky operations** | Beat 3: a £122 refund and an 8-replica scale request both pause for a human; the storefront's approval card is populated from a cached presenter identity, forwarded as `X-Approved-By`, recorded in the refunds row (`issued_by`/`approved_by`/`correlation_id`) -- the action and the authorization are the same auditable event. |
| **Audit-ready controls across Kubernetes, cloud-native, and hybrid** | The Approval card's detail drawer shows approver + workload identity + the action together, and this record persists after the SVID that made the call has long since expired -- the ephemeral thing and the durable record of who authorized it are different things, on purpose. |

## Beat 1 -- standing access is the problem (~3 min)

> "The support widget is talking to `agent-insecure`: a static password, no identity, created
> once and never rotated."

**Presenter does** (`scripts/demo-beat1.sh` is the rehearsal harness; perform this live in the
browser on stage):
1. Show the secret in the clear in a presenter terminal, second window:
   `kubectl get secret db-static-creds -n nimbus -o jsonpath='{.data.password}' | base64 -d`
2. Ask it to refund **your own** order (#1042) -- it works.
3. Ask it to refund **someone else's** order (#1046, Ilan's, while "shopping as" Idhazhini) -- it
   also works.

**The line:** *"the credential belongs to the app, not the task -- it has no idea whose order
this is."*

## Beat 2 -- verified identity, no credential to steal (~5 min)

Switch the widget to `agent-secure`.

**Presenter does:**
1. `kubectl -n agents exec deploy/agent-secure -c agent -- env | grep -iE 'pass|secret'` --
   nothing. *"There is no secret in this pod to find."*
2. *(Optional.)* `cat /svids/jwt_svid.token`, decode the payload: `sub` is the full SPIFFE ID,
   `aud: gateway`, `exp` five minutes out. The Identity card already shows this and a live
   countdown -- cutting this step saves a window switch at the exact moment the panel is most
   interesting.
3. Ask it to refund order #1045. Identity lights first; Gateway and Policy both light green
   (verified, allowed); Execute shows the refund landing, scope `orders:SELECT`, `refunds:INSERT`,
   `customers: ✗ denied`.
4. Ask for another customer's order, or PII directly -- denied, and say why: *"this isn't an
   if-statement -- PostgreSQL itself has no grant for this role on `customers`."*
5. **The money shot**: there is no lease to revoke on command here, because there was never a
   separate credential behind the identity to begin with. Open the
   Identity card -- the SVID countdown is already live. In a second terminal:
   `kubectl delete clusterspiffeid ai-order-agent`. **The line:** *"its identity itself expires --
   there is nothing standing to steal, and nothing left for anyone, including me, to separately
   revoke."* This takes up to 5 minutes to fully play out (SPIRE simply stops renewing, it doesn't
   instantly kill the current SVID) -- show the mechanism and the live countdown rather than
   waiting it out on stage unless time allows.

## Beat 3 -- policy on every call, and human intent (~4 min)

**Setup, before walking on stage:** `bash scripts/human-approval-login.sh "<your name>"`. Caches your
name as the approver for the next 30 minutes -- NOT a real IdP login. If skipped, the Approve
button is disabled with an explicit reason, not a silent failure.

**Presenter does:**
1. Ask for a refund clearly too large (#1044, £122) -- the graph pauses at Policy (amber); the
   approval card shows an identity chip ("Approve as **you** -- expires in Nm") instead of a
   text box.
2. Click **Approve**. Two things are true at once: the identity performing the call is still the
   verified agent's own SVID (nothing about the agent's identity changed); the *authorization*
   now carries a recorded, audited `X-Approved-By` header mahi-tools checks before proceeding.
   **Say plainly if asked**: this is NOT cryptographically verified delegation (no Vault OBO in
   this build) -- it's a recorded, audited convenience. What IS cryptographically real in this
   demo is everything upstream of it: the SVID, Envoy Gateway's JWT check, OPA's policy decision.
3. Click the **Approval** card: the detail drawer shows approver + workload + action together.
   **The line:** *"the credential is gone the moment the identity that made this call expires --
   this record is not."*
4. **The Kubernetes op**: "the storefront is slow, scale it to 2 replicas" -- auto-approves (under
   OPA's ceiling). "scale it to 8" -- pauses for approval, same mechanism, a cluster action instead
   of a database row. Approve it; `kubectl -n nimbus get deploy storefront -w` on screen.

## Beat 4 -- the gateway catches what admission control can't (~3 min)

Entirely presenter-terminal -- see `scripts/demo-beat4.sh`, which walks through both halves with
the exact commands.

**Part A**: widen `order-agent`'s Postgres login role in **Git** (`k8s/cnpg/cluster.yaml`'s
`inRoles`) to include `mahi_refund_grp`, commit, push, let ArgoCD sync it. Confirm the privilege
really widened (`\du agent_order_login` shows the new membership). Then ask order-agent's own
identity for a refund again, directly (bypassing the storefront's dispatcher) -- **still denied**.
**The line:** *"OPA's rule is on the SPIFFE identity calling this exact path, never on whatever
Postgres privilege that identity's role happens to hold right now. A git-committed mistake didn't
open anything."*

**Part B**: `kubectl apply` a pod with a plain static DB password and no SPIFFE volume, in the
`agents` namespace -- Kyverno's `require-spiffe-identity` ClusterPolicy refuses it at admission.
It never even starts, a stronger guarantee than "the gateway would have denied its calls."

**Callback line:** *"the ceiling policy you just watched NOT catch a mistake, on a normal
request, is the SAME policy that gated the real approved refund in beat 3. One policy, two
request shapes, two different outcomes -- that contrast is the whole lesson."*

## If asked: what's not real here

Say these plainly -- a defensible simplification stated out loud is not a thing to hide:

- **The approval step's `X-Approved-By` header is not cryptographically verified.** No real IdP,
  no signed delegation token. What's upstream of it (SVID issuance, Envoy Gateway's JWT
  verification, OPA's policy decision) is all real; this one step is a recorded, audited
  convenience, not a cryptographic guarantee -- the one piece of the system with no
  off-the-shelf CNCF-landscape equivalent to build it from, said so rather than hidden.
- **"Task-scoped" means capability-and-lifetime-scoped, not row-scoped.** OPA's policy and
  Postgres's GRANTs both operate at the level of "which table/column," not "which specific row" --
  true row-level scoping would need PostgreSQL RLS driven by a session variable, not built here.
- **The storefront's admin endpoints have no application-level auth** -- access control is the
  ALB security-group IP allowlist, narrowed to the presenter's IP right before the talk. This is
  why the demo is presenter-driven rather than audience-browsed.
- **The `AGENT_ENGINE=langchain` path is not implemented in this build** -- only the deterministic
  regex-based engine is, and it's what every beat above is validated against. Carried over as an
  explicit, disclosed scope cut, not a silent gap.
