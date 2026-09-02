-- =====================================================================
-- 30_rls_policies.sql
-- Row level security. Nothing is readable or writable unless a policy
-- below says so.
--
-- Three callers:
--   anon           -- not signed in. Catalogue only.
--   authenticated  -- signed in shopper. Own rows only.
--   staff/admin    -- an authenticated user whose JWT carries
--                     app_metadata.role in ('admin','staff'). See is_staff().
--   service_role   -- the server-side key. Bypasses RLS entirely; used by
--                     webhooks (payments) and back-office jobs.
--
-- Re-running this file is safe: every policy is dropped first.
-- =====================================================================

do $$
declare
  t text;
begin
  foreach t in array array[
    'customers','addresses','categories','products','product_variants',
    'product_images','inventory','inventory_movements','carts','cart_items',
    'orders','order_items','payments','shipments','shipment_items',
    'order_status_history'
  ]
  loop
    execute format('alter table %I enable row level security', t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------
-- Catalogue: world readable when published, staff writable.
-- ---------------------------------------------------------------------
drop policy if exists categories_read_active on categories;
create policy categories_read_active on categories
  for select to anon, authenticated
  using (is_active or public.is_staff());

drop policy if exists categories_staff_write on categories;
create policy categories_staff_write on categories
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists products_read_active on products;
create policy products_read_active on products
  for select to anon, authenticated
  using (status = 'active' or public.is_staff());

drop policy if exists products_staff_write on products;
create policy products_staff_write on products
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists product_variants_read_active on product_variants;
create policy product_variants_read_active on product_variants
  for select to anon, authenticated
  using (
    public.is_staff()
    or (is_active and exists (
      select 1 from products p where p.id = product_id and p.status = 'active'))
  );

drop policy if exists product_variants_staff_write on product_variants;
create policy product_variants_staff_write on product_variants
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists product_images_read on product_images;
create policy product_images_read on product_images
  for select to anon, authenticated
  using (
    public.is_staff()
    or exists (select 1 from products p where p.id = product_id and p.status = 'active')
  );

drop policy if exists product_images_staff_write on product_images;
create policy product_images_staff_write on product_images
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------
-- Stock: staff only at table level. The storefront reads availability
-- through v_available_stock, which does not expose the real numbers.
-- ---------------------------------------------------------------------
drop policy if exists inventory_staff_all on inventory;
create policy inventory_staff_all on inventory
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists inventory_movements_staff_read on inventory_movements;
create policy inventory_movements_staff_read on inventory_movements
  for select to authenticated
  using (public.is_staff());

-- ---------------------------------------------------------------------
-- Customers: a shopper sees exactly one row -- their own.
-- ---------------------------------------------------------------------
drop policy if exists customers_select_own on customers;
create policy customers_select_own on customers
  for select to authenticated
  using (auth_user_id = auth.uid() or public.is_staff());

drop policy if exists customers_insert_own on customers;
create policy customers_insert_own on customers
  for insert to authenticated
  with check (auth_user_id = auth.uid() or public.is_staff());

drop policy if exists customers_update_own on customers;
create policy customers_update_own on customers
  for update to authenticated
  using (auth_user_id = auth.uid() or public.is_staff())
  with check (auth_user_id = auth.uid() or public.is_staff());

drop policy if exists customers_staff_delete on customers;
create policy customers_staff_delete on customers
  for delete to authenticated
  using (public.is_staff());

-- ---------------------------------------------------------------------
-- Addresses: full CRUD on my own.
-- ---------------------------------------------------------------------
drop policy if exists addresses_own_all on addresses;
create policy addresses_own_all on addresses
  for all to authenticated
  using (customer_id = public.current_customer_id() or public.is_staff())
  with check (customer_id = public.current_customer_id() or public.is_staff());

-- ---------------------------------------------------------------------
-- Carts: signed-in shoppers only. Guest carts are handled server side
-- with the service key (see docs/HANDOVER.md, "Guest checkout").
-- ---------------------------------------------------------------------
drop policy if exists carts_own_all on carts;
create policy carts_own_all on carts
  for all to authenticated
  using (customer_id = public.current_customer_id() or public.is_staff())
  with check (customer_id = public.current_customer_id() or public.is_staff());

drop policy if exists cart_items_own_all on cart_items;
create policy cart_items_own_all on cart_items
  for all to authenticated
  using (exists (
    select 1 from carts c
     where c.id = cart_id
       and (c.customer_id = public.current_customer_id() or public.is_staff())))
  with check (exists (
    select 1 from carts c
     where c.id = cart_id
       and (c.customer_id = public.current_customer_id() or public.is_staff())));

-- ---------------------------------------------------------------------
-- Orders: read own, create own. No UPDATE and no DELETE for shoppers --
-- cancelling goes through cancel_order(), status changes through staff.
-- ---------------------------------------------------------------------
drop policy if exists orders_select_own on orders;
create policy orders_select_own on orders
  for select to authenticated
  using (customer_id = public.current_customer_id() or public.is_staff());

drop policy if exists orders_insert_own on orders;
create policy orders_insert_own on orders
  for insert to authenticated
  with check (customer_id = public.current_customer_id() or public.is_staff());

drop policy if exists orders_staff_update on orders;
create policy orders_staff_update on orders
  for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists orders_staff_delete on orders;
create policy orders_staff_delete on orders
  for delete to authenticated
  using (public.is_staff());

drop policy if exists order_items_select_own on order_items;
create policy order_items_select_own on order_items
  for select to authenticated
  using (exists (
    select 1 from orders o
     where o.id = order_id
       and (o.customer_id = public.current_customer_id() or public.is_staff())));

-- A shopper may only add lines to their own order while it is pending.
drop policy if exists order_items_insert_own_pending on order_items;
create policy order_items_insert_own_pending on order_items
  for insert to authenticated
  with check (exists (
    select 1 from orders o
     where o.id = order_id
       and (public.is_staff()
            or (o.customer_id = public.current_customer_id() and o.status = 'pending'))));

drop policy if exists order_items_staff_write on order_items;
create policy order_items_staff_write on order_items
  for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists order_items_staff_delete on order_items;
create policy order_items_staff_delete on order_items
  for delete to authenticated
  using (public.is_staff());

-- ---------------------------------------------------------------------
-- Money and fulfilment: readable by the owner, writable only by the
-- service key (payment webhooks) or staff.
-- ---------------------------------------------------------------------
drop policy if exists payments_select_own on payments;
create policy payments_select_own on payments
  for select to authenticated
  using (exists (
    select 1 from orders o
     where o.id = order_id
       and (o.customer_id = public.current_customer_id() or public.is_staff())));

drop policy if exists payments_staff_write on payments;
create policy payments_staff_write on payments
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists shipments_select_own on shipments;
create policy shipments_select_own on shipments
  for select to authenticated
  using (exists (
    select 1 from orders o
     where o.id = order_id
       and (o.customer_id = public.current_customer_id() or public.is_staff())));

drop policy if exists shipments_staff_write on shipments;
create policy shipments_staff_write on shipments
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists shipment_items_select_own on shipment_items;
create policy shipment_items_select_own on shipment_items
  for select to authenticated
  using (exists (
    select 1 from shipments s join orders o on o.id = s.order_id
     where s.id = shipment_id
       and (o.customer_id = public.current_customer_id() or public.is_staff())));

drop policy if exists shipment_items_staff_write on shipment_items;
create policy shipment_items_staff_write on shipment_items
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists order_status_history_select_own on order_status_history;
create policy order_status_history_select_own on order_status_history
  for select to authenticated
  using (exists (
    select 1 from orders o
     where o.id = order_id
       and (o.customer_id = public.current_customer_id() or public.is_staff())));
