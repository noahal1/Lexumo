-- Local test shim: just enough of Supabase's schema to run the migration.
-- Supabase provides `auth.users` and `auth.uid()`; a bare Postgres does not.
create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text unique
);

-- Supabase sets a GUC per request; auth.uid() reads it.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

-- Supabase's built-in role for signed-in users; `grant execute ... to
-- authenticated` in the migration needs it to exist.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated;
  end if;
end $$;
