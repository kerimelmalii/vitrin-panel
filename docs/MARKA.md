# Marka uygulaması (panel)

Panel, vitrinweb. marka kılavuzuna göre tasarlanır. Yeni ekran/özellik eklerken aynı kuralları koruyun.

## Varlıklar (`public/`)
| Dosya | Kullanım |
|---|---|
| `brand/vitrinweb.png`, `brand/vitrinweb-1x.png` | Logo (şeffaf zemin; siyah "vitrin", lacivert "web."). Giriş ekranı ve üst bar |
| `favicon.svg`, `icon-192.png`, `icon-512.png`, `apple-touch-icon.png` | "V." uygulama ikonu (siyah kare, beyaz V, mavi nokta) |
| `manifest.webmanifest` | Telefonda "Ana ekrana ekle" için |
| `fonts/manrope-*.woff2` | Manrope (SIL OFL, `fonts/OFL.txt`); dışarıdan yüklenmez, kendi sunucumuzdan gelir |

## Renk ve tipografi
* Zemin `#FFFFFF` · ikincil yüzey `#F5F5F7` · çizgi `#E4E4E9` · ana metin `#111114` · gövde `#46464D` · soluk metin `#6B6B73`
* **Tek vurgu rengi: lacivert `#1F2F6B`** (logo, etkin sekme, ilerleme çubukları, bağlantılar, odak halkası). Başka vurgu rengi eklemeyin.
* Anlamsal renkler yalnızca durum için: yeşil (olumlu), kehribar (uyarı), kırmızı (olumsuz).
* Yazı tipi Manrope: başlıklar 800, gövde 500, dar harf aralığı (−0.03em). Hiyerarşi renkle değil ağırlıkla kurulur.

## Yapmayın (yapay zekâ kalıplarından kaçınma)
Gradyan, parıltı/cam efekti, gölge, mor-indigo tonları, her şeye rozet, aşırı yuvarlak kartlar, süs amaçlı widget, her yerde ikon. Düz, ince 1px çizgiler, siyah hap biçimli ana düğmeler (`→` yalnızca asıl eylemde), tipografi öncelikli hiyerarşi kullanın. Boş durumlarda marka kılavuzundaki ince çizgi illüstrasyon stili (`#shop`).

## Erişilebilirlik
Panel, `AXE=... node tests/panel.e2e.mjs` taramasından ihlalsiz geçmelidir (WCAG 2 A/AA, renk kontrastı dahil).
