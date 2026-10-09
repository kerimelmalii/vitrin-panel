// Vitrin Web – panelden tarama (Supabase Edge Function, tek dosya, dış bağımlılık yok).
//
// Panel giriş yapmış kullanıcının kimliğiyle bu fonksiyonu çağırır; fonksiyon Google Places'ı sorgular,
// filtreler ve Supabase'e yazar. Google anahtarı yalnızca burada (Supabase gizli anahtarı) durur.
//
// Gerekli gizli anahtar : GOOGLE_API_KEY
// Opsiyonel             : MAX_CALLS_PER_DAY (varsayılan 60), ALLOWED_ORIGINS (virgülle; varsayılan panel adresi),
//                         SCAN_SERVICE_KEY (platform service_role anahtarını sağlamıyorsa)
// Otomatik gelenler     : SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// Mantık scan.py ile aynıdır; ortak test verisi: tests/scan_cases.json.

declare const Deno: any;

// ------------------------------------------------------------------ sabitler
const PLACES_URL = "https://places.googleapis.com/v1/places:searchText";
const FIELD_MASK = [
  "places.id", "places.displayName", "places.formattedAddress", "places.nationalPhoneNumber",
  "places.internationalPhoneNumber", "places.rating", "places.userRatingCount", "places.websiteUri",
  "places.googleMapsUri", "places.businessStatus", "nextPageToken",
].join(",");
export const MIN_RATING = 4.3;
export const MIN_REVIEWS = 10;
export const MAX_REVIEWS = 300;
export const RESCAN_DAYS = 90;
const PAGE_SIZE = 20;
const MAX_PAGES = 3;
const DEFAULT_ALLOWED_ORIGINS = ["https://panel.vitrinweb.com.tr"];
const SOCIAL_HOSTS = [
  "instagram.com", "facebook.com", "fb.com", "fb.me", "linktr.ee", "wa.me", "whatsapp.com",
  "tiktok.com", "twitter.com", "x.com", "youtube.com", "youtu.be", "t.me", "beacons.ai",
  "taplink.cc", "linkin.bio", "sahibinden.com",
];
export const PROVINCES = [
  "Adana", "Adıyaman", "Afyonkarahisar", "Ağrı", "Aksaray", "Amasya", "Ankara", "Antalya", "Ardahan", "Artvin",
  "Aydın", "Balıkesir", "Bartın", "Batman", "Bayburt", "Bilecik", "Bingöl", "Bitlis", "Bolu", "Burdur", "Bursa",
  "Çanakkale", "Çankırı", "Çorum", "Denizli", "Diyarbakır", "Düzce", "Edirne", "Elazığ", "Erzincan", "Erzurum",
  "Eskişehir", "Gaziantep", "Giresun", "Gümüşhane", "Hakkari", "Hatay", "Iğdır", "Isparta", "İstanbul", "İzmir",
  "Kahramanmaraş", "Karabük", "Karaman", "Kars", "Kastamonu", "Kayseri", "Kırıkkale", "Kırklareli", "Kırşehir",
  "Kilis", "Kocaeli", "Konya", "Kütahya", "Malatya", "Manisa", "Mardin", "Mersin", "Muğla", "Muş", "Nevşehir",
  "Niğde", "Ordu", "Osmaniye", "Rize", "Sakarya", "Samsun", "Siirt", "Sinop", "Sivas", "Şanlıurfa", "Şırnak",
  "Tekirdağ", "Tokat", "Trabzon", "Tunceli", "Uşak", "Van", "Yalova", "Yozgat", "Zonguldak",
];

// ------------------------------------------------------------------ saf mantık (test edilir)
/** Türkçe'ye uygun küçük harf (İ->i, I->ı). */
export function trLower(s: string | null | undefined): string {
  return (s ?? "").replace(/İ/g, "i").replace(/I/g, "ı").toLowerCase();
}

