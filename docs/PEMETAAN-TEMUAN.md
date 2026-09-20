# Perbaikan terhadap temuan analisis sebelumnya

Status berikut adalah **implementasi dan pengujian paket v4**, bukan klaim bahwa situs produksi sudah diperbarui.

| Temuan | Penyelesaian di v4 |
|---|---|
| F01 — Jumlah master bukan stok tersedia | Buku + ledger penerimaan awal satu transaksi; stok masuk terpisah; master lama tanpa ledger ditandai review. |
| F02 — Rusak/hilang dikurangi dua kali | `available_delta=0` untuk kembali rusak/hilang; minus untuk kejadian di rak; saldo dan sisa rombel diperbarui atomik. |
| F03 — Identitas guru bebas diketik | Akun guru pribadi wajib login; actor ID dan nama saat transaksi dari sesi; admin mengelola akun. |
| F04 — Transaksi ganda / sukses terlihat gagal | UUID idempotency, status request, replay hasil, pending recovery, dan bukti simpan tidak hilang otomatis. |
| F05 — Edit master memutus pengembalian lama | Larang perubahan kelas/status dengan pinjaman terbuka; pengembalian historis tetap diperbolehkan; snapshot dan revision guard. |
| F06 — Tipe JDBC UUID/integer | Jalur operasional JDBC/Apps Script diganti Neon HTTP parameterized RPC dengan cast SQL eksplisit. |
| F07 — Tanggal tidak konsisten | Tanggal sekolah dari database, eksplisit `Asia/Makassar`; form, riwayat, dashboard, dan laporan mengikuti WITA. |
| F08 — Fresh install dan upgrade berbeda | Satu migrasi atomik, preflight, pemeriksaan saldo, upgrade dua schema lama, rollback pada data ambigu/negatif, tanpa seed produksi. |
| F09 — Validasi/indikator/dashboard/state keliru | Tidak membuang baris invalid diam-diam; agregasi seluruh ledger; cursor; koneksi terukur; cleanup password/DOM/cache saat logout; stale-response guard antar sesi. |
| F10 — Error proxy tidak terkendali | Allowlist action, JSON object, payload 64 KiB, timeout, status HTTP, request ID, sanitized errors, dan parameterisasi SQL. |
| F11 — Sesi dan privilege lemah | bcrypt, cookie HttpOnly/Secure/Strict, CSRF same-origin, rate limit persisten, audit, sesi dicabut saat reset, SECURITY DEFINER terbatas, role runtime API-only. |

## Tambahan yang relevan

- Pengembalian kondisi campuran dalam satu simpan, sisa tetap per rombel–buku.
- Label **pelaku transaksi terakhir** tidak mengklaim selalu guru peminjam terakhir.
- Master rombel, akun, stok masuk, kerusakan dari rak, QR, dan laporan memiliki antarmuka admin.
- CSV menggantikan rekap Spreadsheet Apps Script pada rilis ini; pengiriman email/rekap otomatis tidak ikut dipindahkan.
- Native BarcodeDetector + fallback ZXing lazy; manual/USB tetap tersedia.
- Penguncian rombel lalu buku berurutan; uji concurrency dijalankan dengan guru berbeda pada PostgreSQL asli.
- HTML, JS, CSS, SQL, Function, dan konfigurasi hosting berada dalam struktur source yang konsisten.

## Tugas operator yang tetap diperlukan

Rekonsiliasi data lama yang ambigu, backup/restore rehearsal, uji staging branch sebenarnya, pencabutan credential Apps Script lama, konfigurasi secret/WAF Cloudflare, penerapan di produksi, serta pengukuran kinerja jaringan nyata. Detail di `MIGRASI.md`, `OPERASIONAL.md`, dan `PENGUJIAN-DAN-KINERJA.md`.
