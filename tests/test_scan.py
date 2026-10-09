import base64, io, json, os, sys, unittest
from contextlib import redirect_stdout
from unittest import mock
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import scan


def place(**kw):
    p = {"id": "pid1", "displayName": {"text": "Güzel Kuaför"}, "formattedAddress": "Kızılay Mah, Çankaya/Ankara, Türkiye",
         "nationalPhoneNumber": "0532 111 22 33", "rating": 4.7, "userRatingCount": 80, "googleMapsUri": "https://maps.google.com/?cid=1",
         "businessStatus": "OPERATIONAL"}
    p.update(kw)
    return p


class Title(unittest.TestCase):
    def test_tr_title(self):
        self.assertEqual(scan.tr_title("çankaya"), "Çankaya")
        self.assertEqual(scan.tr_title("ISPARTA"), "Isparta")
        self.assertEqual(scan.tr_title("iğdır merkez"), "İğdır Merkez")
        self.assertEqual(scan.tr_title("İZMİR"), "İzmir")


class Fixtures(unittest.TestCase):
    """Edge Function (TypeScript) ile aynı sonuçları vermek zorunda: ortak test verisi."""
    cases = json.load(open(os.path.join(os.path.dirname(__file__), "scan_cases.json"), encoding="utf-8"))

    def test_phones(self):
        for raw, exp in self.cases["phones"]:
            self.assertEqual(scan.normalize_phone(raw), exp, raw)

    def test_websites(self):
        for uri, exp in self.cases["websites"]:
            self.assertEqual(scan.classify_website(uri), exp, uri)

    def test_scores(self):
        for r, n, w, m, exp in self.cases["scores"]:
            self.assertEqual(scan.lead_score(r, n, w, m), exp, (r, n, w, m))

    def test_places(self):
        for k in self.cases["places"]:
            row, why = scan.place_to_row(place(**k["place"]), k["city"], k["district"], k["sector"])
            if k.get("ok"):
                self.assertIsNotNone(row, (k["name"], why))
            else:
                self.assertIsNone(row, k["name"])
                self.assertEqual(why, k["why"], k["name"])
            if row and "phone" in k:
                self.assertEqual(row["phone_normalized"], k["phone"])
            if row and "website" in k:
                self.assertEqual(row["website_status"], k["website"])


class Phone(unittest.TestCase):
    def test_formats(self):
        for raw in ("0532 111 22 33", "+90 532 111 22 33", "(0532) 111-22-33", "5321112233", "00905321112233"):
            self.assertEqual(scan.normalize_phone(raw), "+905321112233", raw)
        self.assertEqual(scan.normalize_phone("(0312) 123 45 67"), "+903121234567")

    def test_invalid(self):
        for raw in (None, "", "444 1 234", "0850 123 45 67", "0800 123 45 67", "123", "0532 111 22"):
            self.assertIsNone(scan.normalize_phone(raw), raw)

    def test_mobile(self):
        self.assertTrue(scan.is_mobile("+905321112233"))
        self.assertFalse(scan.is_mobile("+903121234567"))
        self.assertFalse(scan.is_mobile(None))


class Website(unittest.TestCase):
    def test_classify(self):
        c = scan.classify_website
        self.assertEqual(c(None), "none")
        self.assertEqual(c(""), "none")
        self.assertEqual(c("https://www.instagram.com/guzelkuafor"), "social_only")
        self.assertEqual(c("https://m.facebook.com/x"), "social_only")
        self.assertEqual(c("http://linktr.ee/x"), "social_only")
        self.assertEqual(c("https://guzelkuafor.com"), "has_site")
        self.assertEqual(c("https://notinstagram.com"), "has_site")   # sonek tuzağı
        self.assertEqual(c("https://fakex.com"), "has_site")


class Filter(unittest.TestCase):
    def row(self, **kw):
        return scan.place_to_row(place(**kw), "Ankara", "Çankaya", "kuaför")

    def test_ok(self):
        r, why = self.row()
        self.assertIsNone(why)
        self.assertEqual((r["phone_normalized"], r["website_status"], r["city"], r["district"]), ("+905321112233", "none", "Ankara", "Çankaya"))
        self.assertTrue(0 <= r["lead_score"] <= 100)

    def test_rejects(self):
        cases = {"puan düşük": dict(rating=4.2), "yorum aralık dışı": dict(userRatingCount=9),
                 "yorum aralık dışı ": dict(userRatingCount=301), "sitesi var": dict(websiteUri="https://x.com.tr"),
                 "telefon yok/geçersiz": dict(nationalPhoneNumber=None), "kapalı": dict(businessStatus="CLOSED_PERMANENTLY"),
                 "bölge dışı": dict(formattedAddress="Moda, Kadıköy/İstanbul, Türkiye"), "puan yok": dict(rating=None)}
        for why, kw in cases.items():
            r, got = self.row(**kw)
            self.assertIsNone(r, why)
            self.assertEqual(got, why.strip())

    def test_boundaries(self):
        for kw in (dict(rating=4.3), dict(userRatingCount=10), dict(userRatingCount=300)):
            self.assertIsNotNone(self.row(**kw)[0], kw)

    def test_social_only_allowed(self):
        r, _ = self.row(websiteUri="https://instagram.com/x")
        self.assertEqual(r["website_status"], "social_only")

    def test_turkish_case_district(self):
        r, _ = scan.place_to_row(place(formattedAddress="X Cd, ÇANKAYA/ANKARA, Türkiye"), "Ankara", "Çankaya", "kuaför")
        self.assertIsNotNone(r)
        r, _ = scan.place_to_row(place(formattedAddress="X Cd, Bornova/İZMİR"), "İzmir", "Bornova", "kuaför")
        self.assertIsNotNone(r)

    def test_score_order(self):
        hi = scan.lead_score(5.0, 150, "none", True)
        lo = scan.lead_score(4.3, 10, "social_only", False)
        self.assertGreater(hi, lo)
        self.assertEqual(hi, 100)


