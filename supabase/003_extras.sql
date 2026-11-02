-- Infinipixels 003: timelapse replay, Claude commentary. Run after 002_game.sql.
-- Additive (new column/table/functions); paint_pixel and get_state are replaced with the same signatures. Safe to re-run.

-- ---------------------------------------------------------------- timelapse: remember the colour each paint replaced
alter table public.pixel_events add column if not exists prev_c smallint;
update public.pixel_events e
   set prev_c = coalesce((select p.c from public.pixel_events p
                           where p.x = e.x and p.y = e.y and p.id < e.id
                           order by p.id desc limit 1), 0)
 where e.prev_c is null;

-- ---------------------------------------------------------------- commentary (written by the Worker cron)
create table if not exists public.commentary (
  id      bigserial primary key,
  line    text not null,
  flagged boolean not null default false,   -- Claude flagged possible offensive art: stored for review, never shown
  at      timestamptz not null default now()
);
alter table public.commentary enable row level security;
revoke all on public.commentary from anon, authenticated;

-- ---------------------------------------------------------------- paint (same as 002, plus prev_c)
create or replace function public.paint_pixel(x int, y int, c int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  px   int := x;
  py   int := y;
  pc   int := c;
  vtx  int;
  vty  int;
  off  int;
  me   public.painters%rowtype;
  remaining numeric;
  old_c     int;
  old_owner int;
  new_owner int;
  prev_c  int;
  prev_u  uuid;
  prev2_c int;
  cand    text[] := '{}';
  new_ach text[];
  scores  jsonb;
  gmove   jsonb;
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if px < 0 or px >= 1000 or py < 0 or py >= 1000 then
    raise exception 'out of bounds';
  end if;
  if pc < 0 or pc >= 16 then
    raise exception 'bad colour';
  end if;
  vtx := px / 100;
  vty := py / 100;
  off := (py % 100) * 100 + (px % 100);

  -- Atomic 2s cooldown + stats. New painters join the smaller team.
  insert into public.painters as p (user_id, last_paint_at, pixel_count, tiles_mask, colours_mask, team)
  values (uid, clock_timestamp(), 1,
          set_bit(repeat('0', 100)::bit(100), vty * 10 + vtx, 1), 1 << pc,
          (select case when count(*) filter (where q.team = 1) <= count(*) filter (where q.team = 2) then 1 else 2 end
             from public.painters q))
  on conflict (user_id) do update
    set last_paint_at = clock_timestamp(),
        pixel_count   = p.pixel_count + 1,
        tiles_mask    = set_bit(p.tiles_mask, vty * 10 + vtx, 1),
        colours_mask  = p.colours_mask | (1 << pc),
        team          = coalesce(p.team, excluded.team)
    where p.last_paint_at is null
       or p.last_paint_at <= clock_timestamp() - interval '2 seconds'
  returning p.* into me;

  if me.user_id is null then
    select 2 - extract(epoch from (clock_timestamp() - p.last_paint_at))
      into remaining
      from public.painters p where p.user_id = uid;
    raise exception 'cooldown: % seconds remaining', round(greatest(remaining, 0.1), 1);
  end if;

  -- pixel + team territory
  select get_byte(t.data, off), get_byte(t.owners, off) into old_c, old_owner
    from public.tiles t where t.tx = vtx and t.ty = vty for update;
  new_owner := coalesce(me.team, 0);
  update public.tiles t
     set data = set_byte(t.data, off, pc), owners = set_byte(t.owners, off, new_owner)
   where t.tx = vtx and t.ty = vty;
  if new_owner <> old_owner then
    update public.team_scores s
       set pixels = greatest(0, s.pixels + case when s.team = new_owner then 1 else -1 end)
     where s.team in (new_owner, old_owner);
  end if;

  -- history-based achievements (read before logging this paint)
  select e.c, e.user_id into prev_c, prev_u
    from public.pixel_events e where e.x = px and e.y = py order by e.id desc limit 1;
  select e.c into prev2_c
    from public.pixel_events e where e.x = px and e.y = py order by e.id desc offset 1 limit 1;
  if prev_u is not null and prev_u <> uid and prev_c <> pc and prev2_c = pc then
    cand := array_append(cand, 'defender');
  end if;
  if exists (select 1 from public.pixel_events e
              where e.x between px - 1 and px + 1 and e.y between py - 1 and py + 1
                and e.user_id <> uid and e.at > clock_timestamp() - interval '10 seconds') then
    cand := array_append(cand, 'collab');
  end if;

  insert into public.pixel_events (x, y, c, prev_c, user_id, team) values (px, py, pc, old_c, uid, new_owner);

  cand := array_append(cand, 'first');
  if me.pixel_count >= 10  then cand := array_append(cand, 'p10');  end if;
  if me.pixel_count >= 50  then cand := array_append(cand, 'p50');  end if;
  if me.pixel_count >= 100 then cand := array_append(cand, 'p100'); end if;
  if me.pixel_count >= 500 then cand := array_append(cand, 'p500'); end if;
  if length(replace(me.tiles_mask::text, '0', '')) >= 10 then cand := array_append(cand, 'explorer'); end if;
  if me.colours_mask = 65535 then cand := array_append(cand, 'spectrum'); end if;
  if (select count(*) from public.pixel_events e
       where e.user_id = uid and e.at > clock_timestamp() - interval '60 seconds') >= 15 then
    cand := array_append(cand, 'onfire');
  end if;
  if extract(hour from clock_timestamp() at time zone 'Asia/Singapore') < 5 then
    cand := array_append(cand, 'nightowl');
  end if;

  -- golden pixel: +25 bonus, then it respawns elsewhere
  if exists (select 1 from public.golden g where g.id = 1 and g.x = px and g.y = py) then
    cand := array_append(cand, 'golden');
    update public.painters p set bonus = p.bonus + 25 where p.user_id = uid;
    gmove := public._golden_move(coalesce(nullif(me.name, ''), 'anon'), me.emoji);
  end if;

  with ins as (
    insert into public.achievements (user_id, code)
    select uid, u.code from unnest(cand) as u(code)
    on conflict do nothing
    returning achievements.code
  )
  select coalesce(array_agg(ins.code), '{}') into new_ach from ins;

  select jsonb_object_agg(s.team, s.pixels) into scores from public.team_scores s;

  -- Server-authoritative broadcast on the public "canvas" channel. Never fail a paint over it.
  begin
    perform realtime.send(jsonb_build_object('x', px, 'y', py, 'c', pc, 'u', uid, 's', scores), 'px', 'canvas', false);
    if cardinality(new_ach) > 0 then
      perform realtime.send(jsonb_build_object('u', uid, 'n', coalesce(nullif(me.name, ''), 'anon'), 'e', me.emoji,
                                               'a', to_jsonb(new_ach)), 'ach', 'canvas', false);
    end if;
  exception when others then null;
  end;

  return jsonb_build_object('a', to_jsonb(new_ach), 's', scores, 'g', gmove, 'team', me.team);
end;
$$;

-- ---------------------------------------------------------------- timelapse
-- Last 60k paints packed as 6 bytes each (x:int16, y:int16, c:uint8, prev_c:uint8), oldest first, base64.
create or replace function public.timelapse()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'n', count(*),
    'b64', replace(encode(coalesce(string_agg(
             int2send(t.x) || int2send(t.y)
             || substring(int2send(t.c) from 2 for 1)
             || substring(int2send(coalesce(t.prev_c, 0::smallint)) from 2 for 1),
             ''::bytea order by t.id), ''::bytea), 'base64'), E'\n', ''))
  from (select e.id, e.x, e.y, e.c, e.prev_c from public.pixel_events e order by e.id desc limit 60000) t;
