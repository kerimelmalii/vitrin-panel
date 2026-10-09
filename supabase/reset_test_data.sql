-- DENEME VERİSİNİ SİLER (Ankara/Çankaya kuaför denemesi gibi).
-- Gerçek müşteri taramasından ÖNCE bir kez çalıştırın. Geri alınamaz.
-- Kapalı bölgeler (Bursa) korunur; işletme, arama ve tarama geçmişi silinir.
begin;
delete from public.calls;
delete from public.businesses;
delete from public.scan_history;
commit;
