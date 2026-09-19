# SINABOS 4.0 — Buku untuk belajar
## SMP Labschool UNTAD Palu

Pembaruan dari aplikasi v3: **Cloudflare Pages/Functions → Neon langsung**, dengan **akun pribadi guru dan admin**. Google Apps Script tidak lagi menjadi jalur API aplikasi.

> **Status penyerahan:** source, aset hasil build, migrasi, dan pengujian lokal tersedia. **Belum diterapkan pada akun Cloudflare/Neon/GitHub produksi Anda.** Pratinjau menggunakan database simulasi terpisah. Jangan menyalin data demo atau password demo ke produksi.

**Mulai dari mana?** Operator: buka `docs/CHECKLIST-DEPLOY.md` (langkah deployment berurutan). Migrasi teknis: `docs/MIGRASI.md`. Operasional harian: `docs/OPERASIONAL.md`. Bukti pengujian: `docs/PENGUJIAN-DAN-KINERJA.md`.

**Validasi paket:** 66/66 skenario otomatis lulus (48 aturan/API/CSV/migrasi, 6 PostgreSQL multi-koneksi/privilege, 12 browser). Instalasi Node 22 dan kompilasi Function Cloudflare berhasil. Detail serta batas buktinya ada di `docs/PENGUJIAN-DAN-KINERJA.md`; pemetaan F01–F11 ada di `docs/PEMETAAN-TEMUAN.md`.

## Yang diperbaiki

- Master buku dan stok awal disimpan **atomik**; input 50 benar-benar menghasilkan tersedia 50.
- Pengembalian rusak/hilang **tidak mengurangi tersedia dua kali**. Kerusakan dari rak adalah event berbeda dengan pengurangan yang benar.
- Pengembalian satu buku dengan kondisi campuran diperbolehkan, dengan validasi **jumlah agregat**.
- Retry memakai `request_id` dan hasil idempotency tersimpan: respons terputus tidak menggandakan transaksi.
- Bukti simpan tetap terlihat. Kegagalan memuat daftar tidak diartikan sebagai kegagalan menyimpan.
- Nama pencatat berasal dari akun terverifikasi, bukan teks bebas. Guru hanya melihat riwayatnya sendiri; monitoring saldo tetap per rombel.
- Login guru/admin, pengelolaan akun, reset password, wajib ganti password sementara, pencabutan sesi, dan audit aktivitas.
- Cookie sesi `HttpOnly`, `Secure`, `SameSite=Strict`; token tidak disimpan di localStorage. Password di-hash bcrypt cost 12 melalui pgcrypto di database, bukan SHA-256 polos.
- Validasi server, pembatasan request/login, CSRF same-origin, ukuran payload maksimal 64 KiB, dan error HTTP yang konsisten.
- Perubahan kelas/status buku atau rombel dibatasi bila masih dipinjam. Pengembalian historis buku lama tetap dapat diselesaikan.
- Snapshot judul/mapel pada item transaksi, tanggal bisnis `Asia/Makassar`, pagination riwayat, serta penghitung dashboard dari seluruh transaksi.
- Stok masuk, rusak/hilang dari rak, master rombel, label QR unduh/cetak, ekspor laporan CSV untuk Excel/Sheets.
- Role database runtime tanpa hak membaca password/tabel atau menjalankan bootstrap; hanya boleh memanggil satu fungsi API yang memeriksa sesi/role.

## Perubahan untuk respons cepat

1. **Hapus satu lapisan komunikasi:** browser → Cloudflare → Neon; tidak ada HTTP Cloudflare → Apps Script → JDBC untuk setiap request.
2. **Satu query RPC per request API**, termasuk verifikasi sesi; bukan query auth dan query data terpisah melalui jaringan.
3. **Tabel saldo yang diperbarui atomik oleh trigger** menghindari penjumlahan seluruh riwayat ledger setiap kali scan atau membuka stok. Ledger tetap sumber kebenaran.
4. Riwayat memakai **cursor/keyset**, indeks waktu/aktor, dan ukuran halaman 25. Daftar buku/akun juga dibatasi dan dicari di server.
5. Pemuatan hanya layar aktif, deduplikasi read yang sama, cache memori singkat 20 detik yang dibatalkan setelah mutasi, debounce pencarian, tanpa polling terus-menerus.
6. HTML/CSS/JavaScript lokal, tanpa font/CDN eksternal. Aset di-minify dan diberi nama hash untuk cache browser immutable. QR dan pemindai kamera kompatibilitas dimuat **hanya saat dipakai**.
7. Rate limit request terautentikasi per akun, bukan satu lock IP untuk seluruh guru pada jaringan sekolah.

