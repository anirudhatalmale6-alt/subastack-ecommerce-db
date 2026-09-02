-- =====================================================================
-- 01_auth_shim.sql
-- LOCAL / CI ONLY -- do not run this on the Subastack project.
--
-- Subastack (like every GoTrue-style backend) already ships an `auth`
-- schema with auth.users, auth.uid() and auth.jwt(). This file recreates
-- just enough of it so the schema, the policies and the test suite can
-- run on a bare Postgres 16.
--
-- Every statement checks for an existing object first, so if you *do*
-- run it by accident on the hosted project it will not overwrite the
-- platform's own functions.
-- =====================================================================

create schema if not exists auth;

do $$
begin
  if to_regclass('auth.users') is null then
    create table auth.users (
      id            uuid primary key default gen_random_uuid(),
      email         text unique,
      raw_app_meta_data jsonb not null default '{}'::jsonb,
      created_at    timestamptz not null default now()
    );
  end if;
end
$$;

-- auth.uid()  -> the caller's user id, read from the request JWT claims.
do $$
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'uid'
  ) then
    execute $fn$
      create function auth.uid() returns uuid
      language sql stable
      as $body$
        select nullif(
          current_setting('request.jwt.claims', true)::jsonb ->> 'sub',
          ''
        )::uuid
      $body$;
    $fn$;
  end if;
end
$$;

-- auth.jwt()  -> the whole claim set as jsonb.
do $$
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'jwt'
  ) then
    execute $fn$
      create function auth.jwt() returns jsonb
      language sql stable
      as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claims', true), '')::jsonb,
          '{}'::jsonb
        )
      $body$;
    $fn$;
  end if;
end
$$;

grant usage on schema auth to anon, authenticated, service_role;
