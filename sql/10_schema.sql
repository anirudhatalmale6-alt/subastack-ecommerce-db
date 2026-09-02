-- =====================================================================
-- 10_schema.sql
-- Core relational model: catalogue, customers, carts, orders, money,
-- fulfilment, stock.
--
-- Conventions (see docs/HANDOVER.md):
--   * snake_case, plural table names
--   * uuid primary keys named `id`, generated with gen_random_uuid()
--   * every FK column is `<singular_table>_id`
--   * money is numeric(12,2), currency is a 3-letter ISO code
--   * every table carries created_at; mutable tables carry updated_at
-- =====================================================================

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'product_status') then
    create type product_status as enum ('draft', 'active', 'archived');
  end if;

  if not exists (select 1 from pg_type where typname = 'order_status') then
    -- lifecycle of the order document itself
    create type order_status as enum ('pending', 'confirmed', 'cancelled', 'completed');
  end if;

  if not exists (select 1 from pg_type where typname = 'payment_status') then
    -- money state of the order (rolled up from the payments table)
    create type payment_status as enum ('unpaid', 'authorized', 'paid', 'partially_refunded', 'refunded', 'failed');
  end if;

  if not exists (select 1 from pg_type where typname = 'fulfillment_status') then
    create type fulfillment_status as enum ('unfulfilled', 'partially_fulfilled', 'fulfilled', 'returned');
  end if;

  if not exists (select 1 from pg_type where typname = 'payment_transaction_status') then
    create type payment_transaction_status as enum ('pending', 'authorized', 'captured', 'failed', 'refunded');
  end if;

  if not exists (select 1 from pg_type where typname = 'shipment_status') then
    create type shipment_status as enum ('pending', 'in_transit', 'delivered', 'returned', 'lost');
  end if;

  if not exists (select 1 from pg_type where typname = 'stock_movement_reason') then
    create type stock_movement_reason as enum
      ('purchase', 'reserve', 'release', 'sale', 'return', 'adjustment');
  end if;
