# Vitrin Web – müşteri bulma ve arama sistemi

Google Haritalar'da puanı yüksek ama web sitesi olmayan işletmeleri bölge bölge bulur; ekip WhatsApp'tan yazar / arar,
sonuçlar kaydedilir, aranan işletme bir daha çıkmaz. Hedef: haftada ~100 temas, günde en fazla ~25 WhatsApp.

| Parça | Dosya | Nerede çalışır |
|---|---|---|
| Veritabanı | `supabase/schema.sql` | Supabase |
| Tarama | `scan.py` | Sadece sizin Mac'iniz |
| Panel | `public/index.html` | Vercel (`panel.vitrinweb.com.tr`) |

## Kurulum (bir kez, bu sırayla)

1. **Veritabanı:** Supabase > SQL Editor'e `supabase/schema.sql` içeriğini yapıştırıp Run. Güvenle tekrar çalıştırılabilir; mevcut verinin üstüne ekler.
   Authentication > Sign In / Providers'ta **"Allow new users to sign up" kapalı** olmalı; kullanıcıları Authentication > Users'tan siz ekleyin.
2. **Deneme verisini silin** (gerçek taramadan önce): `supabase/reset_test_data.sql`.
3. **Panel:** `public/index.html` içindeki `SUPABASE_URL` ve `SUPABASE_ANON_KEY` (publishable) değerlerinin **şema çalıştırdığınız projeyle aynı** olduğunu kontrol edin.
   Vercel: Framework Preset = *Other*, Build Command boş. Çıktı klasörü `vercel.json` ile `public/` olarak ayarlı.
   Domain: Vercel > Settings > Domains'e `panel.vitrinweb.com.tr`, DNS'te CNAME.
4. **Tarama anahtarları:** `.env.example` dosyasını `.env` olarak kopyalayıp doldurun (yalnızca kendi Mac'inizde).
   Google anahtarını Places API ile kısıtlayın ve Google Cloud > Faturalama > **Bütçeler ve uyarılar** bölümünden bütçe uyarısı kurun.

## Tarama

```bash
# önce deneme: Google'a sorar ama hiçbir şey yazmaz
python3 scan.py --city Ankara --districts "Çankaya,Keçiören" --sectors "kuaför,diş hekimi" --dry-run
# gerçek tarama
python3 scan.py --city Ankara --districts "Çankaya" --sectors "kuaför"
```

* Filtre: puan ≥ 4.3, yorum 10–300, web sitesi yok ya da yalnızca sosyal medya/link sayfası, geçerli telefon, açık işletme.
* Aynı bölge+sektör **90 gün** tekrar taranmaz (`--force` ile zorlanır). `closed_regions` tablosundaki bölgeler (Bursa) atlanır.
* Aynı `place_id` ya da telefon ikinci kez eklenmez; "ilgilenmiyor/dur dedi" diyenler kayıtta kalır, bu yüzden tekrar taramada geri gelmez.
* Her sorgu en çok `--max-pages` (3) sayfa ≈ 60 sonuç = en çok 3 API çağrısıdır; `--max-queries` (30) toplam çağrıyı sınırlar. Fiyat için Google Maps Platform fiyat sayfasına bakın.
* Her kayda 0–100 **skor** verilir (puan, yorum, sitesizlik, cep numarası); panel yüksek skoru önce gösterir.

## Panel

* **WhatsApp:** yeni + cep numarası. "WhatsApp'tan yaz" hazır mesajla açar, ekip gözden geçirip kendi gönderir, sonra "WhatsApp gönderdim". 3 gün sonra **Takip**'e düşer.
  WhatsApp'ı olmayan ya da yazmak istemediğiniz kayıt için **"Arama listesine al"**.
* **Arama:** sabit hatlar + arama listesine alınanlar + açmayanlar (günde bir tekrar, en fazla 3 deneme; sonra "ulaşılamaz").
* **Takip:** zamanı gelen "sonra ara", WhatsApp'ı 3 gün önce gidenler, ilgilenenler.
* **Geçmiş:** tüm kayıtlar, ad/not/telefonla arama.
* İki kişi aynı anda çalışabilir: sunucu bir kartı açana 15 dk "kilitler", diğeri başka kart görür.
* Sayaçlar (hafta/bugün) Türkiye saatiyle ve ekip toplamıdır. Günlük 25 WhatsApp aşılırsa uyarır (engellemez).
* "İlgilenmiyor" ve "Dur dedi" kalıcıdır, sunucu bir daha işlem yapılmasına izin vermez.

## Güvenlik

* Panele yalnızca *publishable* anahtar konur. **Secret anahtar** sadece `.env`'de (Mac) durur, git'e girmez.
* Tarayıcı veritabanını yalnızca okuyabilir; her yazma `log_call` vb. fonksiyonlarla olur. Kayıt kapalı, giriş yalnızca eklediğiniz kullanıcılarla.
* Site `noindex`, çerçevelenemez, sıkı CSP ile yayınlanır; `supabase-js` sürümü sabit ve bütünlük (SRI) denetimli.
* `scan.py`, SQL ve testler `public/` dışında olduğundan internetten indirilemez.

## Testler

```bash
python3 -m unittest tests.test_scan                  # tarama mantığı
node tests/panel.e2e.mjs                             # panel, gerçek tarayıcıda (playwright gerekir)
PGHOST=... PGUSER=postgres tests/run_sql_tests.sh    # şema + iş kuralları, boş bir Postgres'e karşı
```

## Hukuki not
Cep numaralarına ticari ileti göndermek KVKK ve İYS (6563 sayılı Kanun) kapsamına girebilir. Canlıya geçmeden bir hukukçuya danışın.
Mesaj şablonundaki "dur yazmanız yeterli" cümlesi panelde silinemez; "dur" diyenleri "Dur dedi" olarak işaretlemeyi unutmayın.
