# Proje özeti ve durum (Kasım 2026)

**Yön:** Vitrin, web sitesi hizmetini bıraktı; dijital çözümler sunan bir ajansa dönüşüyor. Bu panel, ajansın kendi kullandığı
ve diğer şirketlere de sunacağı çözümlerden biri: müşteri bulma (tarama) → arama/WhatsApp → müşteri takibi → satış → aylık rapor.

## Durum
- **Tamam:** çok şirketli yapı (çalışma alanları, veritabanında zorunlu ayrım), demo sürüm (şerit, paketler, kota), site hizmeti
  izlerinin kaldırılması, isteğe bağlı tarama filtreleri (puan, yorum, çalışma günü), ret sebepleri, satış kalemleri (ürün/adet/tutar),
  sade müşteri aşamaları, aylık rapor, 30 gün kuralı, ilk giriş tanıtımı, alan ayarları (şablon, sektörler, hedef), aydınlatma metni taslağı.
- **Pilot:** demo alan, aylık 500 işletme kotası. Kurulum adımları README > "Bu sürüme geçiş".
- **Paketler (taslak):** Başlangıç 500 TL, Standart 1.000 TL, Profesyonel 2.000 TL / ay. İçerikleri henüz belirlenmedi (demo'da kilitli görünür).

## Sonraya kalanlar
- Ücretli sürüm: Google şartlarına uygun "yalnızca `place_id` sakla, kart açılınca anlık çek" modeli; kart başına kredi.
- Sales Pilot ile birleştirme.
- Ödeme altyapısı (iyzico/PayTR) ve e-fatura; Vercel ve Supabase'in ücretli planları (ticari kullanım).
- Açık veri kaynaklarından içe aktarma (belediye portalları vb.).

## Dikkat
- Google deneme kredisi 5 Ocak 2027'de bitiyor; Google Cloud'da bütçe uyarısı ve günlük kota sınırı kurulmalı.
- KVKK/İYS ve Google şartları için hukukçu görüşü (sorular `docs/AYDINLATMA_METNI.md` sonunda).
- WhatsApp elle ve düşük hacimde (günde ~20).