/** Her kelimenin ilk harfi Türkçe kurallarıyla büyük: "çankaya" -> "Çankaya". */
export function trTitle(s: string): string {
  return trLower(s).trim().split(/\s+/).filter(Boolean).map((w) => {
    const first = w[0] === "i" ? "İ" : w[0] === "ı" ? "I" : w[0].toUpperCase();
    return first + w.slice(1);
  }).join(" ");
}

export function normalizePhone(raw: string | null | undefined): string | null {
  let d = (raw ?? "").replace(/\D/g, "");
  if (d.startsWith("00")) d = d.slice(2);
  if (d.startsWith("90") && d.length === 12) { /* tamam */ }
  else if (d.startsWith("0") && d.length === 11) d = "90" + d.slice(1);
  else if (d.length === 10) d = "90" + d;
  else return null;
  if (!"2345".includes(d[2])) return null;   // 0850/0800 gibi servis numaraları elenir
  return "+" + d;
}

export function isMobile(phone: string | null | undefined): boolean {
  return !!phone && phone.startsWith("+905") && phone.length === 13;
}

export function classifyWebsite(uri: string | null | undefined): "none" | "social_only" | "has_site" {
  if (!uri) return "none";
  let host = "";
  try { host = new URL(uri.includes("//") ? uri : "https://" + uri).hostname.toLowerCase(); } catch { host = ""; }
  if (host.startsWith("www.")) host = host.slice(4);
  return SOCIAL_HOSTS.some((h) => host === h || host.endsWith("." + h)) ? "social_only" : "has_site";
}

export function leadScore(rating: number, reviews: number, website: string, mobile: boolean): number {
  let s = Math.max(0, Math.min(1, (rating - MIN_RATING) / (5.0 - MIN_RATING))) * 30;
  s += Math.min(reviews, 150) / 150 * 30;
  s += website === "none" ? 25 : 15;
  s += mobile ? 15 : 0;
  return Math.floor(s + 0.5);
}

export interface Row {
  place_id: string; name: string; address: string; city: string; district: string | null; sector: string;
  phone_raw: string | null; phone_normalized: string; rating: number; review_count: number;
  website_status: string; maps_url: string | null; lead_score: number;
}

export function placeToRow(place: any, city: string, district: string, sector: string): { row?: Row; why?: string } {
  if (place.businessStatus != null && place.businessStatus !== "OPERATIONAL") return { why: "kapalı" };
  const rating = place.rating, reviews = place.userRatingCount;
  if (rating == null || reviews == null) return { why: "puan yok" };
  if (rating < MIN_RATING) return { why: "puan düşük" };
  if (reviews < MIN_REVIEWS || reviews > MAX_REVIEWS) return { why: "yorum aralık dışı" };
  const website = classifyWebsite(place.websiteUri);
  if (website === "has_site") return { why: "sitesi var" };
  const rawPhone = place.nationalPhoneNumber || place.internationalPhoneNumber || null;
  const phone = normalizePhone(rawPhone);
  if (!phone) return { why: "telefon yok/geçersiz" };
  const addr = place.formattedAddress || "";
  const addrL = trLower(addr);
  if (!addrL.includes(trLower(city)) || (district && !addrL.includes(trLower(district)))) return { why: "bölge dışı" };
  const name = place.displayName?.text || "";
  if (!name || !place.id) return { why: "ad yok" };
  return {
    row: {
      place_id: place.id, name, address: addr, city, district: district || null, sector, phone_raw: rawPhone,
      phone_normalized: phone, rating, review_count: reviews, website_status: website,
      maps_url: place.googleMapsUri ?? null, lead_score: leadScore(rating, reviews, website, isMobile(phone)),
    },
  };
}

export function regionClosed(closed: any[], city: string, district: string): boolean {
  return closed.some((c) => trLower(c.city) === trLower(city) &&
    (!c.district || trLower(c.district) === trLower(district)));
}

export function recentScan(history: any[], city: string, district: string, sector: string, now = Date.now()): any | null {
  const cutoff = now - RESCAN_DAYS * 86400_000;
  return history.find((h) => trLower(h.city) === trLower(city) && trLower(h.district ?? "") === trLower(district) &&
    trLower(h.sector) === trLower(sector) && Date.parse(h.scanned_at) >= cutoff) ?? null;
}

