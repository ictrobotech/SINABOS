# Hasil pengujian dan kinerja — SINABOS 4.0

**Tanggal rilis paket: 20 September 2026, WITA.** Semua data uji sintetis/simulasi. Tidak ada migrasi, seed, transaksi, push GitHub, atau deployment ke layanan produksi sekolah.

## 1. Ringkasan bukti

| Kelompok | Hasil | Bukti |
|---|---:|---|
| HTTP/API, database/auth, formatter CSV, upgrade legacy | **48/48 lulus** | `artifacts/test-unit.tap` |
| PostgreSQL asli: multi-koneksi dan privilege/role runtime | **6/6 lulus** | `artifacts/postgres-concurrency-performance.json` |
| Browser Chromium: desktop/mobile dan keamanan UI | **12/12 lulus** | `artifacts/browser-test-output.txt`, `browser-results.json` |
| **Total skenario otomatis** | **66/66 lulus** | Kode dapat dijalankan ulang di `tests/` |
| Instalasi dependency Node 22 | Sukses | `artifacts/install-node22.txt` |
| Build Cloudflare Pages Function | Sukses | `artifacts/cloudflare-build.txt` |
| Audit dependency | Pemeriksaan awal 0 temuan; audit akhir terhalang maintenance npm 503 | `artifacts/install-node22.txt`, `npm-audit.json` |

**Catatan audit dependency:** audit awal dan `npm ci` melaporkan 0 temuan. Pemeriksaan terakhir dengan npm 11 gagal karena endpoint advisory registry sedang maintenance (HTTP 503), bukan karena temuan kerentanan. Audit terakhir belum tuntas; ulangi `npm audit` saat layanan tersedia. Audit dependency bukan pentest atau jaminan bebas kerentanan, dan hasil awal tidak menggantikan pemeriksaan mutakhir. Source API/SQL tidak diubah sesudah suite terakhirnya; perubahan UI final juga telah dibangun dan diuji ulang di browser.

## 2. Apa yang benar-benar diuji

### Aturan bisnis dan data

- Stok awal 50 atomik dan tidak berubah karena edit metadata.
- Pinjam 10, kembali baik 4/rusak 2/hilang 1 → tersedia **44**, sisa rombel **3**.
- Duplikasi baris kondisi yang sama, kuantitas nol/pecahan/string, kelas salah, over-loan, serta over-return ditolak tanpa sebagian transaksi tertinggal.
- Identitas guru dari sesi; input nama/actor palsu tidak menentukan pencatat.
- Akun guru tidak memiliki akses admin dan tidak membaca riwayat guru lain.
- Snapshot judul; pengembalian buku/barcode lama yang kini nonaktif tetap bisa diselesaikan.
- Revision guard pada buku, akun, dan rombel; normalisasi kode buku mencegah duplikat kapital/spasi.
- Replay request dan password-bearing request aman; password tidak disimpan plaintext dalam audit/idempotency.
- Force-password-change, pencabutan sesi, self-admin guard, limiter login termasuk variasi whitespace username, dan tanggal WITA.
- Dashboard menghitung lebih dari 100 transaksi dan riwayat menggunakan cursor.
- CSV memproteksi teks formula; angka negatif yang benar-benar numerik tetap bisa dijumlahkan dalam spreadsheet.

### Migrasi

Dua schema v3 (repository GitHub dan lampiran) diuji. ID dan ledger seed dipertahankan, master-only 75 ditandai review tanpa menambah stok otomatis, serta kasus rusak lama **38 → 40** dikoreksi tanpa menghapus sejarah. Ledger negatif dan mutasi ambigu menyebabkan rollback. Preflight benar-benar baca-saja. Rerun migrasi tidak menggandakan ledger.

### Concurrency PostgreSQL asli

PGlite bukan bukti locking multi-koneksi. Karena itu, suite terpisah dijalankan pada **PostgreSQL 17.11**, pool 12 koneksi, bukan hanya satu engine in-memory.

- Dua guru berbeda dan dua rombel bersaing meminjam 30 dari stok 50 → hanya satu diterima; sisa **20**.
- Dua transaksi multi-buku dengan urutan buku terbalik → tidak deadlock; saldo masing-masing benar.
- Sepuluh retry UUID yang sama → satu header/item/mutasi, satu hasil.
- Dua pengembalian 15 bersaing terhadap sisa 20 → satu diterima.
- Role aplikasi boleh memanggil API, tetapi tabel password dan bootstrap ditolak.
- Helper owner membuat LOGIN role minimum; helper tidak dapat dipanggil runtime.

### Browser

Desktop 1440×1000 dan mobile 390×844, dengan data simulasi. Uji mencakup navigasi semua layar admin, login guru, cookie HttpOnly/Secure, pemuatan lazy, multi-kondisi, bukti simpan persisten, respons hilang **setelah commit** lalu reload/status recovery, retry akun **sebelum commit** dengan UUID sama dan password yang harus diisi ulang, QR/CSV, CSP produksi, kegagalan/race modal QR, penolakan izin kamera, pembersihan media stream, logout dan isolasi cache antar akun.

**Kamera menggunakan MediaStream/BarcodeDetector simulasi dalam uji otomatis**, bukan pengujian optik QR pada kamera HP nyata. Tidak ada klaim uji Safari/iOS atau perangkat sekolah fisik. Uji manual HTTPS pada perangkat nyata tetap bagian checklist staging.

