# Hand-over notes

Everything a future dev (or you, in six months) needs to extend this schema
without surprises.

---

## 1. What this is

A production-shaped relational model for an e-commerce store on Postgres,
built for a Subastack-style project: one `public` schema exposed as a REST
API, `anon` / `authenticated` / `service_role` API roles, and row level
security doing the access control.

16 tables, 4 read-model views, 4 callable RPCs (plus 2 identity helpers), 7 enum
types, 20 foreign keys.

| Area | Tables |
|---|---|
| Catalogue | `categories`, `products`, `product_variants`, `product_images` |
| Stock | `inventory`, `inventory_movements` |
| Customers | `customers`, `addresses` |
| Cart | `carts`, `cart_items` |
| Orders | `orders`, `order_items`, `order_status_history` |
| Money | `payments` |
| Fulfilment | `shipments`, `shipment_items` |

ER diagram: [`er-diagram.png`](er-diagram.png) — regenerate any time with
`python3 scripts/gen_er.py "$DB_URL" docs/er-diagram`. It reads the live
catalogue, so it cannot drift away from the deployed schema.

---

## 2. Applying it

```bash
# against your Subastack project (connection string from the dashboard)
./scripts/apply.sh "postgresql://postgres:PASSWORD@db.<ref>.subastack.co:5432/postgres"

# without the demo data
./scripts/apply.sh "$DB_URL" --no-seed

# against a plain Postgres with no auth schema (local dev, CI)
./scripts/apply.sh "$DB_URL" --with-shim
```

Or paste the files into the dashboard's SQL editor **in numeric order**:

| File | What it does |
|---|---|
| `00_extensions_roles.sql` | `pgcrypto`, `citext`, the three API roles |
| `01_auth_shim.sql` | **local only** — fake `auth.users` / `auth.uid()` for testing |
| `10_schema.sql` | types, tables, constraints, indexes |
| `15_views.sql` | read models |
| `20_functions_triggers.sql` | totals, stock, payment roll-up, history |
| `25_rpc_guards.sql` | `add_to_cart`, `cancel_order`, protected columns |
| `26_auth_hook.sql` | signup → customer row |
| `30_rls_policies.sql` | row level security |
| `40_grants.sql` | table/function privileges |
| `50_seed.sql` | demo data (skip in production) |
| `51_seed_auth_local.sql` | **local only** — test identities |

Every file is idempotent — re-running changes nothing. Applying the whole
set twice in a row is part of the test script.

---

## 3. Naming conventions

Follow these and the API stays predictable:

* `snake_case` everywhere, plural table names.
* Primary key is always `id uuid default gen_random_uuid()`. The two
  append-only ledgers (`inventory_movements`, `order_status_history`) use
  `bigint generated always as identity` instead — they are written far more
  often than they are joined by key.
* Foreign key columns are `<singular_target>_id` — `customer_id`,
  `variant_id`, `order_id`.
* Money is `numeric(12,2)`. Never float. Currency is `char(3)`, ISO 4217.
* Timestamps are `timestamptz` (UTC), named `*_at`. Every table has
  `created_at`; mutable tables also have `updated_at`, maintained by trigger.
* Booleans read as assertions: `is_active`, `is_default_shipping`.
* Enums are singular: `order_status`, `payment_status`.
* Views are prefixed `v_`; trigger functions `tg_`; everything else is a
  plain verb (`checkout_cart`, `apply_stock_movement`).

---

## 4. The decisions worth knowing

**Orders reference variants, not products.** Every product has at least one
`product_variants` row (a single-variant product uses one named `Default`).
Price and stock live only on the variant, so there is never a question of
which one is authoritative.

**Order lines are snapshots.** `order_items` copies `sku`, `product_name`,
`variant_name` and `unit_price` at checkout. Renaming or repricing a product
next year does not rewrite last year's invoices. `variant_id` is
`on delete restrict` — you cannot delete a variant that has been sold; set
`is_active = false` instead.

**Totals are computed, never accepted from the client.** A trigger on
`order_items` recomputes `orders.subtotal`, and a trigger on `orders`
recomputes `grand_total = subtotal − discount + shipping + tax`. Shoppers
have no `UPDATE` on `orders` at all. A malicious client cannot post a
$0.01 order.

**`payment_status` is derived from the `payments` ledger.** Never set it by
hand. Insert a payment row and the roll-up runs:

| ledger | resulting `orders.payment_status` |
|---|---|
| no rows | `unpaid` |
| an `authorized` row, or a partial capture | `authorized` |
| captured ≥ `grand_total` | `paid` |
| a `refunded` row for part of it | `partially_refunded` |
| refunded ≥ captured | `refunded` |
| only failures | `failed` |

