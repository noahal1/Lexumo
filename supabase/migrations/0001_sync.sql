-- Lexumo sync, as a Postgres function behind Supabase RPC.
--
-- This is the server half of the sync protocol described in
-- `docs/sync-protocol.md`. It is a deliberate one-to-one translation of
-- `server/src/store.js` (`applySync`, lines 109-170), which is the reference
-- implementation and the thing its 12 tests assert against. Same ordering,
-- same comparison operators, same error codes — see
-- `supabase/tests/` where those 12 behaviours are re-asserted in SQL.
--
-- Why a function instead of PostgREST upserts: last-write-wins needs
--
--     on conflict (user_id, kind, id) do update
--       set payload = excluded.payload
--       where excluded.updated_at >= sync_records.updated_at
--
-- and PostgREST's `on_conflict` cannot express a conditional update. The
-- workaround — a BEFORE trigger that silently drops stale rows — would make
-- "wrote but did not take effect" unobservable, and an LWW conflict is a
-- normal path, not an error. So: one `security definer` function that applies
-- and returns the increment inside a single transaction.
--
-- `security definer` bypasses RLS. Every statement below therefore filters on
-- `auth.uid()` explicitly. Missing one would be a cross-tenant read.
--
-- Apply with `supabase db push`, or in tests via `supabase/tests/run.sh`.

-- ---------------------------------------------------------------- tables

create table if not exists public.sync_records (
  user_id    uuid        not null references auth.users (id) on delete cascade,
  kind       text        not null check (kind in ('lists', 'words', 'logs')),
  id         text        not null check (char_length(id) between 1 and 200),
  -- Monotonic per-user sequence. A client sends back the highest `rev` it has
  -- seen as `since`, and gets everything above it.
  rev        bigint      not null,
  -- Copied out of the payload so the LWW comparison can use an index. `logs`
  -- have no updatedAt and leave this null.
  updated_at double precision,
  payload    jsonb       not null,
  primary key (user_id, kind, id)
);

-- The hot query is "this user's records of one kind above rev N".
create index if not exists sync_records_increment_idx
  on public.sync_records (user_id, kind, rev);

create table if not exists public.sync_meta (
  user_id          uuid   primary key references auth.users (id) on delete cascade,
  -- Highest rev handed out for this user.
  rev              bigint not null default 0,
  -- Settings are one whole record with its own stamp, not a row per field:
  -- the protocol syncs them as a unit (see sync-protocol.md, `SettingsRecord`).
  settings_payload jsonb,
  settings_rev     bigint not null default 0
);

-- RLS on with no policies: the tables are reachable *only* through `sync()`.
-- The client never touches them directly (it only calls the RPC), so denying
-- direct access costs nothing and means a leaked anon key reads nothing.
alter table public.sync_records enable row level security;
alter table public.sync_meta    enable row level security;

-- ---------------------------------------------------------------- validation

