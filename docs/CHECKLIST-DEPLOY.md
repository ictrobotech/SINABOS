# Checklist deployment SINABOS 4.0 — langkah demi langkah

Ikuti berurutan. Jangan melompat ke produksi sebelum staging lulus.
**Aturan utama:** semua file SQL dijalankan dengan **psql**, bukan tempel di editor web Neon (editor web terbukti memotong file besar). Selama `COMMIT` migrasi belum sukses, **tidak ada data yang berubah**.

---

## Fase 0 — Bereskan editor sekarang (5 menit)

1. Buka tab `001-v4` di SQL Editor Neon.
2. Bila muncul banner merah **Failed transaction: ROLLBACK required** → klik **ROLLBACK**.
3. Hapus/simpan-draft query tersimpan `001-v4` yang isinya diawali `-- QUERY TRUNCATED` — jangan pernah di-Run.
4. Abaikan tulisan "Statement executed successfully" — itu hanya untuk statement yang sedang disorot (mis. `BEGIN`).

## Fase 1 — Siapkan alat di komputer operator

1. Pasang **psql** (bagian dari PostgreSQL): Windows boleh pakai installer EDB atau `winget install PostgreSQL.PostgreSQL.17`. Cek: `psql --version`. Ini **hanya untuk migrasi database** — deploy frontend Cloudflare tidak butuh instalasi (lihat Fase 3 langkah 9). Bila benar-benar tidak bisa memasang apa pun, alternatif tanpa instalasi adalah GitHub Codespaces di browser (terminal Ubuntu, `sudo apt install postgresql-client`, lalu jalankan perintah psql yang sama). File kecil (`000-preflight`, `002-verify`, `003-maintenance`) aman dijalankan lewat SQL Editor web Neon; hanya `001-v4.sql` yang besar dan **wajib** psql karena editor web memotongnya.
2. **Neon Console** → project `flat-brook-32121427` → tab **Branches** → **Create branch** → nama `staging-v4`, parent `production` → Create. Ini salinan data produksi; produksi tidak terganggu.
3. Pilih branch `staging-v4` → **Connect** → salin connection string psql (ada password di dalamnya → simpan di password manager, jangan dikirim ke chat/repo).
4. Ekstrak paket `sinabos-v4` ke komputer; buka terminal di folder tersebut.
5. Simpan URL ini di terminal (contoh Linux/macOS; Windows PowerShell sesuaikan):
   - `set STAGING_URL="postgresql://...staging.../neondb?sslmode=require"`
   - `set PROD_URL="postgresql://...production.../neondb?sslmode=require"`

## Fase 2 — Uji semuanya di branch staging (data salinan produksi)

**2a. Preflight (baca-saja)**
```
psql "%STAGING_URL%" -v ON_ERROR_STOP=1 -f sql/000-preflight.sql
```
Catat hasil bagian A–F. Kosong = aman. Isi = ikuti **Tabel remediasi** di bawah, lalu ulangi preflight sampai bersih.

**2b. Migrasi**
```
psql "%STAGING_URL%" -v ON_ERROR_STOP=1 -f sql/001-v4.sql
```
Harus berakhir `COMMIT`. Bila gagal: baca teks error → perbaiki data → jalankan ulang (aman, transaksi gagal tidak meninggalkan apa pun). Jangan pernah menghapus blok `RAISE EXCEPTION`.

**2c. Verifikasi**
```
psql "%STAGING_URL%" -v ON_ERROR_STOP=1 -f sql/002-verify.sql
```
Semua angka harus 0/OK sesuai komentar file.

**2d. (Disarankan) Tes aplikasi nyata ke staging**
1. `set DATABASE_URL_ADMIN="<URL owner branch staging>"` lalu `npm run admin:create` → buat admin staging.
2. `npm run runtime:create` → membuat role runtime + file `.runtime.secrets` (berisi `DATABASE_URL` runtime & `APP_SECRET`; tidak ditampilkan di layar).
3. Cloudflare Pages → project → **Settings → Environment variables → Preview**: tambah `DATABASE_URL` dan `APP_SECRET` dari `.runtime.secrets` (pilih **Encrypt**).
4. Push source paket ke branch staging GitHub → tunggu preview deployment → uji: login admin, buat akun guru, scan, pinjam/kembali, dashboard.
5. Jangan pernah memakai URL owner sebagai `DATABASE_URL` runtime.

## Fase 3 — Cutover produksi (pilih jam sepi, mis. 16.00 WITA)

