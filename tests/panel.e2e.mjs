// Panel uçtan uca testi: gerçek Chromium + sahte Supabase istemcisi (tests/fake-supabase.js, ağ yok).
// Çalıştırma: node tests/panel.e2e.mjs   (playwright yerelde ya da global kurulu olmalı)
// İsteğe bağlı: SHOTS=klasör (ekran görüntüleri) · VIEW=1280x860 · AXE=/yol/axe.min.js (erişilebilirlik taraması)
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const { chromium } = (() => { try { return require('playwright'); } catch { return require(execSync('npm root -g').toString().trim() + '/playwright'); } })();

const html = fs.readFileSync(new URL('../public/index.html', import.meta.url), 'utf8')
  .replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/, '<script src="/fake-supabase.js"></script>');
assert.ok(html.includes('/fake-supabase.js'), 'CDN etiketi bulunamadı');
const fake = fs.readFileSync(new URL('./fake-supabase.js', import.meta.url), 'utf8');

const [VW, VH] = (process.env.VIEW || '390x844').split('x').map(Number);
const SHOTS = process.env.SHOTS; if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });
const CHROME = process.env.CHROMIUM || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const browser = await chromium.launch(fs.existsSync(CHROME) ? { executablePath: CHROME } : {});   // yol yoksa playwright'ın kendi tarayıcısı
let step = 0; const ok = m => console.log(`ok ${++step} – ${m}`);
const IGNORED = /Failed to load resource: the server responded with a status of (400|404|429)/;   // sahte servis hataları beklenir

