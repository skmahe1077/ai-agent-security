"""Settings for mahi-tools -- the one service that actually touches
Postgres on an agent's behalf. No Vault, no SPIFFE here: by the time a
request reaches this service, Envoy Gateway has already verified the
caller's JWT-SVID and OPA has already decided whether this identity may
call this path at all. This module only needs to know how to reach
Postgres and the Kubernetes API, and which Postgres login role corresponds
to which calling identity.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_port: int
    db_name: str

    # Two login roles, one per agent identity -- see k8s/cnpg/cluster.yaml's
    # spec.managed.roles. mahi-tools picks between them per request based on
    # the X-Spiffe-Id header Envoy Gateway forwards (claimToHeaders: sub ->
    # X-Spiffe-Id, see k8s/gateway/security-policy.yaml). This is the ONE
    # standing credential in the whole system -- deliberately: the agents
    # hold none at all, this service holds exactly two, least-privileged,
    # declared in Git, revocable by a git commit.
    order_agent_spiffe_id: str
    order_db_user: str
    order_db_password: str

    refund_agent_spiffe_id: str
    refund_db_user: str
    refund_db_password: str

    refund_approval_threshold_pence: int

    # scale_deployment's blast radius -- a single, hardcoded Deployment
    # name and namespace, not a general-purpose K8s client. Least
    # privilege at the RBAC layer too: see k8s/mahi-tools/rbac.yaml.
    scalable_deployment_namespace: str
    scalable_deployment_name: str


def load_settings() -> Settings:
    return Settings(
        db_host=os.environ.get("DB_HOST", "mahistores-db-rw.data.svc.cluster.local"),
        db_port=int(os.environ.get("DB_PORT", "5432")),
        db_name=os.environ.get("DB_NAME", "mahistores"),
        order_agent_spiffe_id=os.environ["ORDER_AGENT_SPIFFE_ID"],
        order_db_user=os.environ.get("ORDER_DB_USER", "agent_order_login"),
        order_db_password=os.environ["ORDER_DB_PASSWORD"],
        refund_agent_spiffe_id=os.environ["REFUND_AGENT_SPIFFE_ID"],
        refund_db_user=os.environ.get("REFUND_DB_USER", "agent_refund_login"),
        refund_db_password=os.environ["REFUND_DB_PASSWORD"],
        refund_approval_threshold_pence=int(os.environ.get("REFUND_APPROVAL_THRESHOLD_PENCE", "10000")),
        scalable_deployment_namespace=os.environ.get("SCALABLE_DEPLOYMENT_NAMESPACE", "nimbus"),
        scalable_deployment_name=os.environ.get("SCALABLE_DEPLOYMENT_NAME", "storefront"),
    )
