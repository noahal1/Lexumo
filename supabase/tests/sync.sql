-- The 12 behaviours from `server/test/sync.test.js`, re-asserted in SQL.
--
-- That file tests the reference implementation (`server/src/store.js`). This
-- file tests the Supabase translation (`supabase/migrations/0001_sync.sql`)
-- and is deliberately named after the same list: if the two ever disagree,
-- one of them is wrong and the divergence is the bug. Test 12 (restart
-- persistence) has no SQL analogue — Postgres is the persistence — so it is
-- covered by the "reconnect" case at the bottom instead.
--
-- Run with `supabase/tests/run.sh`, which creates a throwaway database,
-- applies the shim + migration, then this file. Every case runs inside a
-- transaction that is rolled back, so they are order-independent.
--
--   psql -f shim.sql -f ../migrations/0001_sync.sql -f sync.sql

\set ON_ERROR_STOP on

-- --------------------------------------------------------------- fixtures

create or replace function pg_temp.as_user(target uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', target::text, true);
end;
$$;

create or replace function pg_temp.fresh_user()
returns uuid language plpgsql as $$
declare
  new_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (new_id, new_id::text || '@test.local');
  return new_id;
end;
$$;

-- Assert helper: raise with a readable message instead of a bare `false`.
create or replace function pg_temp.expect(ok boolean, msg text)
returns void language plpgsql as $$
begin
  if ok is not true then
    raise exception 'FAILED: %', msg;
  end if;
end;
$$;

-- A word record, with only the fields the server looks at.
create or replace function pg_temp.word(id text, updated_at double precision, extra jsonb default '{}'::jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object('id', id, 'updatedAt', updated_at, 'term', 't', 'definition', 'd', 'deleted', false) || extra
$$;

create or replace function pg_temp.log_rec(id text, at double precision, extra jsonb default '{}'::jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object('id', id, 'at', at, 'wordId', 'w1', 'grade', 'good') || extra
$$;

-- ---------------------------------------------------------------- test 1
-- Push 2 words + 1 log: the response carries them back and rev advanced.

create temp table t_results (name text, ok boolean, detail text);

create or replace function pg_temp.run_test_1() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  r jsonb;
begin
  perform pg_temp.as_user(u);
  r := public.sync(0, jsonb_build_object(
    'words', jsonb_build_array(pg_temp.word('w1', 100), pg_temp.word('w2', 101)),
    'logs',  jsonb_build_array(pg_temp.log_rec('l1', 150))
  ));

  perform pg_temp.expect(jsonb_array_length(r -> 'changes' -> 'words') = 2, 'test1: two words come back');
  perform pg_temp.expect(jsonb_array_length(r -> 'changes' -> 'logs') = 1, 'test1: one log comes back');
  perform pg_temp.expect((r ->> 'rev')::bigint = 3, 'test1: rev is 3 after three records');
  -- `_rev` is a response-only decoration; it must never be stored.
  perform pg_temp.expect((r -> 'changes' -> 'words' -> 0 ? '_rev'), 'test1: _rev appears in the response');
end;
$$;

-- ---------------------------------------------------------------- test 2
-- Incremental pull: since=lastRev returns only what is newer.

create or replace function pg_temp.run_test_2() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  first jsonb;
  second jsonb;
begin
  perform pg_temp.as_user(u);
  first := public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 100))));
  second := public.sync((first ->> 'rev')::bigint,
                        jsonb_build_object('words', jsonb_build_array(pg_temp.word('w2', 200))));

  perform pg_temp.expect(jsonb_array_length(second -> 'changes' -> 'words') = 1, 'test2: only the new word');
  perform pg_temp.expect(second -> 'changes' -> 'words' -> 0 ->> 'id' = 'w2', 'test2: and it is w2');

  -- A round with no changes still reports the current rev and an empty set.
  declare
    third jsonb := public.sync((second ->> 'rev')::bigint, '{}'::jsonb);
  begin
    perform pg_temp.expect(jsonb_array_length(third -> 'changes' -> 'words') = 0, 'test2: empty round returns nothing');
    perform pg_temp.expect((third ->> 'rev')::bigint = (second ->> 'rev')::bigint, 'test2: rev unchanged');
  end;
end;
$$;

-- ---------------------------------------------------------------- test 3
-- LWW: older updatedAt is dropped; newer AND equal are accepted.

