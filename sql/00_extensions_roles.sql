-- =====================================================================
-- 00_extensions_roles.sql
-- Extensions + platform roles.
--
-- Safe to run on a Subastack/Postgres project where the roles already
-- exist: every statement is guarded and idempotent.
-- =====================================================================

create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "citext";     -- case-insensitive email

-- The three API roles. On a hosted project these already exist; this
-- block only creates them when running against a plain Postgres (local
-- dev, CI, staging restore).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;

-- New objects created by the migration owner are granted to the API
-- roles automatically; explicit grants still follow in 40_grants.sql so
-- the file is readable on its own.
