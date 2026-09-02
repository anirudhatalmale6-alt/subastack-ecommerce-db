# Subastack e-commerce database

A production-shaped relational schema for an e-commerce store: customers,
catalogue, stock, carts, orders, payments and fulfilment — with row level
security, seed data, an ER diagram and a test suite that proves the
security model actually holds.

Built for a Subastack project (Postgres + auto-generated REST API +
`anon` / `authenticated` / `service_role` roles). It applies cleanly to any
Postgres 14+.

```bash
./scripts/apply.sh "postgresql://postgres:PASSWORD@db.<ref>.subastack.co:5432/postgres"
```

* [Hand-over notes](docs/HANDOVER.md) — conventions, design decisions, the
  security model, extension points
* [API examples](docs/API_EXAMPLES.md) — every call the app needs, as curl
  and as JS
* [ER diagram](docs/er-diagram.png) — generated from the live catalogue

---

## The model

```mermaid
erDiagram
    categories      ||--o{ categories       : "parent of"
    categories      ||--o{ products         : contains
    products        ||--|{ product_variants : "sold as"
    products        ||--o{ product_images   : has
    product_variants||--|| inventory        : "stock level"
    product_variants||--o{ inventory_movements : "ledger"
    customers       ||--o{ addresses        : has
    customers       ||--o{ carts            : has
    carts           ||--o{ cart_items       : holds
    product_variants||--o{ cart_items       : "in"
    customers       ||--o{ orders           : places
    orders          ||--|{ order_items      : contains
    product_variants||--o{ order_items      : "sold as"
    orders          ||--o{ payments         : "paid by"
    orders          ||--o{ shipments        : "shipped in"
    shipments       ||--o{ shipment_items   : contains
    order_items     ||--o{ shipment_items   : "shipped as"
    orders          ||--o{ order_status_history : "audited by"

    customers {
        uuid id PK
        uuid auth_user_id "-> auth.users"
        citext email UK
        text full_name
        boolean is_active "staff only"
    }
    products {
        uuid id PK
        text sku UK
        text slug UK
        product_status status "draft|active|archived"
        numeric base_price
    }
    product_variants {
        uuid id PK
        text sku UK
        numeric price "authoritative price"
        jsonb options "size, colour"
    }
    inventory {
        uuid variant_id FK
        integer quantity_on_hand
        integer quantity_reserved
        integer reorder_level
    }
    orders {
        uuid id PK
        text order_number UK
        order_status status
        payment_status payment_status "derived"
        fulfillment_status fulfillment_status
        numeric subtotal "computed"
        numeric grand_total "computed"
        jsonb shipping_address "snapshot"
    }
    order_items {
        uuid id PK
        text sku "snapshot"
        text product_name "snapshot"
        numeric unit_price "snapshot"
        integer quantity
        numeric line_total "generated"
    }
    payments {
        uuid id PK
        text provider
        text provider_reference UK
        numeric amount "negative = refund"
        payment_transaction_status status
    }
```

The four rules the schema enforces for you:

1. **Totals are computed, never posted.** `subtotal` comes from the line
   items; `grand_total = subtotal − discount + shipping + tax`. Shoppers
   have no `UPDATE` on `orders` at all.
2. **`payment_status` is derived from the payments ledger.** Insert a
   capture or a refund; the status follows.
3. **Stock is reserved on order, released on cancel, deducted on
   fulfilment** — and every movement is written to an append-only ledger.
   Overselling is refused by the database.
4. **Order lines are snapshots.** Renaming or repricing a product does not
   rewrite last year's orders.

---

## Layout

```
sql/                 apply in numeric order
  00_extensions_roles.sql   pgcrypto, citext, the API roles
  01_auth_shim.sql          LOCAL ONLY: fake auth.users for testing
  10_schema.sql             types, tables, constraints, indexes
  15_views.sql              read models
  20_functions_triggers.sql totals, stock, payment roll-up, history
  25_rpc_guards.sql         add_to_cart, cancel_order, protected columns
  26_auth_hook.sql          signup -> customer row
  30_rls_policies.sql       row level security
  40_grants.sql             table/function privileges
  50_seed.sql               demo data
  51_seed_auth_local.sql    LOCAL ONLY: test identities
tests/rls_tests.sql  39 assertions about who can see and do what
scripts/
  apply.sh           apply everything to a database
  local_test.sh      throwaway cluster -> apply -> seed -> test -> re-apply
  gen_er.py          regenerate the ER diagram from the live catalogue
docs/
  HANDOVER.md        conventions, decisions, security model, extensions
  API_EXAMPLES.md    curl + JS for every endpoint
  er-diagram.png     generated
```

---

## Seed data

13 products (one deliberately `draft`) across 8 categories, 21 variants,
opening stock with one line under its reorder level, 5 customers with
addresses, and 6 orders covering the states you need to test against:

| Order | Status | Payment | Fulfilment |
|---|---|---|---|
| SEED-0001 | pending | unpaid | unfulfilled |
| SEED-0002 | confirmed | paid | unfulfilled |
| SEED-0003 | confirmed | paid | fulfilled (in transit) |
| SEED-0004 | completed | paid | fulfilled (delivered) |
| SEED-0005 | cancelled | failed | unfulfilled |
| SEED-0006 | completed | partially_refunded | fulfilled |

Those payment and stock states were not typed in — the seed creates each
order, adds its lines and moves it forward, and the triggers produce them.

---

## Testing

```bash
./scripts/local_test.sh
```

Builds a throwaway Postgres cluster, applies every file, seeds it, runs 39
assertions as anon / shopper / staff, then applies everything a second time
to prove idempotency. No network, no external services.

```
PASS  anon is refused the customers table
PASS  Ava sees only her own 2 orders (saw 2)
PASS  a shopper cannot rewrite the order subtotal
PASS  the schema refuses to oversell a variant
PASS  cancelling released the reservation (back to 0)
PASS  capturing the full amount flips the order to paid
...
ALL CHECKS PASSED
```
