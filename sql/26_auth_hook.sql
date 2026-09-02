-- =====================================================================
-- 26_auth_hook.sql
-- When a user signs up, give them a customers row automatically, so the
-- app never has to remember to create one (and so RLS has something to
-- match on from the very first request).
--
-- If an anonymous order was already placed with that email address, the
-- existing customer row is claimed instead of a duplicate being made.
--
-- Creating a trigger on auth.users needs ownership of that table. If the
-- project does not allow it the block below logs a notice and the rest
-- of the migration still applies -- call public.link_auth_user() from an
-- app-side signup handler instead.
-- =====================================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into customers (auth_user_id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_app_meta_data ->> 'full_name', split_part(new.email, '@', 1))
  )
  on conflict (email) do update
    set auth_user_id = excluded.auth_user_id
    where customers.auth_user_id is null;
  return new;
end;
$$;

do $$
begin
  if to_regclass('auth.users') is not null then
    begin
      execute 'drop trigger if exists on_auth_user_created on auth.users';
      execute 'create trigger on_auth_user_created
                 after insert on auth.users
                 for each row execute function public.handle_new_auth_user()';
      raise notice 'installed on_auth_user_created trigger';
    exception when insufficient_privilege then
      raise notice 'no permission to add a trigger on auth.users -- call public.link_auth_user() from the app after signup instead';
    end;
  end if;
end
$$;

-- Manual fallback / repair: attach the signed-in auth user to a customer
-- row, creating it if needed. Safe to call on every app start.
create or replace function public.link_auth_user(p_email text default null, p_full_name text default null)
returns customers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  uid uuid := auth.uid();
  cust customers%rowtype;
begin
  if uid is null then
    raise exception 'link_auth_user() must be called by a signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  select * into cust from customers where auth_user_id = uid;
  if found then
    return cust;
  end if;

  if p_email is null then
    raise exception 'p_email is required the first time a user is linked';
  end if;

  insert into customers (auth_user_id, email, full_name)
  values (uid, p_email, p_full_name)
  on conflict (email) do update
    set auth_user_id = excluded.auth_user_id,
        full_name = coalesce(customers.full_name, excluded.full_name)
    where customers.auth_user_id is null
  returning * into cust;

  if cust.id is null then
    raise exception 'the email % already belongs to another account', p_email
      using errcode = 'unique_violation';
  end if;

  return cust;
end;
$$;

grant execute on function public.link_auth_user(text, text) to authenticated, service_role;
