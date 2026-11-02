"""Two implementations of the same duck-typed interface (`begin_turn`,
`identity_event`, `lookup_order`, `issue_refund`, `lookup_customer_pii`,
`scale_deployment`, `status`), selected once at startup by
`build_session(settings)` -- the one swap point between the two identity
models this demo contrasts.

`GatewaySession` (secure mode) holds no database credential, ever. Its
only material is the JWT-SVID spiffe-helper writes to disk -- it reads
that file, puts it in an Authorization header, and calls mahi-tools
through Envoy Gateway. Every response is interpreted at THREE possible
layers, in order, and the UI needs to tell them apart (see
app/storefront/static/app.js's event contract):
  401  -- Envoy Gateway itself refused the JWT (expired/wrong aud/no SVID
          at all). The request never reached OPA, let alone mahi-tools.
  403  -- OPA's extAuth denied it (wrong identity for this tool path,
          replica ceiling, etc.), or mahi-tools' own Postgres GRANT check
          refused the query. Distinguished by whether a JSON body with our
          event schema came back at all.
  428  -- mahi-tools itself decided this refund needs a human (the ONE
          decision in this whole system that genuinely needs the real
          order total, which only mahi-tools has -- see
          app/mahi-tools/src/actions.py's comment on why this isn't OPA's
          call to make).

`StaticDBSession` (insecure mode) is the anti-pattern: a single long-lived
password, held for the container's entire lifetime, connecting straight to
Postgres with none of the above in the way.
"""
from __future__ import annotations

import base64
import json
import time

import psycopg2
import psycopg2.extras
import requests

from config import Settings


def _decode_jwt_payload(token: str) -> dict:
    """Display-only decode, no signature verification -- Envoy Gateway is
    the thing actually verifying this token's signature on every request."""
    try:
        payload_b64 = token.split(".")[1]
        padded = payload_b64 + "=" * (-len(payload_b64) % 4)
        return json.loads(base64.urlsafe_b64decode(padded))
    except Exception:  # noqa: BLE001
        return {}


class GatewaySession:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._identity_announced = False

    def begin_turn(self) -> None:
        self._identity_announced = False

    def _read_svid(self) -> tuple[str, dict]:
        with open(self.settings.svid_path, "r", encoding="utf-8") as f:
            token = f.read().strip()
        return token, _decode_jwt_payload(token)

    def identity_event(self) -> dict | None:
        if self._identity_announced:
            return None
        self._identity_announced = True
        try:
            token, claims = self._read_svid()
        except OSError as exc:
            return {"type": "error", "message": f"no SVID available: {exc}"}
        exp = claims.get("exp")
        now = int(time.time())
        return {
            "type": "identity",
            "spiffe_id": claims.get("sub"),
            "svid_expires_at": exp,
            "ttl_seconds": (exp - now) if exp else None,
            "message": f"workload identity {claims.get('sub')} (expires in {(exp - now) if exp else '?'}s)",
        }

    def _post(self, path: str, body: dict, approved_by: str | None = None) -> tuple[int, dict | None]:
        try:
            token, _ = self._read_svid()
        except OSError as exc:
            return 0, {"reply": f"no identity available: {exc}", "events": [
                {"type": "denied", "resource": "identity", "message": str(exc)},
            ]}

        headers = {"Authorization": f"Bearer {token}"}
        if approved_by:
            headers["X-Approved-By"] = approved_by

        try:
            resp = requests.post(f"{self.settings.gateway_url}{path}", json=body, headers=headers, timeout=10)
        except requests.RequestException as exc:
            return 0, {"reply": f"couldn't reach the gateway: {exc}", "events": [
                {"type": "error", "message": f"gateway unreachable: {exc}"},
            ]}

        try:
            payload = resp.json()
        except ValueError:
            payload = None

        if payload is not None and "events" in payload:
            return resp.status_code, payload

        # No parseable body with our schema -- a rejection from Envoy
        # Gateway's own JWT check (401) or OPA's extAuth (403), neither of
        # which speaks our event JSON. Synthesize an honest event instead
        # of pretending we know more than we do.
        if resp.status_code == 401:
            return resp.status_code, {"reply": "I'm not able to do that right now.", "events": [
                {"type": "denied", "resource": "identity", "message": "Envoy Gateway refused this request's JWT-SVID"},
            ]}
        return resp.status_code, {"reply": "I'm not able to do that right now.", "events": [
            {"type": "denied", "resource": "policy", "message": f"OPA denied this request (HTTP {resp.status_code})"},
        ]}

    def lookup_order(self, order_id: int, customer_id: int, enforce_ownership: bool) -> tuple[str, list[dict]]:
        events = [e for e in [self.identity_event()] if e]
        status, payload = self._post("/tools/lookup_order", {
            "order_id": order_id, "requester_customer_id": customer_id, "enforce_ownership": enforce_ownership,
        })
        return payload["reply"], events + payload["events"]

    def issue_refund(self, order_id: int, reason: str, customer_id: int, enforce_ownership: bool,
                      issued_by: str, approved_by: str | None = None,
                      correlation_id: str | None = None) -> tuple[str, list[dict], bool, int | None]:
        events = [e for e in [self.identity_event()] if e]
        status, payload = self._post("/tools/issue_refund", {
            "order_id": order_id, "reason": reason, "requester_customer_id": customer_id,
            "enforce_ownership": enforce_ownership, "issued_by": issued_by, "correlation_id": correlation_id,
        }, approved_by=approved_by)
        amount = next((e.get("amount_pence") for e in payload["events"] if e["type"] == "approval_required"), None)
        return payload["reply"], events + payload["events"], status == 428, amount

    def lookup_customer_pii(self, customer_id: int, issued_by: str) -> tuple[str, list[dict]]:
        events = [e for e in [self.identity_event()] if e]
        status, payload = self._post("/tools/lookup_customer_pii", {
            "customer_id": customer_id, "issued_by": issued_by,
        })
        return payload["reply"], events + payload["events"]

    def scale_deployment(self, replicas: int, approved_by: str | None = None) -> tuple[str, list[dict], bool]:
        events = [e for e in [self.identity_event()] if e]
        status, payload = self._post("/tools/scale_deployment", {"replicas": replicas}, approved_by=approved_by)
        return payload["reply"], events + payload["events"], status == 428

    def status(self) -> dict:
        try:
            _, claims = self._read_svid()
            # svid_expires_at is what the storefront's Identity-stage drawer
            # live-counts-down from (app.js's renderStageDetail) -- polled
            # every 4s via /api/state, not pushed, so this field has to be
            # here on every call, not just inside identity_event()'s
            # once-per-turn event.
            return {"available": True, "mode": "secure", "identity": {
                "spiffe_id": claims.get("sub"), "svid_expires_at": claims.get("exp"),
            }}
        except OSError:
            return {"available": False, "mode": "secure", "identity": None}


