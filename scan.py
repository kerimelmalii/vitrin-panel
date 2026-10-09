#!/usr/bin/env python3
"""Vitrin Web – işletme tarama scripti (Google Places API (New) -> Supabase).

Web sitesi olmayan (ya da sadece sosyal medyası olan), puanı yüksek küçük işletmeleri
şehir / ilçe / sektör bazında bulur ve Supabase'e yazar.

Kullanım:
  export GOOGLE_API_KEY=...            # kısıtlı Places API anahtarı
  export SUPABASE_URL=https://xxxx.supabase.co
  export SUPABASE_SERVICE_KEY=...      # SECRET (service_role) anahtar – sadece bu Mac'te kalsın
  python3 scan.py --city Ankara --districts "Çankaya,Keçiören" --sectors "kuaför,diş hekimi" --dry-run
  python3 scan.py --city Ankara --districts "Çankaya" --sectors "kuaför"

Anahtarlar ortam değişkeninden ya da bu klasördeki .env dosyasından (git'e girmez) okunur.
Sadece Python standart kütüphanesi kullanılır; kurulum gerekmez.
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

PLACES_URL = "https://places.googleapis.com/v1/places:searchText"
FIELD_MASK = ",".join([
    "places.id", "places.displayName", "places.formattedAddress", "places.nationalPhoneNumber",
    "places.internationalPhoneNumber", "places.rating", "places.userRatingCount", "places.websiteUri",
    "places.googleMapsUri", "places.businessStatus", "nextPageToken",
])

# Filtre eşikleri
MIN_RATING = 4.3
MIN_REVIEWS = 10
MAX_REVIEWS = 300
RESCAN_DAYS = 90
PAGE_SIZE = 20

SOCIAL_HOSTS = (
    "instagram.com", "facebook.com", "fb.com", "fb.me", "linktr.ee", "wa.me", "whatsapp.com",
    "tiktok.com", "twitter.com", "x.com", "youtube.com", "youtu.be", "t.me", "beacons.ai",
    "taplink.cc", "linkin.bio", "sahibinden.com",
)


# ---------------------------------------------------------------- yardımcılar
def tr_lower(s):
    """Türkçe'ye uygun küçük harf (İ->i, I->ı)."""
    return (s or "").replace("İ", "i").replace("I", "ı").lower()


def tr_title(s):
    """Her kelimenin ilk harfi Türkçe kurallarıyla büyük: 'çankaya' -> 'Çankaya'."""
    out = []
    for w in tr_lower(s).split():
        first = "İ" if w[0] == "i" else "I" if w[0] == "ı" else w[0].upper()
        out.append(first + w[1:])
    return " ".join(out)


def normalize_phone(raw):
    """Türkiye numarasını +90XXXXXXXXXX biçimine çevirir; geçersizse None."""
    digits = "".join(ch for ch in (raw or "") if ch.isdigit())
    if digits.startswith("00"):
        digits = digits[2:]
    if digits.startswith("90") and len(digits) == 12:
        pass
    elif digits.startswith("0") and len(digits) == 11:
        digits = "90" + digits[1:]
    elif len(digits) == 10:
        digits = "90" + digits
    else:
        return None
    # 2xx/3xx/4xx sabit hat, 5xx cep. 0850/0800 gibi servis numaraları elenir.
    if digits[2] not in "2345":
        return None
    return "+" + digits


def is_mobile(phone):
    return bool(phone) and phone.startswith("+905") and len(phone) == 13


def classify_website(uri):
    """'none' | 'social_only' | 'has_site'"""
    if not uri:
        return "none"
    host = urllib.parse.urlparse(uri if "//" in uri else "//" + uri).hostname or ""
    host = host.lower()
    if host.startswith("www."):
        host = host[4:]
    if any(host == h or host.endswith("." + h) for h in SOCIAL_HOSTS):
        return "social_only"
    return "has_site"


def lead_score(rating, reviews, website_status, mobile):
    """0-100: iyi puan, yeterli yorum, sitesi hiç yok, WhatsApp'tan ulaşılabilir."""
    s = max(0.0, min(1.0, (rating - MIN_RATING) / (5.0 - MIN_RATING))) * 30
    s += min(reviews, 150) / 150 * 30
    s += 25 if website_status == "none" else 15
    s += 15 if mobile else 0
    return int(s + 0.5)   # yarıyı yukarı yuvarla (TypeScript sürümüyle aynı sonuç)


