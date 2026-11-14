// Edge Function testleri (node:test). Çalıştırma: node --test tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import * as fn from '../supabase/functions/scan/index.ts';

const cases = JSON.parse(fs.readFileSync(new URL('./scan_cases.json', import.meta.url), 'utf8'));
const basePlace = { id: 'pid1', displayName: { text: 'Güzel Kuaför' }, formattedAddress: 'Kızılay Mah, Çankaya/Ankara, Türkiye',
  nationalPhoneNumber: '0532 111 22 33', rating: 4.7, userRatingCount: 80, googleMapsUri: 'https://maps.google.com/?cid=1', businessStatus: 'OPERATIONAL' };

test('ortak test verisi: telefon', () => { for (const [raw, exp] of cases.phones) assert.equal(fn.normalizePhone(raw), exp, String(raw)); });
test('ortak test verisi: web sitesi', () => { for (const [u, exp] of cases.websites) assert.equal(fn.classifyWebsite(u), exp, String(u)); });
test('ortak test verisi: skor', () => { for (const [r, n, m, exp] of cases.scores) assert.equal(fn.leadScore(r, n, m), exp, `${r} ${n} ${m}`); });
test('ortak test verisi: işletme filtresi', () => {
  for (const k of cases.places) {
    const { row, why } = fn.placeToRow({ ...basePlace, ...k.place }, k.city, k.district, k.sector, k.filters);
    if (k.ok) { assert.ok(row && !why, `${k.name}: ${why}`); } else { assert.equal(row, undefined, k.name); assert.equal(why, k.why, k.name); }
    if (row && k.phone) assert.equal(row.phone_normalized, k.phone);
    if (row && k.website) assert.equal(row.website_status, k.website);
  }
});

test('Türkçe yardımcılar', () => {
  assert.equal(fn.trLower('ÇANKAYA İSTANBUL ISPARTA'), 'çankaya istanbul ısparta');
  assert.equal(fn.trTitle('çankaya'), 'Çankaya');
  assert.equal(fn.trTitle('ISPARTA'), 'Isparta');
  assert.equal(fn.trTitle('iğdır merkez'), 'İğdır Merkez');
  assert.equal(fn.cleanCity('ankara'), 'Ankara');
  assert.equal(fn.cleanCity('İZMİR'), 'İzmir');
  assert.equal(fn.cleanCity('ısparta'), 'Isparta');
  assert.throws(() => fn.cleanCity('Atlantis'), /Şehir tanınmadı/);
  assert.equal(fn.PROVINCES.length, 81);
  assert.equal(new Set(fn.PROVINCES).size, 81);
});

test('girdi doğrulama', () => {
  assert.deepEqual(fn.cleanList('çankaya, Keçiören ,çankaya', 5, 'district', fn.trTitle), ['Çankaya', 'Keçiören']);
  assert.deepEqual(fn.cleanList(['Kuaför', 'Diş Hekimi'], 5, 'sector', fn.trLower), ['kuaför', 'diş hekimi']);
  assert.throws(() => fn.cleanList('a<script>', 5, 'sector', fn.trLower), /geçersiz/);
  assert.throws(() => fn.cleanList('x1,x2,x3', 2, 'sector', fn.trLower), /En fazla 2/);
  assert.throws(() => fn.cleanName('a'.repeat(51), 'sector'));
});

test('filtre doğrulama', () => {
  assert.deepEqual(fn.cleanFilters(undefined), {});
  assert.deepEqual(fn.cleanFilters({ min_rating: '4.2', min_reviews: '', max_reviews: 300, open_days: [6, 1, 6] }), { min_rating: 4.2, max_reviews: 300, open_days: [1, 6] });
  assert.throws(() => fn.cleanFilters({ min_rating: 7 }), /geçersiz/);
  assert.throws(() => fn.cleanFilters({ min_reviews: 50, max_reviews: 10 }), /büyük olamaz/);
  assert.throws(() => fn.cleanFilters({ open_days: [9] }), /geçersiz/);
  assert.throws(() => fn.cleanFilters({ open_days: 'pazar' }), /geçersiz/);
});

test('İstanbul gün başlangıcı', () => {
  assert.equal(fn.istanbulDayStart(Date.parse('2026-10-09T22:30:00Z')), '2026-10-09T21:00:00.000Z'); // 10 Ekim 01:30 TR
  assert.equal(fn.istanbulDayStart(Date.parse('2026-10-09T10:00:00Z')), '2026-10-08T21:00:00.000Z'); // 9 Ekim 13:00 TR
});

