# Panduan Perubahan Database — SINABOS 4.1

Panduan ini untuk **pengembangan berkelanjutan**: apa yang harus dilakukan bila kelak ada perubahan struktur/aturan database, lengkap dengan perintah untuk **Neon (produksi/staging)** maupun **PostgreSQL lokal di laptop**. Ikuti urutannya; jangan mengubah database langsung tanpa file migrasi.

---

## 1. Peta komponen yang berkaitan dengan database

| Berkas / objek | Peran |
|---|---|
| `sql/001-v4.sql` | Instalasi penuh skema v4 (tabel, view, fungsi, grant). **Jangan pernah diedit setelah dipakai.** |
| `sql/004-v4.1.sql` | Contoh upgrade kecil (ISBN/Edisi + resetBooks). Pola untuk migrasi berikutnya. |
| `sql/005-….sql` (kelak) | Migrasi baru Anda — satu file per perubahan, nomor urut naik. |
| `sql/000-preflight.sql` | Cek baca-saja sebelum migrasi di database lama. |
| `sql/002-verify.sql` | Verifikasi pasca-migrasi (harus 0/OK semua). |
| `sql/003-maintenance.sql` | Pembersihan rutin sesi/limiter kedaluwarsa. |
| `server/api.js` | Daftar `ACTIONS` (allowlist aksi) + `VERSION`. |
| `web/app.js` | Daftar `MUTATIONS` (aksi tulis) + antarmuka. |
| `functions/api.js` | Pembungkus Pages Function — jarang diubah. |

**Objek database inti:** tabel `books`, `stock_movements`, `circulation_transactions`, `circulation_items`, `rombel_barcodes`, `sinabos_users`, `sinabos_sessions`, `sinabos_limits`, `sinabos_requests`, `sinabos_audit`, `sinabos_migrations`, saldo `sinabos_book_balances` & `sinabos_loan_balances`; view `sinabos_stock`, `v_stok`; fungsi `sinabos_v4_api`, `sinabos_v4_dispatch`, `sinabos_v4_limit`, `sinabos_v4_require_text`, `sinabos_v4_password`, `sinabos_v4_bootstrap`, `sinabos_v4_runtime_role`, trigger stok/pinjam.

**Aturan emas:** saldo buku hanya boleh berubah lewat `stock_movements` (trigger yang menyesuaikan cache). Perubahan apa pun pada database **wajib lewat file migrasi bernomor** yang dijalankan ke staging lebih dulu — bukan edit manual lewat editor.

---

## 2. Aturan wajib sebelum mengubah apa pun

1. **Backup dulu.** Neon: Console → Branches → **Create branch** dari `production` (mis. `backup-pra-005`, Auto-delete: Never). Lokal: `pg_dump` (bab 5).
2. **Uji di branch staging dulu**, bukan produksi. Neon: buat branch `staging-v4` dari `production`, jalankan migrasi di sana, uji aplikasi dengan URL staging bila perlu.
3. **Satu file migrasi = satu perubahan logis**, selalu: `BEGIN;` → perubahan → catat versi → `COMMIT;`.
4. **Blok pembuka standar** (mencegah dua migrasi jalan bersamaan):
   ```sql
   BEGIN;
   SELECT pg_advisory_xact_lock(734120260001::bigint);
   ```
5. **CREATE OR REPLACE VIEW: kolom baru hanya boleh ditambah di UJUNG daftar.** Menyisipkan kolom di tengah akan membuat upgrade gagal (pelajaran nyata dari 004). Bila urutan kolom harus berubah: buat view dengan nama baru, pindahkan dependensi, lalu ganti nama dalam satu transaksi.
6. **Fungsi selalu `CREATE OR REPLACE … SET search_path=pg_catalog,public,pg_temp`** — jangan DROP kecuali tahu tidak ada dependensi/grant.
7. **Jangan mengedit `001-v4.sql` yang sudah dipakai produksi.** Instalasi baru tetap 001 + seluruh migrasi berikutnya secara urut.
8. **Tambahkan nomor versi baru** ke `sinabos_migrations` di akhir file, dan naikkan `VERSION` di `server/api.js` (mis. `4.2.0`) bila frontend/ikut berubah.
9. **Rollback**: migrasi dibuat "maju saja". Bila perlu membatalkan, tulis migrasi pembalik berikutnya (`006-revert-005.sql`) atau restore branch backup. Transaksi gagal otomatis tidak meninggalkan apa pun.

---

## 3. Template file migrasi baru

Simpan sebagai `sql/005-nama-perubahan.sql` (ganti nama & versi):

