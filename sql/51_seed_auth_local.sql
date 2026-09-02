-- =====================================================================
-- 51_seed_auth_local.sql
-- LOCAL / CI ONLY. Creates auth users for the seeded customers so the
-- RLS test suite has real identities to sign in as.
--
-- On Subastack you create these through the dashboard or the admin API
-- (signup), NOT by inserting into auth.users. The on_auth_user_created
-- trigger from 26_auth_hook.sql then links each new user to the matching
-- customers row by email.
--
-- Staff: note the app_metadata role claim. is_staff() reads exactly this.
-- =====================================================================

insert into auth.users (id, email, raw_app_meta_data) values
  ('a0000000-0000-4000-8000-000000000001', 'ava.stone@example.com',   '{}'),
  ('a0000000-0000-4000-8000-000000000002', 'noah.reyes@example.com',  '{}'),
  ('a0000000-0000-4000-8000-000000000003', 'mia.tanaka@example.com',  '{}'),
  ('a0000000-0000-4000-8000-000000000004', 'liam.okafor@example.com', '{}'),
  ('a0000000-0000-4000-8000-000000000005', 'sofia.marin@example.com', '{}'),
  ('a0000000-0000-4000-8000-0000000000ff', 'ops@example.com',         '{"role":"admin"}')
on conflict (id) do nothing;