// ---------------- işleyici: sahte Supabase + Google
const WS = '99999999-0000-0000-0000-000000000001';
function world({ closed = [], history = [], usage = 0, user = true, places, googleStatus = 200, canScan = true, quota = null, monthUsed = 0, noRole = false } = {}) {
  const log = { google: 0, ingest: [], history: [], authCalls: 0, wsFilters: [] };
  const pages = places ?? [{ places: [{ ...basePlace, id: 'a' }, { ...basePlace, id: 'b', rating: 3 }] }];
  const f = async (url, init = {}) => {
    const u = String(url); const body = init.body ? JSON.parse(init.body) : null;
    const J = (o, status = 200) => new Response(JSON.stringify(o), { status });
    if (u.includes('/auth/v1/user')) { log.authCalls++; return user ? J({ id: 'u1' }) : J({}, 401); }
    if (u.includes('places.googleapis.com')) { log.google++; return googleStatus === 200 ? J(pages[Math.min(log.google - 1, pages.length - 1)]) : new Response('denied AIzaSyABCDEFG', { status: googleStatus }); }
    if (u.includes('/rest/v1/closed_regions') || (u.includes('/rest/v1/scan_history') && !init.method)) log.wsFilters.push(u.includes('workspace_id=eq.' + WS));
    if (u.includes('/rest/v1/closed_regions')) return J(closed);
    if (u.includes('/rest/v1/scan_history') && !init.method) return J(u.includes('select=api_calls') ? [{ api_calls: usage }] : history);
    if (u.includes('/rpc/scan_context')) { log.perm = body; return J(noRole ? null : { workspace_id: WS, can_scan: canScan, lead_quota: quota, leads_this_month: monthUsed }); }
    if (u.includes('/rpc/ingest_businesses')) { log.ingest.push(body.p_rows); log.ingestWs = body.p_workspace; return J(body.p_rows.length); }
    if (u.endsWith('/rest/v1/scan_history') && init.method === 'POST') { log.history.push(body); return new Response(null, { status: 201 }); }
    throw new Error('beklenmeyen çağrı ' + u);
  };
  return { f, log };
}
const ENV = { SUPABASE_URL: 'https://x.supabase.co', SERVICE_KEY: 'sb_secret_x', GOOGLE_API_KEY: 'g', MAX_CALLS_PER_DAY: 60, ALLOWED_ORIGINS: ['https://panel.vitrinweb.com.tr'] };
const call = (w, body, { env = ENV, headers = {}, method = 'POST' } = {}) => fn.handle(
  new Request('https://x/functions/v1/scan', { method, headers: { authorization: 'Bearer jwt', origin: 'https://panel.vitrinweb.com.tr', 'content-type': 'application/json', ...headers }, body: method === 'POST' ? JSON.stringify(body) : undefined }),
  env, w.f, Date.parse('2026-10-09T12:00:00Z'));

test('CORS: izinli adrese başlık, izinsize yok; OPTIONS 204', async () => {
  const w = world();
  let r = await call(w, {}, { method: 'OPTIONS' });
  assert.equal(r.status, 204); assert.equal(r.headers.get('access-control-allow-origin'), 'https://panel.vitrinweb.com.tr');
  r = await call(w, { action: 'x' }, { headers: { origin: 'https://evil.example' } });
  assert.equal(r.headers.get('access-control-allow-origin'), null);
});

test('giriş yoksa ya da oturum geçersizse 401, Google/DB çağrılmaz', async () => {
  const w = world({ user: false });
  let r = await call(w, { action: 'plan', city: 'Ankara', sectors: 'kuaför' }, { headers: { authorization: '' } });
  assert.equal(r.status, 401);
  r = await call(w, { action: 'plan', city: 'Ankara', sectors: 'kuaför' });
  assert.equal(r.status, 401); assert.equal(w.log.google, 0);
});

test('tarama izni olmayan rol (örn. tasarımcı) 403 alır, Google çağrılmaz', async () => {
  const w = world({ canScan: false });
  const r = await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' });
  assert.equal(r.status, 403); assert.equal((await r.json()).error, 'forbidden');
  assert.deepEqual(w.log.perm, { p_user: 'u1' }); assert.equal(w.log.google, 0); assert.equal(w.log.ingest.length, 0);
  assert.equal((await call(w, { action: 'plan', city: 'Ankara', sectors: 'kuaför' })).status, 403);
  assert.equal((await call(world({ noRole: true }), { action: 'plan', city: 'Ankara', sectors: 'kuaför' })).status, 403);
});