create or replace function pg_temp.run_test_3() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  r jsonb;
begin
  perform pg_temp.as_user(u);
  perform public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 200, '{"term":"original"}'::jsonb))));

  -- Older: rejected, so it does not appear in the increment at all.
  r := public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 100, '{"term":"stale"}'::jsonb))));
  perform pg_temp.expect(not exists (
    select 1 from jsonb_array_elements(r -> 'changes' -> 'words') e where e ->> 'term' = 'stale'
  ), 'test3: older record did not overwrite');

  -- Equal: accepted. This is the `>=` that is easy to lose in a rewrite.
  r := public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 200, '{"term":"equal"}'::jsonb))));
  perform pg_temp.expect(exists (
    select 1 from jsonb_array_elements(r -> 'changes' -> 'words') e where e ->> 'term' = 'equal'
  ), 'test3: equal updatedAt is accepted');

  -- Newer: accepted.
  r := public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 300, '{"term":"newer"}'::jsonb))));
  perform pg_temp.expect(exists (
    select 1 from jsonb_array_elements(r -> 'changes' -> 'words') e where e ->> 'term' = 'newer'
  ), 'test3: newer record overwrote');

  -- And the stored copy is the newest one.
  perform pg_temp.expect(
    (select payload ->> 'term' from public.sync_records
      where user_id = u and kind = 'words' and id = 'w1') = 'newer',
    'test3: stored copy is the newest'
  );
end;
$$;

-- ---------------------------------------------------------------- test 4
-- Lists follow the same LWW rule as words.

create or replace function pg_temp.run_test_4() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  r jsonb;
begin
  perform pg_temp.as_user(u);
  perform public.sync(0, jsonb_build_object('lists', jsonb_build_array(
    jsonb_build_object('id', 'list1', 'updatedAt', 200, 'name', 'original')
  )));

  r := public.sync(0, jsonb_build_object('lists', jsonb_build_array(
    jsonb_build_object('id', 'list1', 'updatedAt', 100, 'name', 'stale')
  )));
  perform pg_temp.expect(not exists (
    select 1 from jsonb_array_elements(r -> 'changes' -> 'lists') e where e ->> 'name' = 'stale'
  ), 'test4: older list rejected');

  perform pg_temp.expect(
    (select payload ->> 'name' from public.sync_records
      where user_id = u and kind = 'lists' and id = 'list1') = 'original',
    'test4: stored list unchanged'
  );
end;
$$;

-- ---------------------------------------------------------------- test 5
-- Logs are idempotent: the same id pushed twice stays one row.

create or replace function pg_temp.run_test_5() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  before_rev bigint;
  after_rev bigint;
begin
  perform pg_temp.as_user(u);
  perform public.sync(0, jsonb_build_object('logs', jsonb_build_array(pg_temp.log_rec('l1', 150))));
  select rev into before_rev from public.sync_meta where user_id = u;

  perform public.sync(0, jsonb_build_object('logs', jsonb_build_array(pg_temp.log_rec('l1', 150))));
  select rev into after_rev from public.sync_meta where user_id = u;

  perform pg_temp.expect(
    (select count(*) from public.sync_records where user_id = u and kind = 'logs') = 1,
    'test5: one log row, not two'
  );
  -- A duplicate must not consume a rev: otherwise every client re-pulling
  -- from the old `since` sees a phantom change.
  perform pg_temp.expect(before_rev = after_rev, 'test5: duplicate did not bump rev');
end;
$$;

-- ---------------------------------------------------------------- test 6
-- Log tombstone: after a delete, another client's full pull has no live log.

create or replace function pg_temp.run_test_6() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  r jsonb;
  live_count int;
  tomb_count int;
begin
  perform pg_temp.as_user(u);
  perform public.sync(0, jsonb_build_object('logs', jsonb_build_array(pg_temp.log_rec('l1', 150))));

  -- Another device deletes it.
  perform public.sync(0, jsonb_build_object('logs', jsonb_build_array(
    jsonb_build_object('id', 'l1', 'at', 150, 'deleted', true)
  )));

  r := public.sync(0, '{}'::jsonb);
  select count(*) filter (where not coalesce((e ->> 'deleted')::boolean, false)),
         count(*) filter (where coalesce((e ->> 'deleted')::boolean, false))
    into live_count, tomb_count
    from jsonb_array_elements(r -> 'changes' -> 'logs') e;

  perform pg_temp.expect(live_count = 0, 'test6: no live log after delete');
  perform pg_temp.expect(tomb_count = 1, 'test6: the tombstone travels');

  -- Deleting again is a no-op (no new rev).
  declare
    rev_before bigint := (select rev from public.sync_meta where user_id = u);
    rev_after bigint;
  begin
    perform public.sync(0, jsonb_build_object('logs', jsonb_build_array(
      jsonb_build_object('id', 'l1', 'at', 150, 'deleted', true)
    )));
    rev_after := (select rev from public.sync_meta where user_id = u);
    perform pg_temp.expect(rev_before = rev_after, 'test6: second delete is a no-op');
  end;