1. **Informasikan guru** layanan buku ditutup sementara.
2. **Hentikan penulis lama**: matikan trigger/deployment Apps Script lama sehingga tidak ada lagi yang menulis ke Neon saat migrasi.
3. **Backup akhir**: Neon → Branches → Create branch `backup-pra-v4` (parent `production`).
4. **Preflight produksi**: `psql "%PROD_URL%" -v ON_ERROR_STOP=1 -f sql/000-preflight.sql`. Bila muncul temuan baru (data berubah sejak branch staging) → remediasi dulu.
5. **Migrasi produksi**: `psql "%PROD_URL%" -v ON_ERROR_STOP=1 -f sql/001-v4.sql` → tunggu `COMMIT`.
6. **Verifikasi produksi**: `psql "%PROD_URL%" -v ON_ERROR_STOP=1 -f sql/002-verify.sql` → semua 0/OK.
7. **Role runtime produksi**: `set DATABASE_URL_ADMIN="<URL owner production>"` lalu `npm run runtime:create` → `.runtime.secrets` sekarang berisi kredensial runtime **produksi**.
8. **Secret produksi Cloudflare**: Pages → Settings → Environment variables → **Production** → `DATABASE_URL` + `APP_SECRET` dari `.runtime.secrets` (Encrypt).
9. **Deploy aplikasi baru**, pilih salah satu:
   - **Tanpa instalasi apa pun di laptop (disarankan):** upload isi paket ke repo `ictrobotech/sinabos` lewat browser github.com (Add file → Upload files) atau editor web github.dev, lalu Cloudflare Pages membangun otomatis di servernya (build command `npm ci && npm run build`, output `public`). Tidak perlu Node, git, maupun wrangler lokal.
   - Git dengan git terpasang: push isi paket ke repo `ictrobotech/sinabos` (branch yang dipakai Pages).
   - Direct upload: `npx wrangler@4 pages deploy public --project-name sinabos` (perlu Node lokal; jalankan `npm run build` dulu).
10. **Admin pertama produksi**: `set DATABASE_URL_ADMIN="<URL owner production>"` lalu `npm run admin:create`.
11. Buka https://sinabos.smplabschooluntadpalu.my.id → login admin → buat akun untuk **setiap guru** (mereka wajib mengganti password saat login pertama).
12. **Uji nyata ringan**: scan satu rombel → pinjam 1 buku → kembalikan → cek dashboard/riwayat; cocokkan stok satu judul dengan hitung cepat di rak.

## Fase 4 — Setelah cutover

1. Pantau 1–2 hari. **Jangan aktifkan lagi Apps Script lama.**
2. Rollback darurat aplikasi = rollback deployment Pages dan/atau rotasi `DATABASE_URL`. Catatan: transaksi yang sudah masuk lewat v4 **tidak boleh** ditulis balik lewat jalur lama.
3. Rutin mingguan: `psql "%PROD_URL%" -v ON_ERROR_STOP=1 -f sql/003-maintenance.sql`; pastikan backup/branch otomatis Neon tetap aktif.

---

## Tabel remediasi hasil preflight (jalankan di branch staging dulu)

Semua keputusan data dicatat dengan `migration_note`/keterangan — jangan mengubah tanpa jejak.

**A — mutasi rusak/hilang tanpa transaksi pengembalian.** Putuskan per baris (cek rak/catatan guru):
```sql
-- Buku benar-benar hilang dari rak / rusak dibuang:
UPDATE public.stock_movements SET available_delta=-jumlah,
  migration_note='keputusan-<tanggal>-<inisial>: hilang dari rak' WHERE id='<movement_id>';
-- Buku masih ada di rak (mis. catatan rusak tetapi buku kembali dipakai):
UPDATE public.stock_movements SET available_delta=0,
  migration_note='keputusan-<tanggal>-<inisial>: masih di rak' WHERE id='<movement_id>';
```

**B — saldo ledger negatif.** Cocokkan dengan **hitung fisik**; jangan menebak. Bila hitungan fisik memang lebih banyak dari catatan, tambahkan koreksi penerimaan:
```sql
INSERT INTO public.stock_movements(buku_id,tipe,jumlah,sumber_perolehan,tanggal,keterangan)
VALUES('<buku_id>','masuk',<selisih_fisik>,'Rekonsiliasi fisik <tanggal>','<tanggal>','penyesuaian hasil hitung fisik');
```

**D — pengembalian melebihi peminjaman.** Artinya ada transaksi pinjam yang hilang/salah catat. Cari sumbernya (buku besar/guru); koreksi `jumlah` baris yang salah **dengan catatan**, atau lengkapi transaksi pinjam yang tertinggal. Bila tidak dapat dipastikan, biarkan — migrasi memang menolak, dan data jangan dibenahi dengan asumsi.

**E — kode buku dobel (beda kapital/spasi).** Tentukan record yang benar, ganti kode salah satunya:
```sql
UPDATE public.books SET kode_buku=kode_buku||'-DUP' WHERE id='<buku_id>';
```

**C — master punya total tetapi tanpa penerimaan.** Tidak menghalangi migrasi. Verifikasi fisik, lalu catat stok masuknya dari menu admin v4 setelah aplikasi aktif.

---

## Kalau macet

- Kirim hasil preflight A–F (teks, tanpa kredensial) untuk dibantu analisis.
- Jangan edit file `sql/*`, jangan matikan pengaman `RAISE EXCEPTION`, jangan jalankan file yang terpotong.
- Transaksi gagal = tidak ada perubahan. Aman diulang setelah data diperbaiki.