class Rules(unittest.TestCase):
    def test_closed_region(self):
        closed = [{"city": "Bursa", "district": None}, {"city": "İzmir", "district": "Konak"}]
        self.assertTrue(scan.region_closed(closed, "BURSA", "Nilüfer"))
        self.assertTrue(scan.region_closed(closed, "izmir", "KONAK"))
        self.assertFalse(scan.region_closed(closed, "İzmir", "Bornova"))

    def test_recent_scan(self):
        now = scan.datetime.now(scan.timezone.utc)
        hist = [{"city": "Ankara", "district": "Çankaya", "sector": "kuaför", "scanned_at": (now - scan.timedelta(days=30)).isoformat()}]
        self.assertTrue(scan.recently_scanned(hist, "ankara", "ÇANKAYA", "Kuaför"))
        self.assertFalse(scan.recently_scanned(hist, "Ankara", "Keçiören", "kuaför"))

    def test_secret_key_check(self):
        mk = lambda role: "h." + base64.urlsafe_b64encode(json.dumps({"role": role}).encode()).decode().rstrip("=") + ".s"
        self.assertTrue(scan.is_secret_key(mk("service_role")))
        self.assertFalse(scan.is_secret_key(mk("anon")))
        self.assertFalse(scan.is_secret_key("sb_publishable_abc"))
        self.assertTrue(scan.is_secret_key("sb_secret_abc"))


class Flow(unittest.TestCase):
    """main() akışı: sahte Google + sahte Supabase."""
    def run_main(self, argv, history=(), closed=(), pages=None):
        pages = pages or [{"places": [place(id="a"), place(id="b", nationalPhoneNumber="0533 222 33 44", rating=3.0)]}]
        calls = {"places": 0, "rpc": [], "hist": []}

        def fake_search(key, q, token=None):
            calls["places"] += 1
            return pages[min(calls["places"] - 1, len(pages) - 1)]

        class FakeSupa:
            def __init__(self, *a): pass
            def get(self, path): return list(closed) if "closed_regions" in path else list(history)
            def rpc(self, fn, args): calls["rpc"].append(args["p_rows"]); return len(args["p_rows"])
            def insert(self, table, row): calls["hist"].append(row)

        env = {"GOOGLE_API_KEY": "g", "SUPABASE_URL": "https://x.supabase.co", "SUPABASE_SERVICE_KEY": "sb_secret_x"}
        buf = io.StringIO()
        with mock.patch.object(scan, "search_text", fake_search), mock.patch.object(scan, "Supa", FakeSupa), \
             mock.patch.object(scan, "load_env_file"), mock.patch.dict(os.environ, env), redirect_stdout(buf):
            scan.main(argv)
        return calls, buf.getvalue()

    def test_saves_only_passing(self):
        calls, out = self.run_main(["--city", "Ankara", "--districts", "Çankaya", "--sectors", "kuaför"])
        self.assertEqual(len(calls["rpc"]), 1)
        self.assertEqual([r["place_id"] for r in calls["rpc"][0]], ["a"])
        self.assertEqual(calls["hist"][0]["saved"], 1)
        self.assertEqual(calls["places"], 1)

    def test_dry_run_writes_nothing(self):
        calls, _ = self.run_main(["--city", "Ankara", "--districts", "Çankaya", "--sectors", "kuaför", "--dry-run"])
        self.assertEqual((calls["rpc"], calls["hist"]), ([], []))

    def test_skips_closed_and_recent(self):
        now = scan.datetime.now(scan.timezone.utc).isoformat()
        calls, out = self.run_main(["--city", "Bursa", "--districts", "Nilüfer", "--sectors", "kuaför"], closed=[{"city": "Bursa", "district": None}])
        self.assertEqual(calls["places"], 0); self.assertIn("KAPALI", out)
        hist = [{"city": "Ankara", "district": "Çankaya", "sector": "kuaför", "scanned_at": now}]
        calls, out = self.run_main(["--city", "Ankara", "--districts", "Çankaya", "--sectors", "kuaför"], history=hist)
        self.assertEqual(calls["places"], 0)
        calls, out = self.run_main(["--city", "Ankara", "--districts", "Çankaya", "--sectors", "kuaför", "--force"], history=hist)
        self.assertEqual(calls["places"], 1)

    def test_budget_and_paging(self):
        full = {"places": [place(id=f"p{i}", nationalPhoneNumber=f"053{i%10} 111 22 3{i%10}") for i in range(20)], "nextPageToken": "t"}
        calls, _ = self.run_main(["--city", "Ankara", "--districts", "Çankaya", "--sectors", "kuaför", "--max-pages", "5", "--max-queries", "2"], pages=[full])
        self.assertEqual(calls["places"], 2)   # bütçe 2'de durdurur


if __name__ == "__main__":
    unittest.main()
