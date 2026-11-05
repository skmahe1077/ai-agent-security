"""mahi-tools' actual business logic -- what runs once Envoy Gateway has
verified the caller's JWT-SVID and OPA has decided this identity may call
this path at all. Every function returns `(reply_text, events)`; PostgreSQL
GRANTs are the real backstop, not an if-statement, enforced via
`psycopg2.errors.InsufficientPrivilege`. There is no per-request credential
to mint here -- just a long-lived least-privilege login role selected by
caller identity (see db.py). Approval evidence is a plain X-Approved-By
header the storefront sets only after a presenter clicks Approve -- not
cryptographically verified, an honest simplification stated plainly rather
than hidden (see docs/TALK-NOTES.md's "if asked" section).
"""
from __future__ import annotations

import psycopg2
import psycopg2.extras

import db
from config import Settings


def peek_order_total_pence(order_id: int, spiffe_id: str, settings: Settings) -> int | None:
    with db.connect(spiffe_id, settings) as conn, conn.cursor() as cur:
        cur.execute("SELECT total_pence FROM orders WHERE order_id = %s", (order_id,))
        row = cur.fetchone()
    return row[0] if row else None


def lookup_order(order_id: int, requester_customer_id: int, spiffe_id: str, settings: Settings,
                  enforce_ownership: bool = True) -> tuple[str, list[dict]]:
    events: list[dict] = []
    try:
        with db.connect(spiffe_id, settings) as conn, db.dict_cursor(conn) as cur:
            cur.execute(
                """
                SELECT o.order_id, o.customer_id, p.name AS product_name, o.total_pence, o.status
                FROM orders o JOIN products p ON p.product_id = o.product_id
                WHERE o.order_id = %s
                """,
                (order_id,),
            )
            row = cur.fetchone()
    except psycopg2.errors.InsufficientPrivilege:
        events.append({
            "type": "denied",
            "resource": "products",
            "message": "this identity's database role has no grant on products -- PostgreSQL refused the query",
        })
        return "I'm not able to look up order details right now.", events

    if row is None:
        return f"I can't find order #{order_id}.", events

    if enforce_ownership and row["customer_id"] != requester_customer_id:
        events.append({
            "type": "denied",
            "resource": "orders",
            "message": f"refused: order #{order_id} belongs to a different customer than the one chatting",
        })
        return "I can only look up your own orders.", events

    events.append({
        "type": "order_lookup", "order_id": order_id,
        "message": f"looked up order #{order_id}",
    })
    return (
        f"Order #{row['order_id']}: {row['product_name']}, "
        f"£{row['total_pence']/100:.2f}, status: {row['status']}."
    ), events


def issue_refund(
    order_id: int,
    reason: str,
    requester_customer_id: int,
    spiffe_id: str,
    settings: Settings,
    issued_by: str,
    enforce_ownership: bool = True,
    approved_by: str | None = None,
    correlation_id: str | None = None,
) -> tuple[str, list[dict], int]:
    """Returns (reply_text, events, http_status). Status is 428 (Precondition
    Required) when the real order total exceeds the approval threshold and
    no `approved_by` evidence was presented -- mahi-tools, not OPA, makes
    this specific call, because it is the only thing in the request path
    that actually knows the order's real amount. OPA has already decided
    (before this code ever runs) whether this SPIFFE identity may call
    POST /tools/issue_refund AT ALL -- order-agent's requests never reach
    this function; Envoy Gateway's extAuth denies them on the path alone.
    """
    events: list[dict] = []

    with db.connect(spiffe_id, settings) as conn:
        with db.dict_cursor(conn) as cur:
            cur.execute(
                "SELECT customer_id, total_pence, status FROM orders WHERE order_id = %s",
                (order_id,),
            )
            row = cur.fetchone()

        if row is None:
            return f"I can't find order #{order_id}.", events, 404

        if enforce_ownership and row["customer_id"] != requester_customer_id:
            events.append({
                "type": "denied",
                "resource": "orders",
                "message": f"refused: order #{order_id} belongs to a different customer than the one chatting",
            })
            return "I can only refund your own orders.", events, 403

        if row["status"] == "refunded":
            return f"Order #{order_id} was already refunded.", events, 200

        if row["total_pence"] > settings.refund_approval_threshold_pence and not approved_by:
            events.append({
                "type": "approval_required",
                "order_id": order_id,
                "amount_pence": row["total_pence"],
                "message": (
                    f"£{row['total_pence']/100:.2f} exceeds the £"
                    f"{settings.refund_approval_threshold_pence/100:.0f} auto-approval threshold -- "
                    "awaiting a human approval before this proceeds"
                ),
            })
            return "This refund needs a human's approval first.", events, 428

        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO refunds (order_id, amount_pence, reason, issued_by, approved_by, correlation_id)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (order_id, row["total_pence"], reason, issued_by, approved_by, correlation_id),
                )
                cur.execute("UPDATE orders SET status = 'refunded' WHERE order_id = %s", (order_id,))
            conn.commit()
        except psycopg2.errors.InsufficientPrivilege:
            conn.rollback()
            events.append({
                "type": "denied",
                "resource": "refunds",
                "message": f"{issued_by}'s database role has no grant to write refunds -- PostgreSQL refused the query",
            })
            return (
                "I'm not able to process refunds -- that's outside what I'm allowed to do. "
                "I can look up the order status for you instead."
            ), events, 403

    events.append({
        "type": "refund_issued",
        "order_id": order_id,
        "amount_pence": row["total_pence"],
        "message": (
            f"refunded order #{order_id} (£{row['total_pence']/100:.2f})"
            + (f", approved by {approved_by}" if approved_by else "")
        ),
    })
    return f"Done -- refunded £{row['total_pence']/100:.2f} for order #{order_id}.", events, 200


def lookup_customer_pii(customer_id: int, spiffe_id: str, settings: Settings,
                         issued_by: str) -> tuple[str, list[dict]]:
    """Reachable from either secure identity, on purpose: the point is that
    it is denied either way. Neither mahi_order_grp nor mahi_refund_grp
    (app/db/03_group_roles.sql) has ever been granted SELECT on customers.
    Contrast with agent-insecure, which connects directly to Postgres as
    mahi_legacy and this same query genuinely succeeds -- that code path
    lives in the agent image's insecure mode, not here, because the whole
    point of beat 1 is that it bypasses this service entirely."""
    events: list[dict] = []
    try:
        with db.connect(spiffe_id, settings) as conn, db.dict_cursor(conn) as cur:
            cur.execute("SELECT name, email, phone FROM customers WHERE customer_id = %s", (customer_id,))
            row = cur.fetchone()
    except psycopg2.errors.InsufficientPrivilege:
        events.append({
            "type": "denied",
            "resource": "customers",
            "message": f"{issued_by}'s database role has no grant on customers -- PostgreSQL refused the query",
        })
        return "I'm not able to access customer contact details.", events

    if row is None:
        return f"I can't find customer #{customer_id}.", events

    # Should be unreachable -- kept only as an honest "if this ever fires,
    # something upstream is badly misconfigured" signal, not a code path
    # this demo expects to exercise.
    events.append({
        "type": "scope_violation",
        "resource": "customers",
        "message": f"⚠ {issued_by} read customers.email/phone for {row['name']} via mahi-tools -- this should be impossible",
    })
    return f"{row['name']} / {row['email']} / {row['phone']}", events