Refunds are rows with a **negative** `amount` and `status = 'refunded'`.

**Stock has three numbers, not one.** `quantity_on_hand` is what is in the
warehouse; `quantity_reserved` is spoken for by open orders; available is the
difference. Adding a line to an open order reserves; cancelling releases;
marking an order `fulfilled` converts the reservation into a sale (on-hand
drops). Every one of those writes a row in `inventory_movements`, so
"why is stock 3?" always has an answer. Overselling raises a
`check_violation` — it is refused at the database, not in app code.

**Guest carts.** `carts.session_token` exists for them but anon has no RLS
policy on `carts` — an anonymous key that could read carts by token could
read *anyone's*. Handle guest checkout server-side with the service key, or
require sign-in. This is a deliberate open door, not an oversight.

---

## 5. The security model

Four callers:

| Caller | Sees | Can write |
|---|---|---|
| `anon` | active products, categories, images, availability | nothing |
| `authenticated` | own customer row, addresses, cart, orders, payments, shipments | own profile, addresses, cart; create own orders |
| staff | everything | catalogue, stock, orders, payments, shipments |
| `service_role` | everything (bypasses RLS) | everything |

Staff is not a separate table. It is any authenticated user whose JWT
carries:

```json
{ "app_metadata": { "role": "admin" } }
```

`public.is_staff()` reads exactly that. `app_metadata` is server-controlled —
a user cannot grant it to themselves the way they could with
`user_metadata`. Set it in the dashboard's user editor or with the admin API.

Two locks, both required for any operation:

* **GRANTs** decide which tables and verbs are reachable at all.
* **RLS policies** decide which rows.

Note the shape in `40_grants.sql`: `authenticated` is granted write verbs on
back-office tables and RLS then narrows them to `is_staff()`. That is why a
staff member is just a signed-in user, with no second connection.

**RLS cannot restrict columns.** A shopper may update their own row, which
without help would include `is_active` and `auth_user_id`. The trigger
`tg_customers_protect_columns` blocks those three fields for non-staff. If
you add a privileged column to `customers` (`credit_limit`, `tier`,
`is_wholesale`…), **add it to that trigger in the same commit.**

Two functions are `SECURITY DEFINER` and bypass RLS on purpose —
`apply_stock_movement()` and `recalc_order_payment_status()`. They are
granted to `service_role` only. Do not widen that.

### Proving it

`tests/rls_tests.sql` signs in as anon, as a shopper and as staff, and
asserts 39 things — including that one shopper cannot see
another's orders, cannot rewrite a total, cannot oversell, and cannot call
the privileged internals. Run it after any policy change:

```bash
./scripts/local_test.sh            # throwaway cluster, applies + seeds + tests
DB_URL=postgres://... ./scripts/local_test.sh
```

It runs in a transaction and rolls back — no rows are left behind.

---

## 6. Extension points

Things deliberately left out, and where they would go:

* **Discounts / coupons** — `orders.discount_total` is already in the total
  formula. Add `coupons` + `order_discounts`, and extend
  `tg_orders_compute_grand_total` to sum them.
* **Tax rules** — `orders.tax_total` is a plain number today. A `tax_rates`
  table keyed by country/region would slot in at checkout.
* **Multiple warehouses** — `inventory` and `inventory_movements` are already
  keyed by `location`; `v_available_stock` hard-codes `'main'`. Widen that
  view and pass a location into `apply_stock_movement()`.
* **Reviews, wishlists** — new tables keyed by `customer_id`; copy the
  `addresses_own_all` policy pattern verbatim.
* **Returns / RMA** — `fulfillment_status = 'returned'` and the `'return'`
  movement reason already exist; a `returns` table would hang off `orders`.
* **Soft deletes** — none anywhere. Products archive via
  `status = 'archived'`, variants via `is_active = false`.

When you add a table, the checklist is: enable RLS → write the policies →
grant the verbs → add it to `tests/rls_tests.sql` → regenerate the diagram.
A table with RLS enabled and no policy is invisible to everyone, which is
the safe failure but a confusing one to debug.

---

## 7. Operational notes

* **Indexes** cover every foreign key and the columns you filter on
  (`orders.customer_id + placed_at`, `orders.status`, `products.status`,
  `products(lower(name))`). Add more when you see slow queries — measure
  first.
* **`order_number`** comes from `order_number_seq` as `SO-001001`. Change
  the prefix or padding in the column default on `orders`.
* **Seed data** is safe to leave in a staging project and should be removed
  from production: everything it creates is either an `@example.com`
  customer or an order numbered `SEED-…`.
* **Backups**: the ledgers (`inventory_movements`, `order_status_history`)
  are append-only and are what let you reconstruct history after an
  incident. Do not add a retention purge to them without a plan.
