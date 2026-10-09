// Panel uçtan uca testi: gerçek Chromium + sahte Supabase istemcisi (ağ yok).
// Çalıştırma: node tests/panel.e2e.mjs   (playwright yerelde ya da global kurulu olmalı)
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
const require = createRequire(import.meta.url);
const { chromium } = (() => { try { return require('playwright'); } catch { return require(execSync('npm root -g').toString().trim() + '/playwright'); } })();
import fs from 'node:fs';
import assert from 'node:assert/strict';

const html = fs.readFileSync(new URL('../public/index.html', import.meta.url), 'utf8')
  .replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/, '<script src="/fake-supabase.js"></script>');
assert.ok(html.includes('/fake-supabase.js'), 'CDN etiketi bulunamadı');

const fake = `(() => {
window.__calls = []; window.__loggedIn = false;
const B = (o) => Object.assign({ address:'Çankaya/Ankara', city:'Ankara', district:'Çankaya', sector:'kuaför', rating:4.7, review_count:50,
  website_status:'none', lead_score:80, status:'new', call_list:false, attempt_count:0, maps_url:'https://maps.google.com/?cid=1' }, o);
const biz = [
  B({ id:'m1', name:'Mavi Kuaför | Çankaya Saç Tasarım', phone_raw:'0532 111 22 33', phone_normalized:'+905321112233', lead_score:90 }),
  B({ id:'m2', name:'Yeşil Berber', phone_raw:'0533 222 33 44', phone_normalized:'+905332223344', lead_score:70, maps_url:'javascript:alert(1)' }),
  B({ id:'l1', name:'Sabit Diş', sector:'diş', phone_raw:'0312 123 45 67', phone_normalized:'+903121234567' }),
  B({ id:'f1', name:'Takip Eczane', sector:'eczane', status:'callback', lead_score:95, attempt_count:1, phone_raw:'0534 000 00 00', phone_normalized:'+905340000000' }),
];
const isMobile = b => /^\\+905\\d{9}$/.test(b.phone_normalized);
const lstOf = b => b.status==='callback'||b.status==='wa_sent' ? 'followup' : b.status==='new' ? ((!isMobile(b)||b.call_list)?'call':'whatsapp') : null;
const log = [];
const handlers = {
  next_business: a => { const x = biz.filter(b=>lstOf(b)===a.p_list && !(a.p_skip||[]).includes(b.id) && (!a.p_city||b.city===a.p_city) && (!a.p_sector||b.sector===a.p_sector))
      .sort((p,q)=>q.lead_score-p.lead_score)[0]; return x ? [x] : []; },
  release_business: () => null,
  move_to_call_list: a => { biz.find(b=>b.id===a.p_business_id).call_list = true; return null; },
  log_call: a => { const b = biz.find(x=>x.id===a.p_business_id);
      if (a.p_outcome==='callback' && !a.p_callback_at) return { error:{message:'Geri arama tarihi gerekli'} };
      b.status = a.p_outcome==='wa_sent' ? 'wa_sent' : a.p_outcome; b.attempt_count++; log.push({ ...a }); return null; },
  list_counts: a => ['whatsapp','call','followup'].map(l=>({ lst:l, n:biz.filter(b=>lstOf(b)===l && (!a.p_city||b.city===a.p_city)&&(!a.p_sector||b.sector===a.p_sector)).length })).filter(r=>r.n),
  filter_options: () => [...new Map(biz.filter(lstOf).map(b=>[b.city+b.sector,{city:b.city,sector:b.sector}])).values()],
  stats: () => [{ week_total:log.length+7, week_wa:3, today_total:log.length, today_wa:log.filter(l=>l.p_outcome==='wa_sent').length }],
  search_history: a => log.filter(l=>!a.p_term||JSON.stringify(l).includes(a.p_term)).map(l=>({ called_at:new Date().toISOString(), outcome:l.p_outcome, note:l.p_note, name:biz.find(b=>b.id===l.p_business_id).name, phone_raw:'x', city:'Ankara' })),
};
window.supabase = { createClient: () => ({
  auth: {
    getSession: async () => ({ data:{ session: window.__loggedIn ? {} : null } }),
    signInWithPassword: async ({email,password}) => password==='dogru' ? (window.__loggedIn=true, {error:null}) : {error:{message:'bad'}},
    signOut: async () => { window.__loggedIn=false; },
    onAuthStateChange: () => ({}),
  },
  rpc: async (name, args) => { window.__calls.push([name, args]); const r = handlers[name](args||{}); return r && r.error ? { data:null, error:r.error } : { data:r, error:null }; },
  from: (table) => { if (table === 'scan_history') { const q = { select:()=>q, order:()=>q, limit:()=>Promise.resolve({ data:[{ scanned_at:new Date().toISOString(), city:'Ankara', district:'Çankaya', sector:'kuaför', places_found:60, saved:31 }], error:null }) }; return q; }
    const q = { select:()=>q, eq:()=>q, order:()=>q, limit:()=>Promise.resolve({ data:[{called_at:new Date().toISOString(),outcome:'no_answer',note:'meşguldü'}], error:null }) }; return q; },
}) };
})();`;

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const [VW, VH] = (process.env.VIEW || '390x844').split('x').map(Number);
const ctx = await browser.newContext({ viewport: { width: VW, height: VH }, colorScheme: process.env.SCHEME || 'light' });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', e => errors.push(String(e)));
page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
await page.route('https://panel.test/fake-supabase.js', r => r.fulfill({ contentType: 'text/javascript', body: fake }));
await page.route('https://panel.test/', r => r.fulfill({ contentType: 'text/html', body: html }));
await page.addInitScript(() => { window.__opened = []; window.open = (u) => { window.__opened.push(u); return null; }; });

