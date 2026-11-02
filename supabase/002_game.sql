-- Infinipixels 002: teams, achievements, golden pixel, pixel history, server-side broadcast.
-- Run after migration.sql in the Supabase SQL editor. Additive (new columns/tables), no data dropped.
-- paint_pixel and leaderboard are dropped and recreated because their return types change. Safe to re-run.

-- ---------------------------------------------------------------- schema
alter table public.tiles add column if not exists owners bytea;        -- team that owns each pixel (0 = none)
update public.tiles set owners = decode(repeat('00', 10000), 'hex') where owners is null;
alter table public.tiles alter column owners set not null;

alter table public.painters add column if not exists team         smallint check (team in (1, 2));  -- 1 cyan, 2 magenta
alter table public.painters add column if not exists emoji        text;
alter table public.painters add column if not exists bonus        int not null default 0;
alter table public.painters add column if not exists tiles_mask   bit(100) not null default repeat('0', 100)::bit(100);
alter table public.painters add column if not exists colours_mask int not null default 0;

create table if not exists public.team_scores (
  team   smallint primary key,
  pixels int not null default 0
);
insert into public.team_scores values (1, 0), (2, 0) on conflict do nothing;

create table if not exists public.achievements (
  user_id   uuid not null,
  code      text not null,
  earned_at timestamptz not null default now(),
  primary key (user_id, code)
);

create table if not exists public.pixel_events (
  id      bigserial primary key,
  x       smallint not null,
  y       smallint not null,
  c       smallint not null,
  user_id uuid not null,
  team    smallint not null default 0,
  at      timestamptz not null default clock_timestamp()
);
create index if not exists pixel_events_xy   on public.pixel_events (x, y, id desc);
create index if not exists pixel_events_user on public.pixel_events (user_id, at);

create table if not exists public.golden (
  id         int primary key default 1 check (id = 1),
  x          int not null,
  y          int not null,
  spawned_at timestamptz not null default now()
);
insert into public.golden (id, x, y)
values (1, 400 + floor(random() * 200)::int, 400 + floor(random() * 200)::int)
on conflict do nothing;

alter table public.team_scores  enable row level security;
alter table public.achievements enable row level security;
alter table public.pixel_events enable row level security;
alter table public.golden       enable row level security;

drop policy if exists team_scores_read  on public.team_scores;
drop policy if exists achievements_read on public.achievements;
drop policy if exists golden_read       on public.golden;
create policy team_scores_read  on public.team_scores  for select to authenticated using (true);
create policy achievements_read on public.achievements for select to authenticated using (true);
create policy golden_read       on public.golden       for select to authenticated using (true);
-- pixel_events: no policy; read only through pixel_info().

revoke all on public.team_scores, public.achievements, public.pixel_events, public.golden from anon, authenticated;
grant select on public.team_scores, public.achievements, public.golden to authenticated;

-- ---------------------------------------------------------------- internal helper (not callable by clients)
create or replace function public._golden_move(by_name text default null, by_emoji text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare g jsonb;
begin
  update public.golden
     set x = 60 + floor(random() * 880)::int, y = 60 + floor(random() * 880)::int, spawned_at = now()
   where id = 1
  returning jsonb_build_object('x', golden.x, 'y', golden.y) into g;
  begin
    perform realtime.send(g || jsonb_build_object('n', by_name, 'e', by_emoji), 'golden', 'canvas', false);
  exception when others then null;
  end;
  return g;
end;
$$;

-- ---------------------------------------------------------------- paint
drop function if exists public.paint_pixel(int, int, int);
create function public.paint_pixel(x int, y int, c int)
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
  select get_byte(t.owners, off) into old_owner
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

  insert into public.pixel_events (x, y, c, user_id, team) values (px, py, pc, uid, new_owner);

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

-- ---------------------------------------------------------------- reads
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
  return jsonb_build_object('s', (select jsonb_object_agg(s.team, s.pixels) from public.team_scores s), 'g', g);
end;
$$;

drop function if exists public.leaderboard();
create function public.leaderboard()
returns table (name text, emoji text, team smallint, score int, badges int)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(p.name, ''), 'anon'), p.emoji, p.team, p.pixel_count + p.bonus,
         (select count(*)::int from public.achievements a where a.user_id = p.user_id)
    from public.painters p
   where p.pixel_count > 0
   order by p.pixel_count + p.bonus desc, p.last_paint_at
   limit 10;
$$;

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
    'rank',   (select count(*) + 1 from public.painters q where q.pixel_count + q.bonus > p.pixel_count + p.bonus),
    'ach',    coalesce((select jsonb_agg(a.code) from public.achievements a where a.user_id = p.user_id), '[]'::jsonb))
  from public.painters p
  where p.user_id = auth.uid();
$$;

create or replace function public.pixel_info(x int, y int)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('n', coalesce(nullif(p.name, ''), 'anon'), 'e', p.emoji, 't', e.team, 'at', e.at)
    from public.pixel_events e
    left join public.painters p on p.user_id = e.user_id
   where e.x = pixel_info.x and e.y = pixel_info.y
   order by e.id desc
   limit 1;
$$;

-- name, emoji and (optionally) team. A null team keeps the current one, or joins the smaller team.
create or replace function public.set_profile(n text, e text, t int default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare tm int;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  if t is not null and t not in (1, 2) then
    raise exception 'bad team';
  end if;
  insert into public.painters as p (user_id, name, emoji, team)
  values (auth.uid(), left(btrim(n), 24), left(e, 8),
          coalesce(t, (select case when count(*) filter (where q.team = 1) <= count(*) filter (where q.team = 2) then 1 else 2 end
                         from public.painters q)))
  on conflict (user_id) do update
    set name  = left(btrim(n), 24),
        emoji = left(e, 8),
        team  = coalesce(t, p.team, excluded.team)
  returning p.team into tm;
  return tm;
end;
$$;

-- ---------------------------------------------------------------- grants
revoke execute on function public._golden_move(text, text)    from public, anon, authenticated;
revoke execute on function public.paint_pixel(int, int, int)  from public, anon;
revoke execute on function public.get_state()                 from public, anon;
revoke execute on function public.leaderboard()               from public, anon;
revoke execute on function public.my_stats()                  from public, anon;
revoke execute on function public.pixel_info(int, int)        from public, anon;
revoke execute on function public.set_profile(text, text, int) from public, anon;
grant  execute on function public.paint_pixel(int, int, int)  to authenticated;
grant  execute on function public.get_state()                 to authenticated;
grant  execute on function public.leaderboard()               to authenticated;
grant  execute on function public.my_stats()                  to authenticated;
grant  execute on function public.pixel_info(int, int)        to authenticated;
grant  execute on function public.set_profile(text, text, int) to authenticated;
