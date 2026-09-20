-- SINABOS — diagnostik kondisi setengah-migrasi (BACA-SAJA, aman di SQL Editor web).
-- Jalankan pada branch yang ingin diperiksa. Tidak mengubah data apa pun.
BEGIN TRANSACTION READ ONLY;

-- 1. Apakah migrasi v4 resmi tercatat? (kosong = v4 belum aktif)
SELECT version, applied_at FROM public.sinabos_migrations ORDER BY 1;

-- 2. Fungsi v4 yang sudah terpasang
SELECT proname FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'sinabos%' ORDER BY 1;

-- 3. Fungsi lama v3 (harus masih ada agar situs lama tetap melayani)
SELECT proname FROM pg_proc WHERE pronamespace='public'::regnamespace
AND proname IN ('simpan_transaksi_scan','lookup_rombel_barcode') ORDER BY 1;

-- 4. Role runtime v4 (harusnya belum ada sebelum migrasi utuh)
SELECT rolname FROM pg_roles WHERE rolname='sinabos_app';

-- 5. Status backfill available_delta
SELECT count(*) AS total_mutasi,
       count(*) FILTER (WHERE available_delta IS NULL) AS belum_klasifikasi,
       count(*) FILTER (WHERE tipe IN ('masuk','kembali') AND available_delta<0) AS delta_masuk_negatif
FROM public.stock_movements;

-- 6. Kandidat pelanggaran pengaman data (semua harus 0 sebelum migrasi utuh bisa COMMIT)
SELECT 'delta_belum_klasifikasi' AS cek, count(*) AS jumlah FROM public.stock_movements WHERE available_delta IS NULL
UNION ALL
SELECT 'saldo_ledger_negatif', count(*) FROM (
 SELECT buku_id FROM public.stock_movements GROUP BY buku_id HAVING sum(available_delta)<0) x
UNION ALL
SELECT 'pinjaman_negatif', count(*) FROM (
 SELECT t.rombel_barcode_id,i.buku_id FROM public.circulation_transactions t
 JOIN public.circulation_items i ON i.transaction_id=t.id
 GROUP BY t.rombel_barcode_id,i.buku_id
 HAVING sum(CASE WHEN t.jenis_transaksi='pinjam' THEN i.jumlah ELSE -i.jumlah END)<0) y;

-- 7. Kondisi kolom kunci (bandingkan nullable sebelum menjalankan 001-v4 utuh)
SELECT table_name,column_name,data_type,is_nullable FROM information_schema.columns
WHERE table_schema='public' AND table_name IN ('stock_movements','books','circulation_transactions','circulation_items')
AND column_name IN ('available_delta','total_buku','actor_id','request_id','judul_snapshot','revision','migration_note')
ORDER BY table_name,column_name;

-- 8. Seberapa besar data nyata di dalamnya
SELECT (SELECT count(*) FROM public.books) AS buku,
       (SELECT count(*) FROM public.circulation_transactions) AS transaksi,
       (SELECT count(*) FROM public.stock_movements) AS mutasi,
       (SELECT count(*) FROM public.sinabos_users) AS pengguna_v4;

COMMIT;
