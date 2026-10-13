# Vitrin Web – müşteri bulma, satış ve proje takip paneli

Google Haritalar'da puanı yüksek ama web sitesi olmayan işletmeleri bölge bölge bulur; ekip WhatsApp'tan yazar / arar,
sonuçlar kaydedilir, aranan işletme bir daha çıkmaz. Hedef: haftada ~100 temas, günde en fazla ~25 WhatsApp.

| Parça | Dosya | Nerede çalışır |
|---|---|---|
| Veritabanı, roller, müşteri hattı | `supabase/schema.sql` | Supabase |
| Tarama (panelden) | `supabase/functions/scan/index.ts` | Supabase Edge Function |
| Tarama (terminalden, isteğe bağlı) | `scan.py` | Sadece sizin Mac'iniz |
| Panel | `public/index.html` | Vercel (`panel.vitrinweb.com.tr`) |

## Kurulum (bir kez, bu sırayla)

1. **Veritabanı:** Supabase > SQL Editor'e `supabase/schema.sql` içeriğini yapıştırıp Run. Güvenle tekrar çalıştırılabilir; mevcut verinin üstüne ekler.
   Authentication > Sign In / Providers'ta **"Allow new users to sign up" kapalı** olmalı; kullanıcıları Authentication > Users'tan siz ekleyin.
2. **Deneme verisini silin** (gerçek taramadan önce): `supabase/reset_test_data.sql`.
3. **Panel:** `public/index.html` içindeki `SUPABASE_URL` ve `SUPABASE_ANON_KEY` (publishable) değerlerinin **şema çalıştırdığınız projeyle aynı** olduğunu kontrol edin.
   Vercel: Framework Preset = *Other*, Build Command boş. Çıktı klasörü `vercel.json` ile `public/` olarak ayarlı.
   Domain: Vercel > Settings > Domains'e `panel.vitrinweb.com.tr`, DNS'te CNAME.
4. **Panelden tarama (önerilen, bir kez kurulur):** aşağıdaki "Panelden tarama" bölümünü yapın.
   Google anahtarını Places API ile kısıtlayın ve Google Cloud > Faturalama > **Bütçeler ve uyarılar** bölümünden bütçe uyarısı kurun.