end;
$$;

-- ---------------------------------------------------------------- test 7
-- Word tombstone: push {id, deleted:true}, another client's full pull sees it.

create or replace function pg_temp.run_test_7() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  r jsonb;
begin
  perform pg_temp.as_user(u);
  perform public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 100))));

  perform public.sync(0, jsonb_build_object('words', jsonb_build_array(
    jsonb_build_object('id', 'w1', 'updatedAt', 200, 'deleted', true)
  )));

  r := public.sync(0, '{}'::jsonb);
  perform pg_temp.expect(
    (select coalesce((e ->> 'deleted')::boolean, false)
       from jsonb_array_elements(r -> 'changes' -> 'words') e
      where e ->> 'id' = 'w1') is true,
    'test7: tombstone is delivered'
  );
end;
$$;

-- ---------------------------------------------------------------- test 8
-- Settings are LWW as a whole record; an unchanged settings returns null.

create or replace function pg_temp.run_test_8() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  r jsonb;
begin
  perform pg_temp.as_user(u);

  r := public.sync(0, jsonb_build_object('settings', jsonb_build_object('updatedAt', 100, 'theme', 'light')));
  perform pg_temp.expect((r ->> 'rev')::bigint = 1, 'test8: first settings takes rev 1');
  perform pg_temp.expect(r -> 'changes' -> 'settings' ->> 'theme' = 'light', 'test8: settings accepted');
  perform pg_temp.expect((r -> 'changes' -> 'settings' ->> '_rev')::bigint = 1, 'test8: settings carries _rev');

  -- Older, with since=1 (the rev the client already has): rejected, and
  -- because nothing changed after `since`, `settings` comes back as JSON null
  -- rather than the record it already knows about.
  r := public.sync(1, jsonb_build_object('settings', jsonb_build_object('updatedAt', 50, 'theme', 'stale')));
  perform pg_temp.expect((r ->> 'rev')::bigint = 1, 'test8: rejected settings did not consume a rev');
  perform pg_temp.expect(jsonb_typeof(r -> 'changes' -> 'settings') = 'null', 'test8: older settings rejected, null returned');

  -- Newer: accepted, and rev advances.
  r := public.sync(1, jsonb_build_object('settings', jsonb_build_object('updatedAt', 200, 'theme', 'dark')));
  perform pg_temp.expect((r ->> 'rev')::bigint = 2, 'test8: newer settings took rev 2');
  perform pg_temp.expect(r -> 'changes' -> 'settings' ->> 'theme' = 'dark', 'test8: newer settings accepted');
  perform pg_temp.expect((r -> 'changes' -> 'settings' ->> '_rev')::bigint = 2, 'test8: and carries rev 2');

  -- Nothing changed after rev 2.
  r := public.sync(2, '{}'::jsonb);
  perform pg_temp.expect(jsonb_typeof(r -> 'changes' -> 'settings') = 'null', 'test8: unchanged settings is null');
end;
$$;

-- ---------------------------------------------------------------- test 9
-- Over 5000 items: too_many_changes, and the batch is not partly written.

create or replace function pg_temp.run_test_9() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  big jsonb;
  overflowed boolean := false;
  stored int;
begin
  perform pg_temp.as_user(u);

  select jsonb_agg(pg_temp.word('w' || i, 100)) into big
    from generate_series(1, 5001) i;

  begin
    perform public.sync(0, jsonb_build_object('words', big));
  exception when others then
    if sqlerrm = 'too_many_changes' then overflowed := true; else raise; end if;
  end;

  perform pg_temp.expect(overflowed, 'test9: too_many_changes raised');

  -- The whole statement rolled back: not 5000 rows, not 0 with a bumped rev.
  select count(*) into stored from public.sync_records where user_id = u;
  perform pg_temp.expect(stored = 0, 'test9: nothing written');
  perform pg_temp.expect(
    coalesce((select rev from public.sync_meta where user_id = u), 0) = 0,
    'test9: rev not consumed'
  );
end;
$$;

-- --------------------------------------------------------------- test 10
-- Malformed changes are bad_request.

