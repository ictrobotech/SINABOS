-- SINABOS v4 — hanya untuk DATABASE LAMA v3, sebelum 001-v4.sql.
-- Semua query baca-saja. Untuk database baru yang belum memiliki books, lewati file ini.
-- Simpan hasil secara privat; tidak perlu membagikan password/connection string.
BEGIN TRANSACTION READ ONLY;
SELECT current_database() AS database,current_user AS role_editor,current_setting('TimeZone') AS zona_editor;
SELECT table_name,column_name,data_type,is_nullable FROM information_schema.columns
WHERE table_schema='public' AND table_name IN ('books','stock_movements','circulation_transactions')
ORDER BY table_name,ordinal_position;

-- A. Mutasi rusak/hilang yang perlu keputusan manusia.
-- Jika kolom available_delta sudah diisi melalui rekonsiliasi terverifikasi, nilainya dipertahankan.
SELECT m.id AS movement_id,m.buku_id,m.tipe,m.jumlah,m.transaksi_id,m.keterangan
FROM public.stock_movements m LEFT JOIN public.circulation_transactions t ON t.id=m.transaksi_id
WHERE m.tipe IN ('rusak','hilang')
  AND (t.id IS NULL OR t.jenis_transaksi<>'kembali')
  AND to_jsonb(m)->>'available_delta' IS NULL;

-- B. Saldo fisik calon v4. NULL berarti belum terklasifikasi; negatif menghentikan migrasi.
WITH impacts AS (
 SELECT m.buku_id,CASE
  WHEN to_jsonb(m)->>'available_delta' IS NOT NULL THEN (to_jsonb(m)->>'available_delta')::integer
  WHEN m.tipe IN ('masuk','kembali') THEN m.jumlah
  WHEN m.tipe='pinjam' THEN -m.jumlah
  WHEN m.tipe IN ('rusak','hilang') AND t.jenis_transaksi='kembali' THEN 0
  ELSE NULL END AS delta
 FROM public.stock_movements m LEFT JOIN public.circulation_transactions t ON t.id=m.transaksi_id
)
SELECT b.id,b.kode_buku,coalesce(sum(i.delta),0) AS saldo_terklasifikasi,
       count(*) FILTER(WHERE i.buku_id IS NOT NULL AND i.delta IS NULL) AS mutasi_belum_jelas
FROM public.books b LEFT JOIN impacts i ON i.buku_id=b.id GROUP BY b.id,b.kode_buku
HAVING coalesce(sum(i.delta),0)<0 OR count(*) FILTER(WHERE i.buku_id IS NOT NULL AND i.delta IS NULL)>0;

-- C. Master memiliki total tetapi tidak ada penerimaan. Jangan otomatis menambah angka ini.
SELECT b.id,b.kode_buku,(to_jsonb(b)->>'total_buku')::integer AS total_master_lama
FROM public.books b WHERE coalesce((to_jsonb(b)->>'total_buku')::integer,0)>0
AND NOT EXISTS(SELECT 1 FROM public.stock_movements m WHERE m.buku_id=b.id AND m.tipe='masuk');

-- D. Pinjaman negatif adalah inkonsistensi data lama yang menghentikan migrasi.
SELECT t.rombel_barcode_id,i.buku_id,
 sum(CASE WHEN t.jenis_transaksi='pinjam' THEN i.jumlah ELSE -i.jumlah END) AS sisa
FROM public.circulation_transactions t JOIN public.circulation_items i ON i.transaction_id=t.id
GROUP BY t.rombel_barcode_id,i.buku_id
HAVING sum(CASE WHEN t.jenis_transaksi='pinjam' THEN i.jumlah ELSE -i.jumlah END)<0;

-- E. Kode hanya berbeda kapital/spasi harus direkonsiliasi, bukan digabung otomatis.
SELECT lower(trim(kode_buku)) AS kode_normal,array_agg(kode_buku) AS variasi,count(*) AS jumlah
FROM public.books GROUP BY lower(trim(kode_buku)) HAVING count(*)>1;

-- F. Komponen lama yang mungkin memiliki dependency/grant khusus perlu diperiksa.
SELECT p.oid::regprocedure::text AS fungsi,p.prosecdef AS security_definer,p.proacl
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('simpan_transaksi_scan','lookup_rombel_barcode');
SELECT count(*) AS jumlah_transaksi,min(tanggal) AS tanggal_awal,max(tanggal) AS tanggal_akhir FROM public.circulation_transactions;
COMMIT;