5. *(İsteğe bağlı)* Terminalden taramak için `.env.example` dosyasını `.env` olarak kopyalayıp doldurun (yalnızca kendi Mac'inizde).

## Mevcut kurulumu güncelleme (müşteri hattı + roller sürümü)

Sırayla, kesinti olmadan:
1. **Supabase > SQL Editor:** `supabase/schema.sql` dosyasının güncel halini çalıştırın. Mevcut veriyi silmez. Mevcut kullanıcılara rol atar: **en eski kullanıcı Yönetici, diğerleri Satış**. Durumu "won" olan eski kayıtlar müşteri olarak eklenir. Eski panel şema güncellenince de çalışmaya devam eder.
2. **Edge Functions > scan:** `supabase/functions/scan/index.ts` dosyasının yeni halini yapıştırıp yeniden Deploy edin (tarama artık "tarama" iznini de kontrol eder).
3. Dalı/PR'ı birleştirin; Vercel yeni paneli yayınlar.
4. Panele girin, **Ekip** sekmesinden arkadaşınıza ve diğer kişilere rol verin.

Panel "Veritabanı güncellemesi gerekli" derse 1. adım yapılmamıştır.

## Müşteriler (satış sonrası takip)

Listede **Satış oldu** dediğiniz işletme otomatik olarak **Müşteriler** sekmesine düşer (görüşme notunuz ilk not olur). Listeden gelmeyen müşteriyi **+ Ekle** ile elle girebilirsiniz.

* **Aşamalar:** Satış gerçekleşti → Bilgi toplanıyor → Site tasarlanıyor → Müşteri onayında → Yayında. Ayrıca Beklemede ve İptal. Aşama değişince isteğe bağlı not yazılır; kim, ne zaman değiştirdi kayda geçer.
* **Her müşteride:** tutar (TL), alan adı, sıradaki adım ve tarihi (geçen adım kırmızı görünür), sınırsız not ve tam geçmiş (zaman çizelgesi), arama/WhatsApp düğmeleri.
* **Pano:** aşama sayaçlarına tıklayarak filtreleyin, ad/telefon/alan adı ile arayın; üstte müşteri sayısı, üretimdekiler ve toplam tutar görünür.

## Roller ve yetkiler

Kullanıcıyı **Supabase > Authentication > Users > Add user** ile siz eklersiniz (kayıt kapalıdır). Rolü **Ekip** sekmesinden (yalnızca Yönetici) verirsiniz. **Rolü olmayan kimse hiçbir veri göremez.**

| Rol | Görür / yapar |
|---|---|
| **Yönetici** | Her şey: listeler, tarama, müşteriler, ekip ve roller, (ileride) abonelikler |
| **Satış** | Listeler, geçmiş, tarama, müşteriler. Ekip ve abonelikleri görmez |
| **Tasarımcı** | Yalnızca müşteriler (aşama, not, tutar, alan adı). Satış listelerini ve taramayı göremez |

Yetkiler arayüzde gizlenmekle kalmaz, veritabanında da zorunludur (satır düzeyinde güvenlik + fonksiyon kontrolleri). Son yöneticiyi kaldırmak/düşürmek engellenir.
Yeni bir modül (örn. araç abonelikleri: Claude, GitHub…) eklemek için `role_perms` fonksiyonuna izin eklemek yeterlidir; `subscriptions` izni şimdiden yalnızca Yönetici'de tanımlıdır.

## Panelden tarama (Tara sekmesi)

Terminal gerekmez. Panelde **Tara** sekmesinde şehir, ilçe ve sektör yazılır; **Planı göster** hangi bölgelerin taranacağını (taranmış/kapalı olanlar atlanır) ve en çok kaç Google çağrısı yapılacağını gösterir; **Taramayı başlat** bölgeleri sırayla tarar, **Durdur** ile yarıda kesilebilir. Sonuçlar anında WhatsApp / Arama listelerine düşer.

Google anahtarı panelde değil, Supabase'de gizli kalır. Kurulum (bir kez):
1. Supabase > **Edge Functions** > **Deploy a new function** > **Via Editor**. Ad: `scan`. Editördeki her şeyi silip `supabase/functions/scan/index.ts` dosyasının tamamını yapıştırın, **Deploy**.
2. Fonksiyonun **Settings** bölümünde **Verify JWT** (legacy secret) seçeneğini **kapatın**. Giriş kontrolünü fonksiyonun kendisi yapar ve kayıtlı kullanıcı dışındakini reddeder.
3. Supabase > Edge Functions > **Secrets** > **Add new secret**: Ad `GOOGLE_API_KEY`, değer Google'daki Places anahtarınız.
4. Panelde **Tara** sekmesini deneyin. "Tarama servisi kurulu değil" yazarsa 1. adım eksiktir.

* **Günlük sınır:** Bir günde (Türkiye saatiyle) en çok **60** Google çağrısı yapılır (≈20 bölge). Değiştirmek için `MAX_CALLS_PER_DAY` adlı secret ekleyin. Sınır aşılırsa panel yarın devam etmenizi söyler.
* **Başka alan adı:** Paneli `panel.vitrinweb.com.tr` dışında bir adresten açacaksanız `ALLOWED_ORIGINS` secret'ına o adresi (virgülle) ekleyin.
* **Fonksiyonu güncellemek:** Dosya değişince aynı editörde yeni içeriği yapıştırıp yeniden Deploy edin.

## Tarama (terminalden, isteğe bağlı)

```bash
# önce deneme: Google'a sorar ama hiçbir şey yazmaz
python3 scan.py --city Ankara --districts "Çankaya,Keçiören" --sectors "kuaför,diş hekimi" --dry-run
# gerçek tarama
python3 scan.py --city Ankara --districts "Çankaya" --sectors "kuaför"
```

* Filtre: puan ≥ 4.3, yorum 10–300, web sitesi yok ya da yalnızca sosyal medya/link sayfası, geçerli telefon, açık işletme.
* Aynı bölge+sektör **90 gün** tekrar taranmaz (`--force` ile zorlanır). `closed_regions` tablosundaki bölgeler (Bursa) atlanır.
* Aynı `place_id` ya da telefon ikinci kez eklenmez; "ilgilenmiyor/iptal dedi" diyenler kayıtta kalır, bu yüzden tekrar taramada geri gelmez.
* Her sorgu en çok `--max-pages` (3) sayfa ≈ 60 sonuç = en çok 3 API çağrısıdır; `--max-queries` (30) toplam çağrıyı sınırlar. Fiyat için Google Maps Platform fiyat sayfasına bakın.
* Her kayda 0–100 **skor** verilir (puan, yorum, sitesizlik, cep numarası); panel yüksek skoru önce gösterir.

## Panel

vitrinweb. marka diliyle tasarlanmıştır (beyaz zemin, Manrope, lacivert vurgu; bkz. `docs/MARKA.md`). Telefonda alt gezinme çubuğu, bilgisayarda üst menü kullanır. Üstteki ince çubuk haftalık hedefe (100) ilerlemeyi gösterir.

**Masaüstü kısayolları:** `W` WhatsApp'tan yaz, `S` şimdilik atla, `N` nota geç. (Sonuç düğmeleri yanlışlıkla basılmasın diye kısayolsuzdur.)


* **Üst menü:** Liste (WhatsApp / Arama / Takip) · Müşteriler · Tara · Geçmiş · Ekip. Menüde yalnızca rolünüzün göreceği bölümler çıkar.
* **WhatsApp:** yeni + cep numarası. "WhatsApp'tan yaz" hazır mesajla açar, ekip gözden geçirip kendi gönderir; "Broşürü gönder" broşürü panoya kopyalar (bilgisayarda Cmd+V) ya da telefonda paylaşım menüsünü açar; sonra "WhatsApp gönderdim". 3 gün sonra **Takip**'e düşer.
  WhatsApp'ı olmayan ya da yazmak istemediğiniz kayıt için **"Arama listesine al"**.
* **Arama:** sabit hatlar + arama listesine alınanlar + açmayanlar (günde bir tekrar, en fazla 3 deneme; sonra "ulaşılamaz").
* **Takip:** zamanı gelen "sonra ara", WhatsApp'ı 3 gün önce gidenler, ilgilenenler.
* **Tara:** şehir/ilçe/sektör girip yeni işletme bulur (aşağıda "Panelden tarama").
* **Geçmiş:** tüm kayıtlar, ad/not/telefonla arama.
* İki kişi aynı anda çalışabilir: sunucu bir kartı açana 15 dk "kilitler", diğeri başka kart görür.
* Sayaçlar (hafta/bugün) Türkiye saatiyle ve ekip toplamıdır. Günlük 20 WhatsApp aşılırsa uyarır (engellemez).
* "İlgilenmiyor" ve "İptal dedi" kalıcıdır, sunucu bir daha işlem yapılmasına izin vermez.

## Güvenlik

* Panele yalnızca *publishable* anahtar konur. **Secret anahtar** sadece `.env`'de (Mac) durur, git'e girmez.
* Tarayıcı veritabanını yalnızca okuyabilir; her yazma `log_call` vb. fonksiyonlarla olur. Kayıt kapalı, giriş yalnızca eklediğiniz kullanıcılarla.
* Site `noindex`, çerçevelenemez, sıkı CSP ile yayınlanır; `supabase-js` sürümü sabit ve bütünlük (SRI) denetimli.
* `scan.py`, SQL ve testler `public/` dışında olduğundan internetten indirilemez.
* Tarama servisi yalnızca giriş yapmış ve **tarama izni olan** kullanıcıyı kabul eder, girdileri doğrular ve günlük Google çağrı sınırı koyar. Google anahtarı hiçbir yanıtta görünmez.

## Testler

```bash
python3 -m unittest tests.test_scan                  # tarama mantığı (Python)
node --test tests/scan_edge.test.mjs                 # panelden tarama servisi (Node 22+)
node tests/panel.e2e.mjs                             # panel, gerçek tarayıcıda (playwright gerekir)
#   ekran görüntüsü: SHOTS=klasör  ·  masaüstü: VIEW=1280x860
#   erişilebilirlik taraması: AXE=node_modules/axe-core/axe.min.js (npm i axe-core)
PGHOST=... PGUSER=postgres tests/run_sql_tests.sh    # şema + iş kuralları, boş bir Postgres'e karşı
```

## Hukuki not
Cep numaralarına ticari ileti göndermek KVKK ve İYS (6563 sayılı Kanun) kapsamına girebilir. Canlıya geçmeden bir hukukçuya danışın.
Mesaj şablonundaki "iptal yazmanız yeterli" cümlesi panelde silinemez; "iptal" yazanları "İptal dedi" olarak işaretlemeyi unutmayın.