```sql
-- SINABOS 4.2.0 — <jelaskan perubahan satu kalimat>.
-- Idempotent: aman dijalankan ulang. Jalankan lewat psql (file >50 KB wajib psql).
BEGIN;
SELECT pg_advisory_xact_lock(734120260001::bigint);

-- ===== Contoh: kolom baru pada books =====
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS catatan text;

-- View ikut diperbarui — kolom baru DI UJUNG:
CREATE OR REPLACE VIEW public.sinabos_stock AS
SELECT b.id,b.kode_buku,b.judul,b.mata_pelajaran,b.kelas_target,b.tahun_terbit,b.penulis,b.penerbit,b.kurikulum,b.sumber_buku,b.sumber_dana,b.aktif,b.revision,
 s.total_masuk AS total_buku,s.total_masuk,s.total_pinjam,s.total_kembali,(s.total_rusak+s.total_hilang)::int AS total_rusak_hilang,
 s.total_rusak,s.total_hilang,s.tersedia,
 coalesce((SELECT sum(l.sisa)::int FROM public.sinabos_loan_balances l WHERE l.buku_id=b.id AND l.sisa>0),0) AS dipinjam,
 b.legacy_total_buku,(coalesce(b.legacy_total_buku,0)>0 AND b.legacy_reviewed_at IS NULL AND s.total_masuk=0) AS needs_opening_review,b.isbn,b.edisi,b.catatan
FROM public.books b JOIN public.sinabos_book_balances s ON s.buku_id=b.id;

INSERT INTO public.sinabos_migrations(version) VALUES('4.2.0') ON CONFLICT DO NOTHING;
COMMIT;
```

---

## 4. Menjalankan migrasi di Neon — perintah lengkap

### 4.1 Ambil koneksi
1. Neon Console → pilih **branch** (staging dulu, produksi kemudian) → **Connect** → **Direct connection** → salin `postgresql://neondb_owner:…@ep-…/neondb?sslmode=require`. Simpan di tempat aman; **jangan pernah dikirim ke chat/repo**.

### 4.2 Jalankan migrasi (utama — lewat psql)
Windows (PowerShell, psql di `E:\EMLTR\PostgreSQL\bin`):
```powershell
cd C:\Users\acern\Downloads\sinabos-v4
& "E:\EMLTR\PostgreSQL\bin\psql.exe" "postgresql://…URL-BRANCH…" -v ON_ERROR_STOP=1 -f sql\005-nama-perubahan.sql
```
Linux/macOS:
```bash
psql "postgresql://…URL-BRANCH…" -v ON_ERROR_STOP=1 -f sql/005-nama-perubahan.sql
```
- Harus berakhir `COMMIT`. Gagal = tidak ada yang berubah; perbaiki lalu ulangi.
- `ON_ERROR_STOP=1` wajib agar berhenti di error pertama.
- **File besar wajib psql** — editor web Neon memotong query (tanda `-- QUERY TRUNCATED`). File kecil (<±50 KB) boleh lewat SQL Editor web: tempel utuh, pastikan baris akhir `COMMIT;`, Run sekali sekaligus, klik ROLLBACK bila muncul banner "Failed transaction".

### 4.3 Verifikasi setiap selesai
```sql
SELECT version, applied_at FROM public.sinabos_migrations ORDER BY applied_at DESC LIMIT 3;
SELECT current_setting('neon.branch', true) AS cabang;
```
lalu jalankan `002-verify.sql` (psql `-f sql\002-verify.sql`) — semua angka harus 0/OK. Di editor web, cek `neon.branch` **sebelum** menyimpulkan: produksi dan staging punya tampilan mirip.

### 4.4 Alur lengkap perubahan di Neon
```
backup-pra-005 (branch dari production)
   └─> staging-v4 (branch dari production) → psql -f 005 → 002-verify → uji aplikasi (ops.: set DATABASE_URL preview ke URL staging di Cloudflare, lalu kembalikan)
         └─> production: hentikan penulisan? (tidak perlu untuk perubahan additif) → psql -f 005 → 002-verify → selesai
```
Perubahan **additif** (kolom/view/fungsi baru) tidak perlu mematikan aplikasi. Perubahan yang **mengubah perilaku fungsi lama**: deploy aplikasi pendukungnya di commit yang sama/berurutan; bila ragu, jalankan migrasi saat sepi (mis. 16.00 WITA).

### 4.5 Rollback bila hasil tak sesuai
- Transaksi gagal → tidak ada perubahan (cek: banner merah → ROLLBACK → perbaiki → ulangi).
- Sudah COMMIT tapi salah → jalankan `006-revert-…` (migrasi pembalik) **atau** Neon Console → Branches → production → **Restore** ke titik waktu sebelum migrasi (fitur point-in-time restore) — lalu verifikasi ulang.

---

## 5. Menjalankan di PostgreSQL lokal (laptop)

Gunanya: mencoba migrasi tanpa menyentuh Neon, dan sebagai server cadangan/pengembangan.