end
$$;

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
create table if not exists customers (
  id             uuid primary key default gen_random_uuid(),
  -- link to the platform's auth user. Nullable so back-office staff can
  -- create a customer record before (or without) an account existing.
  auth_user_id   uuid unique,
  email          citext not null unique,
  full_name      text,
  phone          text,
  marketing_opt_in boolean not null default false,
  is_active      boolean not null default true,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint customers_email_shape_chk check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

-- FK to auth.users only when the platform schema is present.
do $$
begin
  if to_regclass('auth.users') is not null
     and not exists (select 1 from pg_constraint where conname = 'customers_auth_user_id_fkey') then
    alter table customers
      add constraint customers_auth_user_id_fkey
      foreign key (auth_user_id) references auth.users (id) on delete set null;
  end if;
end
$$;

create table if not exists addresses (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references customers (id) on delete cascade,
  label         text,                       -- 'Home', 'Office', ...
  recipient_name text not null,
  phone         text,
  line1         text not null,
  line2         text,
  city          text not null,
  region        text,
  postal_code   text,
  country_code  char(2) not null,
  is_default_shipping boolean not null default false,
  is_default_billing  boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists addresses_customer_id_idx on addresses (customer_id);
-- at most one default of each kind per customer
create unique index if not exists addresses_one_default_shipping_idx
  on addresses (customer_id) where is_default_shipping;
create unique index if not exists addresses_one_default_billing_idx
  on addresses (customer_id) where is_default_billing;

-- ---------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------
create table if not exists categories (
  id          uuid primary key default gen_random_uuid(),
  parent_id   uuid references categories (id) on delete set null,
  name        text not null,
  slug        text not null unique,
  description text,
  position    integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint categories_not_own_parent_chk check (parent_id is null or parent_id <> id)
);

create index if not exists categories_parent_id_idx on categories (parent_id);

create table if not exists products (
  id           uuid primary key default gen_random_uuid(),
  category_id  uuid references categories (id) on delete set null,
  sku          text not null unique,
  name         text not null,
  slug         text not null unique,
  description  text,
  brand        text,
  status       product_status not null default 'draft',
  base_price   numeric(12,2) not null check (base_price >= 0),
  currency     char(3) not null default 'USD',
  weight_grams integer check (weight_grams is null or weight_grams >= 0),
  attributes   jsonb not null default '{}'::jsonb,   -- free-form facets
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists products_category_id_idx on products (category_id);
create index if not exists products_status_idx on products (status);
create index if not exists products_name_trgm_idx on products (lower(name));

-- Every product has at least one variant; a single-variant product uses
-- one row named 'Default'. Orders always reference a variant, never a
-- product, so pricing and stock have exactly one home.
create table if not exists product_variants (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products (id) on delete cascade,
  sku         text not null unique,
  name        text not null default 'Default',
  price       numeric(12,2) not null check (price >= 0),
  compare_at_price numeric(12,2) check (compare_at_price is null or compare_at_price >= 0),
  options     jsonb not null default '{}'::jsonb,    -- {"size":"M","color":"black"}
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists product_variants_product_id_idx on product_variants (product_id);

create table if not exists product_images (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products (id) on delete cascade,
  variant_id  uuid references product_variants (id) on delete set null,
  url         text not null,
  alt_text    text,
  position    integer not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists product_images_product_id_idx on product_images (product_id);

-- ---------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------
create table if not exists inventory (
  id                 uuid primary key default gen_random_uuid(),
  variant_id         uuid not null references product_variants (id) on delete cascade,
  location           text not null default 'main',
  quantity_on_hand   integer not null default 0 check (quantity_on_hand >= 0),
  quantity_reserved  integer not null default 0 check (quantity_reserved >= 0),
  reorder_level      integer not null default 0 check (reorder_level >= 0),
  updated_at         timestamptz not null default now(),
  unique (variant_id, location),
  constraint inventory_reserved_le_on_hand_chk check (quantity_reserved <= quantity_on_hand)
);

-- Append-only ledger: every change to `inventory` writes a row here, so
-- "why is stock 3?" is always answerable.
create table if not exists inventory_movements (
  id            bigint generated always as identity primary key,
  variant_id    uuid not null references product_variants (id) on delete cascade,
  location      text not null default 'main',
  delta         integer not null,                    -- signed change to on-hand
  reserved_delta integer not null default 0,         -- signed change to reserved
  reason        stock_movement_reason not null,
  reference_type text,                               -- 'order', 'shipment', ...
  reference_id  uuid,
  note          text,
  created_at    timestamptz not null default now()
);

create index if not exists inventory_movements_variant_id_idx on inventory_movements (variant_id, created_at desc);
create index if not exists inventory_movements_reference_idx on inventory_movements (reference_type, reference_id);

-- Read models over these tables live in 15_views.sql.

-- ---------------------------------------------------------------------
-- Carts (pre-order state)
-- ---------------------------------------------------------------------
create table if not exists carts (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid references customers (id) on delete cascade,
  session_token text,                       -- guest carts
  currency     char(3) not null default 'USD',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint carts_owner_chk check (customer_id is not null or session_token is not null)
);

create index if not exists carts_customer_id_idx on carts (customer_id);

create table if not exists cart_items (
  id         uuid primary key default gen_random_uuid(),
  cart_id    uuid not null references carts (id) on delete cascade,
  variant_id uuid not null references product_variants (id) on delete cascade,
  quantity   integer not null check (quantity > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cart_id, variant_id)
);

-- ---------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------
create sequence if not exists order_number_seq start with 1001;

create table if not exists orders (
  id             uuid primary key default gen_random_uuid(),
  order_number   text not null unique default ('SO-' || lpad(nextval('order_number_seq')::text, 6, '0')),
  customer_id    uuid references customers (id) on delete set null,   -- kept for guest / deleted accounts
  email          citext not null,
  status         order_status not null default 'pending',
  payment_status payment_status not null default 'unpaid',
  fulfillment_status fulfillment_status not null default 'unfulfilled',
  currency       char(3) not null default 'USD',

  -- Money. subtotal / grand_total are maintained by trigger from
  -- order_items, so a client cannot post its own totals.
  subtotal       numeric(12,2) not null default 0 check (subtotal >= 0),
  discount_total numeric(12,2) not null default 0 check (discount_total >= 0),
  shipping_total numeric(12,2) not null default 0 check (shipping_total >= 0),
  tax_total      numeric(12,2) not null default 0 check (tax_total >= 0),
  grand_total    numeric(12,2) not null default 0 check (grand_total >= 0),

  -- Immutable snapshots: the address as it was at checkout time.
  shipping_address jsonb,
  billing_address  jsonb,

  placed_at      timestamptz not null default now(),
  cancelled_at   timestamptz,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists orders_customer_id_idx on orders (customer_id, placed_at desc);
create index if not exists orders_status_idx on orders (status);
create index if not exists orders_payment_status_idx on orders (payment_status);
create index if not exists orders_placed_at_idx on orders (placed_at desc);

create table if not exists order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders (id) on delete cascade,
  variant_id  uuid references product_variants (id) on delete restrict,
  -- snapshots: history must survive a product rename, reprice or delete
  sku         text not null,
  product_name text not null,
  variant_name text,
  unit_price  numeric(12,2) not null check (unit_price >= 0),
  quantity    integer not null check (quantity > 0),
  line_total  numeric(12,2) generated always as (unit_price * quantity) stored,
  created_at  timestamptz not null default now()
);

create index if not exists order_items_order_id_idx on order_items (order_id);
create index if not exists order_items_variant_id_idx on order_items (variant_id);

create table if not exists payments (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references orders (id) on delete cascade,
  provider     text not null,                        -- 'stripe', 'razorpay', 'cod'
  provider_reference text,                           -- pi_..., pay_...
  method       text,                                 -- 'card', 'upi', 'cash'
  amount       numeric(12,2) not null check (amount <> 0),
  currency     char(3) not null default 'USD',
  status       payment_transaction_status not null default 'pending',
  error_message text,
  raw_response jsonb not null default '{}'::jsonb,
  processed_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (provider, provider_reference)
);

create index if not exists payments_order_id_idx on payments (order_id);

create table if not exists shipments (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references orders (id) on delete cascade,
  carrier      text,
  service      text,
  tracking_number text,
  status       shipment_status not null default 'pending',
  shipped_at   timestamptz,
  delivered_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists shipments_order_id_idx on shipments (order_id);

create table if not exists shipment_items (
  id          uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments (id) on delete cascade,
  order_item_id uuid not null references order_items (id) on delete cascade,
  quantity    integer not null check (quantity > 0),
  unique (shipment_id, order_item_id)
);

-- Who moved the order to which state, and when.
create table if not exists order_status_history (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references orders (id) on delete cascade,
  from_status order_status,
  to_status   order_status not null,
  from_payment_status payment_status,
  to_payment_status   payment_status,
  changed_by  uuid,                                   -- auth user id, null = system
  note        text,
  created_at  timestamptz not null default now()
);

create index if not exists order_status_history_order_id_idx on order_status_history (order_id, created_at desc);
