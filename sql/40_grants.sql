-- =====================================================================
-- 40_grants.sql
-- Table/function privileges. RLS (30_rls_policies.sql) decides WHICH
-- ROWS; these grants decide which TABLES and VERBS are reachable at all.
-- Both have to allow an operation for it to succeed.
--
-- Note the shape: `authenticated` is granted write verbs on back-office
-- tables (products, inventory, payments...) and RLS then narrows those
-- to is_staff() only. That is intentional -- it means a staff member is
-- just a normal signed-in user with a role claim, no second connection.
-- =====================================================================

-- Start from a clean slate: nothing is public.
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;

-- Revoke EXECUTE from PUBLIC on our own functions only.
--
-- `revoke all on all functions in schema public` would also strip the
-- citext and pgcrypto operators that were installed into this schema,
-- and every `where email = '...'` on a citext column would then fail
-- with "permission denied for function citext_eq". Extension-owned
-- functions are skipped here on purpose.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and not exists (
         select 1 from pg_depend d
          where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from public', f.sig);
  end loop;

  -- Repair step: if a blanket revoke was ever run on this database, put
  -- EXECUTE back on the extension functions so citext/pgcrypto work.
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_depend d on d.objid = p.oid
                      and d.classid = 'pg_proc'::regclass
                      and d.deptype = 'e'
     where n.nspname = 'public'
  loop
    execute format('grant execute on function %s to public', f.sig);
  end loop;
end
$$;

-- ---------------------------------------------------------------------
-- anon -- storefront browsing only
-- ---------------------------------------------------------------------
grant select on
  categories, products, product_variants, product_images,
  v_available_stock, v_product_catalog
to anon;

-- ---------------------------------------------------------------------
-- authenticated -- everything the app may touch; RLS scopes the rows
-- ---------------------------------------------------------------------
grant select on
  categories, products, product_variants, product_images,
  customers, addresses, carts, cart_items,
  orders, order_items, payments, shipments, shipment_items,
  order_status_history, inventory, inventory_movements,
  v_available_stock, v_product_catalog, v_inventory_status, v_order_summary
to authenticated;

grant insert, update, delete on
  addresses, carts, cart_items
to authenticated;

grant insert, update on customers to authenticated;   -- columns guarded by trigger
grant insert on orders, order_items to authenticated; -- update/delete blocked by RLS

-- Back-office verbs. Only is_staff() rows pass RLS.
grant insert, update, delete on
  categories, products, product_variants, product_images,
  inventory, payments, shipments, shipment_items
to authenticated;
grant update, delete on orders, order_items to authenticated;

grant usage on sequence order_number_seq to authenticated, service_role;

-- ---------------------------------------------------------------------
-- service_role -- the server-side key. Bypasses RLS.
-- ---------------------------------------------------------------------
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- ---------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------

-- Helpers: safe for anyone to call, they only read the caller's own JWT.
grant execute on function public.current_customer_id() to anon, authenticated, service_role;
grant execute on function public.is_staff() to anon, authenticated, service_role;

-- Shopper-facing RPCs.
grant execute on function public.add_to_cart(uuid, integer) to authenticated, service_role;
grant execute on function public.cancel_order(uuid, text) to authenticated, service_role;
grant execute on function public.checkout_cart(uuid, text, jsonb, jsonb, numeric, numeric)
  to authenticated, service_role;

-- SECURITY DEFINER internals -- server side only. These bypass RLS by
-- design, so they must never be reachable from an anon/authenticated key.
grant execute on function public.apply_stock_movement(uuid, integer, integer, stock_movement_reason, text, uuid, text, text)
  to service_role;
grant execute on function public.recalc_order_payment_status(uuid) to service_role;

-- ---------------------------------------------------------------------
-- Anything added later inherits the same shape.
-- ---------------------------------------------------------------------
alter default privileges in schema public grant select on tables to anon, authenticated;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
-- NB: no `alter default privileges ... revoke execute on functions` here.
-- It would silently break the next extension you install into public.
-- Instead: re-run this file after adding a function, or revoke by hand.