## 3. Benchmark database lokal

Dataset ditambah **10.000 transaksi sintetis**, dengan ledger/item dan trigger saldo. Masing-masing action dipanaskan 3 kali lalu diukur 30 kali; median dari dua nilai tengah, p95 nearest-rank. Durasi meliputi RPC SQL melalui TCP loopback, termasuk pemeriksaan sesi/limiter, **bukan** HTTP browser → Cloudflare → Neon.

| Action | Median (ms) | p95 (ms) |
|---|---:|---:|
| dashboard | 3.63 | 3.86 |
| scan | 1.42 | 1.71 |
| books | 1.48 | 2.30 |
| history | 1.73 | 2.14 |

**Batas interpretasi:** ini bukan pengujian produksi, bukan load test ribuan pengguna, dan bukan angka speedup dibanding v3. Jumlah buku pada fixture relatif kecil; hasil tidak mewakili inventaris ratusan ribu judul. Hosting, jaringan Palu–region Neon, cold start, suspend/resume, dan kapasitas compute perlu diuji di staging/produksi.

Login/ganti password sengaja membayar biaya bcrypt cost 12 untuk keamanan; tidak dijanjikan latencynya sama dengan read stok.

## 4. Aset dan pemuatan awal

| Komponen | Byte minified | Byte gzip sintetis |
|---|---:|---:|
| JavaScript aplikasi awal | 48,201 | 16,796 |
| QR — lazy | 24,267 | 9,450 |
| ZXing — lazy bila kamera native tidak tersedia | 442,539 | 116,658 |
| Shared helper | 78 | 79 |
| CSS awal | 26,929 | 6,940 |

Gzip dihitung dengan Node `gzipSync`; bukan ukuran transfer HTTP teramati dari Cloudflare. HTML, logo, serta header HTTP belum termasuk angka JS/CSS di tabel. Logo UI dikurangi dari **135,652 byte / 512×512** ke **42,326 byte / 192×192**, dengan rasio aspek dipertahankan.

QR dan ZXing **terbukti tidak di-request pada dashboard awal**. Nama aset memakai content hash, cache immutable hanya untuk `/assets/*`, sedangkan HTML revalidate. Aturan `_headers` tidak menumpuk dua nilai `max-age` yang berbeda pada aset. API selalu `no-store`.

CSP produksi dicoba pada browser langsung. Pratinjau Arena sengaja mengizinkan iframe; cookie demo HTTPS terpartisi untuk kompatibilitas embed. **Produksi tetap cookie Strict dan frame-ancestors none**. Jalur proxy Cloudflare aktual belum dideploy pada akun sekolah.

## 5. Mengukur sesudah deployment

1. Di staging, ukur login, buka dashboard, scan, simpan multi-buku, history-next, dan laporan bulanan pada jaringan sekolah/seluler.
2. Bedakan kondisi database hangat dan resume setelah idle; jangan menonaktifkan suspend atau menaikkan compute berbayar tanpa persetujuan pengelola.
3. Catat minimal p50/p95/p99, jumlah sampel, waktu uji, jenis perangkat, region/paket, dan jumlah pengguna bersamaan.
4. Header API `Server-Timing` berisi `db` (round-trip Neon) dan `total` (handler), bukan rincian SQL internal. Bandingkan dengan durasi fetch browser untuk melihat biaya jaringan pengguna.
5. Uji beban/tulis hanya pada staging/branch terpisah. Jangan membuat ribuan transaksi palsu di buku sekolah asli.
6. Gunakan checklist migrasi dan reconciler saldo sebelum layanan dinyatakan siap produksi.

## 6. Belum diverifikasi / perlu operator

- Schema, jumlah data, custom grants/trigger, secret, WAF, serta region/compute Neon produksi.
- Skrip CLI bootstrap/role terhadap endpoint Neon sekolah sebenarnya; SQL privileged helper telah diuji lokal, tetapi koneksi/otorisasi owner produksi belum tersedia.
- Pipeline GitHub/Cloudflare akun sekolah, deployment pada custom domain, backup restore rehearsal, dan cutover/rollback nyata.
- Performa end-to-end produksi, semua kombinasi browser, kamera fisik, printer, dan kebijakan cookie pengguna.

Bukti lengkap ada di `artifacts/`. Trace/cache yang mungkin berisi cookie demo tidak dimasukkan ke paket.


## Riwayat 4.1.0 (20 Sep 2026)

Perubahan: kolom ISBN/Edisi (opsional, ISBN divalidasi karakter), aksi admin `resetBooks` yang menolak reset setelah transaksi pertama (teruji: guru ditolak 403, admin ditolak 409 saat ada transaksi, replay UUID aman), serta perapian label menu. Upgrade produksi dari 4.0.0 memakai `sql/004-v4.1.sql` (idempotent, teruji dijalankan ulang).

Perbaikan upgrade: penambahan kolom ISBN/Edisi dipindah ke **ujung** view `sinabos_stock` (CREATE OR REPLACE VIEW PostgreSQL hanya mengizinkan kolom baru di akhir); ditambah uji khusus jalur upgrade dari struktur 4.0.0 dan uji sesi dibuat deterministik. Hasil akhir: **51/51** unit/DB/migrasi/CSV, **6/6** PostgreSQL native, **12/12** browser, kompilasi Wrangler sukses pada Node 22. Skema pengujian dan batas interpretasi pada bab sebelumnya tetap berlaku.
