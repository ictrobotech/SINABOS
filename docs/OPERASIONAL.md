# Operasional, keamanan, dan batas layanan

## Akun dan sesi

- Setiap guru memakai akun masing-masing. Admin dapat membuat, mengganti nama/role, menonaktifkan, dan mereset password akun.
- Username 3–40 karakter, huruf kecil/angka/titik/garis bawah/tanda hubung. Password minimal 12 karakter dan maksimal 72 byte UTF-8 (batas bcrypt).
- Akun baru/reset harus mengganti password sementara saat login. Admin harus menyerahkan password sementara melalui saluran privat, bukan grup terbuka.
- Perubahan password mencabut sesi lain; reset/penonaktifan oleh admin mencabut sesi target. Tidak ada tombol “lupa password” publik atau pengiriman email otomatis.
- Sesi maksimal 8 jam. Setelah keluar cookie dihapus, sesi server dicabut, tampilan/pending/cache akun dibersihkan.
- Jangan membagikan akun admin. Bootstrap hanya dari terminal operator dengan kredensial owner; tidak dapat dipanggil oleh role runtime.
- `APP_SECRET` dipakai untuk HMAC alamat IP pada limiter, bukan untuk mengubah password. Rotasi `APP_SECRET` bukan mekanisme logout global; pencabutan sesi dilakukan di database/operasi akun.

## Perangkat dan kamera

- Gunakan browser modern dengan JavaScript modules, Web Crypto, `crypto.randomUUID`, dan `AbortController` (target ES2022).
- Kamera membutuhkan HTTPS, izin browser, serta perangkat kamera yang tersedia. Gunakan domain produksi langsung, bukan embed iframe situs lain: CSP produksi melarang embedding untuk mengurangi clickjacking.
- Browser yang mendukung BarcodeDetector memakai pemindai native; browser lain memuat ZXing hanya ketika kamera diminta.
- Mode manual dan scanner USB yang mengetik kode tetap tersedia ketika kamera ditolak/tidak tersedia. QR rombel berisi kode rombel, **bukan password atau token login**.
- Pengujian otomatis Chromium bukan pengganti uji kamera pada Android/iOS/perangkat sekolah nyata. Izin kamera harus diberikan pengguna.

## Jika koneksi buruk

1. Jangan langsung membuat transaksi baru ketika respons simpan tidak sampai.
2. Gunakan **Periksa status**, kemudian retry dengan ID yang sama bila belum ada hasil.
3. UUID dan payload non-rahasia disimpan dalam sessionStorage per tab; token/password tidak disimpan di sana. Password hanya berada di memori/form saat diperlukan dan harus diisi ulang setelah reload.
4. Bukti yang sudah dikonfirmasi tetap tampil sampai transaksi baru. Tombol cetak tersedia.
5. Jika tab ditutup atau storage dihapus, lihat riwayat sebelum menulis ulang. Data pending bukan antrian offline dan bukan cadangan ledger.
6. Kalau status belum dapat dipastikan, aplikasi menahan mutasi baru/log out agar bukti tidak hilang. Jangan tinggalkan perangkat bersama tanpa pengawasan; pulihkan jaringan/konfirmasi status atau tutup sesi profil browser. Koneksi offline tidak dapat menjamin pencabutan sesi server.

### Khusus respons ganti password yang terputus

Ganti password merotasi sesi, sehingga tidak memakai panel retry transaksi. Muat ulang halaman dan coba masuk dengan password **baru**. Jika perubahan belum tersimpan dan password baru ditolak, gunakan password lama atau minta reset admin. Jangan mengulang banyak percobaan hingga terkena rate limit. Akun/ledger tidak dihapus oleh kegagalan respons ini.

### Tampilan dan laporan

Tema antarmuka (Pengaturan → Tampilan: Modern/Profesional/Emerald) tersimpan **per perangkat** dan diterapkan kembali saat login — mengubahnya tidak memengaruhi pengguna lain. Laporan Bulanan menyediakan "Unduh Excel" (.xls berwarna, siap diolah) dan "Unduh PDF" (dialog cetak A4 berisi kop, tabel berwarna, dan blok tanda tangan) untuk arsip kertas.

## Persediaan dan laporan