-- Validate one kind's array and return it unchanged, or raise.
--
-- Split out so the whole request can be checked before anything is written:
-- the protocol says a bad request changes nothing (`store.js:267-287`), and
-- the 5000-item cap must reject the batch *entirely*, not truncate it.
create or replace function public.sync_validate_items(arr jsonb, kind text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  item jsonb;
begin
  if arr is null or jsonb_typeof(arr) = 'null' then
    return '[]'::jsonb;
  end if;

  if jsonb_typeof(arr) <> 'array' then
    raise exception 'bad_request' using errcode = '22000';
  end if;

  for item in select * from jsonb_array_elements(arr)
  loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'bad_request' using errcode = '22000';
    end if;

    if jsonb_typeof(item -> 'id') is distinct from 'string'
       or char_length(item ->> 'id') < 1
       or char_length(item ->> 'id') > 200 then
      raise exception 'bad_request' using errcode = '22000';
    end if;

    -- words/lists need updatedAt for LWW; logs dedupe by id alone (a log
    -- tombstone carries `at`, not `updatedAt`).
    if kind <> 'logs' and jsonb_typeof(item -> 'updatedAt') is distinct from 'number' then
      raise exception 'bad_request' using errcode = '22000';
    end if;
  end loop;

  return arr;
end;
$$;

-- ---------------------------------------------------------------- the RPC

create or replace function public.sync(since bigint default 0, changes jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid        uuid := auth.uid();
  since_rev  bigint;
  lists      jsonb;
  words      jsonb;
  logs       jsonb;
  settings   jsonb;
  cur_rev    bigint;
  item       jsonb;
  stored     public.sync_records;
  next_rev   bigint;
  out_lists  jsonb;
  out_words  jsonb;
  out_logs   jsonb;
  out_settings jsonb;
  v_settings_rev bigint;
  v_settings_payload jsonb;
begin
  if uid is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  -- `since` normalisation, mirroring `normalizeSince` (store.js:261-265):
  -- non-positive and non-finite both mean "everything".
  if since is null or since <= 0 then
    since_rev := 0;
  else
    since_rev := since;
  end if;

  -- ---- validate everything first; a raise here rolls the whole call back
  if changes is not null and jsonb_typeof(changes) <> 'object' then
    raise exception 'bad_request' using errcode = '22000';
  end if;

  lists    := public.sync_validate_items(changes -> 'lists', 'lists');
  words    := public.sync_validate_items(changes -> 'words', 'words');
  logs     := public.sync_validate_items(changes -> 'logs', 'logs');
  settings := case
                when changes is null then null
                when jsonb_typeof(changes -> 'settings') = 'null' then null
                when changes -> 'settings' is null then null
                else changes -> 'settings'
              end;

  if settings is not null then
    if jsonb_typeof(settings) <> 'object' then
      raise exception 'bad_request' using errcode = '22000';
    end if;
    if jsonb_typeof(settings -> 'updatedAt') is distinct from 'number' then
      raise exception 'bad_request' using errcode = '22000';
    end if;
  end if;

  if jsonb_array_length(lists) + jsonb_array_length(words) + jsonb_array_length(logs) > 5000 then
    raise exception 'too_many_changes' using errcode = '22000';
  end if;

  -- ---- take the per-user lock, then read the counter
  --
  -- Without `for update`, two concurrent rounds could read the same rev and
  -- hand out duplicate ones; `rev > since` would then be ambiguous and an
  -- increment could be silently skipped.
  insert into public.sync_meta (user_id) values (uid)
  on conflict (user_id) do nothing;

  select rev, settings_rev, settings_payload
    into cur_rev, v_settings_rev, v_settings_payload
    from public.sync_meta
   where user_id = uid
     for update;

  cur_rev := coalesce(cur_rev, 0);
  v_settings_rev := coalesce(v_settings_rev, 0);

  -- ---- apply lists then words, both LWW (store.js:117-126)
  --
  -- Accept when there is nothing stored, or when incoming >= stored. `>=`
  -- rather than `>` matters: the same edit arriving twice must still be
  -- accepted, otherwise a retried request would look like a conflict.
  for item in select * from jsonb_array_elements(lists)
  loop
    select * into stored
      from public.sync_records
     where user_id = uid and kind = 'lists' and id = (item ->> 'id');

    if not found or (item ->> 'updatedAt')::double precision >= coalesce(stored.updated_at, '-Infinity'::double precision) then
      cur_rev := cur_rev + 1;
      insert into public.sync_records (user_id, kind, id, rev, updated_at, payload)
      values (uid, 'lists', item ->> 'id', cur_rev, (item ->> 'updatedAt')::double precision, item)
      on conflict (user_id, kind, id) do update
        set rev = excluded.rev,
            updated_at = excluded.updated_at,
            payload = excluded.payload;
    end if;
  end loop;

  for item in select * from jsonb_array_elements(words)
  loop
    select * into stored
      from public.sync_records
     where user_id = uid and kind = 'words' and id = (item ->> 'id');

    if not found or (item ->> 'updatedAt')::double precision >= coalesce(stored.updated_at, '-Infinity'::double precision) then
      cur_rev := cur_rev + 1;
      insert into public.sync_records (user_id, kind, id, rev, updated_at, payload)
      values (uid, 'words', item ->> 'id', cur_rev, (item ->> 'updatedAt')::double precision, item)
      on conflict (user_id, kind, id) do update
        set rev = excluded.rev,
            updated_at = excluded.updated_at,
            payload = excluded.payload;
    end if;
  end loop;

  -- ---- logs: append-only, dedupe by id, plus tombstones (store.js:128-143)
  for item in select * from jsonb_array_elements(logs)
  loop
    select * into stored
      from public.sync_records
     where user_id = uid and kind = 'logs' and id = (item ->> 'id');

    if (item ->> 'deleted')::boolean is true then
      -- Deleting: only meaningful if a live log is there. Keep the tombstone
      -- so the deletion travels to other devices through the same increment.
      if found and coalesce((stored.payload ->> 'deleted')::boolean, false) is not true then
        cur_rev := cur_rev + 1;
        update public.sync_records
           set rev = cur_rev,
               payload = item || '{"deleted": true}'::jsonb
         where user_id = uid and kind = 'logs' and id = (item ->> 'id');
      end if;
    else
      -- A normal log: ignore if a live one already exists; re-insert over a
      -- tombstone (an undo followed by a re-grade is a real sequence).
      if not found or coalesce((stored.payload ->> 'deleted')::boolean, false) is true then
        cur_rev := cur_rev + 1;
        insert into public.sync_records (user_id, kind, id, rev, updated_at, payload)
        values (uid, 'logs', item ->> 'id', cur_rev, null, item)
        on conflict (user_id, kind, id) do update
          set rev = excluded.rev,
              updated_at = null,
              payload = excluded.payload;
      end if;
    end if;
  end loop;

  -- ---- settings: LWW as one whole record (store.js:145-152)
  if settings is not null then
    if v_settings_rev = 0 or (settings ->> 'updatedAt')::double precision >= coalesce((v_settings_payload ->> 'updatedAt')::double precision, '-Infinity'::double precision) then
      cur_rev := cur_rev + 1;
      v_settings_rev := cur_rev;
      v_settings_payload := settings;
    end if;
  end if;

  update public.sync_meta
     set rev = cur_rev,
         settings_rev = v_settings_rev,
         settings_payload = v_settings_payload
   where user_id = uid;

  -- ---- collect the increment (store.js:315-323)
  --
  -- `rev > since` includes what this very call just wrote, which is how the
  -- client learns the server's revision of its own records.
  select coalesce(jsonb_agg(e.payload || jsonb_build_object('_rev', e.rev) order by e.rev), '[]'::jsonb)
    into out_lists
    from (select rev, payload from public.sync_records
           where user_id = uid and kind = 'lists' and rev > since_rev) e;

  select coalesce(jsonb_agg(e.payload || jsonb_build_object('_rev', e.rev) order by e.rev), '[]'::jsonb)
    into out_words
    from (select rev, payload from public.sync_records
           where user_id = uid and kind = 'words' and rev > since_rev) e;

  select coalesce(jsonb_agg(e.payload || jsonb_build_object('_rev', e.rev) order by e.rev), '[]'::jsonb)
    into out_logs
    from (select rev, payload from public.sync_records
           where user_id = uid and kind = 'logs' and rev > since_rev) e;

  out_settings := case
                    when v_settings_payload is not null and v_settings_rev > since_rev
                      then v_settings_payload || jsonb_build_object('_rev', v_settings_rev)
                    else null
                  end;

  return jsonb_build_object(
    'rev', cur_rev,
    'serverTime', (extract(epoch from clock_timestamp()) * 1000)::bigint,
    'changes', jsonb_build_object(
      'lists', out_lists,
      'words', out_words,
      'logs', out_logs,
      'settings', coalesce(out_settings, 'null'::jsonb)
    )
  );
end;
$$;

revoke all on function public.sync(bigint, jsonb) from public;
grant execute on function public.sync(bigint, jsonb) to authenticated;

revoke all on function public.sync_validate_items(jsonb, text) from public;
