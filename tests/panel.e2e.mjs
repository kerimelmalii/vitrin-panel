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
  from: () => { const q = { select:()=>q, eq:()=>q, order:()=>q, limit:()=>Promise.resolve({ data:[{called_at:new Date().toISOString(),outcome:'no_answer',note:'meşguldü'}], error:null }) }; return q; },
}) };
})();`;

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', e => errors.push(String(e)));
page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
await page.route('https://panel.test/fake-supabase.js', r => r.fulfill({ contentType: 'text/javascript', body: fake }));
await page.route('https://panel.test/', r => r.fulfill({ contentType: 'text/html', body: html }));
await page.addInitScript(() => { window.__opened = []; window.open = (u) => { window.__opened.push(u); return null; }; window.confirm = () => true; });

const txt = sel => page.locator(sel).innerText();
const calls = async () => page.evaluate(() => window.__calls);
const rpcCount = async n => (await calls()).filter(c => c[0] === n).length;
let step = 0; const ok = m => console.log(`ok ${++step} – ${m}`);

await page.goto('https://panel.test/'); await page.waitForTimeout(800); if (errors.length) console.log('SAYFA HATALARI:', errors);
await page.waitForSelector('#login:not(.hide)'); ok('giriş ekranı açıldı');
await page.fill('#email', 'a@b.com'); await page.fill('#password', 'yanlis'); await page.click('#loginForm button');
await page.waitForFunction(() => document.getElementById('loginErr').textContent.length > 0); ok('yanlış şifre hata gösterir');
await page.fill('#password', 'dogru'); await page.click('#loginForm button');
await page.waitForSelector('#biz:not(.hide)'); ok('giriş sonrası kart geldi');

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
await page.click('[data-o="do_not_contact"]'); await page.waitForFunction(() => document.getElementById('bName').textContent !== 'Takip Eczane');
assert.equal((await calls()).filter(c => c[0] === 'log_call').at(-1)[1].p_outcome, 'do_not_contact'); ok('"dur dedi" onayla kaydedildi');

// Geçmiş
await page.click('[data-tab="hist"]'); await page.waitForSelector('#histTable tr:nth-child(2)');
assert.ok((await page.locator('#histTable tr').count()) >= 4); ok('geçmiş tablosu dolu');
await page.fill('#histSearch', 'meşgul'); await page.waitForTimeout(500);
assert.ok((await calls()).some(c => c[0] === 'search_history' && c[1].p_term === 'meşgul')); ok('geçmişte arama sunucuya gider');

// çıkış
await page.click('#logout'); await page.waitForSelector('#login:not(.hide)'); ok('çıkış giriş ekranına döner');

// mobil taşma
await page.click('#email');
const sw = await page.evaluate(() => document.documentElement.scrollWidth); assert.ok(sw <= 390, 'yatay taşma: ' + sw); ok('390px ekranda yatay taşma yok');

assert.deepEqual(errors, [], 'konsol hataları: ' + errors.join(' | ')); ok('konsol hatası yok');
await browser.close();
console.log('\nTÜM PANEL TESTLERİ GEÇTİ');
