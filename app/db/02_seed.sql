-- Demo data for Mahi Stores -- a KubeCon swag catalog, items and prices
-- drawn from the real CNCF store (https://store.cncf.io/collections/all)
-- as of 2026-11-02. See app/storefront/static/images/ATTRIBUTION.md for
-- why the product *photos* aren't copied from that store (its own
-- copyrighted product photography) while the *logos* on each card are
-- (official cncf/artwork assets, reused under the Linux Foundation
-- trademark usage guidelines -- legitimate for a KubeCon talk about these
-- exact projects).
--
-- order #1042 (Idhazhini, Kubernetes hoodie, £78) is beat 1's refund.
-- order #1045 (Idhazhini, CNCF trucker cap x2, £48) is beat 2's refund --
-- deliberately a DIFFERENT order than beat 1's, so scripts/demo-beat{1,2}.sh
-- can run back-to-back without scripts/reset.sh in between and neither hits
-- "already refunded." Both are under the £100 auto-approval threshold.
-- order #1046 (Ilan, Kubernetes beanie, £18) is the "wrong customer"
-- refund both beat 1 (succeeds -- the point) and beat 2 (denied -- the
-- point) attempt while chatting as Idhazhini. Also under threshold, so the
-- point stays overprivilege/ownership, not the approval gate. Deliberately
-- a DIFFERENT product than order #1045's, even though both are Idhazhini/
-- Ilan's cheap items -- the original design reused the same product_id for
-- both, which reads as a duplicate line item in the Order History table.
-- order #1043 (Ilan, Samsonite backpack, £204) and #1044 (Ruba, Eddie Bauer
-- parka, £122) sit above the threshold for exercising the approval flow
-- itself -- #1044 is the one scripts/demo-beat3.sh actually walks through.

INSERT INTO customers (customer_id, name, email, phone) VALUES
    (1, 'Idhazhini',  'idhazhini@example.com', '+44 7700 900001'),
    (2, 'Ilan',       'ilan@example.com',      '+44 7700 900002'),
    (3, 'Ruba',       'ruba@example.com',      '+44 7700 900003')
ON CONFLICT (customer_id) DO NOTHING;

-- Products 5-14 are additive only -- do not renumber 1-4, the orders below
-- reference them by id, and scripts/demo-beat{1,2,3}.sh reference those
-- orders by id in turn. Each card's logo ties back to a real CNCF project;
-- where the real store item is generically "CNCF"-branded (not already a
-- specific sub-project's own merch) it's assigned one of the projects this
-- demo's own security stack actually runs, as a deliberate easter egg --
-- the swag you can "buy" features the same projects securing the checkout.
INSERT INTO products (product_id, name, description, price_pence, stock) VALUES
    (1,  'Custom Kubernetes Full Zip Hoodie',      'Embroidered Kubernetes wheel, fleece-lined',        7800,  42),
    (2,  'Samsonite Arcway Laptop Backpack',       'Professional travel backpack, CNCF embroidery',    20400,  12),
    (3,  'Eddie Bauer Hooded Soft Shell Parka',    'Insulated, water-resistant, CNCF embroidery',       12200,  15),
    (4,  'CNCF Richardson Low Pro Trucker',        'Low-profile trucker cap, snapback',                  2400,  80),
    (5,  'Heritage Corduroy Trucker Cap',          'Classic corduroy trucker, adjustable',               3400,  38),
    (6,  'Kubernetes Custom Woven Beanie',         'Knit winter beanie, woven wheel logo',               1800,  65),
    (7,  'Kruger Fleece Crew',                     'Casual fleece crewneck',                             4400,  50),
    (8,  'Helm - Embossed Midweight Crewneck',     'Embossed Helm ship-wheel logo',                     10000,  24),
    (9,  'Phippy & Friends Core Cotton Tee',       'Phippy the giraffe, soft cotton tee',                2100,  90),
    (10, 'SOMOTO Eco Long Sleeve Tee',             'Sustainable fabric, long sleeve',                    4400,  55),
    (11, 'Stanley/Stella Cooper Dry Hoodie',       'Organic cotton blend hoodie',                        7200,  30),
    (12, 'The Illustrated Children''s Guide to Kubernetes', 'Picture book, ages 5+',                       500, 100),
    (13, 'Eddie Bauer Fleece Vest',                'Mid-layer fleece vest, CNCF embroidery',             6200,  20),
    (14, 'Car Magnet - CNCF',                      'Small vehicle magnet',                                300, 150)
ON CONFLICT (product_id) DO NOTHING;

INSERT INTO orders (order_id, customer_id, product_id, quantity, total_pence, status, placed_at) VALUES
    (1042, 1, 1, 1, 7800,  'delivered', now() - interval '6 days'),
    (1043, 2, 2, 1, 20400, 'delivered', now() - interval '4 days'),
    (1044, 3, 3, 1, 12200, 'delivered', now() - interval '2 days'),
    (1045, 1, 4, 2, 4800,  'shipped',   now() - interval '1 day'),
    (1046, 2, 6, 1, 1800,  'delivered', now() - interval '3 days')
ON CONFLICT (order_id) DO NOTHING;

SELECT setval('orders_order_id_seq', (SELECT MAX(order_id) FROM orders));
SELECT setval('customers_customer_id_seq', (SELECT MAX(customer_id) FROM customers));
SELECT setval('products_product_id_seq', (SELECT MAX(product_id) FROM products));
