-- ============================================================
-- SINABOS v3.0 — Data Contoh Form Transaksi
-- Jalankan setelah schema.sql. Tidak perlu menjalankan policies.sql Supabase.
-- ============================================================

insert into books (kode_buku, judul, mata_pelajaran, kelas_target, sumber_dana)
values
  ('MTK-VII', 'Buku Matematika VII', 'Matematika', 'VII', 'BOS'),
  ('IPA-VII', 'Buku IPA VII', 'IPA', 'VII', 'BOS'),
  ('BIN-VII', 'Buku Bahasa Indonesia VII', 'Bahasa Indonesia', 'VII', 'BOS'),
  ('MTK-VIII', 'Buku Matematika VIII', 'Matematika', 'VIII', 'BOS'),
  ('IPA-VIII', 'Buku IPA VIII', 'IPA', 'VIII', 'BOS')
on conflict (kode_buku) do update set
  judul = excluded.judul,
  mata_pelajaran = excluded.mata_pelajaran,
  kelas_target = excluded.kelas_target;

-- Stok awal: form operasional hanya membutuhkan jumlah + sumber diperoleh.
insert into stock_movements (buku_id, tipe, jumlah, sumber_perolehan, keterangan)
select b.id, 'masuk', 50, 'BOS 2026', 'Stok awal simulasi'
from books b
where b.kode_buku in ('MTK-VII','IPA-VII','BIN-VII','MTK-VIII','IPA-VIII')
  and not exists (
    select 1 from stock_movements sm
    where sm.buku_id = b.id
      and sm.tipe = 'masuk'
      and sm.sumber_perolehan = 'BOS 2026'
      and sm.keterangan = 'Stok awal simulasi'
  );

-- Satu barcode mewakili satu rombel. Setelah scan, form menampilkan
-- semua mapel pada kelas tersebut dan guru dapat menambah beberapa baris.
insert into rombel_barcodes (barcode, rombel, kelas_target, keterangan)
values
  ('RBL-VII-A', 'VII-A', 'VII', 'Barcode rombel VII-A'),
  ('RBL-VIII-A', 'VIII-A', 'VIII', 'Barcode rombel VIII-A')
on conflict (barcode) do update set
  rombel = excluded.rombel,
  kelas_target = excluded.kelas_target,
  keterangan = excluded.keterangan;

select * from v_stok order by kelas_target, kode_buku;
select * from rombel_barcodes order by barcode;
