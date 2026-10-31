"""Picks which least-privileged Postgres login role to connect as, based on
the calling agent's SPIFFE ID -- then just connects. There is no credential
minting, no lease, no TTL on the connection itself: the thing that expires
is the caller's JWT-SVID (300s, checked by Envoy Gateway before the request
ever reaches this service), not the database session. Revocation of the
underlying privilege is a Git commit against k8s/cnpg/cluster.yaml's
spec.managed.roles, reconciled by the CloudNativePG operator -- see that
file's comment.
"""
from __future__ import annotations

import psycopg2
import psycopg2.extras

from config import Settings


class UnknownIdentity(Exception):
    """Raised when X-Spiffe-Id doesn't match either known agent identity.
    Should be unreachable in practice -- OPA's policy already restricted
    which identities may reach mahi-tools at all -- but a defensive 403
    here is cheap insurance, not a load-bearing control."""


def credentials_for(spiffe_id: str, settings: Settings) -> dict:
    if spiffe_id == settings.order_agent_spiffe_id:
        return {"user": settings.order_db_user, "password": settings.order_db_password}
    if spiffe_id == settings.refund_agent_spiffe_id:
        return {"user": settings.refund_db_user, "password": settings.refund_db_password}
    raise UnknownIdentity(spiffe_id)


def connect(spiffe_id: str, settings: Settings):
    creds = credentials_for(spiffe_id, settings)
    return psycopg2.connect(
        host=settings.db_host,
        port=settings.db_port,
        dbname=settings.db_name,
        user=creds["user"],
        password=creds["password"],
    )


def dict_cursor(conn):
    return conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
