-- Least-privilege group roles for mahi-tools' two agent-facing identities.
-- These are NOLOGIN -- nobody connects AS one of these directly. mahi-tools
-- connects as a per-identity LOGIN role (agent_order_login /
-- agent_refund_login, declared in k8s/cnpg/cluster.yaml's
-- spec.managed.roles, in Git) that is a MEMBER of one of these via
-- `inRoles`. This is the actual, empirically-proven restriction mechanism
-- in this demo: if order-agent's identity is ever routed to
-- POST /tools/issue_refund, this is what refuses the INSERT -- not an
-- if-statement in mahi-tools, and not whatever Envoy Gateway or OPA
-- decided on the way in.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'mahi_order_grp') THEN
        CREATE ROLE mahi_order_grp NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'mahi_refund_grp') THEN
        CREATE ROLE mahi_refund_grp NOLOGIN;
    END IF;
    -- PII escalation target for beat 4's "what if a mistake widens this
    -- role's privilege" test. Never granted to either agent role except
    -- during the deliberate, Git-committed misconfiguration beat 4 shows
    -- and then reverts.
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'mahi_pii_grp') THEN
        CREATE ROLE mahi_pii_grp NOLOGIN;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE mahistores TO mahi_order_grp, mahi_refund_grp, mahi_pii_grp;
GRANT USAGE ON SCHEMA public TO mahi_order_grp, mahi_refund_grp, mahi_pii_grp;

-- order-agent's role: read-only. No INSERT on refunds, no UPDATE anywhere.
GRANT SELECT ON orders, products TO mahi_order_grp;

-- refund-agent's role: read orders/products (via membership) plus the two
-- grants a refund actually needs.
GRANT mahi_order_grp TO mahi_refund_grp;
GRANT SELECT, UPDATE ON orders TO mahi_refund_grp;
GRANT INSERT ON refunds TO mahi_refund_grp;
GRANT USAGE, SELECT ON refunds_refund_id_seq TO mahi_refund_grp;

-- PII group -- SELECT on customers only. Not granted to mahi_order_grp or
-- mahi_refund_grp by default.
GRANT SELECT ON customers TO mahi_pii_grp;