test('GET reddedilir', async () => { assert.equal((await call(world(), null, { method: 'GET' })).status, 405); });

test('plan: kapalı, yakın zamanda taranmış ve taranacak birimleri ayırır', async () => {
  const recent = new Date(Date.parse('2026-10-09T12:00:00Z') - 10 * 86400_000).toISOString();
  const w = world({ closed: [{ city: 'Bursa', district: null }, { city: 'Ankara', district: 'Keçiören' }], history: [{ city: 'Ankara', district: 'Çankaya', sector: 'kuaför', scanned_at: recent }], usage: 7 });
  let j = await (await call(w, { action: 'plan', city: 'ankara', districts: 'çankaya,keçiören,yenimahalle', sectors: 'Kuaför' })).json();
  assert.deepEqual(j.units.map((u) => [u.district, u.sector, u.status]), [['Çankaya', 'kuaför', 'recent'], ['Keçiören', 'kuaför', 'closed'], ['Yenimahalle', 'kuaför', 'scan']]);
  assert.equal(j.city, 'Ankara'); assert.equal(j.est_calls, 3); assert.deepEqual(j.usage, { used: 7, limit: 60 }); assert.equal(j.fits_today, 17);
  assert.deepEqual(j.quota, { limit: null, used: 0, left: null });
  assert.ok(w.log.wsFilters.length && w.log.wsFilters.every(Boolean), 'geçmiş/kapalı bölge sorguları alana göre süzülmeli');
  j = await (await call(w, { action: 'plan', city: 'Bursa', districts: 'Nilüfer', sectors: 'kuaför' })).json();
  assert.equal(j.units[0].status, 'closed');
  assert.equal((await call(w, { action: 'plan', city: 'Ankara', sectors: '' })).status, 400);
  assert.equal((await call(w, { action: 'plan', city: 'Mars', sectors: 'kuaför' })).status, 400);
});

