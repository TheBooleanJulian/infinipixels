# Infinipixels

A live, collaborative 1000×1000 pixel canvas (r/place style). Live at https://infinipixels.thebooleanjulian.dev

- Frontend: one static page (`public/index.html`), vanilla JS, supabase-js from a pinned CDN. No build step.
- Data: Supabase (tiles as `bytea`, painting via the `paint_pixel` RPC with a 3 s cooldown).
- Realtime: one channel `canvas`. Broadcast carries pixels and cursors, and Presence gives the live count.
- Hosting: Cloudflare Workers static assets (`wrangler.jsonc`).

## Setup

1. In Supabase, run `supabase/migration.sql`, then `supabase/seed.sql` in the SQL editor.
2. Turn on Authentication > Providers > **Allow anonymous sign-ins**.
3. Put the project URL and anon key in `public/config.js`.
4. Deploy with `npx wrangler deploy`.

To regenerate the seed art and `og.png`, run `python tools/gen_seed.py`.

## Known limits (demo)

- Broadcasts come from clients, so a modified client can show fake pixels to others until they refocus or reconnect.
  The database stays authoritative.
- The cooldown is per anonymous user. Clearing site data gets you a fresh identity.
