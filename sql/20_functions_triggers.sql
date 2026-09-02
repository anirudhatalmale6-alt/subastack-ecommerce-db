-- =====================================================================
-- 20_functions_triggers.sql
-- Business rules that must hold no matter which client wrote the row:
--   * updated_at maintenance
--   * order totals recomputed from the line items (never client-supplied)
--   * stock reserved on order, released on cancel, deducted on fulfilment
--   * payment_status rolled up from the payments ledger
--   * order status history written automatically
--
-- All trigger functions are SECURITY DEFINER so they keep working once
-- row level security is switched on in 30_rls_policies.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Identity helpers used by the RLS policies
-- ---------------------------------------------------------------------

-- The customers.id belonging to the caller, or NULL for anonymous.
create or replace function public.current_customer_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.id from customers c where c.auth_user_id = auth.uid() limit 1;
$$;

-- True for back-office users. Set `role` inside the user's app_metadata
-- ("app_metadata": {"role": "admin"}) -- app_metadata is not writable by
-- the user, unlike user_metadata, so this cannot be self-granted.
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role') in ('admin', 'staff'),
    false
  );
$$;

-- ---------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------
create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'customers','addresses','categories','products','product_variants',
    'carts','cart_items','orders','payments','shipments','inventory'
  ]
  loop
    execute format('drop trigger if exists set_updated_at on %I', t);
    execute format(
      'create trigger set_updated_at before update on %I
         for each row execute function public.tg_set_updated_at()', t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------
-- Order totals
-- ---------------------------------------------------------------------

-- grand_total is always derived, on every write to orders.
create or replace function public.tg_orders_compute_grand_total()
returns trigger
language plpgsql
as $$
begin
  new.grand_total := new.subtotal - new.discount_total + new.shipping_total + new.tax_total;
  if new.grand_total < 0 then
    raise exception 'order % totals are negative (subtotal % - discount % + shipping % + tax %)',
      new.order_number, new.subtotal, new.discount_total, new.shipping_total, new.tax_total;
  end if;
  return new;
end;
$$;

drop trigger if exists compute_grand_total on orders;
create trigger compute_grand_total
  before insert or update on orders
  for each row execute function public.tg_orders_compute_grand_total();

-- subtotal is the sum of the line items; the client cannot set it.
create or replace function public.tg_order_items_recalc_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target_order uuid := coalesce(new.order_id, old.order_id);
begin
  update orders o
     set subtotal = coalesce((
           select sum(oi.line_total) from order_items oi where oi.order_id = target_order
         ), 0)
   where o.id = target_order;
  return null;
end;
$$;

drop trigger if exists recalc_order_totals on order_items;
create trigger recalc_order_totals
  after insert or update or delete on order_items
  for each row execute function public.tg_order_items_recalc_totals();

-- ---------------------------------------------------------------------
-- Stock movements
-- ---------------------------------------------------------------------

-- One place that touches `inventory` + writes the ledger row.
create or replace function public.apply_stock_movement(
  p_variant_id     uuid,
  p_on_hand_delta  integer,
  p_reserved_delta integer,
  p_reason         stock_movement_reason,
  p_reference_type text default null,
  p_reference_id   uuid default null,
  p_location       text default 'main',
  p_note           text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  inv inventory%rowtype;
begin
  select * into inv
    from inventory
   where variant_id = p_variant_id and location = p_location
   for update;

  if not found then
    insert into inventory (variant_id, location, quantity_on_hand, quantity_reserved)
    values (p_variant_id, p_location, 0, 0)
    returning * into inv;
  end if;

  if inv.quantity_on_hand + p_on_hand_delta < 0 then
    raise exception 'insufficient stock for variant % at %: on hand %, requested %',
      p_variant_id, p_location, inv.quantity_on_hand, -p_on_hand_delta
      using errcode = 'check_violation';
  end if;

  if (inv.quantity_reserved + p_reserved_delta) > (inv.quantity_on_hand + p_on_hand_delta) then
    raise exception 'cannot reserve % of variant %: only % available',
      p_reserved_delta, p_variant_id,
      inv.quantity_on_hand - inv.quantity_reserved
      using errcode = 'check_violation';
  end if;

  update inventory
     set quantity_on_hand  = quantity_on_hand + p_on_hand_delta,
         quantity_reserved = greatest(quantity_reserved + p_reserved_delta, 0),
         updated_at        = now()
   where id = inv.id;

  insert into inventory_movements
    (variant_id, location, delta, reserved_delta, reason, reference_type, reference_id, note)
  values
    (p_variant_id, p_location, p_on_hand_delta, p_reserved_delta, p_reason,
     p_reference_type, p_reference_id, p_note);
end;
$$;

-- Adding a line to an open order reserves stock; removing it releases.
create or replace function public.tg_order_items_reserve_stock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  ord orders%rowtype;
begin
  select * into ord from orders where id = coalesce(new.order_id, old.order_id);

  -- Only open orders hold reservations. Lines added to a completed or
  -- cancelled order (data fixes, back-office edits) do not move stock.
  if ord.status not in ('pending', 'confirmed') then
    return null;
  end if;

  if tg_op = 'INSERT' and new.variant_id is not null then
    perform public.apply_stock_movement(
      new.variant_id, 0, new.quantity, 'reserve', 'order', new.order_id);

  elsif tg_op = 'UPDATE' and new.variant_id is not null then
    if new.quantity <> old.quantity then
      perform public.apply_stock_movement(
        new.variant_id, 0, new.quantity - old.quantity,
        case when new.quantity > old.quantity then 'reserve' else 'release' end,
        'order', new.order_id);
    end if;

  elsif tg_op = 'DELETE' and old.variant_id is not null then
    perform public.apply_stock_movement(
      old.variant_id, 0, -old.quantity, 'release', 'order', old.order_id);
  end if;

  return null;
end;
$$;

drop trigger if exists reserve_stock on order_items;
create trigger reserve_stock
  after insert or update or delete on order_items
  for each row execute function public.tg_order_items_reserve_stock();

-- Cancelling releases the reservation; fulfilling converts it to a sale.
create or replace function public.tg_orders_stock_on_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  item order_items%rowtype;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled'
     and old.fulfillment_status <> 'fulfilled' then
    for item in select * from order_items where order_id = new.id and variant_id is not null loop
      perform public.apply_stock_movement(
        item.variant_id, 0, -item.quantity, 'release', 'order', new.id, 'main', 'order cancelled');
    end loop;
    update orders set cancelled_at = coalesce(cancelled_at, now()) where id = new.id;
  end if;

  if new.fulfillment_status = 'fulfilled' and old.fulfillment_status <> 'fulfilled' then
    for item in select * from order_items where order_id = new.id and variant_id is not null loop
      perform public.apply_stock_movement(
        item.variant_id, -item.quantity, -item.quantity, 'sale', 'order', new.id, 'main', 'order fulfilled');
    end loop;
  end if;

  if new.fulfillment_status = 'returned' and old.fulfillment_status = 'fulfilled' then
    for item in select * from order_items where order_id = new.id and variant_id is not null loop
      perform public.apply_stock_movement(
        item.variant_id, item.quantity, 0, 'return', 'order', new.id, 'main', 'order returned');
    end loop;
  end if;

  return null;
end;
$$;

drop trigger if exists stock_on_status_change on orders;
create trigger stock_on_status_change
  after update on orders
  for each row
  when (old.status is distinct from new.status
        or old.fulfillment_status is distinct from new.fulfillment_status)
  execute function public.tg_orders_stock_on_status_change();

-- ---------------------------------------------------------------------
-- Payment status roll-up
-- ---------------------------------------------------------------------
-- Refunds are stored as rows with a negative `amount` and status
-- 'refunded'; captures are positive with status 'captured'.
create or replace function public.recalc_order_payment_status(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  captured numeric(12,2);
  refunded numeric(12,2);
  authorized_count integer;
  failed_count integer;
  row_count integer;
  total numeric(12,2);
  next_status payment_status;
begin
  select grand_total into total from orders where id = p_order_id;

  select
    coalesce(sum(amount) filter (where status = 'captured'), 0),
    abs(coalesce(sum(amount) filter (where status = 'refunded'), 0)),
    count(*) filter (where status = 'authorized'),
    count(*) filter (where status = 'failed'),
    count(*)
  into captured, refunded, authorized_count, failed_count, row_count
  from payments where order_id = p_order_id;

  if row_count = 0 then
    next_status := 'unpaid';
  elsif refunded > 0 and refunded >= captured then
    next_status := 'refunded';
  elsif refunded > 0 then
    next_status := 'partially_refunded';
  elsif captured > 0 and captured >= total then
    next_status := 'paid';
  elsif captured > 0 or authorized_count > 0 then
    next_status := 'authorized';
  elsif failed_count > 0 then
    next_status := 'failed';
  else
    next_status := 'unpaid';
  end if;

  update orders set payment_status = next_status
   where id = p_order_id and payment_status is distinct from next_status;
end;
$$;

create or replace function public.tg_payments_recalc_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.recalc_order_payment_status(coalesce(new.order_id, old.order_id));
  return null;
end;
$$;

drop trigger if exists recalc_payment_status on payments;
create trigger recalc_payment_status
  after insert or update or delete on payments
  for each row execute function public.tg_payments_recalc_status();

-- ---------------------------------------------------------------------
-- Order status history
-- ---------------------------------------------------------------------
create or replace function public.tg_orders_log_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    insert into order_status_history (order_id, to_status, to_payment_status, changed_by, note)
    values (new.id, new.status, new.payment_status, auth.uid(), 'order created');
  elsif new.status is distinct from old.status
     or new.payment_status is distinct from old.payment_status then
    insert into order_status_history
      (order_id, from_status, to_status, from_payment_status, to_payment_status, changed_by)
    values (new.id, old.status, new.status, old.payment_status, new.payment_status, auth.uid());
  end if;
  return null;
end;
$$;

drop trigger if exists log_order_status on orders;
create trigger log_order_status
  after insert or update on orders
  for each row execute function public.tg_orders_log_status();

-- ---------------------------------------------------------------------
-- Checkout: turn a cart into an order in one round trip.
-- Call from the app:  POST /rpc/checkout_cart  {"p_cart_id": "...", ...}
-- ---------------------------------------------------------------------
create or replace function public.checkout_cart(
  p_cart_id          uuid,
  p_email            text default null,
  p_shipping_address jsonb default null,
  p_billing_address  jsonb default null,
  p_shipping_total   numeric default 0,
  p_tax_total        numeric default 0
)
returns orders
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  cart carts%rowtype;
  cust customers%rowtype;
  new_order orders%rowtype;
  item record;
  buyer_email citext;
begin
  select * into cart from carts where id = p_cart_id;
  if not found then
    raise exception 'cart % not found', p_cart_id using errcode = 'no_data_found';
  end if;

  -- A signed-in caller may only check out their own cart.
  if auth.uid() is not null and not public.is_staff() then
    if cart.customer_id is distinct from public.current_customer_id() then
      raise exception 'not your cart' using errcode = 'insufficient_privilege';
    end if;
  end if;

  if cart.customer_id is not null then
    select * into cust from customers where id = cart.customer_id;
  end if;

  buyer_email := coalesce(p_email, cust.email);
  if buyer_email is null then
    raise exception 'an email address is required to place an order';
  end if;

  if not exists (select 1 from cart_items where cart_id = cart.id) then
    raise exception 'cart % is empty', cart.id;
  end if;

  insert into orders (customer_id, email, currency, shipping_address, billing_address,
                      shipping_total, tax_total, status)
  values (cart.customer_id, buyer_email, cart.currency,
          coalesce(p_shipping_address, (
            select to_jsonb(a) - 'id' - 'customer_id'
              from addresses a
             where a.customer_id = cart.customer_id and a.is_default_shipping
             limit 1)),
          p_billing_address,
          coalesce(p_shipping_total, 0), coalesce(p_tax_total, 0), 'pending')
  returning * into new_order;

  for item in
    select ci.variant_id, ci.quantity, pv.sku, pv.name as variant_name,
           pv.price, p.name as product_name
      from cart_items ci
      join product_variants pv on pv.id = ci.variant_id
      join products p on p.id = pv.product_id
     where ci.cart_id = cart.id
  loop
    insert into order_items
      (order_id, variant_id, sku, product_name, variant_name, unit_price, quantity)
    values
      (new_order.id, item.variant_id, item.sku, item.product_name,
       item.variant_name, item.price, item.quantity);
  end loop;

  delete from cart_items where cart_id = cart.id;

  select * into new_order from orders where id = new_order.id;   -- re-read computed totals
  return new_order;
end;
$$;
