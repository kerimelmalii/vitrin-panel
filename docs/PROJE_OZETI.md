# Proje özeti ve durum (Ekim 2026)

**Amaç:** Vitrin Web için müşteri bulma ve arama sistemi (bkz. README.md).

## Durum
- Tamam: şema (`supabase/schema.sql`), tarama scripti, panelden tarama (Edge Function), yeniden tasarlanan panel (açık/koyu tema, üç liste, Tara sekmesi), otomatik testler, güvenli yayın düzeni.
- Sizde yapılacak: şemayı Supabase'te çalıştırmak, `reset_test_data.sql`, `.env` doldurmak, dalı `main`'e almak (Vercel yayını), Google bütçe uyarısı, gerçek bölge taraması, arkadaşınızla deneme araması.
- Dikkat: Google deneme kredisi 5 Ocak 2027'de bitiyor. KVKK/İYS için hukukçu görüşü alın. WhatsApp elle ve düşük hacimde (günde ~25).
- Açık nokta: panelin `SUPABASE_URL` değeri ile şemayı çalıştırdığınız proje aynı olmalı.