test('run: filtre yoksa hepsini, filtreyle uyanları kaydeder; alana yazar, anahtarı sızdırmaz', async () => {
  let w = world();
  let r = await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' });
  let j = await r.json();
  assert.equal(r.status, 200);
  assert.deepEqual([j.found, j.matched, j.saved, j.calls], [2, 2, 2, 1]);
  assert.equal(w.log.ingestWs, WS);
  assert.deepEqual(w.log.history[0], { workspace_id: WS, city: 'Ankara', district: 'Çankaya', sector: 'kuaför', places_found: 2, saved: 2, api_calls: 1 });
  assert.ok(!JSON.stringify(j).includes('sb_secret'));
  w = world();
  j = await (await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför', filters: { min_rating: 4 } })).json();
  assert.deepEqual([j.found, j.matched, j.saved], [2, 1, 1]);
  assert.deepEqual(j.reasons, { 'puan düşük': 1 });
  assert.equal(w.log.ingest[0][0].place_id, 'a');
  assert.equal((await call(world(), { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför', filters: { min_rating: 9 } })).status, 400);
});

test('run: aylık işletme kotası', async () => {
  let w = world({ quota: 500, monthUsed: 500 });
  let r = await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' });
  assert.equal(r.status, 429); assert.equal((await r.json()).error, 'quota'); assert.equal(w.log.google, 0);
  // 1 hak kaldıysa en yüksek skorlu 1 işletme kaydedilir, kalan uyarıda yazar
  w = world({ quota: 500, monthUsed: 499, places: [{ places: [{ ...basePlace, id: 'low', rating: 3.6, nationalPhoneNumber: '0532 000 00 01' }, { ...basePlace, id: 'high', rating: 4.9 }] }] });
  const j = await (await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' })).json();
  assert.equal(j.saved, 1); assert.equal(w.log.ingest[0].length, 1); assert.equal(w.log.ingest[0][0].place_id, 'high');
  assert.match(j.warning, /kota nedeniyle 1 işletme/); assert.deepEqual(j.quota, { limit: 500, used: 500, left: 0 });
  const p = await (await call(world({ quota: 500, monthUsed: 120 }), { action: 'plan', city: 'Ankara', sectors: 'kuaför' })).json();
  assert.deepEqual(p.quota, { limit: 500, used: 120, left: 380 });
});

test('run: kapalı/yakın tarama atlanır ve Google çağrılmaz; force ile taranır', async () => {
  const recent = new Date(Date.parse('2026-10-09T12:00:00Z') - 5 * 86400_000).toISOString();
  const w = world({ closed: [{ city: 'Bursa', district: null }], history: [{ city: 'Ankara', district: 'Çankaya', sector: 'kuaför', scanned_at: recent }] });
  assert.equal((await (await call(w, { action: 'run', city: 'Bursa', district: 'Nilüfer', sector: 'kuaför' })).json()).skipped, 'closed');
  assert.equal((await (await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' })).json()).skipped, 'recent');
  assert.equal(w.log.google, 0);
  const j = await (await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför', force: true })).json();
  assert.equal(j.saved, 2); assert.equal(w.log.google, 1);
});

test('run: günlük çağrı sınırı', async () => {
  let w = world({ usage: 60 });
  let r = await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' });
  assert.equal(r.status, 429); assert.equal((await r.json()).error, 'daily_limit'); assert.equal(w.log.google, 0);
  // 2 çağrı hakkı kaldıysa en fazla 2 sayfa gezer
  const full = { places: Array.from({ length: 20 }, (_, i) => ({ ...basePlace, id: 'p' + i, nationalPhoneNumber: `053${i % 10} 111 22 3${i % 10}` })), nextPageToken: 't' };
  w = world({ usage: 58, places: [full] });
  const j = await (await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' })).json();
  assert.equal(j.calls, 2); assert.equal(w.log.google, 2); assert.equal(j.used, 60);
});

test('run: Google reddederse anlaşılır hata, geçmişe yazılmaz, anahtar maskelenir', async () => {
  const w = world({ googleStatus: 403 });
  const r = await call(w, { action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' });
  const j = await r.json();
  assert.equal(r.status, 502); assert.match(j.message, /Places API/); assert.ok(!j.message.includes('AIzaSy'));
  assert.equal(w.log.history.length, 0);
});

test('run: Google geçici hata (503) verirse bir kez yeniden dener', async () => {
  const w = world(); let n = 0; const inner = w.f;
  const f = async (u, i) => (String(u).includes('places.googleapis') && ++n === 1) ? new Response('busy', { status: 503 }) : inner(u, i);
  const r = await fn.handle(new Request('https://x/f', { method: 'POST', headers: { authorization: 'Bearer j', origin: 'https://panel.vitrinweb.com.tr' }, body: JSON.stringify({ action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' }) }),
    { ...ENV, SLEEP: async () => {} }, f, Date.parse('2026-10-09T12:00:00Z'));
  assert.equal(r.status, 200); assert.equal((await r.json()).saved, 2); assert.equal(n, 2);
});

test('run: Google sürekli 503 verirse anlaşılır hata, geçmişe yazılmaz', async () => {
  const w = world({ googleStatus: 503 });
  const r = await fn.handle(new Request('https://x/f', { method: 'POST', headers: { authorization: 'Bearer j' }, body: JSON.stringify({ action: 'run', city: 'Ankara', district: 'Çankaya', sector: 'kuaför' }) }),
    { ...ENV, SLEEP: async () => {} }, w.f, Date.parse('2026-10-09T12:00:00Z'));
  assert.equal(r.status, 502); assert.match((await r.json()).message, /geçici hata/); assert.equal(w.log.history.length, 0); assert.equal(w.log.google, 2);
});

test('run: Google anahtarı tanımsızsa açık hata', async () => {
  const r = await call(world(), { action: 'run', city: 'Ankara', district: '', sector: 'kuaför' }, { env: { ...ENV, GOOGLE_API_KEY: '' } });
  assert.equal(r.status, 500); assert.equal((await r.json()).error, 'not_configured');
});

test('run: geçersiz sektör/ilçe reddedilir', async () => {
  const w = world();
  assert.equal((await call(w, { action: 'run', city: 'Ankara', district: '<x>', sector: 'kuaför' })).status, 400);
  assert.equal((await call(w, { action: 'run', city: 'Ankara', district: '', sector: "'; drop table" })).status, 400);
  assert.equal(w.log.google, 0);
});

test('loadEnv', () => {
  const e = fn.loadEnv((k) => ({ SUPABASE_URL: 'https://x.supabase.co/', SUPABASE_SERVICE_ROLE_KEY: 'a', ALLOWED_ORIGINS: 'https://b.com, https://c.com', MAX_CALLS_PER_DAY: '5' })[k]);
  assert.equal(e.SUPABASE_URL, 'https://x.supabase.co'); assert.equal(e.MAX_CALLS_PER_DAY, 5);
  assert.deepEqual(e.ALLOWED_ORIGINS, ['https://panel.vitrinweb.com.tr', 'https://b.com', 'https://c.com']);
  assert.equal(fn.loadEnv(() => undefined).MAX_CALLS_PER_DAY, 60);
});
