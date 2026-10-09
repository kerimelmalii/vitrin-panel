-- DENEME VERİSİNİ SİLER (Ankara/Çankaya kuaför denemesi gibi).
-- Gerçek müşteri taramasından ÖNCE bir kez çalıştırın. Geri alınamaz.
-- Kapalı bölgeler (Bursa), roller ve elle eklenen müşteriler korunur; işletme, arama, tarama geçmişi ve
-- işletmelerden doğan müşteriler silinir.
begin;
-- İşletmelerden doğan müşteriler (ve notları) da test verisidir; elle eklenen müşteriler (işletmesi olmayan) korunur.
delete from public.customers where business_id is not null;
delete from public.calls;
delete from public.businesses;
delete from public.scan_history;
commit;
