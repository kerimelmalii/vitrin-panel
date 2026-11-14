# Vitrin – müşteri bulma ve satış paneli

Google Haritalar'dan bölge ve sektöre göre işletme bulur; ekip WhatsApp'tan yazar ya da arar, sonucu işaretler.
İlgilenenler müşteri panosuna düşer, satışlar ürün/adet/tutar olarak kaydedilir, ay sonunda rapor alınır.
Birden fazla şirket (çalışma alanı) aynı paneli kullanır; her şirket yalnızca kendi verisini görür.

| Parça | Dosya | Nerede çalışır |
|---|---|---|
| Veritabanı, alanlar, roller, iş kuralları | `supabase/schema.sql` | Supabase |
| Tarama | `supabase/functions/scan/index.ts` | Supabase Edge Function |
| Panel | `public/index.html` | Vercel (`panel.vitrinweb.com.tr`) |
| Aydınlatma metni (taslak) | `docs/AYDINLATMA_METNI.md` | Panelde Ekip > Notlar |

## Bu sürüme geçiş (pilot öncesi, bir kez, bu sırayla)

1. **Supabase > SQL Editor:** `supabase/schema.sql` dosyasının tamamını yapıştırıp Run. Mevcut veriyi silmez:
   bütün kayıtlar ve kullanıcılar **Vitrin** alanına bağlanır, eski müşteri aşamaları yenilerine çevrilir
   (tasarım/yayında → Satış tamamlandı, beklemede → Anlaşma aşamasında, iptal → İletişimde), eski "tutar" alanı satış kalemine taşınır.
2. **Supabase > Edge Functions > scan:** `supabase/functions/scan/index.ts` dosyasının yeni halini yapıştırıp Deploy.
3. Dalı birleştirin; Vercel yeni paneli yayınlar.
4. **Pilot şirketi açın:** panelde **Yönetim > Alanlar** bölümünde şirket adını yazın, "Demo sürüm" işaretli ve kota 500 olarak **Alanı oluştur**.
5. **Pilot kullanıcıları:** Supabase > Authentication > Users > Add user ile ekleyin. Kişi bir kez giriş yaptıktan sonra
   **Ekip** listesinde görünür; alanını (pilot şirket) ve rolünü seçip Kaydet. Pilot şirketin en az bir **Yönetici**si olsun:
   o kişi kendi ekibinin rollerini, mesaj şablonunu ve sektör önerilerini kendisi yönetir.
6. *(İsteğe bağlı)* Supabase > Database > Extensions'ta **pg_cron**'u açıp `schema.sql`'i bir kez daha çalıştırın:
   30 gün kuralı her gece otomatik işler. Açmasanız da olur: kural her taramada ayrıca çalışır ve eski kayıtlar listede zaten görünmez.

Panel "Veritabanı güncellemesi gerekli" derse 1. adım yapılmamıştır.

## Kayıt ol ve onay

Giriş ekranında **Kayıt ol** vardır (ad, şirket, telefon, e-posta, şifre). Kayıt olan kişi hiçbir veri göremez;
"Hesabınız onay bekliyor" ekranını görür. Platform yöneticisi **Yönetim** sekmesinde onay bekleyenleri görür,
**Ekip**'te kişinin kayıtta yazdığı ad/şirket/telefonla birlikte alanını ve rolünü seçerek onaylar.

Supabase'de bir kez:
1. Authentication > Sign In / Providers > **Allow new users to sign up** açık olmalı. **Confirm email** açık kalsın (sahte adreslerle kayıt engellenir).
2. Authentication > URL Configuration > **Site URL** = `https://panel.vitrinweb.com.tr` (doğrulama e-postasındaki bağlantı buraya döner).
3. Supabase'in yerleşik e-posta servisi saatte birkaç e-postayla sınırlıdır; kayıt artarsa Authentication > SMTP Settings'ten kendi e-posta servisinizi bağlayın.

## Yönetim (yalnızca Vitrin yöneticileri)

