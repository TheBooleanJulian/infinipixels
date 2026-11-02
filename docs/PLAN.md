# Infinipixels: next-steps plan

Goal: win the audience vote. Everything is ranked by **demo impact ÷ build time**.
Rules that hold throughout: no new frontend dependencies, sounds are synthesised (no audio files),
animations respect `prefers-reduced-motion`, and all game logic stays server-authoritative in Postgres.

## Tier 1: build now (about 30–45 min total, biggest first-impression gain)

| # | Item | Why it wins votes | Effort |
|---|---|---|---|
| 1 | **Server-side broadcast** (`realtime.send` inside `paint_pixel`) | Removes the "fake pixel" hole, so the database becomes the only source of pixels. It's a strong Supabase talking point. | 10 min |
| 2 | **Remote paint pings**: a glowing ripple wherever anyone paints | When zoomed out, other people's single pixels are invisible. Ripples make the canvas feel alive on the projector. | 10 min |
| 3 | **Paint pop + sound**: burst ring on your pixel and a synthesised blip **pitched by colour** (the palette becomes a musical scale) | Instant tactile reward; people will "play" the palette | 10 min |
| 4 | **Cooldown ring on the selected swatch** (conic-gradient) plus a "ready" tick sound | Makes the 2 s rhythm feel like a game loop | 5 min |
| 5 | **Mute toggle** in the header, starting muted until the first paint and remembered per browser | Browsers block autoplay. Also polite in a room full of laptops. | 5 min |

## Tier 2: gamification (each 20–40 min)

1. **Team Cyan vs Team Magenta** (on-brand). Each player joins a team on first paint.
   A live tug-of-war bar in the header shows the share of pixels each team currently owns.
   - Postgres: a second `bytea` per tile stores the owner team, and `team_score` counters are adjusted +1/−1 inside `paint_pixel`.
     That keeps the score O(1) per paint, with no scanning of 1M pixels.
   - Realtime: score deltas ride on the same server broadcast.
2. **Achievements** granted in SQL inside `paint_pixel`, with a confetti burst and chime on unlock:
   - First Pixel, then 10, 100 and 500 pixels.
   - Explorer: painted in 10 different tiles.
   - Collaborator: painted next to someone else's pixel within 10 s.
   - Defender: restored a pixel to its previous colour.
   - Night Owl.
3. **Golden pixel bounty.** Every few minutes pg_cron places a shimmering target somewhere on the canvas.
   The first painter to hit it gets +25 points and a broadcast shout-out ("🦊 Neon482 grabbed the golden pixel!").
4. **Combo streak.** Paint within 0.5 s of the cooldown ending to grow a ×2, ×3 combo shown on the palette.
   It's cosmetic only (no cooldown change), so it can't be abused.
5. **Personal card** in the drawer: your pixels, rank, team, and badges.

## Tier 3: animations and sound polish

- **Fly-in intro:** start at fit-to-screen, then ease-zoom to the start view (536,506 @ 2.4×) once the tiles land.
- **Tiles fade in** as each batch loads.
- **Live counter roll** when "N painting now" changes, and a **rank flash** when you move up the leaderboard.
- **Ambient soundscape:** remote paints play very quiet blips pitched by colour, capped at about 8 per second.
  A busy canvas literally sounds busy.
- Achievement chime (major arpeggio), golden pixel shimmer sound, and a soft error thud on a rejected paint.

## Using Supabase's strengths more

| Feature | Use in Infinipixels | Value |
|---|---|---|
| **Realtime: Broadcast from Database** (`realtime.send`) | Emit `px`, `score` and `achievement` events from inside SQL functions | Server-authoritative, fixes spoofing, and removes the client broadcast step |
| **Realtime Authorization** (RLS on `realtime.messages`) | Make the `canvas` channel private, readable by signed-in users and writable only for cursors | Locks down who can broadcast what |
| **Postgres functions + triggers** | Cooldown, teams, achievements and bounties all live in SQL | One source of truth, zero extra servers |
| **Append-only `pixel_events` log** | Hover a pixel to see "painted by 🦊 Neon482 12 s ago", plus a **timelapse replay** of the whole event | The timelapse is the closing-slide demo |
| **pg_cron** | Golden pixel spawns, hourly snapshots, daily leaderboard reset, pruning old events | Scheduled game events with no extra infrastructure |
| **Edge Functions** | Render the canvas to PNG for a **dynamic og:image** (shares show the live canvas) and a fast first paint (one ~100 KB PNG instead of 1.3 MB of base64) | Better sharing and load time |
| **Storage** | Hourly PNG snapshots form the timelapse frames and a "canvas history" gallery | Cheap, CDN-served |
| **Anonymous → permanent auth** (`linkIdentity` with GitHub) | "Save your stats" button, so pixels and badges follow you across devices | Shows off Auth's upgrade path |
| **Edge Function + Claude** (on-theme for Supabase × Claude) | Every few minutes Claude looks at the latest snapshot and posts a one-line commentary ticker ("Team Magenta is building a heart near the banner"). It also flags offensive regions for review. | AI moderation and commentary: a memorable hackathon hook |

## Recommended build order for the remaining window

1. Tier 1, items 1–5 (server broadcast, pings, pop + sound, cooldown ring, mute), then deploy.
2. Team Cyan vs Magenta, then deploy. This is the strongest "vote for us" hook.
3. If time allows: the `pixel_events` log plus the hover "painted by" tooltip.
4. Post-hackathon: timelapse, pg_cron golden pixel, Claude commentator, dynamic og:image.

Database changes for 1–3 are additive (new columns, tables and functions). No existing data is dropped.