/** Türkiye saatiyle bugünün başlangıcı (UTC+3 sabit) ISO olarak. */
export function istanbulDayStart(now = Date.now()): string {
  const off = 3 * 3600_000;
  return new Date(Math.floor((now + off) / 86400_000) * 86400_000 - off).toISOString();
}

// ------------------------------------------------------------------ girdi doğrulama
export class UserError extends Error {
  code: string;
  status: number;
  constructor(code: string, message: string, status = 400) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export function cleanCity(raw: unknown): string {
  const key = trLower(String(raw ?? "").trim());
  const found = PROVINCES.find((p) => trLower(p) === key);
  if (!found) throw new UserError("bad_city", "Şehir tanınmadı. 81 ilden birini yazın (örn. Ankara).");
  return found;
}

export function cleanName(raw: unknown, what: string): string {
  const v = String(raw ?? "").trim().replace(/\s+/g, " ");
  if (v.length < 2 || v.length > 50 || !/^[\p{L}\p{N} .&'-]+$/u.test(v)) {
    throw new UserError("bad_" + what, `${what === "district" ? "İlçe" : "Sektör"} geçersiz: "${v.slice(0, 30)}"`);
  }
  return v;
}

export function cleanList(raw: unknown, max: number, what: string, canon: (s: string) => string): string[] {
  const arr = Array.isArray(raw) ? raw : String(raw ?? "").split(",");
  const out: string[] = [];
  for (const x of arr) {
    if (!String(x).trim()) continue;
    const v = canon(cleanName(x, what));
    if (!out.includes(v)) out.push(v);
  }
  if (out.length > max) throw new UserError("too_many", `En fazla ${max} ${what === "district" ? "ilçe" : "sektör"} girilebilir.`);
  return out;
}

// ------------------------------------------------------------------ ortam / HTTP
export interface Env {
  SUPABASE_URL: string; SERVICE_KEY: string; GOOGLE_API_KEY: string;
  MAX_CALLS_PER_DAY: number; ALLOWED_ORIGINS: string[];
  SLEEP?: (ms: number) => Promise<void>;   // yalnızca testler için
}
type Fetch = (input: string, init?: any) => Promise<Response>;

export function loadEnv(get: (k: string) => string | undefined): Env {
  const origins = (get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  return {
    SUPABASE_URL: (get("SUPABASE_URL") ?? "").replace(/\/$/, ""),
    SERVICE_KEY: get("SCAN_SERVICE_KEY") || get("SUPABASE_SERVICE_ROLE_KEY") || "",
    GOOGLE_API_KEY: get("GOOGLE_API_KEY") ?? "",
    MAX_CALLS_PER_DAY: Math.max(1, Number(get("MAX_CALLS_PER_DAY")) || 60),
    ALLOWED_ORIGINS: [...DEFAULT_ALLOWED_ORIGINS, ...origins],
  };
}

function corsHeaders(req: Request, env: Env): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  const h: Record<string, string> = {
    "Vary": "Origin", "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
  };
  if (env.ALLOWED_ORIGINS.includes(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

function json(req: Request, env: Env, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders(req, env), "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

class Db {
  env: Env;
  f: Fetch;
  constructor(env: Env, f: Fetch) {
    this.env = env;
    this.f = f;
  }
  h(extra: Record<string, string> = {}) {
    return { apikey: this.env.SERVICE_KEY, Authorization: "Bearer " + this.env.SERVICE_KEY, "Content-Type": "application/json", ...extra };
  }
  async get(path: string): Promise<any[]> {
    const r = await this.f(`${this.env.SUPABASE_URL}/rest/v1${path}`, { headers: this.h() });
    if (!r.ok) throw new Error("db_get " + r.status);
    return await r.json();
  }
  async rpc(fn: string, args: unknown): Promise<any> {
    const r = await this.f(`${this.env.SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers: this.h(), body: JSON.stringify(args) });
    if (!r.ok) throw new Error("db_rpc " + r.status);
    return await r.json();
  }
  async insert(table: string, row: unknown): Promise<void> {
    const r = await this.f(`${this.env.SUPABASE_URL}/rest/v1/${table}`, { method: "POST", headers: this.h({ Prefer: "return=minimal" }), body: JSON.stringify(row) });
    if (!r.ok) throw new Error("db_insert " + r.status);
  }
}

/** İstek sahibi gerçekten giriş yapmış bir Supabase kullanıcısı mı? (kayıt kapalı olduğundan = sizin eklediğiniz kişi) */
async function authenticate(req: Request, env: Env, f: Fetch): Promise<string> {
  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) throw new UserError("unauthorized", "Giriş gerekli.", 401);
  const r = await f(`${env.SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: req.headers.get("apikey") || env.SERVICE_KEY },
  });
  if (!r.ok) throw new UserError("unauthorized", "Oturum geçersiz, yeniden giriş yapın.", 401);
  const u = await r.json();
  if (!u?.id) throw new UserError("unauthorized", "Oturum geçersiz.", 401);
  return u.id;
}

async function usageToday(db: Db, now: number): Promise<number> {
  const rows = await db.get(`/scan_history?select=api_calls&scanned_at=gte.${encodeURIComponent(istanbulDayStart(now))}`);
  return rows.reduce((n, r) => n + (Number(r.api_calls) || 0), 0);
}

async function searchText(env: Env, f: Fetch, query: string, token?: string, sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))): Promise<any> {
  const body: any = { textQuery: query, languageCode: "tr", regionCode: "TR", pageSize: PAGE_SIZE };
  if (token) body.pageToken = token;
  const init = {
    method: "POST", body: JSON.stringify(body),
    headers: { "Content-Type": "application/json", "X-Goog-Api-Key": env.GOOGLE_API_KEY, "X-Goog-FieldMask": FIELD_MASK },
  };
  let r = await f(PLACES_URL, init);
  if (r.status === 429 || r.status >= 500) {   // geçici hata: bir kez daha dene
    await sleep(900);
    r = await f(PLACES_URL, init);
  }
  if (!r.ok) {
    const t = (await r.text()).slice(0, 200);
    throw new UserError("google_" + r.status, r.status === 403 || r.status === 400
      ? "Google erişimi reddetti: Places API (New) etkin ve anahtar doğru mu? (" + t.replace(/AIza[\w-]+/g, "***") + ")"
      : "Google geçici hata verdi (" + r.status + "), biraz sonra tekrar deneyin.", 502);
  }
  return await r.json();
}

// ------------------------------------------------------------------ işlemler
async function plan(db: Db, env: Env, body: any, now: number) {
  const city = cleanCity(body.city);
  const districts = cleanList(body.districts, 30, "district", trTitle);
  const sectors = cleanList(body.sectors, 10, "sector", trLower);
  if (!sectors.length) throw new UserError("no_sector", "En az bir sektör girin.");
  const ds = districts.length ? districts : [""];
  const [closed, history, used] = await Promise.all([
    db.get("/closed_regions?select=city,district"),
    db.get(`/scan_history?select=city,district,sector,scanned_at&scanned_at=gte.${encodeURIComponent(new Date(now - RESCAN_DAYS * 86400_000).toISOString())}`),
    usageToday(db, now),
  ]);
  const units = [];
  for (const district of ds) for (const sector of sectors) {
    const recent = recentScan(history, city, district, sector, now);
    units.push({
      district, sector,
      status: regionClosed(closed, city, district) ? "closed" : recent ? "recent" : "scan",
      last_scanned: recent?.scanned_at ?? null,
    });
  }
  const todo = units.filter((u) => u.status === "scan").length;
  return { city, units, usage: { used, limit: env.MAX_CALLS_PER_DAY }, est_calls: todo * MAX_PAGES, fits_today: Math.max(0, Math.floor((env.MAX_CALLS_PER_DAY - used) / MAX_PAGES)) };
}

async function run(db: Db, env: Env, f: Fetch, body: any, now: number) {
  const city = cleanCity(body.city);
  const district = body.district ? trTitle(cleanName(body.district, "district")) : "";
  const sector = trLower(cleanName(body.sector, "sector"));
  const force = body.force === true;

  const [closed, history, used] = await Promise.all([
    db.get("/closed_regions?select=city,district"),
    db.get(`/scan_history?select=city,district,sector,scanned_at&scanned_at=gte.${encodeURIComponent(new Date(now - RESCAN_DAYS * 86400_000).toISOString())}`),
    usageToday(db, now),
  ]);
  if (regionClosed(closed, city, district)) return { skipped: "closed", message: "Kapalı bölge, taranmadı." };
  if (!force && recentScan(history, city, district, sector, now)) return { skipped: "recent", message: `${RESCAN_DAYS} gün içinde taranmış.` };
  const left = env.MAX_CALLS_PER_DAY - used;
  if (left <= 0) throw new UserError("daily_limit", `Günlük Google çağrı sınırına ulaşıldı (${env.MAX_CALLS_PER_DAY}). Yarın devam edin.`, 429);
  if (!env.GOOGLE_API_KEY) throw new UserError("not_configured", "GOOGLE_API_KEY gizli anahtarı Supabase'de tanımlı değil.", 500);

  const query = [sector, district, city].filter(Boolean).join(" ");
  const rows: Row[] = [], seen = new Set<string>(), reasons: Record<string, number> = {};
  let found = 0, calls = 0, token: string | undefined, warning: string | null = null;
  for (let page = 0; page < Math.min(MAX_PAGES, left); page++) {
    let resp: any;
    try { resp = await searchText(env, f, query, token, env.SLEEP); }
    catch (e) { if (calls === 0) throw e; warning = (e as Error).message; break; }
    calls++;
    const places: any[] = resp.places ?? [];
    found += places.length;
    for (const p of places) {
      const { row, why } = placeToRow(p, city, district, sector);
      if (row && !seen.has(row.place_id)) { seen.add(row.place_id); rows.push(row); }
      else if (why) reasons[why] = (reasons[why] ?? 0) + 1;
    }
    token = resp.nextPageToken;
    if (!token || places.length < PAGE_SIZE) break;
  }
  const saved = rows.length ? Number(await db.rpc("ingest_businesses", { p_rows: rows })) || 0 : 0;
  await db.insert("scan_history", { city, district, sector, places_found: found, saved, api_calls: calls });
  return { city, district, sector, found, matched: rows.length, saved, calls, reasons, warning, used: used + calls, limit: env.MAX_CALLS_PER_DAY };
}

export async function handle(req: Request, env: Env, f: Fetch = fetch, now = Date.now()): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req, env) });
  try {
    if (req.method !== "POST") throw new UserError("method", "Yalnızca POST.", 405);
    if (!env.SUPABASE_URL || !env.SERVICE_KEY) throw new UserError("not_configured", "Sunucu ayarı eksik.", 500);
    await authenticate(req, env, f);
    let body: any;
    try { body = await req.json(); } catch { throw new UserError("bad_json", "Geçersiz istek."); }
    const db = new Db(env, f);
    if (body?.action === "plan") return json(req, env, 200, await plan(db, env, body, now));
    if (body?.action === "run") return json(req, env, 200, await run(db, env, f, body, now));
    throw new UserError("bad_action", "Geçersiz işlem.");
  } catch (e) {
    if (e instanceof UserError) return json(req, env, e.status, { error: e.code, message: e.message });
    console.error("scan hata:", e);
    return json(req, env, 500, { error: "server", message: "Beklenmeyen sunucu hatası." });
  }
}

if (typeof Deno !== "undefined" && Deno.serve) {
  Deno.serve((req: Request) => handle(req, loadEnv((k) => Deno.env.get(k))));
}