$$;

-- ---------------------------------------------------------------- state (adds the latest commentary line)
create or replace function public.get_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare g jsonb;
begin
  -- an unclaimed golden pixel moves after 5 minutes (no cron needed)
  if exists (select 1 from public.golden where id = 1 and spawned_at < now() - interval '5 minutes') then
    g := public._golden_move();
  else
    select jsonb_build_object('x', golden.x, 'y', golden.y) into g from public.golden where id = 1;
  end if;
  return jsonb_build_object(
    's', (select jsonb_object_agg(s.team, s.pixels) from public.team_scores s),
    'g', g,
    'm', (select c.line from public.commentary c
           where not c.flagged and c.at > now() - interval '30 minutes'
           order by c.id desc limit 1));
end;
$$;

-- ---------------------------------------------------------------- my_stats (adds name + emoji so a GitHub sign-in on a new device restores the profile)
create or replace function public.my_stats()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'pixels', p.pixel_count,
    'score',  p.pixel_count + p.bonus,
    'team',   p.team,
    'name',   p.name,
    'emoji',  p.emoji,
    'rank',   (select count(*) + 1 from public.painters q where q.pixel_count + q.bonus > p.pixel_count + p.bonus),
    'ach',    coalesce((select jsonb_agg(a.code) from public.achievements a where a.user_id = p.user_id), '[]'::jsonb))
  from public.painters p
  where p.user_id = auth.uid();
$$;

-- ---------------------------------------------------------------- commentary RPCs (service role only)
create or replace function public.commentary_context()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'due', exists (select 1 from public.pixel_events e
                    where e.at > coalesce((select max(c.at) from public.commentary c), '-infinity')),
    'scores', (select jsonb_object_agg(s.team, s.pixels) from public.team_scores s),
    'paints_5m', (select count(*) from public.pixel_events e where e.at > now() - interval '5 minutes'),
    'painters_5m', (select count(distinct e.user_id) from public.pixel_events e where e.at > now() - interval '5 minutes'),
    'recent', coalesce((select jsonb_agg(r.line) from (select c.line from public.commentary c
                         where not c.flagged order by c.id desc limit 3) r), '[]'::jsonb));
$$;

create or replace function public.post_commentary(line text, flagged boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.commentary (line, flagged) values (left(line, 280), flagged);
  if not flagged then
    begin
      perform realtime.send(jsonb_build_object('m', left(line, 280)), 'commentary', 'canvas', false);
    exception when others then null;
    end;
  end if;
end;
$$;

-- ---------------------------------------------------------------- grants
revoke execute on function public.timelapse()                       from public, anon;
grant  execute on function public.timelapse()                       to authenticated;
revoke execute on function public.commentary_context()              from public, anon, authenticated;
revoke execute on function public.post_commentary(text, boolean)    from public, anon, authenticated;
grant  execute on function public.commentary_context()              to service_role;
grant  execute on function public.post_commentary(text, boolean)    to service_role;
