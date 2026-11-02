# DEMO SCRIPT

A full, speakable walkthrough of the talk -- continuous narration you could read almost verbatim
on stage, not bullet points to reconstruct in the moment. `docs/TALK-NOTES.md` is the terse
cheat-sheet version (the "lines" and the promise→mechanism table) for a quick glance mid-beat;
this file is the rehearsal script. `docs/RUNBOOK.md` covers provisioning/teardown, not delivery.

Two things this script does on purpose: it explains **every tool** in the stack in the order the
audience actually meets it (not an up-front slide dump), and it walks **one request's full
journey** end to end before the beats ever split it into four acts -- so by the time beat 1
starts, the audience already has the shape of the system in their head.

---

## Opening (~1 min)

> "This is Mahi Stores. Small retail site, one support chat widget, and -- behind the scenes --
> two AI agents that can look up orders and issue refunds on a real Postgres database, on a real
> Kubernetes cluster, right now, live.
>
> The question this talk answers is the one in the title: when an agent asks to do something,
> *who let it in* -- and what, exactly, is standing between 'the agent asked' and 'the action
> happened'?
>
> Every piece of what you're about to see is a CNCF project. Nothing proprietary, nothing you
> can't run yourself after this talk, on a free cluster, tonight."

---

## The flow, end to end (~3 min) -- and every tool, in order

Don't split this into beats yet. Walk the single path one request takes, tool by tool, so the
audience has the whole shape before the beats start pulling pieces apart.

> "Here's what happens between 'the agent decides to call a tool' and 'the database row changes.'
> Six things have to agree, in order, every single time -- not once at login."

**1. SPIRE issues the identity.**
Before the agent pod is even scheduled, SPIRE's Kubernetes workload attestor has already matched
it against a `ClusterSPIFFEID` -- a rule keyed on namespace and pod label, declared in Git. The
agent never asks for an identity; it's handed one, as a short-lived JWT-SVID (300 seconds), via a
Unix socket only that pod can reach. *"This is the part most systems skip -- the identity exists
*before* the first call, it isn't minted on request."*