**Bukan janji latency produksi:** biaya jaringan, region Neon, cold start/suspend, dan paket layanan masih memengaruhi waktu respons. Lihat `docs/PENGUJIAN-DAN-KINERJA.md` untuk hasil ukur serta batas buktinya.

---

## Struktur paket

```text
functions/api.js            Route /api Cloudflare Pages
server/api.js               HTTP, cookie, CSRF, validasi envelope, driver Neon
web/                       Source antarmuka tanpa framework berat
public/                    Hasil build untuk dipublikasikan, termasuk _headers/_routes
sql/000-preflight.sql       Pemeriksaan baca-saja database v3
sql/001-v4.sql              Migrasi atomik / instalasi bersih
sql/002-verify.sql          Pemeriksaan saldo, schema, dan hak akses
sql/003-maintenance.sql     Pembersihan sesi/rate limit kedaluwarsa
scripts/                   Build, bootstrap admin, role runtime, demo lokal
tests/                     Uji API, stok, migrasi, browser, concurrency PostgreSQL
docs/                      Deployment, migrasi, operasi, bukti pengujian
artifacts/                 Hasil uji dan ukuran bundle; bukan data sekolah
wrangler.toml              Konfigurasi Pages, bukan tempat secret
```

**Source ini tidak memerlukan `Code.gs` untuk operasional.** Rekap Spreadsheet otomatis versi Apps Script diganti dengan ekspor CSV; dapat diimpor ke Google Sheets. Pengiriman email atau trigger rekap otomatis bukan bagian rilis ini.

---

## 1. Jalankan pratinjau di komputer sendiri

Prasyarat: Node.js **22** dan npm. Database demo dibuat in-memory; tidak mengakses Neon.

```bash
npm ci
npm run build
npm run dev
```

Buka `http://localhost:3000`.

| Akun demo lokal | Username | Password |
|---|---|---|
| Admin | `admin` | `Demo-Admin-2026!` |
| Guru | `guru.demo` | `Demo-Guru-2026!` |

Jika memakai pratinjau tertanam dan browser menolak cookie, buka pratinjau di tab baru. Demo HTTPS memakai cookie terpartisi untuk iframe; **produksi tetap SameSite=Strict dan tidak boleh di-iframe**.

Akun ini hanya dibuat oleh `scripts/demo-server.mjs`, **tidak** oleh migrasi atau fungsi Cloudflare. Data demo kembali ke keadaan awal saat proses demo dimulai ulang. Banner kuning menandai mode demo.

## 2. Siapkan Neon pada branch staging dahulu

1. Buat backup/branch sebelum perubahan. Pastikan database dan branch, bukan hanya nama project.
2. Untuk database lama, jalankan **`sql/000-preflight.sql`**. Untuk database baru kosong, lewati preflight v3.
3. Ikuti **`docs/MIGRASI.md`** jika ditemukan ledger ambigu atau negatif. Jangan menambah stok untuk sekadar menghilangkan error.
4. Jalankan **`sql/001-v4.sql`** sebagai pemilik database.
5. Jalankan **`sql/002-verify.sql`**. Query selisih saldo harus kosong.
6. **Jangan jalankan seed v3.** Data buku, transaksi, item, dan mutasi lama dipertahankan; total master lama tanpa ledger ditandai untuk persetujuan admin.

## 3. Buat admin awal dan role runtime

Di **komputer operator**, bukan dalam chat atau GitHub:

1. Salin `.env.example` menjadi `.env.admin.local`.
2. Isi `DATABASE_URL_ADMIN` dengan koneksi owner branch yang benar. File ini diabaikan Git.
3. Jalankan:

```bash
npm run admin:create
npm run runtime:create
```

- Bootstrap admin meminta username/nama/password secara interaktif; input password disembunyikan.
- Role runtime baru default bernama `sinabos_runtime_v4`, anggota `sinabos_app`, bukan owner.
- Secret runtime dibuat dalam **`.runtime.secrets`** dengan izin file privat. Isinya **jangan di-commit/dikirim ke chat**.
- Tidak ada reset/admin bootstrap publik melalui browser. Akun berikutnya dibuat dari menu **Akun guru & admin** setelah login.
- Runtime role yang sudah ada tidak ditimpa diam-diam. Untuk rotasi terencana, gunakan `RUNTIME_ROLE_NAME` baru dan pindahkan secret deployment, lalu cabut role lama.