- `Tersedia` adalah stok layak pinjam di rak.
- `Dipinjam` adalah sisa seluruh rombel. Kembali baik/rusak/hilang sama-sama menyelesaikan sisa rombel; hanya kondisi baik yang menambah tersedia.
- `Rusak/Hilang dari rak` mengurangi tersedia; jangan dipakai untuk kedua kalinya terhadap buku yang rusak/hilang saat sedang dipinjam.
- `Perolehan` adalah jumlah kumulatif penerimaan ledger, bukan nilai bebas yang diedit dari master.
- Detail transaksi lama mempertahankan judul/mapel snapshot sejak migrasi. Nama pencatat pada transaksi lama tetap teks historis dan tidak otomatis dianggap akun guru baru.
- Guru hanya melihat transaksi yang memiliki `actor_user_id` akunnya. Transaksi v3 tanpa actor ID tetap dapat dilihat admin; tidak diatribusikan otomatis berdasarkan kesamaan nama.
- Laporan CSV dipilih per bulan. Perlindungan formula spreadsheet menambahkan prefiks aman untuk nilai berawalan `=`, `+`, `-`, atau `@`.
- Audit menyimpan tindakan dan ID, bukan plaintext password/token. Retensi audit serta kepatuhan data sekolah tetap kebijakan pengelola.

## Pemeliharaan

Jalankan `sql/003-maintenance.sql` berkala sebagai owner melalui scheduler yang Anda kelola. Ini hanya membuang sesi dan bucket limiter kedaluwarsa. API juga melakukan pembersihan opportunistic terbatas (maksimal 500 per tabel, sekitar 1% request); jadwal tetap berguna ketika trafik rendah. Tidak ada cron otomatis terpasang pada akun Cloudflare Anda oleh paket ini.

- Backup/branch Neon sebelum perubahan schema.
- Pantau error 5xx, rate limit, durasi p50/p95/p99, koneksi, pemakaian storage, cold start, serta proses build.
- Jangan mencatat cookie, password, connection string, atau body login di observability/log HTTP.
- Simpan `sinabos_requests` (idempotency) selama kebijakan retry masih berlaku. Menghapusnya tanpa rencana bisa membuat retry lama tercatat kembali. Rilis ini tidak melakukan penghapusan otomatis atasnya.
- Tabel saldo hanya diperbarui melalui transaksi aplikasi/trigger insert. **Jangan UPDATE/DELETE ledger langsung**: owner secara teknis berkuasa, tetapi operasi manual dapat membuat saldo turunan tidak sinkron. Rekonsiliasi dengan `002-verify.sql` dan jadwal rebuild terkontrol bila diperlukan.
- Versi lama views/RPC selain yang kompatibel bukan API aplikasi baru. Integrasi eksternal yang membaca views legacy perlu ditinjau; gunakan laporan v4 atau SQL yang diverifikasi.
- Dependensi dikunci di `package-lock.json`. Jalankan audit dan suite pengujian setelah update, jangan memakai `npm audit fix --force` di produksi tanpa review.

## Rate limit bawaan

| Operasi | Batas |
|---|---:|
| Percobaan login per IP HMAC | 60/menit |
| Percobaan login per username | 5/10 menit |
| Request akun terautentikasi | 180/menit |
| Sesi invalid per IP | 120/menit |
| Ganti password per akun | 5/10 menit |

Bucket waktu tetap, sehingga waktu reset tergantung posisi dalam interval. Nilai dapat ditinjau berdasarkan penggunaan sekolah. Limiter database membatasi operasi aplikasi tetapi tetap membutuhkan request ke Neon; tambahkan aturan Cloudflare WAF/rate-limit untuk `/api` sesuai paket dan kebijakan sekolah. WAF belum dikonfigurasi lewat paket ini.

## Privilege dan rahasia

- `DATABASE_URL_ADMIN`: hanya operator untuk migrasi/bootstrap, tidak untuk Pages.
- `DATABASE_URL`: login khusus anggota `sinabos_app`; grant API tunggal, tanpa hak tabel.
- File `.env.admin.local` dan `.runtime.secrets`: diabaikan Git; simpan terenkripsi/privat dan hapus setelah dipindahkan ke secret manager bila tak diperlukan.
- Role runtime dapat membaca metadata sistem PostgreSQL sebagaimana role biasa, tetapi tidak tabel akun/sesi/ledger. Akses API tetap membutuhkan cookie sesi sah.
- Cabut deployment dan credential Apps Script lama. Menghapus URL dari frontend tidak mencabut akses pihak yang sudah mengetahui credential owner.
- Tidak ada Klaim “audit keamanan penuh”. Uji mencakup kontrol yang didokumentasikan, bukan pentest menyeluruh atau sertifikasi.
