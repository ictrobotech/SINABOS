# Migrasi data dan cutover yang aman

> Panduan ringkas langkah demi langkah (termasuk contoh SQL perbaikan data): lihat **docs/CHECKLIST-DEPLOY.md**.

## Prinsip

- Jangan menyalin seed/demo ke Neon produksi.
- Simpan ID buku, rombel, transaksi, item, dan mutasi. `001-v4.sql` tidak mengosongkan tabel lama.
- Ledger adalah sumber saldo. `books.total_buku` lama disimpan ke `legacy_total_buku`, bukan dipercaya sebagai saldo fisik.
- Snapshot judul/mapel riwayat lama diisi dari master saat migrasi, sebab v3 belum merekam snapshot. **Nama master pada masa lampau yang sudah hilang tidak dapat direkonstruksi otomatis.** Snapshot baru disimpan saat transaksi.
- Hutang buku melekat pada **rombel–buku**, bukan pada individu guru. Akun guru adalah identitas pencatat yang diaudit.
- Dua schema v3 yang diterima telah diuji; database produksi belum diperiksa dengan akses owner. Uji clone branch yang sebenarnya tetap wajib, terutama bila memiliki custom trigger, view, fungsi, atau grant tambahan.

## A. Sebelum menyentuh produksi

1. Pastikan project/branch/database Neon yang benar. Jangan menyimpulkan branch aktif hanya dari label URL dashboard.
2. Buat branch/backup dan pastikan dapat dipulihkan. Catat waktu, schema, jumlah baris, total mutasi, dan versi source/deployment Cloudflare terakhir.
3. Pisahkan staging Cloudflare + secret staging dari produksi.
4. Jalankan `000-preflight.sql` pada clone v3. Simpan hasil privat.
5. Rekonsiliasi kode buku yang hanya berbeda kapital/spasi bila preflight melaporkannya; v4 melarang duplikasi tersebut. Periksa custom dependencies dan apakah role pemilik migrasi memiliki hak extension, DDL, dan CREATEROLE. Runtime tidak boleh menjadi pemilik schema/fungsi.
6. Jalankan `001-v4.sql` → `002-verify.sql` pada staging.
7. Bootstrap admin, buat role runtime, pasang staging, dan uji penerimaan di bagian D.

Migrasi dibungkus transaksi dengan advisory lock dan lock tabel sumber. Jika menemukan ledger negatif, pengembalian melebihi pinjaman, atau kerusakan ambigu, migrasi **dibatalkan**, bukan “memperbaiki” angka diam-diam. Bila editor mempertahankan transaksi berstatus aborted, jalankan `ROLLBACK;` sebelum melanjutkan investigasi.

## B. Rekonsiliasi kasus lama

### 1. Rusak/hilang dari pengembalian

Mutasi `rusak`/`hilang` yang terhubung ke header transaksi **kembali** diberi `available_delta=0`. Buku sudah keluar saat pinjam; pengembalian rusak/hilang menyelesaikan pinjaman, tetapi tidak menambah ataupun mengurangi lagi stok tersedia.

Contoh teruji: masuk 50, pinjam 10, kembali rusak 2 → tersedia **40**, bukan 38. Baris historis/ID tetap ada.

### 2. Rusak/hilang tanpa hubungan transaksi yang jelas

Tidak mungkin menyimpulkan apakah buku hilang dari rak atau dari rombel hanya berdasarkan angka dan keterangan. Hasil preflight A harus diperiksa manusia dengan bukti fisik/administrasi.

Jika sudah ada keputusan tertulis, owner dapat menambahkan kolom klasifikasi **pada branch staging dahulu** dan mengisi hanya ID yang telah diputuskan:

```sql
BEGIN;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS available_delta integer;
-- Contoh template, ganti ID dengan UUID nyata dari hasil audit; jangan UPDATE semua baris.
-- Kehilangan/kerusakan yang benar-benar terjadi pada stok tersedia di rak:
UPDATE public.stock_movements SET available_delta=-jumlah
WHERE id='UUID_MUTASI_YANG_SUDAH_DIVERIFIKASI' AND tipe IN ('rusak','hilang');
-- Jika verifikasi membuktikan event ini TIDAK lagi mengurangi stok rak:
-- UPDATE public.stock_movements SET available_delta=0
-- WHERE id='UUID_MUTASI_LAIN_YANG_SUDAH_DIVERIFIKASI' AND tipe IN ('rusak','hilang');
COMMIT;
```