## 4. Pasang GitHub → Cloudflare Pages

**Buat branch staging baru terlebih dahulu**, misalnya `sinabos-v4-staging`, lalu upload/commit isi paket di sana. Jangan langsung menimpa branch produksi yang auto-deploy. Pastikan `functions/api.js` lama terganti. File lama `index.html` di root tidak lagi menjadi output hosting.

| Pengaturan Pages | Nilai |
|---|---|
| Repository | `ictrobotech/sinabos` |
| Root directory | Kosong / root repository |
| Framework preset | None |
| Build command | **`npm run build`** |
| Build output directory | **`public`** |
| Node version | **22** (`NODE_VERSION=22`, tersedia juga `.nvmrc`) |
| Domain produksi | `sinabos.smplabschooluntadpalu.my.id` |

Isi **Variables & Secrets** untuk **Functions runtime**:

| Nama | Nilai |
|---|---|
| `DATABASE_URL` | Koneksi Neon **role runtime** dari `.runtime.secrets`, bukan owner |
| `APP_SECRET` | Nilai acak dari `.runtime.secrets`, minimal 32 byte |

Gunakan **encrypted secrets**. Jangan menaruh nilai dalam HTML, `wrangler.toml`, build script, atau GitHub. Preview deployment branch staging harus memakai database staging terpisah; jangan mengisi secret preview dengan database produksi.

`API_TOKEN` dan `APPS_SCRIPT_WEB_APP_URL` tidak dipakai lagi oleh v4. Hapus sesudah cutover berhasil. Deployment harus diulang setelah mengubah environment bila diperlukan oleh Pages.

## 5. Uji staging dan cutover

- Login admin baru, buat akun guru, login guru dan ganti password sementara.
- Tambahkan buku 50; pinjam 10; kembali baik 4, rusak 2, hilang 1 → **tersedia 44**, sisa rombel 3.
- Uji network retry, hak guru/admin, riwayat, QR, dan unduhan CSV.
- Verifikasi saldo dengan `002-verify.sql`; hitung fisik sampel buku.
- Jadwalkan penghentian penulisan v3. Migrasi produksi yang sudah diuji lalu deployment v4 dilakukan dalam jendela pemeliharaan.
- Arsipkan/nonaktifkan deployment Apps Script lama dan cabut koneksi lamanya. v4 menonaktifkan RPC sirkulasi lama; jangan membiarkan dua aplikasi menulis paralel.

**Rollback frontend saja tidak cukup.** Baca `docs/MIGRASI.md` sebelum mengganti layanan. Jika v4 sudah menerima transaksi, jangan memulihkan snapshot lama tanpa rekonsiliasi transaksi baru.

---

## Pengujian yang dapat diulang

```bash
npm test                     # API, aturan stok, auth, dan migrasi PGlite
npm run build
npm run check:cloudflare      # kompilasi Pages Function; tidak perlu secret produksi
npx playwright install --with-deps chromium
npm run test:browser           # demo lokal; jalankan npm run dev pada terminal lain
```

Untuk pengujian multi-koneksi pada PostgreSQL asli lokal, siapkan database terpisah bernama `sinabos_test`, lalu:

```bash
PG_TEST_URL=postgresql://USER@127.0.0.1:5434/sinabos_test npm run test:postgres
```

**Peringatan:** skrip PostgreSQL menghapus schema database test. Guard menolak host non-loopback dan nama database selain pola `sinabos_test`. Jangan mengganti guard untuk menunjuk produksi.

## Pemakaian harian

- **Guru:** login → scan rombel → pilih pinjam/kembali → semua baris wajib valid → simpan → tunggu bukti. Buku rusak/hilang yang sedang dipinjam diselesaikan dari **Pengembalian**, bukan menu kejadian di rak.
- **Admin:** kelola inventaris, + Stok, kejadian rusak/hilang dari rak, rombel, akun, laporan, dan audit. Total perolehan bukan saldo tersedia.
- **Koneksi terputus:** gunakan panel **Periksa status / Ulangi permintaan yang sama**. Permintaan tersimpan sementara per tab, tanpa token/password; pemulihan setelah menutup seluruh tab tidak dijamin. Cek riwayat sebelum membuat request baru.
- **Perangkat bersama:** selalu Keluar; jangan berbagi akun. Sesi berakhir maksimal 8 jam dan reset password mencabut sesi lain.

Untuk detail operasional, keterbatasan, retensi, dan pemeliharaan: **`docs/OPERASIONAL.md`**.
