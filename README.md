# SINABOS v3.0 — Sistem Informasi Buku Operasional Sekolah
## SMP LABSCHOOL UNTAD PALU

Sistem informasi untuk pencatatan stok dan transaksi buku per rombel menggunakan **Neon PostgreSQL, Google Apps Script, GitHub, dan Cloudflare Pages**.

> **Bukan aplikasi perpustakaan.** Guru scan barcode rombel, mengisi form transaksi, lalu data tampil di aplikasi admin.

## Alur kerja

1. Guru scan barcode rombel, misalnya `RBL-VII-A`.
2. Form menampilkan nama guru, peminjaman/pengembalian, mapel, jumlah, kondisi, dan tanggal otomatis.
3. Satu transaksi dapat berisi beberapa mapel.
4. Submit form membuat header transaksi, item multi-mapel, dan mutasi stok secara atomik di Neon.
5. Panel admin membaca data melalui API Apps Script.

## Stok buku masuk

Jenis buku dipilih dari master. Input operasional hanya:

- jumlah buku;
- sumber diperoleh.

Tanggal tersimpan otomatis. Tidak ada nomor nota, harga, anggota, denda, atau jatuh tempo pada form stok masuk.

## Stack

Neon PostgreSQL · Google Apps Script JDBC · GitHub · Cloudflare Pages

## Isi paket

| File | Fungsi |
|---|---|
| `panduan-sim-bos-buku.html` | Panduan implementasi SINABOS |
| `sql/schema.sql` | Schema Neon: buku, barcode rombel, transaksi, item, mutasi, fungsi atomik, views |
| `sql/policies.sql` | Catatan keamanan Neon; tidak menjalankan RLS Supabase lama |
| `sql/seed.sql` | Data contoh kelas VII/VIII dan barcode rombel |
| `apps-script/Code.gs` | API Apps Script + koneksi JDBC ke Neon |
| `frontend/index.html` | Form scan, multi-mapel, stok masuk, dashboard admin |
| `.github/workflows/deploy.yml` | Auto-deploy frontend ke Cloudflare Pages |

## Mulai cepat

1. Neon Console → SQL Editor → jalankan `sql/schema.sql`.
2. Jalankan `sql/seed.sql`.
3. Verifikasi:

   ```sql
   select * from v_stok order by kelas_target, kode_buku;
   select * from rombel_barcodes order by barcode;
   ```

4. Buat project Apps Script dari `apps-script/Code.gs`.
5. Isi Script Properties:
   - `NEON_HOST`
   - `NEON_DB` = `neondb`
   - `NEON_USER` = user dari Neon Connect
   - `NEON_PASSWORD`
   - `NEON_PORT` = `5432`
   - `API_TOKEN`
   - `SEKOLAH_NAMA` = `SMP LABSCHOOL UNTAD PALU`
   - `ADMIN_EMAIL` (opsional)
6. Jalankan fungsi `tesKoneksi()` dan izinkan akses Apps Script.
7. Deploy Apps Script sebagai Web App: **Execute as Me** dan **Anyone with the link**.
8. Isi `APPS_SCRIPT_WEB_APP_URL` dan `API_TOKEN` pada konfigurasi frontend.
9. Uji barcode `RBL-VII-A`, isi beberapa mapel, lalu cek Riwayat Transaksi Admin.

## Mendapatkan property Neon

Di Neon klik **Connect**, pilih branch `production`, database `neondb`, dan koneksi langsung. Ambil host, user, database, port, dan password secara terpisah. Jangan menaruh connection string atau password Neon pada frontend, GitHub, atau chat.

## Keamanan

- Connection string/password Neon hanya berada di Script Properties Apps Script.
- Frontend hanya memanggil endpoint Apps Script dengan `API_TOKEN`.
- Jangan menjalankan `policies.sql` Supabase lama yang memakai `auth.uid()`, `auth.users`, atau `service_role`.
- Fungsi PostgreSQL memvalidasi barcode, kelas mapel, stok, sisa pengembalian, dan transaksi multi-item.
- Backup database sebelum mengubah schema produksi.

Disusun untuk SINABOS SMP LABSCHOOL UNTAD PALU.