Template UUID di atas sengaja bukan nilai valid: **jangan jalankan tanpa menggantinya dengan ID dan keputusan yang benar**. Simpan daftar ID, keputusan, alasan, penanggung jawab, serta backup sebelum perubahan. Migrasi mempertahankan `available_delta` yang telah diklasifikasikan dan memvalidasi bentuknya.

### 3. Master punya jumlah, tidak punya penerimaan ledger

Migrasi menyimpan angka master lama dalam `legacy_total_buku` dan memberi tanda **perlu rekonsiliasi**. Tidak dibuat penerimaan fiktif otomatis. Angka tersedia bisa 0 sampai penerimaan sah dicatat.

Admin memeriksa jumlah fisik serta stok yang sedang dipinjam, lalu memakai **Inventaris buku → + Stok → catatan verifikasi**. Konfirmasi review menghilangkan tanda. Jumlah yang dimasukkan adalah **penerimaan yang belum pernah masuk ledger**, bukan sekadar menyalin angka master atau menambah saldo saat ini lagi.

Jika sudah ada transaksi keluar tetapi sama sekali tidak ada stok sumber sehingga ledger negatif, selesaikan rekonstruksi bukti penerimaan pada clone v3 terlebih dahulu. Menu review v4 bukan jalan pintas untuk melewati penolakan saldo negatif pada migrasi.

### 4. Saldo negatif / over-return / header–item–mutasi tidak sinkron

Hentikan cutover. Bandingkan dokumen transaksi, item, mutasi, jumlah fisik, dan rombel. Query saldo saja tidak membuktikan seluruh ledger historis lengkap. Koreksi manual hanya setelah keputusan penanggung jawab, dengan backup dan jejak koreksi. Jangan menggunakan `GREATEST(saldo,0)` atau menambahkan stok palsu untuk menutupi selisih.

## C. Cutover produksi

1. Jadwalkan waktu pemeliharaan; informasikan guru agar menyelesaikan transaksi sebelum waktu tersebut.
2. Hentikan penulis v3: nonaktifkan akses/deployment Apps Script atau cabut kredensial koneksi lamanya. Tunggu request lama selesai (drain) dan periksa koneksi/job penulis lain sebelum mengambil snapshot; rotasi password saja tidak selalu menutup koneksi yang sudah terbentuk. Jika langkah ini belum siap, **jangan mulai cutover**.
3. Ambil snapshot/backup terakhir sesudah penulisan berhenti. Catat hitungan tabel.
4. Terapkan rekonsiliasi yang telah disetujui, lalu migrasi `001-v4.sql` dan verifikasi `002-verify.sql` sebagai owner yang sama seperti staging.
5. Bootstrap admin, buat runtime role baru, isi encrypted secrets pada environment **production** Cloudflare, dan deploy source/build v4.
6. Jalankan smoke test akun nyata dan sampel buku/rombel. Jangan membuat transaksi fiktif pada ledger produksi untuk sekadar testing; gunakan staging untuk skenario angka 50/10/4/2/1.
7. Cocokkan saldo dan jumlah baris. Baru buka layanan untuk guru.
8. Arsipkan Apps Script lama, nonaktifkan URL/trigger tulis lama, rotasi kredensial owner yang pernah ditaruh dalam Apps Script, dan hapus secret Cloudflare lama yang tidak dipakai.

`001-v4.sql` mengganti `simpan_transaksi_scan` lama dengan penolakan serta mencabut grant fungsi/view lama yang dikenal. **Ini bukan pengganti pencabutan kredensial owner:** aplikasi lama yang masih mengetahui password owner bisa menulis tabel langsung atau mengubah schema. Deployment v3 tidak boleh tetap beroperasi setelah cutover.

## D. Checklist penerimaan staging

