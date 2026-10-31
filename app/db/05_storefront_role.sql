-- The storefront's own least-privilege account. Deliberately NOT the
-- CloudNativePG superuser, and NOT a role mahi-tools or either agent ever
-- uses -- the public website and the agent tool server hold entirely
-- separate, non-overlapping credentials.
--
-- Grants are exactly what app/storefront/db.py needs and no more:
--   list_products / list_customers / list_orders / get_order -> SELECT
--   reset_demo_state                                         -> UPDATE orders, DELETE refunds
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'mahi_storefront') THEN
        CREATE ROLE mahi_storefront LOGIN PASSWORD '${STOREFRONT_DB_PASSWORD}';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE mahistores TO mahi_storefront;
GRANT USAGE  ON SCHEMA public      TO mahi_storefront;
GRANT SELECT ON products, customers, orders, refunds TO mahi_storefront;
GRANT UPDATE ON orders  TO mahi_storefront; -- reset_demo_state
GRANT DELETE ON refunds TO mahi_storefront; -- reset_demo_state
