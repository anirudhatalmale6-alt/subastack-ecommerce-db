-- =====================================================================
-- 25_rpc_guards.sql
-- Actions a shopper is allowed to take that are NOT a plain row write,
-- plus the protected-column guard on customers.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Protected columns on customers.
-- RLS decides WHICH ROW a shopper may update (their own); it cannot
-- decide which COLUMNS. Without this, a PATCH on /customers?id=eq.me
-- could flip is_active or re-point auth_user_id. Staff and service-key
-- callers are exempt.
-- ---------------------------------------------------------------------
create or replace function public.tg_customers_protect_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_staff() or auth.uid() is null then
    return new;   -- back office and service-key callers may set anything
  end if;

  if new.auth_user_id is distinct from old.auth_user_id then
    raise exception 'auth_user_id cannot be changed' using errcode = 'insufficient_privilege';
  end if;
  if new.is_active is distinct from old.is_active then
    raise exception 'is_active is managed by staff' using errcode = 'insufficient_privilege';
  end if;
  if new.notes is distinct from old.notes then
    raise exception 'notes is a back-office field' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_customer_columns on customers;
create trigger protect_customer_columns
  before update on customers
  for each row execute function public.tg_customers_protect_columns();

-- ---------------------------------------------------------------------
-- Cancel my own order.  POST /rpc/cancel_order  {"p_order_id": "..."}
-- Shoppers have no UPDATE grant on orders, so this is the only door.
-- ---------------------------------------------------------------------
create or replace function public.cancel_order(p_order_id uuid, p_reason text default null)
returns orders
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  ord orders%rowtype;
begin
  select * into ord from orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id using errcode = 'no_data_found';
  end if;

  if not public.is_staff() then
    if ord.customer_id is null or ord.customer_id is distinct from public.current_customer_id() then
      raise exception 'not your order' using errcode = 'insufficient_privilege';
    end if;
    if ord.status <> 'pending' then
      raise exception 'order % is % and can no longer be cancelled from the app',
        ord.order_number, ord.status using errcode = 'check_violation';
    end if;
    if ord.payment_status in ('paid', 'partially_refunded') then
      raise exception 'order % is paid -- contact support for a refund', ord.order_number
        using errcode = 'check_violation';
    end if;
  end if;

  update orders
     set status = 'cancelled',
         cancelled_at = now(),
         notes = coalesce(nullif(concat_ws(E'\n', notes, p_reason), ''), notes)
   where id = p_order_id
   returning * into ord;

  return ord;
end;
$$;

-- ---------------------------------------------------------------------
-- Add to cart, creating the cart on first call.
-- POST /rpc/add_to_cart {"p_variant_id": "...", "p_quantity": 2}
-- ---------------------------------------------------------------------
create or replace function public.add_to_cart(p_variant_id uuid, p_quantity integer default 1)
returns carts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  cust_id uuid := public.current_customer_id();
  cart carts%rowtype;
begin
  if cust_id is null then
    raise exception 'sign in to use a cart' using errcode = 'insufficient_privilege';
  end if;
  if p_quantity <= 0 then
    raise exception 'quantity must be positive';
  end if;
  if not exists (select 1 from product_variants where id = p_variant_id and is_active) then
    raise exception 'variant % is not purchasable', p_variant_id;
  end if;

  select * into cart from carts where customer_id = cust_id order by created_at desc limit 1;
  if not found then
    insert into carts (customer_id) values (cust_id) returning * into cart;
  end if;

  insert into cart_items (cart_id, variant_id, quantity)
  values (cart.id, p_variant_id, p_quantity)
  on conflict (cart_id, variant_id)
  do update set quantity = cart_items.quantity + excluded.quantity,
                updated_at = now();

  return cart;
end;
$$;