def place_to_row(place, city, district, sector):
    """Filtrelerden geçerse satır sözlüğü, geçemezse (None, neden)."""
    if place.get("businessStatus") not in (None, "OPERATIONAL"):
        return None, "kapalı"
    rating, reviews = place.get("rating"), place.get("userRatingCount")
    if rating is None or reviews is None:
        return None, "puan yok"
    if rating < MIN_RATING:
        return None, "puan düşük"
    if not (MIN_REVIEWS <= reviews <= MAX_REVIEWS):
        return None, "yorum aralık dışı"
    status = classify_website(place.get("websiteUri"))
    if status == "has_site":
        return None, "sitesi var"
    raw_phone = place.get("nationalPhoneNumber") or place.get("internationalPhoneNumber")
    phone = normalize_phone(raw_phone)
    if not phone:
        return None, "telefon yok/geçersiz"
    addr = place.get("formattedAddress") or ""
    addr_l = tr_lower(addr)
    if tr_lower(city) not in addr_l or (district and tr_lower(district) not in addr_l):
        return None, "bölge dışı"
    name = (place.get("displayName") or {}).get("text") or ""
    if not name or not place.get("id"):
        return None, "ad yok"
    return {
        "place_id": place["id"], "name": name, "address": addr, "city": city, "district": district or None,
        "sector": sector, "phone_raw": raw_phone, "phone_normalized": phone, "rating": rating,
        "review_count": reviews, "website_status": status, "maps_url": place.get("googleMapsUri"),
        "lead_score": lead_score(rating, reviews, status, is_mobile(phone)),
    }, None


def is_secret_key(key):
    """Publishable/anon anahtarını reddeder (yanlış anahtarla tarama sessizce başarısız olmasın)."""
    if key.startswith("sb_publishable"):
        return False
    if key.count(".") == 2:  # eski tip JWT anahtarlar: role alanına bak
        try:
            payload = key.split(".")[1]
            payload += "=" * (-len(payload) % 4)
            return json.loads(base64.urlsafe_b64decode(payload)).get("role") == "service_role"
        except Exception:
            return False
    return True


def load_env_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    except FileNotFoundError:
        pass


# ---------------------------------------------------------------- HTTP
def http_json(url, method="GET", headers=None, body=None, retries=3):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            if e.code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                time.sleep(2 ** (attempt + 1))
                continue
            raise RuntimeError(f"HTTP {e.code} {urllib.parse.urlparse(url).netloc}: {detail}") from None
        except urllib.error.URLError as e:
            if attempt < retries - 1:
                time.sleep(2 ** (attempt + 1))
                continue
            raise RuntimeError(f"Ağ hatası: {e.reason}") from None


class Supa:
    def __init__(self, url, key):
        self.base = url.rstrip("/") + "/rest/v1"
        self.h = {"apikey": key, "Authorization": "Bearer " + key}

    def get(self, path):
        return http_json(self.base + path, headers=self.h) or []

    def rpc(self, fn, args):
        return http_json(f"{self.base}/rpc/{fn}", "POST", self.h, args)

    def insert(self, table, row):
        http_json(f"{self.base}/{table}", "POST", {**self.h, "Prefer": "return=minimal"}, row)


def search_text(api_key, query, page_token=None):
    body = {"textQuery": query, "languageCode": "tr", "regionCode": "TR", "pageSize": PAGE_SIZE}
    if page_token:
        body["pageToken"] = page_token
    return http_json(PLACES_URL, "POST", {"X-Goog-Api-Key": api_key, "X-Goog-FieldMask": FIELD_MASK}, body) or {}


# ---------------------------------------------------------------- ana akış
def region_closed(closed, city, district):
    for c in closed:
        if tr_lower(c["city"]) == tr_lower(city) and (not c.get("district") or tr_lower(c["district"]) == tr_lower(district or "")):
            return c
    return None


def recently_scanned(history, city, district, sector, days=RESCAN_DAYS):
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    for h in history:
        if (tr_lower(h["city"]) == tr_lower(city) and tr_lower(h["district"] or "") == tr_lower(district or "")
                and tr_lower(h["sector"]) == tr_lower(sector)
                and datetime.fromisoformat(h["scanned_at"].replace("Z", "+00:00")) >= cutoff):
            return h
    return None