**Yönetim** sekmesi yalnızca platform (Vitrin) yöneticilerine görünür; müşteri şirketler göremez. Seçilen ay için:
Google çağrısı ve tahmini maliyeti (çağrı başına ~0,035 $, `google_cost_per_call()` fonksiyonundan değiştirilir), bulunan işletme,
işlem, tarama, aktif/toplam kullanıcı, kayıtlı satış; **şirket bazında** ve **kişi bazında** kullanım; onay bekleyenler.
Alan (şirket) açma, kota ve demo ayarı da buradadır. Panelde yapay zekâ olmadığı için token harcaması yoktur.

## Çalışma alanları (şirketler)

* Her şirket bir **alandır**. Vitrin **platform** alanıdır: yöneticileri yeni alan açar, kullanıcıları alanlara atar, kota ve demo durumunu değiştirir.
* Bir kullanıcı tek bir alana aittir. İşletmeler, aramalar, müşteriler, satışlar, tarama geçmişi ve raporlar **alana özeldir**;
  bu kural veritabanında (satır düzeyinde güvenlik ve fonksiyon kontrolleri) zorunludur, arayüzde gizlemeye dayanmaz.
* Aynı işletme iki farklı alanda ayrı ayrı bulunabilir; bir alanın taraması diğerini etkilemez.
* **Demo** alanda üstte "Demo sürüm" şeridi, paketler ve geri bildirim bağlantısı görünür; paket içerikleri kilitlidir.
* **Aylık kota:** alanın bir ayda taramayla kaydedebileceği en çok işletme sayısı (pilot: 500). Kota dolunca tarama durur,
  ay başında yenilenir. Kotanın son kısmında en yüksek öncelikli işletmeler alınır.

## Roller

Kullanıcıyı **Supabase > Authentication > Users > Add user** ile siz eklersiniz (kayıt kapalıdır). **Rolü olmayan kimse hiçbir veri göremez.**

| Rol | Görür / yapar |
|---|---|
| **Yönetici** | Her şey: listeler, tarama, müşteriler, raporlar, ekip ve alan ayarları |
| **Satış** | Listeler, tarama, müşteriler, raporlar. Ekip ve ayarları görmez |
| **Operasyon** | Yalnızca müşteriler (aşama, satış, not). Listeleri ve taramayı göremez |

Bir alanın son yöneticisi kaldırılamaz, düşürülemez ya da başka alana taşınamaz.

## Panel

Telefonda alt gezinme çubuğu, bilgisayarda üst menü. İlk girişte altta kısa bir tanıtım çıkar; üstteki **?** ile tekrar açılır.

* **Liste** (WhatsApp / Arama / Takip / Gönderildi): her seferinde tek işletme. WhatsApp'tan yaz ya da ara, sonucu işaretle.
  İki kişi aynı anda çalışabilir: açılan kart 15 dk kilitlenir. "İlgilenmiyor" derken **sebep** seçilir (raporda görünür).
  Kısayollar (masaüstü): `W` WhatsApp, `S` atla, `N` not.
* **Müşteriler:** "İlgilendi" denen işletme **İletişimde**, "Satış oldu" denen **Satış tamamlandı** aşamasıyla otomatik düşer; elle de eklenir.
  Aşamalar: İletişimde → Anlaşma aşamasında → Satış tamamlandı. Her müşteride **satış kalemleri** (ürün/hizmet, adet, toplam tutar),
  sıradaki adım, notlar ve tam geçmiş tutulur. Satış eklenince müşteri Satış tamamlandı'ya geçer.
* **Tara:** şehir, ilçe, sektör (önerilerden seç ya da kendin yaz). **Filtreler isteğe bağlıdır:** en az Google puanı, yorum sayısı aralığı,
  açık olunması gereken günler. Filtre seçilmezse yalnızca kapalı (geçici/kalıcı) işletmeler ve telefonu olmayanlar atlanır.
* **Raporlar:** ay seçilir; ulaşılan işletme, olumlu, red, satış, ulaşılamayan, WhatsApp, satış tutarı, bulunan işletme,
  red sebepleri, sektör/kişi/ürün dağılımı. Altında aranabilir işlem geçmişi.
* **Ekip:** roller; **Ayarlar** (şirket adı, haftalık hedef, günlük WhatsApp sınırı, sektör önerileri, WhatsApp şablonu);
  **Paket**; **Notlar** (aydınlatma metni taslağı).
