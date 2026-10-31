package envoy.authz

# The policy Envoy Gateway's SecurityPolicy.extAuth (k8s/gateway/security-policy.yaml)
# calls on every single /tools/* request mahi-tools could receive. This is
# "bind every tool or API call to policy" and "enforce least privilege",
# literally: `result` below is the only thing standing between a verified
# SPIFFE identity and mahi-tools actually running a query.
#
# What this file DOES decide: which SPIFFE identity may call which tool
# PATH at all (order-agent can never even reach issue_refund), and the
# scale_deployment replica threshold (a property of the request itself,
# fully knowable here).
#
# What this file DELIBERATELY DOES NOT decide: whether a specific refund
# amount needs approval. That decision needs the order's REAL total,
# which only mahi-tools has (it queries Postgres) -- OPA has no database
# access and would otherwise be trusting a number the calling agent
# self-reported, which defeats the point of a policy layer. See
# app/mahi-tools/src/actions.py's `issue_refund` for that check instead.
# This is a deliberate division of labour, not an oversight: OPA owns
# identity- and request-shape-based policy; mahi-tools (backed by
# Postgres GRANTs as the last line of defence) owns anything that needs
# ground truth.

import rego.v1

order_agent_spiffe_id := "spiffe://mahistores.demo/ns/agents/sa/ai-order-agent"
refund_agent_spiffe_id := "spiffe://mahistores.demo/ns/agents/sa/ai-support-agent-secure"

scale_auto_approve_ceiling := 3
scale_hard_ceiling := 10

default result := {
	"allowed": false,
	"http_status": 403,
	"body": "{\"reply\": \"I'm not able to do that.\", \"events\": [{\"type\": \"denied\", \"resource\": \"policy\", \"message\": \"no policy matched this request\"}]}",
}

# ---- headers / body plumbing -----------------------------------------

_headers := input.attributes.request.http.headers

# object.get, not a bare index -- an absent header must come back as "",
# not undefined, or every rule body that compares it (e.g. `_approved_by
# == ""`) silently fails to match instead of denying as intended. This is
# exactly the bug this file shipped with on the first pass: a missing
# X-Approved-By header fell through to the generic default-deny instead
# of the specific 428 approval_required response, caught by evaluating
# this policy against real inputs before trusting it.
_spiffe_id := object.get(_headers, "x-spiffe-id", "")

_approved_by := object.get(_headers, "x-approved-by", "")

_path := input.attributes.request.http.path

default _body := {}

_body := json.unmarshal(input.attributes.request.http.body) if input.attributes.request.http.body != ""

_denied_body(message) := json.marshal({"reply": "I'm not able to do that.", "events": [
	{"type": "denied", "resource": "policy", "message": message},
]})

# ---- lookup_order: either secure identity ------------------------------

result := {"allowed": true} if {
	_path == "/tools/lookup_order"
	_spiffe_id in {order_agent_spiffe_id, refund_agent_spiffe_id}
}

# ---- peek_order_total: either secure identity --------------------------

result := {"allowed": true} if {
	_path == "/tools/peek_order_total"
	_spiffe_id in {order_agent_spiffe_id, refund_agent_spiffe_id}
}

# ---- lookup_customer_pii: allowed by POLICY for either identity --------
# Deliberately not restricted here -- the point of beat 2 is that
# PostgreSQL itself refuses this query (neither mahi_order_grp nor
# mahi_refund_grp has ever been granted SELECT on customers), not that
# the policy layer never let the request through. Denying it here too
# would be correct in production but would hide the backstop this demo
# exists to show.

result := {"allowed": true} if {
	_path == "/tools/lookup_customer_pii"
	_spiffe_id in {order_agent_spiffe_id, refund_agent_spiffe_id}
}

# ---- issue_refund: refund-agent's identity ONLY -------------------------
# THE rule that makes beat 4's point: this check is on the SPIFFE identity
# making the HTTP call, not on whatever Postgres privilege that identity's
# login role happens to hold right now. Widening order-agent's role in Git
# to include mahi_refund_grp does not change this rule at all.

result := {"allowed": true} if {
	_path == "/tools/issue_refund"
	_spiffe_id == refund_agent_spiffe_id
}

result := {"allowed": false, "http_status": 403, "body": _denied_body(sprintf(
	"%s may not call POST /tools/issue_refund -- only the refund-agent identity can, regardless of its current database privileges",
	[_spiffe_id],
))} if {
	_path == "/tools/issue_refund"
	_spiffe_id != refund_agent_spiffe_id
}

# ---- scale_deployment: either identity, gated on replica count ---------

result := {"allowed": true} if {
	_path == "/tools/scale_deployment"
	_spiffe_id in {order_agent_spiffe_id, refund_agent_spiffe_id}
	_body.replicas <= scale_auto_approve_ceiling
}

result := {"allowed": true} if {
	_path == "/tools/scale_deployment"
	_spiffe_id in {order_agent_spiffe_id, refund_agent_spiffe_id}
	_body.replicas > scale_auto_approve_ceiling
	_body.replicas <= scale_hard_ceiling
	_approved_by != ""
}

result := {"allowed": false, "http_status": 428, "body": json.marshal({
	"reply": "This scaling request needs a human's approval first.",
	"events": [{
		"type": "approval_required",
		"replicas": _body.replicas,
		"message": sprintf(
			"scaling to %d replicas exceeds the auto-approval ceiling of %d and needs a human to sign off",
			[_body.replicas, scale_auto_approve_ceiling],
		),
	}],
})} if {
	_path == "/tools/scale_deployment"
	_spiffe_id in {order_agent_spiffe_id, refund_agent_spiffe_id}
	_body.replicas > scale_auto_approve_ceiling
	_body.replicas <= scale_hard_ceiling
	_approved_by == ""
}

result := {"allowed": false, "http_status": 403, "body": _denied_body(sprintf(
	"%d replicas exceeds this policy's hard ceiling of %d, approved or not",
	[_body.replicas, scale_hard_ceiling],
))} if {
	_path == "/tools/scale_deployment"
	_body.replicas > scale_hard_ceiling
}
