-- =====================================================================
-- tests/rls_tests.sql
-- Proves the security model does what the documentation claims.
--
-- Run against a database that has the schema + 50_seed.sql +
-- 51_seed_auth_local.sql applied:
--
--     psql "$DB_URL" -v ON_ERROR_STOP=1 -f tests/rls_tests.sql
--
-- Every check raises an exception on failure, so a non-zero exit code
-- means something regressed. The whole file runs in one transaction and
-- rolls back at the end -- it leaves no rows behind.
-- =====================================================================

begin;

-- Reads inventory with owner rights so the test can check stock levels
-- while acting as a shopper (who is correctly denied that table).
create or replace function pg_temp.reserved(p_variant uuid)
returns integer language sql security definer as $$
  select quantity_reserved from public.inventory
   where variant_id = p_variant and location = 'main'
$$;

-- Looks up an order id with owner rights, so the test can *try* to touch
-- an order that RLS correctly hides from the caller.
create or replace function pg_temp.order_id(p_number text)
returns uuid language sql security definer as $$
  select id from public.orders where order_number = p_number
$$;

create or replace function pg_temp.check(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then
    raise notice 'PASS  %', label;
  else
    raise exception 'FAIL  %', label;
  end if;
end;
$$;

do $$
declare
  ava_uid   uuid := 'a0000000-0000-4000-8000-000000000001';
  noah_uid  uuid := 'a0000000-0000-4000-8000-000000000002';
  staff_uid uuid := 'a0000000-0000-4000-8000-0000000000ff';
  ava_cust  uuid;
  n         integer;
  ok        boolean;
  v_cart_id uuid;
  ord       orders%rowtype;
  vid       uuid;
  before_reserved integer;
  after_reserved  integer;
begin
  select id into ava_cust from customers where email = 'ava.stone@example.com';

  -- =================================================================
  -- anon
  -- =================================================================
  execute 'set local role anon';
  execute format('set local request.jwt.claims = %L', '{"role":"anon"}');

  select count(*) into n from products;
  perform pg_temp.check(n = 12, format('anon sees the 12 active products (saw %s)', n));

  select count(*) into n from products where status = 'draft';
  perform pg_temp.check(n = 0, 'anon cannot see draft products');

  select count(*) into n from v_available_stock;
  perform pg_temp.check(n > 0, 'anon can read availability through v_available_stock');

  begin
    execute 'select count(*) from customers';
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'anon is refused the customers table');

  execute 'set local role anon';
  begin
    execute 'select count(*) from orders';
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'anon is refused the orders table');

  execute 'set local role anon';
  begin
    execute 'select count(*) from inventory';
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'anon is refused the inventory table');

  -- =================================================================
  -- signed-in shopper (Ava)
  -- =================================================================
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', ava_uid, 'role', 'authenticated')::text);

  perform pg_temp.check(public.current_customer_id() = ava_cust,
                        'current_customer_id() resolves the signed-in shopper');
  perform pg_temp.check(public.is_staff() = false, 'a plain shopper is not staff');

  select count(*) into n from customers;
  perform pg_temp.check(n = 1, format('Ava sees exactly her own customer row (saw %s)', n));

  select count(*) into n from orders;
  perform pg_temp.check(n = 2, format('Ava sees only her own 2 orders (saw %s)', n));

  select count(*) into n from orders where email = 'noah.reyes@example.com';
  perform pg_temp.check(n = 0, 'Ava cannot see another shopper''s order');

  select count(*) into n from order_items;
  perform pg_temp.check(n = 4, format('Ava sees only her own order lines (saw %s)', n));

  select count(*) into n from payments;
  perform pg_temp.check(n = 2, format('Ava sees only her own payments (saw %s)', n));

  select count(*) into n from v_inventory_status;
  perform pg_temp.check(n = 0, 'the staff stock view is empty for a shopper');

  -- protected columns
  begin
    update customers set is_active = false where id = ava_cust;
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'a shopper cannot deactivate/reactivate her own account');

  execute 'set local role authenticated';
  begin
    update customers set auth_user_id = noah_uid where id = ava_cust;
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'a shopper cannot re-point auth_user_id at someone else');

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', ava_uid, 'role', 'authenticated')::text);
  update customers set full_name = 'Ava R. Stone', marketing_opt_in = false where id = ava_cust;
  perform pg_temp.check(
    (select full_name from customers where id = ava_cust) = 'Ava R. Stone',
    'a shopper can still edit her own profile fields');

  -- orders are not directly writable
  update orders set status = 'completed' where customer_id = ava_cust;
  get diagnostics n = row_count;
  perform pg_temp.check(n = 0, 'a shopper cannot UPDATE orders directly (0 rows match the policy)');

  begin
    insert into orders (customer_id, email) values (
      (select id from customers where email = 'noah.reyes@example.com'), 'noah.reyes@example.com');
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'a shopper cannot create an order in someone else''s name');

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', ava_uid, 'role', 'authenticated')::text);

  -- privileged internals are not callable with a shopper key
  begin
    perform public.apply_stock_movement(
      (select id from product_variants where sku = 'AUR-HP-01-BLK'),
      1000, 0, 'adjustment');
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'apply_stock_movement() is not reachable from a shopper key');

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', ava_uid, 'role', 'authenticated')::text);

  -- =================================================================
  -- cart -> checkout -> cancel, as the shopper
  -- =================================================================
  select id into vid from product_variants where sku = 'BVL-KT-01-DEF';
  before_reserved := pg_temp.reserved(vid);

  select id into v_cart_id from public.add_to_cart(vid, 2);
  perform pg_temp.check(
    (select quantity from cart_items where cart_id = v_cart_id and variant_id = vid) = 2,
    'add_to_cart() puts 2 units in the cart');

  select * into ord from public.checkout_cart(v_cart_id, null, null, null, 9.00, 4.50);
  perform pg_temp.check(ord.subtotal = 238.00,
    format('checkout priced the line from the catalogue, not the client (subtotal %s)', ord.subtotal));
  perform pg_temp.check(ord.grand_total = 251.50,
    format('grand_total = subtotal + shipping + tax (got %s)', ord.grand_total));
  perform pg_temp.check(ord.payment_status = 'unpaid', 'a fresh order is unpaid');

  after_reserved := pg_temp.reserved(vid);
  perform pg_temp.check(after_reserved = before_reserved + 2,
    format('checkout reserved 2 units (%s -> %s)', before_reserved, after_reserved));

  perform pg_temp.check(
    (select count(*) from cart_items where cart_id = v_cart_id) = 0,
    'the cart is emptied by checkout');

  -- the client cannot dictate its own totals
  update orders set subtotal = 1 where id = ord.id;   -- blocked by RLS, 0 rows
  get diagnostics n = row_count;
  perform pg_temp.check(n = 0, 'a shopper cannot rewrite the order subtotal');

  -- overselling is refused
  begin
    insert into order_items (order_id, variant_id, sku, product_name, unit_price, quantity)
    values (ord.id, vid, 'BVL-KT-01-DEF', 'Bevel Pour-Over Kettle', 119.00, 100000);
    ok := false;
  exception when check_violation then ok := true;
  end;
  perform pg_temp.check(ok, 'the schema refuses to oversell a variant');

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', ava_uid, 'role', 'authenticated')::text);

  -- cancelling releases the reservation
  perform public.cancel_order(ord.id, 'changed my mind');
  perform pg_temp.check(
    (select status from orders where id = ord.id) = 'cancelled', 'cancel_order() cancels my order');
  after_reserved := pg_temp.reserved(vid);
  perform pg_temp.check(after_reserved = before_reserved,
    format('cancelling released the reservation (back to %s)', after_reserved));

  -- and I cannot cancel someone else's
  begin
    perform public.cancel_order(pg_temp.order_id('SEED-0002'));
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check(ok, 'cancel_order() refuses another shopper''s order');

  -- =================================================================
  -- staff
  -- =================================================================
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', staff_uid, 'role', 'authenticated',
                                   'app_metadata', json_build_object('role', 'admin'))::text);

  perform pg_temp.check(public.is_staff(), 'the ops user is recognised as staff');

  select count(*) into n from orders;
  perform pg_temp.check(n >= 7, format('staff see every order (saw %s)', n));

  -- 5 seeded shoppers + the ops user's own customer row, created by the
  -- on_auth_user_created hook when that account was made.
  select count(*) into n from customers;
  perform pg_temp.check(n = 6, format('staff see every customer (saw %s)', n));

  select count(*) into n from products where status = 'draft';
  perform pg_temp.check(n = 1, 'staff can see draft products');

  select count(*) into n from v_inventory_status;
  perform pg_temp.check(n = 21, format('staff see the real stock numbers (%s rows)', n));

  update orders set status = 'confirmed' where order_number = 'SEED-0001';
  get diagnostics n = row_count;
  perform pg_temp.check(n = 1, 'staff can move an order forward');

  -- payment roll-up
  insert into payments (order_id, provider, provider_reference, method, amount, currency, status, processed_at)
  select o.id, 'stripe', 'pi_test_rollup', 'card', o.grand_total, 'USD', 'captured', now()
    from orders o where o.order_number = 'SEED-0001';
  perform pg_temp.check(
    (select payment_status from orders where order_number = 'SEED-0001') = 'paid',
    'capturing the full amount flips the order to paid');

  insert into payments (order_id, provider, provider_reference, method, amount, currency, status, processed_at)
  select o.id, 'stripe', 're_test_rollup', 'card', -o.grand_total, 'USD', 'refunded', now()
    from orders o where o.order_number = 'SEED-0001';
  perform pg_temp.check(
    (select payment_status from orders where order_number = 'SEED-0001') = 'refunded',
    'a full refund flips the order to refunded');

  reset role;
  raise notice '-------------------------------------------';
  raise notice 'ALL CHECKS PASSED';
  raise notice '-------------------------------------------';
end
$$;

rollback;