def scan_unit(api_key, city, district, sector, max_pages, budget):
    """Bir şehir/ilçe/sektör için sayfaları gezer. (satırlar, bulunan, api_çağrısı, nedenler) döner."""
    query = " ".join(x for x in (sector, district, city) if x)
    rows, seen, found, calls, reasons, token = [], set(), 0, 0, {}, None
    for _ in range(max_pages):
        if budget["left"] <= 0:
            print("  ! API çağrı limiti doldu, durduruluyor.")
            break
        budget["left"] -= 1
        calls += 1
        resp = search_text(api_key, query, token)
        places = resp.get("places", [])
        found += len(places)
        for p in places:
            row, why = place_to_row(p, city, district, sector)
            if row and row["place_id"] not in seen:
                seen.add(row["place_id"])
                rows.append(row)
            elif why:
                reasons[why] = reasons.get(why, 0) + 1
        token = resp.get("nextPageToken")
        if not token or len(places) < PAGE_SIZE:
            break
    return rows, found, calls, reasons


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--city", required=True)
    ap.add_argument("--districts", default="", help="virgülle ayrılmış ilçeler (boşsa tüm şehir tek sorgu)")
    ap.add_argument("--sectors", required=True, help="virgülle ayrılmış sektörler")
    ap.add_argument("--max-pages", type=int, default=3, help="sorgu başına sayfa (her sayfa 20 sonuç, 1 API çağrısı)")
    ap.add_argument("--max-queries", type=int, default=30, help="toplam API çağrısı üst sınırı (bütçe koruması)")
    ap.add_argument("--dry-run", action="store_true", help="Supabase'e yazma; sadece neyin bulunacağını göster")
    ap.add_argument("--force", action="store_true", help="90 gün kuralını yok say")
    a = ap.parse_args(argv)

    load_env_file(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
    api_key = os.environ.get("GOOGLE_API_KEY", "")
    sb_url = os.environ.get("SUPABASE_URL", "")
    sb_key = os.environ.get("SUPABASE_SERVICE_KEY", "")
    if not api_key or not sb_url or not sb_key:
        sys.exit("GOOGLE_API_KEY, SUPABASE_URL ve SUPABASE_SERVICE_KEY tanımlı olmalı (.env.example'a bak).")
    if not sb_url.startswith("https://"):
        sys.exit("SUPABASE_URL https:// ile başlamalı.")
    if not is_secret_key(sb_key):
        sys.exit("SUPABASE_SERVICE_KEY yerine publishable/anon anahtarı girilmiş; secret (service_role) anahtar gerekli.")

    supa = Supa(sb_url, sb_key)
    closed = supa.get("/closed_regions?select=city,district")
    since = (datetime.now(timezone.utc) - timedelta(days=RESCAN_DAYS)).isoformat()
    history = supa.get("/scan_history?select=city,district,sector,scanned_at&scanned_at=gte." + urllib.parse.quote(since))

    # Panelle aynı yazım: filtrelerde aynı şehir/ilçe/sektör iki kez görünmesin
    a.city = tr_title(a.city)
    districts = [tr_title(d) for d in a.districts.split(",") if d.strip()] or [""]
    sectors = [tr_lower(s.strip()) for s in a.sectors.split(",") if s.strip()]
    budget = {"left": a.max_queries}
    total_saved = total_found = total_calls = 0

    for district in districts:
        label_d = district or "(tüm şehir)"
        c = region_closed(closed, a.city, district)
        if c:
            print(f"- {a.city}/{label_d}: KAPALI BÖLGE, atlandı.")
            continue
        for sector in sectors:
            if not a.force and recently_scanned(history, a.city, district, sector):
                print(f"- {a.city}/{label_d}/{sector}: {RESCAN_DAYS} gün içinde taranmış, atlandı (--force ile zorla).")
                continue
            if budget["left"] <= 0:
                print("API çağrı limiti doldu; kalan bölgeler taranmadı.")
                break
            print(f"- {a.city}/{label_d}/{sector}: taranıyor…")
            rows, found, calls, reasons = scan_unit(api_key, a.city, district, sector, a.max_pages, budget)
            total_found += found
            total_calls += calls
            saved = 0
            if rows and not a.dry_run:
                saved = int(supa.rpc("ingest_businesses", {"p_rows": rows}) or 0)
            if not a.dry_run and calls:
                supa.insert("scan_history", {"city": a.city, "district": district, "sector": sector,
                                             "places_found": found, "saved": saved, "api_calls": calls})
            total_saved += saved
            why = ", ".join(f"{k}: {v}" for k, v in sorted(reasons.items(), key=lambda x: -x[1]))
            print(f"  Google {found} işletme döndürdü, {len(rows)} uygun, {saved} yeni kaydedildi"
                  f"{' (dry-run, yazılmadı)' if a.dry_run else ''}. Elenenler -> {why or '-'}")
            if a.dry_run:
                for r in rows[:5]:
                    print(f"    · {r['name']} | {r['phone_normalized']} | {r['rating']}★ {r['review_count']} | {r['website_status']} | skor {r['lead_score']}")
    print(f"\nÖzet: {total_found} bulundu, {total_saved} yeni kaydedildi, {total_calls} API çağrısı yapıldı.")


if __name__ == "__main__":
    main()
