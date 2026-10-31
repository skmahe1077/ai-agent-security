"""mahi-tools: the one HTTP service that actually touches Postgres or the
Kubernetes API on an agent's behalf. Every route is reached ONLY through
Envoy Gateway (k8s/gateway/) -- by the time a request lands here, the
gateway has verified the caller's JWT-SVID against SPIRE's JWKS and OPA has
already decided this identity may call this path at all. This service
still re-checks ownership/threshold/ceiling and relies on Postgres GRANTs
as a backstop -- "bind every tool call to policy" is Envoy+OPA's job
upstream of this file, not a reason to skip checks here.

`X-Spiffe-Id` arrives via Envoy Gateway's SecurityPolicy.jwt.claimToHeaders
(claim `sub` -> header `X-Spiffe-Id`) -- see k8s/gateway/security-policy.yaml.
It is NOT re-verified here: trusting it is exactly what "only reachable
through the gateway" (enforced by a Kyverno-admitted NetworkPolicy, see
policy/kyverno/) is for.
"""
from __future__ import annotations

import logging

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

import actions
import k8s_actions
from config import load_settings

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("mahi-tools")

settings = load_settings()
app = FastAPI(title="mahi-tools")


def _require_spiffe_id(x_spiffe_id: str | None) -> str:
    if not x_spiffe_id:
        # Should be unreachable through the gateway -- a direct request
        # that skipped Envoy Gateway's JWT check entirely. Refuse loudly.
        raise HTTPException(status_code=401, detail="missing X-Spiffe-Id -- this endpoint is only reachable through the gateway")
    return x_spiffe_id


class LookupOrderBody(BaseModel):
    order_id: int
    requester_customer_id: int
    enforce_ownership: bool = True


class IssueRefundBody(BaseModel):
    order_id: int
    reason: str = ""
    requester_customer_id: int
    enforce_ownership: bool = True
    issued_by: str
    correlation_id: str | None = None


class LookupPiiBody(BaseModel):
    customer_id: int
    issued_by: str


class ScaleBody(BaseModel):
    replicas: int


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/tools/lookup_order")
def tools_lookup_order(body: LookupOrderBody, x_spiffe_id: str | None = Header(default=None)):
    spiffe_id = _require_spiffe_id(x_spiffe_id)
    reply, events = actions.lookup_order(
        body.order_id, body.requester_customer_id, spiffe_id, settings, body.enforce_ownership,
    )
    return {"reply": reply, "events": events}


@app.post("/tools/peek_order_total")
def tools_peek_order_total(body: LookupOrderBody, x_spiffe_id: str | None = Header(default=None)):
    spiffe_id = _require_spiffe_id(x_spiffe_id)
    total = actions.peek_order_total_pence(body.order_id, spiffe_id, settings)
    if total is None:
        raise HTTPException(status_code=404, detail="order not found")
    return {"total_pence": total}


@app.post("/tools/issue_refund")
def tools_issue_refund(
    body: IssueRefundBody,
    x_spiffe_id: str | None = Header(default=None),
    x_approved_by: str | None = Header(default=None),
):
    spiffe_id = _require_spiffe_id(x_spiffe_id)
    # X-Approved-By is set by the agent only after a presenter clicks
    # Approve in the storefront's Control Room -- not cryptographically
    # verified. Recorded in the refunds row and in the response event for
    # audit, same as the old Vault talk's `approved_by` field, minus the
    # OBO signature that used to accompany it.
    reply, events, status = actions.issue_refund(
        body.order_id, body.reason, body.requester_customer_id, spiffe_id, settings,
        body.issued_by, body.enforce_ownership, x_approved_by, body.correlation_id,
    )
    return _status_response(status, {"reply": reply, "events": events})


@app.post("/tools/lookup_customer_pii")
def tools_lookup_customer_pii(body: LookupPiiBody, x_spiffe_id: str | None = Header(default=None)):
    spiffe_id = _require_spiffe_id(x_spiffe_id)
    reply, events = actions.lookup_customer_pii(body.customer_id, spiffe_id, settings, body.issued_by)
    return {"reply": reply, "events": events}


@app.post("/tools/scale_deployment")
def tools_scale_deployment(body: ScaleBody, x_spiffe_id: str | None = Header(default=None)):
    _require_spiffe_id(x_spiffe_id)  # identity already confirmed by the gateway; no per-identity DB role needed for this tool
    reply, events, status = k8s_actions.scale_deployment(body.replicas, settings)
    return _status_response(status, {"reply": reply, "events": events})


def _status_response(status: int, payload: dict):
    return JSONResponse(status_code=status, content=payload)
