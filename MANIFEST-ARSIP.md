# Manifest Arsip Lengkap — SINABOS 4.1.0

Arsip ini memuat **seluruh komponen aplikasi**: kode sumber, hasil build, skrip database, pengujian, bukti (evidence), konfigurasi, dan dokumentasi. Tidak ada kredensial di dalam arsip.

## Struktur folder

| Folder / berkas | Isi | Catatan |
|---|---|---|
| `web/` | Kode sumber frontend (`index.html`, `app.js`, `app.css`, logo) + `format.js` | Sumber kebenaran tampilan |
| `server/` | `api.js` — seluruh logika batas HTTP (allowlist, cookie, limit, versi) | Dipakai demo & Function |
| `functions/` | `api.js` — pintu masuk Cloudflare Pages Function | Tipis, memanggil `server/api.js` |
| `scripts/` | `build.mjs` (build & hashing aset), `demo-server.mjs` (pratinjau lokal), `create-admin.mjs`, `create-runtime-role.mjs` (operator, **belum dijalankan**), `notices.mjs` | |
| `sql/` | `000-preflight.sql`, `001-v4.sql` (instalasi penuh), `002-verify.sql`, `003-maintenance.sql`, `004-v4.1.sql` (ISBN/Edisi + resetBooks), `000-diagnostik-v4.sql` | Panduan perubahan: `docs/PANDUAN-PERUBAHAN-DATABASE.md` |
| `public/` | **Hasil build siap deploy**: `index.html`, `assets/app-*.js` (hashed/immutable), CSS, logo, `THIRD_PARTY_NOTICES.txt` | Directory publish Cloudflare |
| `tests/` | 51 uji unit/DB/migrasi/CSV (node:test + PGlite), `concurrency.pg.mjs` (PostgreSQL asli + benchmark), fixture schema v3, uji browser Playwright (13) | |
| `docs/` | `CHECKLIST-DEPLOY.md` (langkah deployment berurutan), `PANDUAN-PERUBAHAN-DATABASE.md` (panduan perubahan DB masa depan — Neon + PostgreSQL lokal, dengan perintah lengkap), `MIGRASI.md` (detail teknis migrasi & cutover), `OPERASIONAL.md` (operasional harian, akun, pemulihan), `PENGUJIAN-DAN-KINERJA.md` (bukti & batas pengujian), `PEMETAAN-TEMUAN.md` (perbaikan temuan F01–F11) | |
| `artifacts/` | **Bukti pengujian**: hasil 51 uji unit (TAP), PostgreSQL native + benchmark JSON, 13 uji browser, kompilasi Cloudflare, audit dependensi, tangkapan layar antarmuka, ukuran bundle | Data di dalamnya simulasi |
| `README.md` | Ringkasan, cara mulai, ringkasan fitur & validasi | Baca pertama |
| `MANIFEST-ARSIP.md` | Berkas ini | |
| `SHA256SUMS.txt` | Checksum SHA-256 seluruh file arsip (selain dirinya) | Verifikasi integritas |
| `.env.example` | Template variabel operator (kosong, aman) | Jangan isi di dalam arsip |
| `.gitignore`, `.nvmrc` | Konfigurasi repo & versi Node 22 | |
| `package.json`, `package-lock.json` | Definisi dependensi terkunci & skrip (`build`, `test`, `test:postgres`, `test:browser`, `check:cloudflare`, `admin:create`, `runtime:create`) | Node ≥ 22 |
| `wrangler.toml` | Konfigurasi Cloudflare Pages (publish `public`, Functions `functions/`) | Tanpa secret |
| `playwright.config.js` | Konfigurasi uji browser (hanya target loopback) | |
| `THIRD_PARTY_NOTICES.txt` | Atribusi lisensi dependensi runtime | Dibuat ulang otomatis saat build |

## Yang sengaja TIDAK ikut dalam arsip

- `node_modules/` — dibangun ulang dengan `npm ci` dari lockfile.
- `.cache/` (termasuk trace browser & cookie uji), `.cf-check/` (hasil kompilasi sementara).
- `.env*` selain `.env.example`, file `.runtime.*` — **tidak pernah** berisi kredensial dalam keadaan apa pun.
- Riwayat git.

## Verifikasi integritas

```powershell
# Windows (PowerShell)
Get-FileHash -Algorithm SHA256 .\SINABOS-4.1.0-ARSIP-LENGKAP.zip
# bandingkan dengan SINABOS-4.1.0-ARSIP-LENGKAP.sha256.txt
```

## Ringkasan status

- Validasi: **51/51** unit/DB/migrasi/CSV · **6/6** PostgreSQL native · **13/13** browser · kompilasi Cloudflare sukses.
- Database produksi sekolah: **4.1.0** (Neon, `production`). Aplikasi terdeploy di Cloudflare Pages.
- Belum dilakukan (tetap milik operator): uji kamera fisik & perangkat nyata, pengukuran kecepatan produksi, rehearsal restore backup.
