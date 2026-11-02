// Infinipixels Worker: static assets, plus
//   GET /og.png   live share image of the canvas (cached 60s; falls back to the static image)

const N = 1000, T = 100;
// r/place 2017 palette; must match public/index.html. Index 16 is the brand background.
const PAL = ["FFFFFF", "E4E4E4", "888888", "222222", "FFA7D1", "E50000", "E59500", "A06A42",
             "E5D900", "94E044", "02BE01", "00D3DD", "0083C7", "0000EA", "CF6EE4", "820080", "05060D"];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/og.png") return ogImage(request, env, ctx);
    return env.ASSETS.fetch(request);
  },
};

// ---------------------------------------------------------------- Supabase (service role, server-side only)
async function rpc(env, name, body = {}) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${name}: ${res.status} ${await res.text()}`);
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

async function loadCanvas(env) {
  const rows = await rpc(env, "get_tiles", { tx_min: 0, ty_min: 0, tx_max: 9, ty_max: 9 });
  const pix = new Uint8Array(N * N);
  for (const r of rows) {
    const bin = atob(r.b64);
    for (let i = 0; i < T * T; i++) {
      pix[(r.ty * T + Math.floor(i / T)) * N + r.tx * T + (i % T)] = bin.charCodeAt(i) & 15;
    }
  }
  return pix;
}

// ---------------------------------------------------------------- PNG (indexed colour, stdlib only)
const CRC = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const out = new Uint8Array(12 + data.length), dv = new DataView(out.buffer);
  dv.setUint32(0, data.length);
  out.set(new TextEncoder().encode(type), 4);
  out.set(data, 8);
  dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}
async function encodePng(w, h, indices) {
  const raw = new Uint8Array((w + 1) * h);
  for (let y = 0; y < h; y++) raw.set(indices.subarray(y * w, (y + 1) * w), y * (w + 1) + 1);
  // CompressionStream "deflate" produces the zlib format PNG expects
  const idat = new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream("deflate"))).arrayBuffer());
  const ihdr = new Uint8Array(13), dv = new DataView(ihdr.buffer);
  dv.setUint32(0, w); dv.setUint32(4, h); ihdr.set([8, 3, 0, 0, 0], 8);
  const plte = new Uint8Array(PAL.length * 3);
  PAL.forEach((hex, i) => plte.set([0, 2, 4].map(o => parseInt(hex.slice(o, o + 2), 16)), i * 3));
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("PLTE", plte), chunk("IDAT", idat), chunk("IEND", new Uint8Array())];
  const png = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { png.set(p, o); o += p.length; }
  return png;
}

// ---------------------------------------------------------------- /og.png
async function ogImage(request, env, ctx) {
  const cache = caches.default, key = new Request(new URL("/og.png", request.url).toString());
  const hit = await cache.match(key).catch(() => null);  // the cache is best-effort
  if (hit) return hit;
  try {
    const pix = await loadCanvas(env);
    // 1200x630: the canvas' centre 1000x630 band on the brand background
    const W = 1200, H = 630, top = (N - H) / 2, side = (W - N) / 2;
    const img = new Uint8Array(W * H).fill(16);
    for (let y = 0; y < H; y++) img.set(pix.subarray((top + y) * N, (top + y + 1) * N), y * W + side);
    const res = new Response(await encodePng(W, H, img), {
      headers: { "Content-Type": "image/png", "Cache-Control": "public, max-age=60" },
    });
    ctx.waitUntil(cache.put(key, res.clone()).catch(() => {}));
    return res;
  } catch (e) {
    console.error("og.png", e);
    return env.ASSETS.fetch(new Request(new URL("/og-static.png", request.url)));
  }
}