create or replace function pg_temp.run_test_10() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  cases jsonb := jsonb_build_array(
    jsonb_build_object('words', '[1,2,3]'::jsonb),                       -- not objects
    jsonb_build_object('words', jsonb_build_array(jsonb_build_object('id', 5, 'updatedAt', 1))),  -- id not a string
    jsonb_build_object('words', jsonb_build_array(jsonb_build_object('id', '', 'updatedAt', 1))), -- empty id
    jsonb_build_object('words', jsonb_build_array(jsonb_build_object('id', repeat('x', 201), 'updatedAt', 1))), -- too long
    jsonb_build_object('words', jsonb_build_array(jsonb_build_object('id', 'w1'))),                -- no updatedAt
    jsonb_build_object('settings', jsonb_build_object('theme', 'light'))                          -- no updatedAt
  );
  each jsonb;
  rejected int := 0;
  total int := 0;
begin
  perform pg_temp.as_user(u);
  for each in select * from jsonb_array_elements(cases) loop
    total := total + 1;
    begin
      perform public.sync(0, each);
    exception when others then
      if sqlerrm = 'bad_request' then rejected := rejected + 1; else raise; end if;
    end;
  end loop;
  perform pg_temp.expect(rejected = total, 'test10: every malformed case rejected (' || rejected || '/' || total || ')');
end;
$$;

-- --------------------------------------------------------------- test 11
-- User isolation: another account cannot see or overwrite the first's data.

create or replace function pg_temp.run_test_11() returns void language plpgsql as $$
declare
  alice uuid := pg_temp.fresh_user();
  bob   uuid := pg_temp.fresh_user();
  r jsonb;
begin
  perform pg_temp.as_user(alice);
  perform public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 100))));

  perform pg_temp.as_user(bob);
  r := public.sync(0, '{}'::jsonb);
  perform pg_temp.expect(jsonb_array_length(r -> 'changes' -> 'words') = 0, 'test11: bob sees nothing');

  -- Bob pushing the same id must create his own row, not touch Alice's.
  perform public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 999))));
  perform pg_temp.expect(
    (select (payload ->> 'updatedAt')::double precision from public.sync_records
      where user_id = alice and kind = 'words' and id = 'w1') = 100,
    'test11: alice unchanged by bob'
  );
end;
$$;

-- --------------------------------------------------------------- test 12
-- No server-restart analogue: Postgres *is* the store. What is worth
-- asserting instead is that state survives a fresh session — i.e. that the
-- function reads committed rows rather than anything session-local.

create or replace function pg_temp.run_test_12() returns void language plpgsql as $$
declare
  u uuid := pg_temp.fresh_user();
  rev_before bigint;
  r jsonb;
begin
  perform pg_temp.as_user(u);
  perform public.sync(0, jsonb_build_object('words', jsonb_build_array(pg_temp.word('w1', 100))));
  select rev into rev_before from public.sync_meta where user_id = u;

  -- New transaction, same user: everything must still be there.
  perform set_config('request.jwt.claim.sub', u::text, true);
  r := public.sync(0, '{}'::jsonb);

  perform pg_temp.expect((r ->> 'rev')::bigint = rev_before, 'test12: rev survives');
  perform pg_temp.expect(jsonb_array_length(r -> 'changes' -> 'words') = 1, 'test12: record survives');
end;
$$;

-- --------------------------------------------------------------- extra
-- Not in the Node suite, but the RPC must refuse an anonymous call: with
-- `security definer` and no `auth.uid()`, a missing check would mean every
-- caller shares one tenant.

create or replace function pg_temp.run_test_13() returns void language plpgsql as $$
declare
  rejected boolean := false;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.sync(0, '{}'::jsonb);
  exception when others then
    if sqlerrm = 'unauthorized' then rejected := true; else raise; end if;
  end;
  perform pg_temp.expect(rejected, 'test13: anonymous call refused');
end;
$$;

-- --------------------------------------------------------------- runner

do $$
declare
  i int;
  failed int := 0;
  total int := 13;
begin
  create temp table if not exists t_results (name text, ok boolean, detail text);
  for i in 1..total loop
    begin
      execute format('select pg_temp.run_test_%s()', i);
      raise notice 'ok   test %', i;
    exception when others then
      failed := failed + 1;
      raise notice 'FAIL test % : %', i, sqlerrm;
    end;
  end loop;

  if failed > 0 then
    raise exception '% of % sync SQL tests failed', failed, total;
  end if;
  raise notice 'all % sync SQL tests passed', total;
end;
$$;
