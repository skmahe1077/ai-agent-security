-- THE ANTI-PATTERN. A static, long-lived DB password sitting in a plain
-- Kubernetes Secret that any pod with RBAC access to `nimbus` secrets can
-- read, mounted into a Deployment that holds it for its entire lifetime --
-- no SPIFFE identity, no gateway, no OPA check, no expiry, and
-- deliberately NOT managed via CloudNativePG's declarative
-- spec.managed.roles / GitOps the way mahi_order_grp's login roles are.
-- This is beat 1's exhibit, not a template to copy.
--
-- `${...}` substituted by scripts/01-provision.sh. The password matches
-- k8s/agents/agent-insecure-secret.yaml's LEGACY_DB_PASSWORD.
--
-- DEMO ONLY. This password is intentionally weak and intentionally static.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'mahi_legacy') THEN
        CREATE ROLE mahi_legacy LOGIN PASSWORD '${LEGACY_DB_PASSWORD}';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE mahistores TO mahi_legacy;
GRANT USAGE ON SCHEMA public TO mahi_legacy;
GRANT SELECT, UPDATE ON orders TO mahi_legacy;
GRANT INSERT ON refunds TO mahi_legacy;
GRANT USAGE, SELECT ON refunds_refund_id_seq TO mahi_legacy;
GRANT SELECT ON customers TO mahi_legacy;   -- the part that should never have been granted
GRANT SELECT ON products TO mahi_legacy;