### 5.1 Windows — satu kali inisialisasi
```powershell
# Folder data baru (di luar folder instalasi)
& "E:\EMLTR\PostgreSQL\bin\initdb.exe" -D "E:\EMLTR\sinabos-pgdata" -U postgres --auth=trust --encoding=UTF8 -E UTF8

# Start (stop juga tersedia; --log ke file)
& "E:\EMLTR\PostgreSQL\bin\pg_ctl.exe" -D "E:\EMLTR\sinabos-pgdata" -o "-p 5433" -l "E:\EMLTR\sinabos-pgdata\server.log" start

# Buat database kosong untuk uji
& "E:\EMLTR\PostgreSQL\bin\createdb.exe" -h 127.0.0.1 -p 5433 -U postgres sinabos_dev

# Instal skema penuh lalu migrasi baru
cd C:\Users\acern\Downloads\sinabos-v4
& "E:\EMLTR\PostgreSQL\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d sinabos_dev -v ON_ERROR_STOP=1 -f sql\001-v4.sql
& "E:\EMLTR\PostgreSQL\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d sinabos_dev -v ON_ERROR_STOP=1 -f sql\004-v4.1.sql
& "E:\EMLTR\PostgreSQL\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d sinabos_dev -v ON_ERROR_STOP=1 -f sql\005-nama-perubahan.sql
```
Setelah itu buat admin pertama lokal (mirip langkah 3b panduan deployment):
```powershell
& "E:\EMLTR\PostgreSQL\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d sinabos_dev -c "SELECT public.sinabos_v4_bootstrap('admin','Admin Lokal','PassfraseLokal-2026');"
```
Matikan server saat selesai:
```powershell
& "E:\EMLTR\PostgreSQL\bin\pg_ctl.exe" -D "E:\EMLTR\sinabos-pgdata" stop
```

### 5.2 Backup & restore lokal
```powershell
# Backup seluruh database ke satu file terkompresi
& "E:\EMLTR\PostgreSQL\bin\pg_dump.exe" -h 127.0.0.1 -p 5433 -U postgres -Fc -f "E:\EMLTR\backup-sinabos-dev.dump" sinabos_dev

# Restore ke database baru
& "E:\EMLTR\PostgreSQL\bin\createdb.exe" -h 127.0.0.1 -p 5433 -U postgres sinabos_restore
& "E:\EMLTR\PostgreSQL\bin\pg_restore.exe" -h 127.0.0.1 -p 5433 -U postgres -d sinabos_restore "E:\EMLTR\backup-sinabos-dev.dump"

# Backup NEON (baca-saja aman) lewat psql yang sama — hanya URL-nya yang beda:
& "E:\EMLTR\PostgreSQL\bin\pg_dump.exe" "postgresql://…URL-PRODUKSI…" -Fc -f "E:\EMLTR\backup-produksi-%DATE:~-4%%DATE:~3,2%%DATE:~0,2%.dump"
```
Neon juga otomatis menyimpan riwayat point-in-time sesuai paket — tetap buat branch backup sebelum migrasi besar.

### 5.3 Menjalankan uji proyek secara lokal
```powershell
cd C:\Users\acern\Downloads\sinabos-v4
node --version                 # perlu Node ≥ 22
npm ci                         # pasang dependensi
npm run build                  # bangun public/
npm test                       # 51 uji unit/DB/migrasi (pakai PGlite, tanpa server)
```
Uji concurrency PostgreSQL asli (suite `tests/concurrency.pg.mjs`) butuh server lokal di loopback; secara default memakai `postgresql://user@127.0.0.1:5434/sinabos_test` dan **menolak** host non-loopback:
```powershell
$env:PG_TEST_URL="postgresql://postgres@127.0.0.1:5433/sinabos_test"
npm run test:postgres
```
Uji browser butuh demo lokal berjalan: `node scripts/demo-server.mjs` lalu `npm run test:browser`.

---

## 6. Contoh nyata end-to-end (kolom baru `catatan`)

1. Buat `sql/005-catatan-buku.sql` dari template bab 3.
2. **Lokal:** initdb/createdd bila belum (bab 5.1) → jalankan 001 (jika database dev baru) → 004 → 005 → `npm test` → perbaiki sampai hijau.
3. **Neon staging:** buat branch backup + pastikan branch `staging-v4` → `psql -f sql\005-…` ke **URL staging** → `002-verify` → cek `sinabos_migrations` (versi 4.2.0 di staging).
4. **Aplikasi:** bila kolom perlu tampil/diisi — tambah field di `bookModal` (`web/app.js`), simpan di `saveBook` (`sinabos_v4_dispatch`: validasi + `INSERT`/`UPDATE`), naikkan `VERSION` menjadi `4.2.0` di `server/api.js`, `npm run build`, uji `npm run test:browser`.
5. **Rilis:** upload ke GitHub (build Cloudflare otomatis) → setelah hijau, jalankan `005` ke **URL produksi** → verifikasi → Ctrl+F5.
6. **Arsip:** masukkan 005 + kode terbaru ke paket/ZIP dan commit — jangan sampai hanya ada di satu komputer.