* **WhatsApp şablonu** alan ayarıdır; `{isim}` işletme adıyla değişir. Boşsa sohbet boş açılır. Şablon yazılırsa içinde "iptal"
  yazarak vazgeçme cümlesi bulunması zorunludur (sunucu da denetler).

## 30 gün kuralı

Hiç işlenmemiş (aranmamış, yazılmamış) işletme kaydı 30 gün sonra listeden düşer ve silinir. İşlenen kayıtlar
(arandı, açmadı, sonra aranacak, WhatsApp gönderildi, ilgilendi, reddetti…) kalır.

## Panelden tarama (kurulum, bir kez)

1. Supabase > **Edge Functions** > **Deploy a new function** > **Via Editor**. Ad: `scan`. `supabase/functions/scan/index.ts` dosyasının tamamını yapıştırın, **Deploy**.
2. Fonksiyonun **Settings** bölümünde **Verify JWT** seçeneğini **kapatın**. Giriş kontrolünü fonksiyonun kendisi yapar.
3. Supabase > Edge Functions > **Secrets**: `GOOGLE_API_KEY` = Google Places anahtarınız.
4. Google anahtarını Places API ile kısıtlayın; Google Cloud > Faturalama > **Bütçeler ve uyarılar** bölümünden bütçe uyarısı kurun.

* **Günlük sınır:** her alan için günde en çok **60** Google çağrısı (≈20 bölge). Değiştirmek için `MAX_CALLS_PER_DAY` secret'ı.
* **Başka alan adı:** paneli başka adresten açacaksanız `ALLOWED_ORIGINS` secret'ına ekleyin (virgülle).
* Aynı bölge+sektör **90 gün** tekrar taranmaz ("yeniden tara" ile zorlanır). Vitrin alanında Bursa kapalı bölgedir.
* Her kayda 0–100 **öncelik** verilir (Google puanı, yorum sayısı, cep telefonu); liste yüksek öncelikliyi önce gösterir.
* **Maliyet:** tarama "Text Search Enterprise" çağrısıdır (bir çağrı ≈ 20 sonuç). Güncel fiyat için Google Maps Platform fiyat sayfasına bakın.

## Güvenlik

* Panele yalnızca *publishable* anahtar konur; secret anahtar hiçbir dosyada yoktur.
* Tarayıcı veritabanını yalnızca **kendi alanı kadar** okuyabilir; her yazma `log_call`, `add_sale` vb. fonksiyonlarla olur.
* Site `noindex`, çerçevelenemez, sıkı CSP ile yayınlanır; `supabase-js` sürümü sabit ve bütünlük (SRI) denetimli.
* Tarama servisi yalnızca giriş yapmış ve **tarama izni olan** kullanıcıyı kabul eder, kullanıcının alanına yazar, kota ve günlük sınır uygular.

## Testler

```bash
node --test tests/scan_edge.test.mjs                 # tarama servisi (Node 22+)
node tests/panel.e2e.mjs                             # panel, gerçek tarayıcıda (playwright gerekir)
#   ekran görüntüsü: SHOTS=klasör  ·  masaüstü: VIEW=1280x860  ·  tarayıcı yolu: CHROMIUM=/yol/chrome
#   erişilebilirlik taraması: AXE=node_modules/axe-core/axe.min.js (npm i axe-core)
PGHOST=... PGUSER=postgres tests/run_sql_tests.sh    # şema, alan ayrımı, iş kuralları ve yükseltmeler, boş bir Postgres'e karşı
```

`tests/fixtures/schema_v1.sql`, canlıdaki önceki şemadır; ondan yükseltmenin veriyi koruduğu test edilir.

## Hukuki not

* Google Maps Platform şartları Places içeriğinin (ad, telefon, puan…) saklanmasına izin vermez; süresiz saklanabilen yalnızca `place_id`'dir.
  Pilot bu bilinçle mevcut yöntemle yürür; ücretli sürüme geçerken "kart açılınca anlık çekme" modeline geçilecektir.
* Cep numaralarına ticari ileti göndermek KVKK ve İYS (6563 sayılı Kanun) kapsamına girebilir. Aydınlatma metni taslağı
  `docs/AYDINLATMA_METNI.md`'dedir ve hukukçu onayı bekler; sorulacak sorular dosyanın sonundadır.