const txt = sel => page.locator(sel).innerText();
const calls = async () => page.evaluate(() => window.__calls);
const rpcCount = async n => (await calls()).filter(c => c[0] === n).length;
const SHOTS = process.env.SHOTS; if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });
const shot = async n => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${n}.png`, fullPage: false }); };
// Erişilebilirlik taraması (isteğe bağlı): AXE=/yol/axe.min.js node tests/panel.e2e.mjs
const axeAudit = async label => {
  if (!process.env.AXE) return;
  await page.waitForTimeout(450);   // renk geçişleri bitsin
  await page.addScriptTag({ content: fs.readFileSync(process.env.AXE, 'utf8') });
  const res = await page.evaluate(async () => (await window.axe.run(document, { runOnly: ['wcag2a', 'wcag2aa'] })).violations
    .map(v => ({ id: v.id, impact: v.impact, n: v.nodes.length, sample: v.nodes[0].target.join(' ') + ' :: ' + (v.nodes[0].any[0]?.message || v.nodes[0].failureSummary || '').slice(0, 140) })));
  console.log(`axe [${label}]:`, res.length ? JSON.stringify(res, null, 1) : 'ihlal yok');
  assert.deepEqual(res.filter(v => v.impact === 'serious' || v.impact === 'critical'), [], `erişilebilirlik ihlali (${label})`);
};
let step = 0; const ok = m => console.log(`ok ${++step} – ${m}`);

await page.goto('https://panel.test/'); await page.waitForTimeout(800); if (errors.length) console.log('SAYFA HATALARI:', errors);
await page.waitForSelector('#login:not(.hide)'); await shot('01-giris'); await axeAudit('giriş'); ok('giriş ekranı açıldı');
await page.fill('#email', 'a@b.com'); await page.fill('#password', 'yanlis'); await page.click('#loginForm button');
await page.waitForFunction(() => document.getElementById('loginErr').textContent.length > 0); ok('yanlış şifre hata gösterir');
await page.fill('#password', 'dogru'); await page.click('#loginForm button');
await page.waitForSelector('#biz:not(.hide)'); ok('giriş sonrası kart geldi');

await page.waitForTimeout(700); await shot('02-whatsapp'); await axeAudit('whatsapp kartı');
assert.equal(await txt('#bName'), 'Mavi Kuaför | Çankaya Saç Tasarım'); ok('en yüksek skorlu cep numarası WhatsApp listesinde ilk');
assert.match(await txt('#n_whatsapp'), /2/); assert.match(await txt('#n_call'), /1/); assert.match(await txt('#n_followup'), /1/); ok('sekme sayaçları 2/1/1');
assert.equal(await txt('#weekCount'), '7'); ok('haftalık sayaç sunucudan');
assert.equal(await page.locator('#waBtn').isDisabled(), false);
await page.click('#waBtn');
const url = (await page.evaluate(() => window.__opened))[0];
assert.ok(url.startsWith('https://wa.me/905321112233?text='), url);
const msg = decodeURIComponent(url.split('text=')[1]);
assert.ok(msg.startsWith('Merhaba, Mavi Kuaför için') && msg.includes('"dur" yazmanız'), msg); ok('WhatsApp linki: numara + kısaltılmış isim + "dur" cümlesi');
assert.equal(await page.locator('#toCallList').isVisible(), true);

// arama listesine al -> kart değişir, call sayısı artar
await page.click('#toCallList'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Yeşil Berber');
assert.equal(await rpcCount('move_to_call_list'), 1); assert.match(await txt('#n_call'), /2/); ok('arama listesine alma çalışıyor');
assert.equal(await page.locator('#bMaps').isVisible(), false); ok('javascript: harita bağlantısı gizlendi');

// WhatsApp gönderdim
await page.click('#btnWaSent'); await page.waitForFunction(() => document.getElementById('empty') && !document.getElementById('empty').classList.contains('hide'));
const lc = (await calls()).find(c => c[0] === 'log_call'); assert.equal(lc[1].p_outcome, 'wa_sent'); assert.equal(lc[1].p_business_id, 'm2');
assert.equal(await txt('#waToday'), '1'); ok('WhatsApp gönderildi kaydedildi, sayaç arttı, liste boşalınca boş durum');

// Arama sekmesi: sabit hat
await page.click('[data-tab="call"]'); await page.waitForFunction(() => document.getElementById('bName').textContent.startsWith('Mavi'));
assert.equal(await page.locator('#toCallList').isVisible(), false); ok('arama listesine alınan cep numarası Arama sekmesinde');
await page.click('#skip'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Sabit Diş');
assert.ok((await calls()).some(c => c[0] === 'release_business')); ok('atla sonraki kartı getirir ve kilidi bırakır');
assert.equal(await page.locator('#waBtn').isDisabled(), true); assert.equal(await page.locator('#btnWaSent').isVisible(), false);
ok('sabit hatta WhatsApp kapalı');

// geri arama: tarih ver
await page.click('[data-o="callback"]'); assert.equal(await page.locator('#cbBox').isVisible(), true);
await page.fill('#note', 'sabah arayın'); await page.click('#cbSave');
await page.waitForFunction(() => document.getElementById('empty') && !document.getElementById('empty').classList.contains('hide'));
const cb = (await calls()).filter(c => c[0] === 'log_call').at(-1)[1]; assert.equal(cb.p_outcome, 'callback'); assert.equal(cb.p_note, 'sabah arayın'); assert.ok(cb.p_callback_at); ok('geri arama tarih+not ile kaydedildi');

// Takip sekmesi: önceki arama geçmişi + reddet (onaylı)
await page.click('[data-tab="followup"]'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Takip Eczane');
assert.match(await txt('#bHistory'), /meşguldü/); ok('takipte önceki arama notu görünür');
await page.click('#closeMenu summary'); await page.click('[data-o="do_not_contact"]');
await page.waitForSelector('#dlg[open]'); assert.match(await txt('#dlgText'), /Takip Eczane/); await shot('04-onay');
await page.click('#dlgOk'); await page.waitForFunction(() => document.getElementById('bName').textContent !== 'Takip Eczane');
assert.equal((await calls()).filter(c => c[0] === 'log_call').at(-1)[1].p_outcome, 'do_not_contact'); ok('"dur dedi" özel onay penceresiyle kaydedildi');


// vazgeçilirse kayıt yapılmaz
{ const before = await rpcCount('log_call');
  await page.click('#closeMenu summary'); await page.click('[data-o="rejected"]'); await page.waitForSelector('#dlg[open]');
  await page.click('#dlg button[value="cancel"]'); await page.waitForFunction(() => !document.getElementById('dlg').open);
  assert.equal(await rpcCount('log_call'), before); ok('onayda "Vazgeç" kaydı engeller'); }

// ---- Tarama sekmesi (Edge Function sahte) ----
const scanCalls = [];
let scanMode = 'ok';
await page.route('**/functions/v1/scan', async route => {
  const req = route.request();
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' };
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
  const b = JSON.parse(req.postData());
  scanCalls.push({ ...b, auth: req.headers()['authorization'], apikey: req.headers()['apikey'] });
  const J = (status, body) => route.fulfill({ status, headers: cors, contentType: 'application/json', body: JSON.stringify(body) });
  if (scanMode === 'missing') return route.fulfill({ status: 404, headers: cors, body: 'not found' });
  if (b.action === 'plan') {
    if (b.city.toLowerCase() === 'mars') return J(400, { error: 'bad_city', message: 'Şehir tanınmadı. 81 ilden birini yazın (örn. Ankara).' });
    return J(200, { city: 'Ankara', usage: { used: 3, limit: 60 }, est_calls: 6, fits_today: 1, units: [
      { district: 'Çankaya', sector: 'kuaför', status: 'recent' }, { district: 'Keçiören', sector: 'kuaför', status: 'scan' }, { district: 'Yenimahalle', sector: 'kuaför', status: 'scan' }, { district: 'Mamak', sector: 'kuaför', status: 'closed' }] });
  }
  if (scanMode === 'slow') await new Promise(r => setTimeout(r, 400));
  if (scanMode === 'fail' && b.district === 'Yenimahalle') return J(429, { error: 'daily_limit', message: 'Günlük Google çağrı sınırına ulaşıldı (60). Yarın devam edin.' });
  return J(200, { city: b.city, district: b.district, sector: b.sector, found: 60, matched: 31, saved: 31, calls: 3, reasons: {}, warning: null, used: 6, limit: 60 });
});

await page.click('[data-tab="scan"]'); await page.waitForSelector('#scanView:not(.hide)');
assert.equal(await page.locator('#biz').isVisible(), false); assert.equal(await page.locator('#scHist li').count(), 1); ok('Tara sekmesi açıldı, son taramalar listelendi');

await shot('05-tara'); await axeAudit('tara');
// sektör önerisi çipi alanı doldurur
await page.click('#sectorChips .chip:text-is("kuaför")'); assert.equal(await page.inputValue('#scSectors'), 'kuaför'); ok('sektör çipi alanı doldurur');
await page.fill('#scCity', 'mars'); await page.fill('#scSectors', 'kuaför'); await page.click('#scPlan');
await page.waitForFunction(() => document.getElementById('toast').textContent.includes('Şehir tanınmadı')); assert.equal(await page.locator('#scRun').isVisible(), false); ok('geçersiz şehir anlaşılır hata verir');

await page.fill('#scCity', 'ankara'); await page.fill('#scDistricts', 'çankaya, keçiören, yenimahalle, mamak'); await page.click('#scPlan');
await page.waitForSelector('#scRun:not(.hide)');
const planTxt = await txt('#scPlanBox'); assert.match(planTxt, /Keçiören · kuaför\s+taranacak/); assert.match(planTxt, /Mamak · kuaför\s+kapalı bölge/); assert.match(await txt('#scTiles'), /3\/60/); assert.match(await txt('#scTiles'), /2\s+taranacak bölge/); await shot('06-plan');
assert.match(await txt('#scRun'), /2 bölge/); assert.match(planTxt, /bugün en çok ~1 bölge taranabilir/); ok('plan günlük sınırı aşıyorsa uyarır');
assert.equal(scanCalls[0].auth.startsWith('Bearer '), true); assert.ok(scanCalls[0].apikey.startsWith('sb_publishable_')); ok('plan: taranacak/atlanacak ayrımı, kullanım ve oturum bilgisi gönderilir');

await page.click('#scRun'); await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
await shot('07-tarama-bitti');
const runs = scanCalls.filter(c => c.action === 'run'); assert.deepEqual(runs.map(r => r.district), ['Keçiören', 'Yenimahalle']); assert.equal(runs[0].city, 'Ankara'); assert.equal(runs[0].force, false);
assert.match(await txt('#scLog'), /62 yeni kaydedildi, 6 Google çağrısı/); assert.equal(await page.locator('#scProg').isVisible(), false); assert.equal(await page.locator('#scCity').isDisabled(), false); ok('tarama sırayla çalışır, özet yazılır, form tekrar açılır');

// zorla tara: recent da dahil
await page.check('#scForce'); await page.click('#scPlan'); await page.waitForSelector('#scRun:not(.hide)');
assert.match(await txt('#scRun'), /3 bölge/); scanCalls.length = 0; await page.click('#scRun'); await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
assert.equal(scanCalls.filter(c => c.action === 'run').every(c => c.force === true), true); ok('"yeniden tara" 90 gün kuralını aşar ve force gönderir');
await page.uncheck('#scForce');

// hata: ikinci bölgede günlük limit -> durur, mesaj gösterilir
scanMode = 'fail'; await page.click('#scPlan'); await page.waitForSelector('#scRun:not(.hide)'); await page.click('#scRun');
await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
const logTxt = await txt('#scLog'); assert.match(logTxt, /Günlük Google çağrı sınırına ulaşıldı/); assert.match(logTxt, /Hata nedeniyle durdu/); assert.match(logTxt, /31 yeni kaydedildi/); ok('hata gelince durur, o ana kadarki sonuç korunur');

// durdur
scanMode = 'slow'; await page.click('#scPlan'); await page.waitForSelector('#scRun:not(.hide)'); await page.click('#scRun');
await page.waitForSelector('#scProg:not(.hide)'); await page.click('#scStop');
await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
assert.match(await txt('#scLog'), /Durduruldu/); ok('durdur düğmesi sıradaki bölgeleri çalıştırmaz');

// servis kurulu değil
scanMode = 'missing'; await page.click('#scPlan');
await page.waitForFunction(() => document.getElementById('toast').textContent.includes('kurulu değil')); ok('servis yoksa kurulum yönlendirmesi gösterilir');
scanMode = 'ok';
await page.click('[data-tab="whatsapp"]'); await page.waitForSelector('#callView:not(.hide)'); ok('Tara sekmesinden listelere dönülür');

// Geçmiş
await page.click('[data-tab="hist"]'); await page.waitForSelector('#histList li');
assert.ok((await page.locator('#histList li').count()) === 3); await shot('08-gecmis'); await axeAudit('geçmiş'); ok('geçmiş tablosu dolu');
await page.fill('#histSearch', 'meşgul'); await page.waitForTimeout(500);
assert.ok((await calls()).some(c => c[0] === 'search_history' && c[1].p_term === 'meşgul')); ok('geçmişte arama sunucuya gider');

// çıkış
await page.click('#logout'); await page.waitForSelector('#login:not(.hide)'); ok('çıkış giriş ekranına döner');

// mobil taşma
await page.click('#email');
const sw = await page.evaluate(() => document.documentElement.scrollWidth); assert.ok(sw <= VW, 'yatay taşma: ' + sw); ok(`${VW}px ekranda yatay taşma yok`);

const real = errors.filter(e => !/Failed to load resource: the server responded with a status of (400|404|429)/.test(e));  // sahte servis hataları beklenir
assert.deepEqual(real, [], 'konsol hataları: ' + real.join(' | ')); ok('konsol hatası yok');
await browser.close();
console.log('\nTÜM PANEL TESTLERİ GEÇTİ');
