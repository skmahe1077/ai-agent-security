"""The real Kubernetes operation -- so the gateway is visibly guarding
cluster actions, not just application logic. Uses the in-cluster config
(mahi-tools' own ServiceAccount token, projected and auto-mounted by
Kubernetes -- not SPIFFE, not a user credential) with RBAC narrowed to
`apps/deployments/scale` on exactly one named Deployment -- see
k8s/mahi-tools/rbac.yaml. Replica count itself is also checked by OPA
before this ever runs (policy/rego/scale.rego): this function trusts that
a request reaching it already passed that check, and only re-asserts the
hard ceiling as a second, cheap backstop.
"""
from __future__ import annotations

from kubernetes import client, config as k8s_config

from config import Settings

_HARD_REPLICA_CEILING = 10  # backstop only -- OPA's ceiling (policy/rego/scale.rego) is the real gate


def scale_deployment(replicas: int, settings: Settings) -> tuple[str, list[dict], int]:
    events: list[dict] = []

    if replicas < 0 or replicas > _HARD_REPLICA_CEILING:
        events.append({
            "type": "denied",
            "resource": "deployments/scale",
            "message": f"refused: {replicas} replicas is outside mahi-tools' own hard ceiling ({_HARD_REPLICA_CEILING})",
        })
        return f"I won't scale to {replicas} replicas -- that's outside what I'll do even if asked.", events, 403

    k8s_config.load_incluster_config()
    apps = client.AppsV1Api()
    apps.patch_namespaced_deployment_scale(
        name=settings.scalable_deployment_name,
        namespace=settings.scalable_deployment_namespace,
        body={"spec": {"replicas": replicas}},
    )

    events.append({
        "type": "scale_applied",
        "replicas": replicas,
        "deployment": settings.scalable_deployment_name,
        "message": f"scaled {settings.scalable_deployment_name} to {replicas} replicas",
    })
    return f"Done -- {settings.scalable_deployment_name} is now scaled to {replicas} replicas.", events, 200