**2. The agent calls mahi-tools -- through Envoy Gateway, never directly.**
Every tool call is a plain HTTP POST, `Authorization: Bearer <JWT-SVID>`, to one path per tool
(`/tools/issue_refund`, `/tools/lookup_order`, ...). It never reaches `mahi-tools` directly --
Envoy Gateway sits in front of it as *the agent gateway* the abstract names. Its
`SecurityPolicy` validates the SVID's signature against SPIRE's own rotating JWKS (fetched live
from SPIRE's OIDC Discovery Provider, not a static bundle that goes stale) and checks the
audience claim. Forged, expired, or wrong-audience tokens are refused here, before anything else
in the chain ever sees the request.

**3. OPA decides, on every single call.**
Envoy Gateway's `extAuth` hands the full request -- identity, path, and body -- to OPA over
`ext_authz`. OPA's Rego policy (`policy/rego/authz.rego`) answers one question: *may this exact
SPIFFE identity call this exact tool path, with this exact body?* Not "is this agent generally
trusted" -- this request, this call, right now. Refund amount and replica count are evaluated
here too, because the gateway forwards the body, not just headers.

**4. mahi-tools executes as a least-privileged identity, never as itself.**
If OPA allows it, `mahi-tools` -- the one service in this system that holds any standing
credential at all -- picks a Postgres login role or a Kubernetes ServiceAccount based on *which
SPIFFE identity called it*, not a shared service account. `order-agent` and `refund-agent` are
joined to two different Postgres group roles with different GRANTs, declared in Git
(`k8s/cnpg/cluster.yaml`). The Kubernetes path is scoped the same way -- RBAC narrowed to
`apps/deployments/scale` on one named Deployment.

**5. Postgres and Kubernetes RBAC are the backstop.**
Even if every layer above this let something through that shouldn't have, the database itself
doesn't have the grant, and the ServiceAccount doesn't have the RBAC. This is the layer that
doesn't care what any other layer decided -- it's enforced by the database and the API server
themselves, re-checked on every query.

**6. Kyverno and ArgoCD are the two you never see fire, unless something's wrong.**
Kyverno sits at admission, not on the request path -- every pod in the `agents` namespace must
mount a SPIFFE identity and must not carry a plain-text database password, or it's rejected
before it ever starts. ArgoCD means every policy, every GRANT, every admission rule you've just
heard about is a line in a Git repo, not a runtime `kubectl edit` someone could quietly make and
forget -- and if someone does edit it live, ArgoCD's `selfHeal` reverts it on its next sync.

> "That's the whole chain: SPIRE, Envoy Gateway, OPA, mahi-tools, Postgres/RBAC, Kyverno, ArgoCD.
> Four beats, same six things, every time -- just different requests hitting them."

---

## Beat 1 -- standing access is the problem (~3 min)

> "First, the anti-pattern -- the thing most agent deployments actually look like today. Switch
> the widget to the legacy agent."

**Do:** `kubectl get secret db-static-creds -n nimbus -o jsonpath='{.data.password}' | base64 -d`
on a second screen.

> "That's it. That's the entire security model for this agent -- a password, in a Secret, created
> once, never rotated, and about to be visible to every single tool call this agent ever makes for
> the rest of its life."

**Do:** ask it to refund order #1042 (your own order). It works.

> "Fine so far -- that's a legitimate refund."

**Do:** ask it to refund order #1046 -- Ilan's order, while "shopping as" Idhazhini.

> "...and that also works. The credential belongs to the *app*, not the *task*. It has no idea
> whose order this is, because nothing about this request carries an identity at all -- just a
> password that opens the same door for every request, forever, regardless of who's asking or
> what they're asking for."

---

## Beat 2 -- verified identity, no credential to steal (~5 min)

> "Now the real agent. Same chat widget, same database, same refund tool -- completely different
> security model underneath."

**Do:** `kubectl -n agents exec deploy/agent-secure -c agent -- env | grep -iE 'pass|secret'` --
nothing.

> "There is no secret in this pod to find. Not hidden somewhere else -- it doesn't exist. What
> this pod has instead is a workload identity, minted by SPIRE, written to a file only it can
> read, with a 300-second clock already running. Watch the Identity card -- that countdown is the
> SVID's real expiry, not a prop."

**Do:** ask it to refund order #1045. The stage graph lights Identity → Gateway → Policy →
Execute.

> "Gateway verified the signature. Policy decided *this identity, this call* is allowed. Execute
> ran it as a role that can SELECT orders and INSERT refunds -- and nothing else."

**Do:** ask for another customer's PII, or someone else's order.

> "Denied -- and this is not an if-statement somewhere in application code. PostgreSQL itself has
> no grant for this role on the `customers` table. There is no code path that could accidentally
> let this through, because there's no code making the decision at all."

**Do (the money shot):** open the Identity card so the countdown is visible on screen. In a second
terminal: `kubectl delete clusterspiffeid ai-order-agent`.

> "Watch the countdown, not me. I just told SPIRE to stop issuing this identity. Nothing happens
> to the token already in that pod -- it keeps working until it naturally expires, because SPIRE
> simply stops renewing it. There is no lease to revoke, no key to rotate, because there was never
> a credential separate from the identity to begin with. When that countdown hits zero, this agent
> is inert -- and there is nothing left, for anyone, including me, to separately go revoke."

---

## Beat 3 -- policy on every call, and human intent (~4 min)

> "Identity and policy handle *can this agent do this*. Some actions also need a human to say
> *should it* -- right now, for this specific case."

**Setup before walking on stage:** `bash scripts/human-approval-login.sh "<your name>"`.

**Do:** ask for a refund clearly over the threshold (#1044, £122).

> "Same identity, same gateway, same OPA -- but this time the policy's answer isn't a flat
> allow or deny, it's 'ask a human first.' The graph pauses at Policy. Notice the approval card:
> it's not a text box for a name, it's an identity chip, because the only way to populate it is
> the cached presenter identity -- there's no way to type someone else's name in here and have it
> mean anything."

**Do:** click **Approve**.

> "Two things just happened, and it's worth being precise about which is which. The identity that
> actually *performs* this call hasn't changed at all -- it's still that same agent's own SVID,
> still expiring on its own clock. What's new is the *authorization*: a recorded 'approved by'
> header, checked by mahi-tools before it proceeds, and written into the refund row itself. I'll
> say this plainly because it matters: that header is not cryptographically signed. There's no
> real identity provider behind it in this build. Everything upstream of it -- the SVID, the
> gateway's JWT check, OPA's decision -- all of that is real. This one step is a recorded, audited
> convenience standing in for a harder problem, and I'd rather tell you that than let you assume
> otherwise."

**Do:** open the Approval card's detail drawer.

> "Approver, workload identity, and the action, together, in one record. The credential is gone
> the moment that SVID expires. This record is not -- those are deliberately different things."

**Do:** "the storefront is slow, scale it to 2 replicas" (auto-approves) -- then "scale it to 8"
(pauses for approval).

> "Same mechanism, completely different kind of action -- a Kubernetes operation, not a database
> row. OPA doesn't care that this is `kubectl scale` instead of `UPDATE refunds` -- it's still just
> identity, path, and body."

**Do:** approve it, with `kubectl -n nimbus get deploy storefront -w` visible on screen.

---

## Beat 4 -- the gateway catches what admission control can't (~3 min)

> "Last beat: two deliberate mistakes, on stage, live -- and two different layers that catch them,
> because they're different *kinds* of mistake."

**Part A -- a policy mistake.** Widen `order-agent`'s Postgres role in Git
(`k8s/cnpg/cluster.yaml`, add `mahi_refund_grp` to its `inRoles`), commit, push, let ArgoCD sync.

**Do:** confirm the privilege really widened: `\du agent_order_login` now shows the new
membership. Then ask `order-agent`'s own identity for a refund, directly -- **still denied.**

> "I just gave this role database-level permission to issue refunds, through Git, through a real
> ArgoCD sync -- and the refund is still denied. OPA's rule checks the *SPIFFE identity* calling
> this *exact path* -- never what privilege that identity's role happens to hold in Postgres right
> now. A git-committed mistake at the database layer didn't open anything at the gateway layer,
> because they're independent checks, not one check in two places."

**Part B -- a deployment mistake.** `kubectl apply` a pod in the `agents` namespace with a plain
static DB password and no SPIFFE volume.

**Do:** show it rejected at admission -- it never starts.

> "Kyverno caught this one before it ever ran. This is a *stronger* guarantee than 'the gateway
> would have denied its calls' -- it never got a chance to make a call at all."

**Closing line:**

> "Notice what just happened: the exact same OPA policy that quietly held in Part A, on a request
> that looked completely normal, is the same policy that gated a real human-approved refund back
> in beat 3. One policy, evaluated on every request, catching two completely different kinds of
> mistake -- a privilege that was widened, and a pod that should never have started. That's the
> whole talk: verified identity, policy on every call, least privilege as the backstop, and
> nothing standing to steal, anywhere in the chain."

---

## If asked: what's not real here

Covered in full in `docs/TALK-NOTES.md`'s own section of the same name -- say these plainly if
asked, don't wait to be caught: the `X-Approved-By` header isn't cryptographically verified;
"task-scoped" here means table/column-scoped, not row-scoped; the storefront's admin endpoints
have no application-level auth (IP allowlist only, which is why this is presenter-driven); and
the LangChain agent engine path isn't implemented in this build, only the deterministic one is.
