"""Settings for the agent. Generic plumbing (agent_mode/agent_name/engine)
is unchanged from the Vault talk. Everything Vault-named is gone: no
vault_addr/vault_auth_mount/vault_role/vault_db_*, no obo_*. In their place:
`gateway_url` (secure mode -- where mahi-tools lives, through Envoy
Gateway) and the same `static_db_*` pair (insecure mode -- unchanged, still
a plain long-lived password).
"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    agent_mode: str          # "insecure" | "secure"
    agent_name: str
    agent_engine: str        # "deterministic" | "langchain"

    svid_path: str
    gateway_url: str

    static_db_host: str
    static_db_name: str
    static_db_user: str
    static_db_password: str

    refund_approval_threshold_pence: int
    anthropic_api_key: str | None
    anthropic_model: str


def load_settings() -> Settings:
    return Settings(
        agent_mode=os.environ.get("AGENT_MODE", "insecure"),
        agent_name=os.environ.get("AGENT_NAME", "support-agent"),
        agent_engine=os.environ.get("AGENT_ENGINE", "deterministic"),
        svid_path=os.environ.get("SVID_PATH", "/svids/jwt_svid.token"),
        gateway_url=os.environ.get("GATEWAY_URL", "http://mahi-gateway-stable.envoy-gateway-system.svc.cluster.local:8080"),
        static_db_host=os.environ.get("DATABASE_HOST", "mahistores-db-rw.data.svc.cluster.local"),
        static_db_name=os.environ.get("DATABASE_NAME", "mahistores"),
        static_db_user=os.environ.get("STATIC_DB_USER", "mahi_legacy"),
        static_db_password=os.environ.get("STATIC_DB_PASSWORD", ""),
        refund_approval_threshold_pence=int(os.environ.get("REFUND_APPROVAL_THRESHOLD_PENCE", "10000")),
        anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY") or None,
        anthropic_model=os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5"),
    )
