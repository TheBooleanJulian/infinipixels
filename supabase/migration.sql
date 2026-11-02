-- Infinipixels: single migration. Paste into the Supabase SQL editor and run once.
-- Safe to re-run (idempotent). Seed art is a separate file: supabase/seed.sql
--
-- Also required in the dashboard (not SQL):
--   Authentication > Providers > "Allow anonymous sign-ins"  -> ON
--   (Realtime Broadcast + Presence need no setup on a public channel)

-- ---------------------------------------------------------------- tables
create table if not exists public.tiles (
  tx   int   not null check (tx between 0 and 9),
  ty   int   not null check (ty between 0 and 9),
  data bytea not null check (length(data) = 10000),
  primary key (tx, ty)
);

create table if not exists public.painters (
  user_id       uuid primary key,
  last_paint_at timestamptz,
  pixel_count   int not null default 0,
  name          text
);

-- 100 tiles of 100x100 pixels, one byte per pixel (palette index 0..15, 0 = white)
insert into public.tiles (tx, ty, data)
select x, y, decode(repeat('00', 10000), 'hex')
from generate_series(0, 9) x, generate_series(0, 9) y
on conflict do nothing;

-- ---------------------------------------------------------------- RLS
-- Anonymous sign-ins use the `authenticated` role, so "signed in" covers them.
alter table public.tiles    enable row level security;
alter table public.painters enable row level security;

drop policy if exists tiles_read    on public.tiles;
drop policy if exists painters_read on public.painters;
create policy tiles_read    on public.tiles    for select to authenticated using (true);
create policy painters_read on public.painters for select to authenticated using (true);

-- No direct writes from clients: only the SECURITY DEFINER functions below write.
revoke all on public.tiles, public.painters from anon, authenticated;
grant select on public.tiles, public.painters to authenticated;

-- ---------------------------------------------------------------- RPCs
create or replace function public.paint_pixel(x int, y int, c int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid       uuid := auth.uid();
  got       timestamptz;
  remaining numeric;
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if x < 0 or x >= 1000 or y < 0 or y >= 1000 then
    raise exception 'out of bounds';
  end if;
  if c < 0 or c >= 16 then
    raise exception 'bad colour';
  end if;

  -- Atomic cooldown: the upsert only succeeds when the last paint is >= 2s old.
  insert into public.painters as p (user_id, last_paint_at, pixel_count)
  values (uid, clock_timestamp(), 1)
  on conflict (user_id) do update
    set last_paint_at = clock_timestamp(),
        pixel_count   = p.pixel_count + 1
    where p.last_paint_at is null
       or p.last_paint_at <= clock_timestamp() - interval '2 seconds'
  returning p.last_paint_at into got;

  if got is null then
    select 2 - extract(epoch from (clock_timestamp() - p.last_paint_at))
      into remaining
      from public.painters p where p.user_id = uid;
    raise exception 'cooldown: % seconds remaining', round(greatest(remaining, 0.1), 1);
  end if;

  update public.tiles t
     set data = set_byte(t.data, (y % 100) * 100 + (x % 100), c)
   where t.tx = x / 100 and t.ty = y / 100;
end;
$$;

-- base64 without the 76-column line breaks that encode() inserts
create or replace function public.get_tiles(tx_min int, ty_min int, tx_max int, ty_max int)
returns table (tx int, ty int, b64 text)
language sql
stable
security invoker
set search_path = public
as $$
  select t.tx, t.ty, replace(encode(t.data, 'base64'), E'\n', '')
    from public.tiles t
   where t.tx between tx_min and tx_max
     and t.ty between ty_min and ty_max
   order by t.ty, t.tx;
$$;

create or replace function public.leaderboard()
returns table (name text, pixel_count int)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(p.name, ''), 'anon'), p.pixel_count
    from public.painters p
   where p.pixel_count > 0
   order by p.pixel_count desc, p.last_paint_at
   limit 10;
$$;

-- Clients cannot update painters directly, so naming goes through here.
create or replace function public.set_name(n text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  insert into public.painters as p (user_id, name)
  values (auth.uid(), left(btrim(n), 24))
  on conflict (user_id) do update set name = left(btrim(n), 24);
end;
$$;

revoke execute on function public.paint_pixel(int, int, int)      from public, anon;
revoke execute on function public.get_tiles(int, int, int, int)   from public, anon;
revoke execute on function public.leaderboard()                   from public, anon;
revoke execute on function public.set_name(text)                  from public, anon;
grant  execute on function public.paint_pixel(int, int, int)      to authenticated;
grant  execute on function public.get_tiles(int, int, int, int)   to authenticated;
grant  execute on function public.leaderboard()                   to authenticated;
grant  execute on function public.set_name(text)                  to authenticated;