- [ ] Login tanpa password yang benar gagal; akun tidak aktif ditolak.
- [ ] Guru baru wajib ganti password sebelum scan; menu admin tidak dapat diakses melalui UI maupun API.
- [ ] Buat buku dengan stok awal 50: tersedia langsung 50. Edit judul tidak mengubah total.
- [ ] Pinjam 10, kembali baik 4 + rusak 2 + hilang 1: tersedia 44, sisa pinjaman rombel 3.
- [ ] Coba pinjam berlebih, kembali berlebih, item nol, serta perubahan kelas dengan pinjaman terbuka: ditolak tanpa sebagian data tersimpan.
- [ ] Simulasikan respons hilang sesudah commit: cek status/retry menghasilkan bukti yang sama, bukan transaksi baru.
- [ ] Pengembalian lama dengan buku yang sekarang tidak aktif tetap dapat diselesaikan.
- [ ] Guru tidak bisa melihat riwayat guru lain; admin dapat memonitor semuanya.
- [ ] Label QR tercetak; kamera diuji di HP sekolah sesungguhnya pada HTTPS dan manual/USB tetap tersedia.
- [ ] CSV dapat diunduh; sel formula tidak dieksekusi sebagai formula spreadsheet.
- [ ] Query selisih saldo di `002-verify.sql` kosong.
- [ ] Runtime hanya anggota role aplikasi, bukan owner/role istimewa; bootstrap/table access ditolak.
- [ ] Waktu transaksi mengikuti WITA, termasuk saat mendekati pergantian tanggal.

## E. Rollback

### Sebelum v4 menerima transaksi baru

Tutup akses, kembalikan database dari backup/branch pra-migrasi dan source/secret deployment v3 yang cocok. Kredensial lama yang sudah dicabut harus ditangani secara terencana. Jangan hanya rollback HTML ketika SQL sudah dimigrasikan: RPC v3 memang dinonaktifkan.

### Setelah v4 menerima transaksi baru

Utamakan **forward fix**. Kunci penulisan terlebih dahulu dan backup keadaan terbaru. Restore snapshot pra-migrasi akan menghilangkan transaksi v4 baru; rekonsiliasi serta replay terkontrol diperlukan sebelum layanan dibuka. Tidak disediakan skrip down-migration otomatis yang berisiko menghapus akun, audit, atau transaksi.

## F. Menjalankan ulang migrasi

Migrasi dirancang idempoten dan pengujian rerun tersedia. Rerun melakukan rebuild saldo dari ledger; lakukan dalam jendela pemeliharaan dengan backup dan role owner, bukan saat trafik padat. Migrasi ulang tidak membuat ulang admin/default account dan tidak menggandakan stok awal.

## Menjalankan file SQL besar: psql, bukan tempel di editor web

Editor SQL web Neon dapat memotong query besar — tandanya komentar `-- QUERY TRUNCATED` di awal isi editor dan jumlah statement terparse jauh lebih sedikit daripada isi file. Jangan pernah menjalankan isi yang terpotong.

1. Gunakan psql dari komputer operator (URL koneksi per branch ada di Neon Console → Connect):
   - `psql "URL-KONEKSI?sslmode=require" -v ON_ERROR_STOP=1 -f sql/000-preflight.sql`
   - `psql "URL-KONEKSI?sslmode=require" -v ON_ERROR_STOP=1 -f sql/001-v4.sql`
   - `psql "URL-KONEKSI?sslmode=require" -v ON_ERROR_STOP=1 -f sql/002-verify.sql`
2. `ON_ERROR_STOP=1` berhenti di error pertama dan menampilkan teks error lengkap; atomicity tetap dijaga `BEGIN…COMMIT` di dalam file.
3. Bila terpaksa memakai editor web: pastikan tidak ada komentar truncation, baris terakhir editor adalah `COMMIT;`, dan jalankan seluruh isi sekaligus — bukan per-statement.
4. Setelah kegagalan di editor, klik ROLLBACK pada banner transaksi sebelum mencoba lagi. Tulisan "Statement executed successfully" hanya berlaku untuk statement yang sedang dipilih (misalnya BEGIN), bukan seluruh migrasi.