async function mk({ role = 'admin', preLogged = false, accessError = false } = {}) {
  const ctx = await browser.newContext({ viewport: { width: VW, height: VH }, colorScheme: 'light' });
  const page = await ctx.newPage(); const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('console', m => { if (m.type() === 'error' && !IGNORED.test(m.text())) errors.push(m.text()); });
  await page.route('https://panel.test/**', r => {
    const path = new URL(r.request().url()).pathname;
    if (path === '/') return r.fulfill({ contentType: 'text/html', body: html });
    if (path === '/fake-supabase.js') return r.fulfill({ contentType: 'text/javascript', body: fake });
    const file = new URL('../public' + path, import.meta.url);   // yazı tipi, logo, ikon, manifest
    if (!path.includes('..') && fs.existsSync(file) && fs.statSync(file).isFile()) {
      const ext = path.split('.').pop(); const types = { png: 'image/png', svg: 'image/svg+xml', woff2: 'font/woff2', webmanifest: 'application/manifest+json' };
      return r.fulfill({ contentType: types[ext] || 'application/octet-stream', body: fs.readFileSync(file) });
    }
    return r.fulfill({ status: 404, body: 'yok' });
  });
  await page.addInitScript(([role, preLogged, accessError]) => {
    window.__role = role; window.__preLogged = preLogged; window.__accessError = accessError; window.__opened = [];
    window.open = u => { window.__opened.push(u); return null; };
  }, [role, preLogged, accessError]);
  const t = {
    txt: sel => page.locator(sel).innerText(),
    raw: sel => page.locator(sel).textContent(),   // CSS büyük harf dönüşümünden etkilenmez
    calls: () => page.evaluate(() => window.__calls),
    count: async n => (await t.calls()).filter(c => c[0] === n).length,
    last: async n => (await t.calls()).filter(c => c[0] === n).at(-1),
    vis: sel => page.locator(sel).isVisible(),
    shot: async n => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${n}.png` }); },
    axe: async label => {
      if (!process.env.AXE) return;
      await page.waitForTimeout(450);   // renk geçişleri bitsin
      await page.addScriptTag({ content: fs.readFileSync(process.env.AXE, 'utf8') });
      const res = await page.evaluate(async () => (await window.axe.run(document, { runOnly: ['wcag2a', 'wcag2aa'] })).violations
        .map(v => ({ id: v.id, impact: v.impact, n: v.nodes.length, sample: v.nodes[0].target.join(' ') + ' :: ' + (v.nodes[0].any[0]?.message || v.nodes[0].failureSummary || '').slice(0, 140) })));
      console.log(`axe [${label}]:`, res.length ? JSON.stringify(res, null, 1) : 'ihlal yok');
      assert.deepEqual(res.filter(v => v.impact === 'serious' || v.impact === 'critical'), [], `erişilebilirlik ihlali (${label})`);
    },
  };
  return { ctx, page, errors, t };
}

// =============================================================== 1) YÖNETİCİ: tam akış
const { ctx, page, errors, t } = await mk();
const { txt, raw, calls, count, last, vis, shot, axe } = t;

await page.goto('https://panel.test/');
await page.waitForSelector('#login:not(.hide)'); await shot('01-giris'); await axe('giriş'); ok('giriş ekranı açıldı');
await page.fill('#email', 'a@b.com'); await page.fill('#password', 'yanlis'); await page.click('#loginForm button');
await page.waitForFunction(() => document.getElementById('loginErr').textContent.length > 0); ok('yanlış şifre hata gösterir');
await page.fill('#password', 'dogru'); await page.click('#loginForm button');
await page.waitForSelector('#biz:not(.hide)'); ok('giriş sonrası kart geldi');

assert.equal(await raw('#roleBadge'), 'Yönetici');
assert.equal(await page.locator('#tabs [data-nav]:not(.hide)').count(), 5); ok('yönetici beş bölümü de görür, rol rozeti görünür');
assert.equal(await txt('#n_customers'), '1'); ok('müşteriler rozeti üretimdeki müşteri sayısını gösterir (satır indirmeden, sayım sorgusuyla)');

await page.waitForTimeout(700); await shot('02-whatsapp'); await axe('whatsapp kartı');
assert.equal(await txt('#bName'), 'Mavi Kuaför | Çankaya Saç Tasarım'); ok('en yüksek skorlu cep numarası WhatsApp listesinde ilk');
assert.match(await txt('#n_whatsapp'), /2/); assert.match(await txt('#n_call'), /1/); assert.match(await txt('#n_followup'), /1/);
assert.equal(await txt('#n_lists'), '4'); ok('liste sayaçları 2/1/1, toplam rozet 4');
assert.equal(await txt('#weekCount'), '7'); ok('haftalık sayaç sunucudan');
await page.click('#waBtn');
const url = (await page.evaluate(() => window.__opened))[0];
assert.ok(url.startsWith('https://web.whatsapp.com/send?phone=905321112233&text='), url);
const msg = decodeURIComponent(url.split('text=')[1]);
assert.ok(msg.startsWith('Merhaba,') && msg.includes('"iptal" yazmanız') && msg.includes('ekteki broşürde'), msg); ok('WhatsApp linki: numara + varsayılan mesaj + "iptal" cümlesi');
assert.equal(await vis('#brBtn'), true); await page.click('#brBtn');
await page.waitForFunction(() => /Broşür (kopyalandı|indirildi)/.test(document.getElementById('toast').textContent)); ok('broşür düğmesi cep numarasında görünür ve çalışır');
await page.click('#toCallList'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Yeşil Berber');
assert.equal(await count('move_to_call_list'), 1); assert.match(await txt('#n_call'), /2/); ok('arama listesine alma çalışıyor');
assert.equal(await vis('#bMaps'), false); ok('javascript: harita bağlantısı gizlendi');
await page.click('#btnWaSent'); await page.waitForFunction(() => !document.getElementById('empty').classList.contains('hide'));
await shot('03-bos'); assert.equal((await last('log_call'))[1].p_outcome, 'wa_sent'); assert.equal(await txt('#waToday'), '1'); ok('WhatsApp gönderildi kaydedildi, sayaç arttı, boş durum');

assert.equal(await txt('#n_sent'), '1');
await page.click('[data-tab="sent"]'); await page.waitForSelector('#sentList li[role="button"]');
assert.equal(await page.locator('#sentList li[role="button"]').count(), 1); assert.equal(await vis('#biz'), false);
await page.fill('#sentSearch', 'xyz'); await page.waitForFunction(() => /Sonuç bulunamadı/.test(document.getElementById('sentList').textContent));
await page.fill('#sentSearch', '0533 222'); await page.waitForSelector('#sentList li[role="button"]');
await page.click('#sentList li[role="button"]'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Yeşil Berber');
assert.equal(await vis('#btnWaSent'), false); assert.equal(await vis('#skip'), false); assert.equal(await vis('#backSent'), true);
await page.click('#backSent'); await page.waitForSelector('#sentList li[role="button"]'); assert.equal(await vis('#biz'), false);
await page.click('#sentList li[role="button"]'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Yeşil Berber');
await page.fill('#note', 'geri döndü'); await page.click('[data-o="interested"]');
await page.waitForFunction(() => /Gönderilen kayıt yok/.test(document.getElementById('sentList').textContent));
assert.equal((await last('log_call'))[1].p_outcome, 'interested');ok('Gönderildi sekmesi: gönderilen kayıt açılıp sonucu değiştirilebiliyor');

await page.click('[data-tab="call"]'); await page.waitForFunction(() => document.getElementById('bName').textContent.startsWith('Mavi'));
assert.equal(await vis('#toCallList'), false); ok('arama listesine alınan cep numarası Arama sekmesinde');
await page.click('#skip'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Sabit Diş');
assert.ok((await calls()).some(c => c[0] === 'release_business')); ok('atla sonraki kartı getirir ve kilidi bırakır');
assert.equal(await page.locator('#waBtn').isDisabled(), true); assert.equal(await vis('#btnWaSent'), false); ok('sabit hatta WhatsApp kapalı');
await page.click('[data-o="callback"]'); assert.equal(await vis('#cbBox'), true);
await page.fill('#note', 'sabah arayın'); await page.click('#cbSave');
await page.waitForFunction(() => !document.getElementById('empty').classList.contains('hide'));
const cb = (await last('log_call'))[1]; assert.equal(cb.p_outcome, 'callback'); assert.equal(cb.p_note, 'sabah arayın'); assert.ok(cb.p_callback_at); ok('geri arama tarih+not ile kaydedildi');

// Takip: önceki not, ardından SATIŞ -> müşteri
await page.click('[data-tab="followup"]'); await page.waitForFunction(() => document.getElementById('bName').textContent === 'Takip Eczane');
assert.match(await txt('#bHistory'), /meşguldü/); ok('takipte önceki arama notu görünür');
await page.fill('#note', 'Kurumsal paket');
await page.click('[data-o="won"]'); await page.waitForFunction(() => document.getElementById('bName').textContent !== 'Takip Eczane');
assert.equal((await last('log_call'))[1].p_outcome, 'won');
await page.waitForFunction(() => document.getElementById('toast').textContent.includes('Müşteriler'));
await page.waitForFunction(() => document.getElementById('n_customers').textContent === '2'); ok('"Satış oldu" müşteri oluşturur, rozet güncellenir');

// kalıcı çıkarma: özel onay penceresi
await page.waitForFunction(() => document.getElementById('bName').textContent === 'Sabit Diş');
{ const before = await count('log_call');
  await page.click('#closeMenu summary'); await page.click('[data-o="rejected"]'); await page.waitForSelector('#dlg[open]');
  await page.click('#dlg button[value="cancel"]'); await page.waitForFunction(() => !document.getElementById('dlg').open);
  assert.equal(await count('log_call'), before); ok('onayda "Vazgeç" kaydı engeller'); }
await page.click('[data-o="do_not_contact"]');
await page.waitForSelector('#dlg[open]'); assert.match(await txt('#dlgText'), /Sabit Diş/); await shot('04-onay');
await page.click('#dlgOk'); await page.waitForFunction(() => !document.getElementById('empty').classList.contains('hide'));
assert.equal((await last('log_call'))[1].p_outcome, 'do_not_contact'); ok('"iptal dedi" özel onay penceresiyle kaydedildi');

// =============================================================== MÜŞTERİLER
await page.click('[data-nav="customers"]'); await page.waitForSelector('.cust');
assert.equal(await page.locator('.cust').count(), 2); assert.match(await txt('#stageBar'), /Tümü\s*2/);
assert.match(await txt('#custTiles'), /2\s+müşteri/); assert.match(await txt('#custTiles'), /1\s+üretimde/);
assert.ok((await page.evaluate(() => window.__ranges || [])).some(r => r[0] === 'v_customers' && r[1] === 0 && r[2] === 999)); assert.equal(await vis('#custTrunc'), false);
assert.ok(await page.locator('.cust .cust-meta .bad').count() >= 1); await shot('05-musteriler'); await axe('müşteriler'); ok('müşteri panosu: aşama sayaçları, özet, geciken adım kırmızı');
await page.fill('#custSearch', 'ESKİ'); await page.waitForFunction(() => document.querySelectorAll('.cust').length === 1);
assert.match(await txt('.cust'), /Eski Müşteri/); await page.fill('#custSearch', ''); await page.waitForFunction(() => document.querySelectorAll('.cust').length === 2); ok('Türkçe büyük/küçük harfe duyarsız arama');

await page.click('.cust:has-text("Takip Eczane")'); await page.waitForSelector('#cdlg[open]');
assert.equal(await txt('#cName'), 'Takip Eczane'); assert.equal(await page.getAttribute('#cCall', 'href'), 'tel:05340000000'); assert.equal(await page.getAttribute('#cWa', 'href'), 'https://wa.me/905340000000');
await page.waitForFunction(() => document.querySelector('#cTimeline li'));
assert.match(await txt('#cTimeline'), /Satış kaydedildi\s+Kurumsal paket/); await shot('06-musteri-detay'); await axe('müşteri detayı'); ok('müşteri detayı: iletişim düğmeleri ve başlangıç notu (satış notu taşındı)');
await page.click('#cStages .chip:text-is("Site tasarlanıyor")'); assert.equal(await vis('#stageBox'), true);
await page.fill('#stageNote', 'Logo bekleniyor'); await page.click('#stageSave');
await page.waitForFunction(() => /Satış gerçekleşti → Site tasarlanıyor/.test(document.querySelector('#cTimeline li')?.textContent || ''));
const st = (await last('set_customer_stage'))[1]; assert.deepEqual([st.p_stage, st.p_note], ['designing', 'Logo bekleniyor']);
assert.match(await txt('#cTimeline li:first-child'), /Logo bekleniyor/); ok('aşama değişir, not zaman çizelgesine yazılır');
await page.fill('#fAmount', 'abc'); await page.click('#fSave');
await page.waitForFunction(() => document.getElementById('toast').textContent.includes('Tutarı sayı olarak')); assert.equal(await count('update_customer'), 0); ok('geçersiz tutar sunucuya gitmez');
await page.fill('#fAmount', '7500'); await page.fill('#fDomain', 'eczane.com'); await page.fill('#fNext', 'Logo iste'); await page.fill('#fNextAt', '2026-12-01'); await page.click('#fSave');
await page.waitForFunction(() => /Güncellendi/.test(document.querySelector('#cTimeline li')?.textContent || ''));
const up = (await last('update_customer'))[1].p_patch; assert.equal(up.amount, '7500'); assert.equal(up.domain, 'eczane.com'); assert.equal(up.next_step, 'Logo iste'); assert.match(up.next_step_at, /^2026-12-01/);
await page.click('#fSave'); await page.waitForFunction(() => document.getElementById('toast').textContent.includes('Değişiklik yok')); ok('bilgiler yalnızca değişen alanlarla kaydedilir');
await page.click('#nChips .chip:text-is("Ödeme alındı")'); await page.fill('#nNote', 'Ödeme alındı\nIBAN ile'); await page.click('#nAdd');
await page.waitForFunction(() => /IBAN ile/.test(document.querySelector('#cTimeline li')?.textContent || '')); assert.equal(await page.inputValue('#nNote'), ''); ok('not eklenir ve en üste gelir');
await page.click('#cClose'); await page.waitForFunction(() => !document.getElementById('cdlg').open);
assert.match(await txt('.cust:has-text("Takip Eczane")'), /Site tasarlanıyor/); assert.match(await txt('.cust:has-text("Takip Eczane")'), /7\.500/); ok('liste kartı yeni aşama ve tutarı gösterir');
await page.click('#stageBar .chip:has-text("Tasarım")'); assert.equal(await page.locator('.cust').count(), 2); ok('aşama filtresi çalışır');
await page.click('#custAdd'); await page.waitForSelector('#adlg[open]');
await page.fill('#aName', 'Elle Kafe'); await page.fill('#aPhone', '0532 999 88 77'); await page.fill('#aAmount', '12000'); await page.fill('#aNote', 'Tanıdık yoluyla'); await page.click('#aForm button:not([type="button"])');
await page.waitForFunction(() => document.querySelectorAll('.cust').length === 3);
const cc = (await last('create_customer'))[1]; assert.deepEqual([cc.p_name, cc.p_amount, cc.p_note], ['Elle Kafe', 12000, 'Tanıdık yoluyla']); ok('elle müşteri eklenir');

// =============================================================== TARAMA (Edge Function sahte)
const scanCalls = []; let scanMode = 'ok';
await page.route('**/functions/v1/scan', async route => {
  const req = route.request(); const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' };
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
const reload = async () => { await page.click('[data-nav="lists"]'); await page.click('[data-nav="scan"]'); await page.waitForSelector('#scanView:not(.hide)'); };

await page.click('[data-nav="scan"]'); await page.waitForSelector('#scanView:not(.hide)');
assert.equal(await vis('#biz'), false); assert.equal(await page.locator('#scHist li').count(), 1); ok('Tara sekmesi açıldı, son taramalar listelendi');
await shot('07-tara'); await axe('tara');
await page.click('#sectorChips .chip:text-is("kuaför")'); assert.equal(await page.inputValue('#scSectors'), 'kuaför'); ok('sektör çipi alanı doldurur');
await page.fill('#scCity', 'mars'); await page.click('#scPlan');
await page.waitForFunction(() => document.getElementById('toast').textContent.includes('Şehir tanınmadı')); assert.equal(await vis('#scRun'), false); ok('geçersiz şehir anlaşılır hata verir');
await page.fill('#scCity', 'ankara'); await page.fill('#scDistricts', 'çankaya, keçiören, yenimahalle, mamak'); await page.click('#scPlan');
await page.waitForSelector('#scRun:not(.hide)');
const planTxt = await txt('#scPlanBox'); assert.match(planTxt, /Keçiören · kuaför\s+taranacak/); assert.match(planTxt, /Mamak · kuaför\s+kapalı bölge/);
assert.match(await txt('#scTiles'), /3\/60/); assert.match(await txt('#scTiles'), /2\s+taranacak bölge/); await shot('08-plan');
assert.match(await txt('#scRun'), /2 bölge/); assert.match(planTxt, /bugün en çok ~1 bölge taranabilir/);
assert.equal(scanCalls[0].auth, 'Bearer tok'); assert.ok(scanCalls[0].apikey.startsWith('sb_publishable_')); ok('plan: taranacak/atlanacak ayrımı, günlük sınır uyarısı, oturum bilgisi gönderilir');
await page.click('#scRun'); await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
await shot('09-tarama-bitti');
const runs = scanCalls.filter(c => c.action === 'run'); assert.deepEqual(runs.map(r => r.district), ['Keçiören', 'Yenimahalle']); assert.equal(runs[0].city, 'Ankara'); assert.equal(runs[0].force, false);
assert.match(await txt('#scLog'), /62 yeni kaydedildi, 6 Google çağrısı/); assert.equal(await vis('#scProg'), false); assert.equal(await page.locator('#scCity').isDisabled(), false); ok('tarama sırayla çalışır, özet yazılır, form tekrar açılır');
await page.check('#scForce'); await page.click('#scPlan'); await page.waitForSelector('#scRun:not(.hide)');
assert.match(await txt('#scRun'), /3 bölge/); scanCalls.length = 0; await page.click('#scRun'); await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
assert.equal(scanCalls.filter(c => c.action === 'run').every(c => c.force === true), true); ok('"yeniden tara" 90 gün kuralını aşar ve force gönderir');
await page.uncheck('#scForce');
scanMode = 'fail'; await page.click('#scPlan'); await page.waitForSelector('#scRun:not(.hide)'); await page.click('#scRun');
await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
const logTxt = await txt('#scLog'); assert.match(logTxt, /Günlük Google çağrı sınırına ulaşıldı/); assert.match(logTxt, /Hata nedeniyle durdu/); assert.match(logTxt, /31 yeni kaydedildi/); ok('hata gelince durur, o ana kadarki sonuç korunur');
scanMode = 'slow'; await page.click('#scPlan'); await page.waitForSelector('#scRun:not(.hide)'); await page.click('#scRun');
await page.waitForSelector('#scProg:not(.hide)'); await page.click('#scStop');
await page.waitForFunction(() => document.getElementById('scLog').textContent.includes('Özet'));
assert.match(await txt('#scLog'), /Durduruldu/); ok('durdur düğmesi sıradaki bölgeleri çalıştırmaz');
scanMode = 'missing'; await page.click('#scPlan');
await page.waitForFunction(() => document.getElementById('toast').textContent.includes('kurulu değil')); ok('servis yoksa kurulum yönlendirmesi gösterilir');
scanMode = 'ok';

// =============================================================== EKİP
await page.click('[data-nav="team"]'); await page.waitForSelector('.trow');
assert.equal(await page.locator('.trow').count(), 3); assert.match(await txt('#teamList'), /Kerim \(siz\)/); assert.match(await txt('#teamView'), /Abonelikler \(yakında\)/);
await shot('10-ekip'); await axe('ekip'); ok('ekip listesi, kendi satırında "(siz)", abonelik yer tutucusu');
await page.selectOption('.trow:nth-child(3) select', 'designer'); await page.fill('.trow:nth-child(3) input', 'Ayşe'); await page.click('.trow:nth-child(3) button');
await page.waitForFunction(() => document.getElementById('toast').textContent.includes('Yetki güncellendi'));
const sr = (await last('set_user_role'))[1]; assert.deepEqual([sr.p_user, sr.p_role, sr.p_name], ['u3', 'designer', 'Ayşe']); ok('rol atanır');
await page.selectOption('.trow:nth-child(2) select', 'none'); await page.click('.trow:nth-child(2) button'); await page.waitForSelector('#dlg[open]');
assert.match(await txt('#dlgText'), /arkadas@vitrin\.test/); assert.equal(await count('set_user_role'), 1);
await page.click('#dlgOk'); await page.waitForFunction(() => window.__calls.filter(c => c[0] === 'set_user_role').length === 2);
assert.equal((await last('set_user_role'))[1].p_role, 'none'); ok('yetki kaldırma onay ister');

// =============================================================== GEÇMİŞ, ÇIKIŞ
await page.click('[data-nav="hist"]'); await page.waitForSelector('#histList li');
assert.match(await txt('#repTiles'), /7\s*Gönderilen/); assert.match(await txt('#repLine'), /Dönüş oranı 30%/); ok('rapor: haftalık sayılar ve dönüş oranı');
assert.equal(await page.locator('#histList li').count(), 5); await shot('11-gecmis'); await axe('geçmiş'); ok('geçmiş listesi dolu');
await page.fill('#histSearch', 'meşgul'); await page.waitForTimeout(500);
assert.ok((await calls()).some(c => c[0] === 'search_history' && c[1].p_term === 'meşgul')); ok('geçmişte arama sunucuya gider');
const hdr = await page.evaluate(() => {   // en kötü durum: 3 haneli sayaç ve en uzun rol adı
  document.getElementById('weekCount').textContent = '100'; document.getElementById('roleBadge').textContent = 'Tasarımcı';
  const r = id => document.getElementById(id).getBoundingClientRect();
  return { badgeRight: r('roleBadge').right, goalLeft: Math.min(r('goalBox').left, document.querySelector('.goal-top').getBoundingClientRect().left) };
});
assert.ok(hdr.badgeRight <= hdr.goalLeft, `başlıkta rol rozeti sayaçla çakışıyor: ${JSON.stringify(hdr)}`); ok('başlıkta rol rozeti ile haftalık sayaç çakışmaz');
await page.click('#logout'); await page.waitForSelector('#login:not(.hide)'); ok('çıkış giriş ekranına döner');
await page.click('#email');
const sw = await page.evaluate(() => document.documentElement.scrollWidth); assert.ok(sw <= VW, 'yatay taşma: ' + sw); ok(`${VW}px ekranda yatay taşma yok`);
assert.deepEqual(errors, [], 'konsol hataları: ' + errors.join(' | ')); ok('konsol hatası yok (yönetici)');
await ctx.close();

// =============================================================== 2) ROL SENARYOLARI
{ // tasarımcı: yalnızca müşteriler
  const r = await mk({ role: 'designer', preLogged: true }); const p = r.page;
  await p.goto('https://panel.test/'); await p.waitForSelector('#customersView:not(.hide)'); await p.waitForSelector('.cust');
  assert.equal(await r.t.raw('#roleBadge'), 'Tasarımcı'); assert.equal(await r.t.vis('#tabs'), false); assert.equal(await r.t.vis('#goalBox'), false);
  const names = (await r.t.calls()).map(c => c[0]);
  for (const n of ['stats', 'list_counts', 'next_business', 'filter_options', 'team_list']) assert.ok(!names.includes(n), `tasarımcı ${n} çağırmamalı`);
  await r.t.shot('12-tasarimci'); await r.t.axe('tasarımcı');
  await p.click('.cust'); await p.waitForSelector('#cdlg[open]'); await p.click('#cStages .chip:text-is("Müşteri onayında")'); await p.click('#stageSave');
  await p.waitForFunction(() => /→ Müşteri onayında/.test(document.querySelector('#cTimeline li')?.textContent || ''));
  assert.equal(await r.t.vis('#custAdd'), true); ok('tasarımcı: yalnızca müşteriler; satış ekranları ve çağrıları yok; aşama değiştirebilir');
  assert.deepEqual(r.errors, []); await r.ctx.close();
}
{ // satış: ekip yok
  const r = await mk({ role: 'sales', preLogged: true }); const p = r.page;
  await p.goto('https://panel.test/'); await p.waitForSelector('#biz:not(.hide)');
  assert.equal(await r.t.raw('#roleBadge'), 'Satış'); assert.equal(await p.locator('#tabs [data-nav]:not(.hide)').count(), 4); assert.equal(await p.locator('[data-nav="team"]').isVisible(), false);
  ok('satış: ekip sekmesi gizli, diğer dört bölüm açık'); assert.deepEqual(r.errors, []); await r.ctx.close();
}
{ // rolsüz
  const r = await mk({ role: 'none', preLogged: true }); const p = r.page;
  await p.goto('https://panel.test/'); await p.waitForSelector('#gate:not(.hide)');
  assert.match(await r.t.txt('#gateTitle'), /henüz yetki verilmedi/); assert.equal(await r.t.vis('#app'), false); await r.t.shot('13-yetkisiz'); await r.t.axe('yetkisiz');
  assert.ok(!(await r.t.calls()).some(c => ['next_business', 'v_customers'].includes(c[0]))); ok('rolsüz kullanıcı yalnızca bilgi ekranını görür, veri çağrısı yapılmaz'); assert.deepEqual(r.errors, []); await r.ctx.close();
}
{ // güncellenmemiş veritabanı
  const r = await mk({ role: 'admin', preLogged: true, accessError: true }); const p = r.page;
  await p.goto('https://panel.test/'); await p.waitForSelector('#gate:not(.hide)');
  assert.match(await r.t.txt('#gateTitle'), /Veritabanı güncellemesi gerekli/); assert.match(await r.t.txt('#gateText'), /schema\.sql/); assert.equal(await r.t.vis('#gateRetry'), true);
  ok('şema eski ise panel net bir kurulum uyarısı verir'); assert.deepEqual(r.errors, []); await r.ctx.close();
}
await browser.close();
console.log('\nTÜM PANEL TESTLERİ GEÇTİ');