---

## 7. Menambah aksi API baru — checklist 6 lokasi

Contoh: aksi baru `cekFisik`. Wajib disentuh:

1. `sql/00N-….sql` — handler baru di `sinabos_v4_dispatch` (`ELSIF p_action='cekFisik' THEN …`) + guard admin bila perlu + tambahkan aksi ke **daftar allowlist di `sinabos_v4_api`** dan (bila aksi tulis) ke **daftar `is_mutation`** di fungsi yang sama.
2. `server/api.js` — tambah `'cekFisik'` ke `ACTIONS`.
3. `web/app.js` — bila aksi tulis: tambah ke `MUTATIONS`; buat tombol/form + handler `mutate('cekFisik', payload)` (sertakan `request_id: crypto.randomUUID()`).
4. Uji: tambah kasus di `tests/database.test.mjs` (dan browser bila UI baru).
5. `VERSION` di `server/api.js` + `docs/PENGUJIAN-DAN-KINERJA.md` (catat hasil uji).
6. Jalankan rantai: `npm test` → (jika perlu) `test:postgres` → `npm run build` → `test:browser` → deploy.

Gejala jika lupa satu lokasi: "Action tidak dikenal" (allowlist DB/API), `FORBIDDEN` (guard admin), `request_id wajib diisi` (lupa UUID), atau tombol tak bereaksi (frontend).

---

## 8. Perintah pemeliharaan rutin

```powershell
# Pembersihan sesi/limiter kedaluwarsa (mingguan, ke URL produksi)
& "E:\EMLTR\PostgreSQL\bin\psql.exe" "postgresql://…URL-PROD…" -v ON_ERROR_STOP=1 -f sql\003-maintenance.sql
```
```sql
-- Reset password akun admin (dijalankan owner; admin wajib ganti lagi saat login)
UPDATE public.sinabos_users SET password_hash=public.sinabos_v4_password('PassfraseBaru-2026'),
 must_change_password=true, revision=revision+1 WHERE username='admin' RETURNING username;

-- Rotasi password role runtime (setelahnya: perbarui DATABASE_URL di Cloudflare + redeploy)
ALTER ROLE sinabos_runtime_v4 WITH LOGIN PASSWORD 'PassfraseRuntimeBaru';

-- Putuskan seluruh sesi (mis. kecurigaan akun)
TRUNCATE public.sinabos_sessions;
```
Rotasi `APP_SECRET`: buat nilai 64-karakter baru (`[guid]::NewGuid().ToString("N")+[guid]::NewGuid().ToString("N")`) → perbarui variabel Cloudflare → **Retry deployment** (semua sesi lama otomatis tidak sah).

---

## 9. Troubleshooting cepat

| Gejala | Penyebab & langkah |
|---|---|
| "Action tidak dikenal" saat UI sudah punya tombolnya | Frontend baru, fungsi DB lama → jalankan file migrasi yang ketinggalan ke **branch production** (cek `neon.branch` + `sinabos_migrations`). Sebaliknya: browser belum Ctrl+F5. |
| Banner "Failed transaction: ROLLBACK required" | Klik ROLLBACK, baca teks error statement yang gagal, perbaiki, ulangi. Transaksi gagal tidak mengubah data. |
| `-- QUERY TRUNCATED` di editor web | File terpotong → wajib psql. |
| ERROR saat CREATE OR REPLACE VIEW (kolom tengah) | Kolom baru hanya boleh di ujung daftar SELECT (bab 2.5). |
| `could not resolve "@neondatabase/serverless"` saat build Cloudflare | Build command kosong/gagal → set `npm ci && npm run build`, output `public`, variabel `NODE_VERSION=22`. |
| 503 "Layanan data belum merespons" | `DATABASE_URL` salah/salah branch → uji URL dengan psql `-c "select current_user"` → perbaiki variabel → Retry deployment. |
| Koneksi Neon terputus diam ("administratively") | Normal (idle timeout) — psql menyambung ulang sendiri; jalankan ulang perintahnya. |
| "Terlalu banyak percobaan" saat login | Rate limit 5/10 menit per username — tunggu, atau bersihkan via 003 bila darurat. |

---

## 10. Disiplin arsip

Setelah setiap rilis: masukkan file migrasi baru + kode + bukti uji ke paket ZIP dan repo GitHub; perbarui `SHA256SUMS.txt`; catat perubahan di `docs/PENGUJIAN-DAN-KINERJA.md`. Database produksi, repo, dan arsip lokal harus menceritakan versi yang sama.