class StaticDBSession:
    """THE ANTI-PATTERN. One password, read once at startup, held for the
    container's entire lifetime, no identity of any kind. Connects
    straight to Postgres as `mahi_legacy` (app/db/04_legacy_role.sql),
    which still has a SELECT grant on `customers` -- so the identical
    query that mahi-tools refuses succeeds here, in application code,
    with no record of who asked beyond a free-text `issued_by` string."""

    def __init__(self, settings: Settings):
        self.settings = settings

    def begin_turn(self) -> None:
        pass

    def identity_event(self) -> dict | None:
        return None  # no identity exists to announce -- that absence is the point

    def _connect(self):
        return psycopg2.connect(
            host=self.settings.static_db_host, dbname=self.settings.static_db_name,
            user=self.settings.static_db_user, password=self.settings.static_db_password,
        )

    def lookup_order(self, order_id: int, customer_id: int, enforce_ownership: bool) -> tuple[str, list[dict]]:
        with self._connect() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """SELECT o.order_id, o.customer_id, p.name AS product_name, o.total_pence, o.status
                   FROM orders o JOIN products p ON p.product_id = o.product_id WHERE o.order_id = %s""",
                (order_id,),
            )
            row = cur.fetchone()
        if row is None:
            return f"I can't find order #{order_id}.", []
        return (
            f"Order #{row['order_id']}: {row['product_name']}, "
            f"£{row['total_pence']/100:.2f}, status: {row['status']}."
        ), []

    def issue_refund(self, order_id: int, reason: str, customer_id: int, enforce_ownership: bool,
                      issued_by: str, approved_by: str | None = None,
                      correlation_id: str | None = None) -> tuple[str, list[dict], bool, int | None]:
        with self._connect() as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute("SELECT customer_id, total_pence, status FROM orders WHERE order_id = %s", (order_id,))
                row = cur.fetchone()
            if row is None:
                return f"I can't find order #{order_id}.", [], False, None
            if row["status"] == "refunded":
                return f"Order #{order_id} was already refunded.", [], False, None
            if row["total_pence"] > self.settings.refund_approval_threshold_pence and not approved_by:
                return "This refund needs a human's approval first.", [{
                    "type": "approval_required", "order_id": order_id, "amount_pence": row["total_pence"],
                    "message": f"£{row['total_pence']/100:.2f} exceeds the auto-approval threshold",
                }], True, row["total_pence"]
            with conn.cursor() as cur:
                cur.execute(
                    """INSERT INTO refunds (order_id, amount_pence, reason, issued_by, approved_by, correlation_id)
                       VALUES (%s, %s, %s, %s, %s, %s)""",
                    (order_id, row["total_pence"], reason, issued_by, approved_by, correlation_id),
                )
                cur.execute("UPDATE orders SET status = 'refunded' WHERE order_id = %s", (order_id,))
            conn.commit()
        return f"Done -- refunded £{row['total_pence']/100:.2f} for order #{order_id}.", [{
            "type": "refund_issued", "order_id": order_id, "amount_pence": row["total_pence"],
            "message": f"refunded order #{order_id} (£{row['total_pence']/100:.2f}) -- no ownership check, no identity",
        }], False, None

    def lookup_customer_pii(self, customer_id: int, issued_by: str) -> tuple[str, list[dict]]:
        with self._connect() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT name, email, phone FROM customers WHERE customer_id = %s", (customer_id,))
            row = cur.fetchone()
        if row is None:
            return f"I can't find customer #{customer_id}.", []
        return f"{row['name']} / {row['email']} / {row['phone']}", [{
            "type": "scope_violation", "resource": "customers",
            "message": f"⚠ {issued_by} read customers.email/phone for {row['name']} -- static credential has no scoping, no identity, no record of who asked",
        }]

    def scale_deployment(self, replicas: int, approved_by: str | None = None) -> tuple[str, list[dict], bool]:
        return "The legacy support agent doesn't have cluster access.", [{
            "type": "denied", "resource": "deployments/scale", "message": "agent-insecure has no Kubernetes RBAC at all",
        }], False

    def status(self) -> dict:
        return {"available": True, "mode": "insecure", "identity": None}


def build_session(settings: Settings):
    if settings.agent_mode == "insecure":
        return StaticDBSession(settings)
    return GatewaySession(settings)
