-- Verifikasi setelah migrasi, baca-saja, tidak menampilkan password/session hash.
BEGIN TRANSACTION READ ONLY;
SELECT version,applied_at FROM public.sinabos_migrations;
SELECT count(*) AS jenis_buku,coalesce(sum(tersedia),0) AS tersedia,
       count(*) FILTER(WHERE needs_opening_review) AS perlu_rekonsiliasi FROM public.sinabos_stock;
-- Harus kosong: perbedaan saldo tersimpan vs ledger sumber.
SELECT b.buku_id,b.tersedia,coalesce(sum(m.available_delta),0) AS ledger
FROM public.sinabos_book_balances b LEFT JOIN public.stock_movements m ON m.buku_id=b.buku_id
GROUP BY b.buku_id,b.tersedia HAVING b.tersedia<>coalesce(sum(m.available_delta),0);
-- Harus kosong: perbedaan saldo rombel tersimpan vs item transaksi sumber.
WITH src AS (
 SELECT t.rombel_barcode_id,i.buku_id,sum(CASE WHEN t.jenis_transaksi='pinjam' THEN i.jumlah ELSE -i.jumlah END) AS sisa
 FROM public.circulation_transactions t JOIN public.circulation_items i ON i.transaction_id=t.id GROUP BY 1,2
)
SELECT coalesce(l.rombel_barcode_id,s.rombel_barcode_id) AS rombel_id,coalesce(l.buku_id,s.buku_id) AS buku_id,l.sisa,s.sisa AS ledger
FROM public.sinabos_loan_balances l FULL JOIN src s USING(rombel_barcode_id,buku_id)
WHERE coalesce(l.sisa,0)<>coalesce(s.sisa,0);
SELECT has_function_privilege('sinabos_app','public.sinabos_v4_api(text,text,jsonb,text)','EXECUTE') AS boleh_api,
       has_function_privilege('sinabos_app','public.sinabos_v4_bootstrap(text,text,text)','EXECUTE') AS boleh_bootstrap_harus_false,
       has_table_privilege('sinabos_app','public.sinabos_users','SELECT') AS boleh_baca_user_harus_false;
SELECT current_setting('TimeZone') AS zona_sesi_editor,(now() AT TIME ZONE 'Asia/Makassar')::date AS tanggal_sekolah;
COMMIT;
