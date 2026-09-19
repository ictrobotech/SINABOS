-- ============================================================
-- SINABOS v3.0 — Scan Barcode Rombel + Form Transaksi
-- SMP LABSCHOOL UNTAD PALU · Neon PostgreSQL
--
-- Alur baru:
--   1. Guru scan barcode rombel.
--   2. Aplikasi menampilkan form: nama guru, jenis transaksi,
--      beberapa mapel, jumlah tiap mapel, tanggal otomatis, kondisi.
--   3. Submit form -> satu transaksi header + beberapa item + mutasi stok.
--   4. Transaksi tampil pada aplikasi admin.
--
-- Bukan model perpustakaan: tidak ada kartu anggota, denda,
-- jatuh tempo, atau peminjam individual yang harus dipilih dari master.
-- ============================================================

create extension if not exists "pgcrypto";

drop view if exists v_peminjaman_aktif;
drop view if exists v_transaksi_admin;
drop view if exists v_mutasi_bulanan;
drop view if exists v_barcode_aktif;
drop view if exists v_stok;

-- 1) MASTER JENIS BUKU / MAPEL
create table if not exists books (
  id uuid primary key default gen_random_uuid(),
  kode_buku text unique not null,
  judul text not null,
  mata_pelajaran text,
  kelas_target text not null,
  sumber_dana text not null default 'BOS',
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);

-- Kompatibilitas jika books pernah dibuat oleh starter kit sebelumnya.
alter table books add column if not exists mata_pelajaran text;
alter table books add column if not exists kelas_target text;
alter table books add column if not exists sumber_dana text default 'BOS';
alter table books add column if not exists aktif boolean default true;

create index if not exists idx_books_judul on books using gin (to_tsvector('simple', judul));
create index if not exists idx_books_kode on books(kode_buku);
create index if not exists idx_books_kelas on books(kelas_target);
create index if not exists idx_books_aktif on books(aktif);

-- 2) MASTER BARCODE ROMBEL
-- Satu barcode mengidentifikasi rombel, bukan satu mapel.
-- Contoh: RBL-VII-A membuka form untuk semua buku kelas VII.
create table if not exists rombel_barcodes (
  id uuid primary key default gen_random_uuid(),
  barcode text not null unique,
  rombel text not null,
  kelas_target text not null,
  keterangan text,
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);

create unique index if not exists uq_rombel_barcodes_lower
  on rombel_barcodes (lower(barcode));
create index if not exists idx_rombel_barcodes_kelas on rombel_barcodes(kelas_target);
create index if not exists idx_rombel_barcodes_rombel on rombel_barcodes(rombel);

-- 3) HEADER TRANSAKSI
-- Akses database pada versi Neon dilakukan server-side melalui Apps Script.
-- Profil login tidak dibuat di schema ini; identitas guru tersimpan pada transaksi.

create table if not exists circulation_transactions (
  id uuid primary key default gen_random_uuid(),
  kode_transaksi text unique not null,
  rombel_barcode_id uuid not null references rombel_barcodes(id) on delete restrict,
  barcode text not null,
  rombel text not null,
  kelas_target text not null,
  nama_guru text not null,
  jenis_transaksi text not null check (jenis_transaksi in ('pinjam','kembali')),
  tanggal date not null default current_date,
  created_at timestamptz not null default now()
);

create index if not exists idx_transactions_barcode on circulation_transactions(rombel_barcode_id);
create index if not exists idx_transactions_tanggal on circulation_transactions(tanggal desc);
create index if not exists idx_transactions_guru on circulation_transactions(nama_guru);
create index if not exists idx_transactions_jenis on circulation_transactions(jenis_transaksi);

-- 5) ITEM TRANSAKSI (satu transaksi boleh berisi banyak mapel)
create table if not exists circulation_items (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references circulation_transactions(id) on delete cascade,
  buku_id uuid not null references books(id) on delete restrict,
  jumlah int not null check (jumlah > 0),
  kondisi text not null default 'baik'
    check (kondisi in ('baik','rusak','hilang')),
  keterangan text
);

create index if not exists idx_circulation_items_transaction on circulation_items(transaction_id);
create index if not exists idx_circulation_items_buku on circulation_items(buku_id);

-- 6) MUTASI STOK
-- Untuk tipe masuk, operator hanya mengisi jumlah + sumber_perolehan.
-- Untuk pinjam/kembali/rusak/hilang, baris dibuat otomatis oleh RPC transaksi.
create table if not exists stock_movements (
  id uuid primary key default gen_random_uuid(),
  buku_id uuid not null references books(id) on delete restrict,
  transaksi_id uuid references circulation_transactions(id) on delete set null,
  rombel_barcode_id uuid references rombel_barcodes(id) on delete set null,
  tipe text not null check (tipe in ('masuk','pinjam','kembali','rusak','hilang')),
  jumlah int not null check (jumlah > 0),
  sumber_perolehan text,
  tanggal date not null default current_date,
  keterangan text,
  created_at timestamptz not null default now(),
  constraint sumber_masuk_wajib check (
    tipe <> 'masuk' or nullif(trim(sumber_perolehan), '') is not null
  )
);

-- Kompatibilitas jika tabel stock_movements sudah ada dari starter kit lama.
alter table stock_movements add column if not exists transaksi_id uuid references circulation_transactions(id) on delete set null;
alter table stock_movements add column if not exists rombel_barcode_id uuid references rombel_barcodes(id) on delete set null;
alter table stock_movements add column if not exists sumber_perolehan text;

create index if not exists idx_stock_buku on stock_movements(buku_id);
create index if not exists idx_stock_transaksi on stock_movements(transaksi_id);
create index if not exists idx_stock_tipe on stock_movements(tipe);
create index if not exists idx_stock_tanggal on stock_movements(tanggal);

-- ============================================================
-- RPC: LOOKUP ROMBEL
-- Dipanggil setelah barcode dipindai untuk membuka form.
-- ============================================================

drop function if exists public.lookup_rombel_barcode(text);
create or replace function public.lookup_rombel_barcode(p_barcode text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rombel rombel_barcodes%rowtype;
  v_books jsonb;
  v_aktif jsonb;
begin
  select rb.* into v_rombel
  from rombel_barcodes rb
  where lower(rb.barcode) = lower(trim(p_barcode))
    and rb.aktif = true;

  if not found then
    raise exception 'Barcode rombel tidak terdaftar atau nonaktif';
  end if;

  select coalesce(jsonb_agg(to_jsonb(b) order by b.judul), '[]'::jsonb)
    into v_books
    from books b
   where b.aktif = true
     and b.kelas_target = v_rombel.kelas_target;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.judul), '[]'::jsonb)
    into v_aktif
    from v_peminjaman_aktif x
   where x.barcode = v_rombel.barcode;

  return jsonb_build_object(
    'ok', true,
    'barcode', v_rombel.barcode,
    'rombel', v_rombel.rombel,
    'kelas_target', v_rombel.kelas_target,
    'keterangan', coalesce(v_rombel.keterangan, ''),
    'books', v_books,
    'aktif', v_aktif
  );
end;
$$;

-- ============================================================
-- RPC: SIMPAN TRANSAKSI HASIL FORM
-- Menulis header, item multi-mapel, dan mutasi stok secara atomik.
-- ============================================================

drop function if exists public.simpan_transaksi_scan(text, text, text, jsonb);
create or replace function public.simpan_transaksi_scan(
  p_barcode text,
  p_jenis_transaksi text,
  p_nama_guru text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rombel rombel_barcodes%rowtype;
  v_transaksi circulation_transactions%rowtype;
  v_item jsonb;
  v_buku books%rowtype;
  v_buku_id uuid;
  v_jumlah int;
  v_kondisi text;
  v_tersedia int;
  v_sisa int;
  v_kode text;
  v_tipe_mutasi text;
  v_total int := 0;
begin
  if nullif(trim(p_barcode), '') is null then
    raise exception 'Barcode wajib diisi';
  end if;
  if p_jenis_transaksi not in ('pinjam','kembali') then
    raise exception 'Jenis transaksi harus pinjam atau kembali';
  end if;
  if nullif(trim(p_nama_guru), '') is null then
    raise exception 'Nama guru wajib diisi';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Minimal satu buku/mapel harus diisi';
  end if;

  select rb.* into v_rombel
  from rombel_barcodes rb
  where lower(rb.barcode) = lower(trim(p_barcode))
    and rb.aktif = true
  for update;

  if not found then
    raise exception 'Barcode rombel tidak terdaftar atau nonaktif';
  end if;

  -- Satu mapel hanya boleh muncul satu kali dalam satu submit.
  if exists (
    select 1
    from jsonb_array_elements(p_items) as z(value)
    group by (z.value ->> 'buku_id')
    having count(*) > 1
  ) then
    raise exception 'Mapel yang sama hanya boleh satu baris; ubah jumlah pada baris tersebut';
  end if;

  v_kode := 'TRX-' || to_char(current_date, 'YYYYMMDD') || '-' ||
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

  insert into circulation_transactions (
    kode_transaksi, rombel_barcode_id, barcode, rombel, kelas_target,
    nama_guru, jenis_transaksi
  ) values (
    v_kode, v_rombel.id, v_rombel.barcode, v_rombel.rombel,
    v_rombel.kelas_target, trim(p_nama_guru), p_jenis_transaksi
  ) returning * into v_transaksi;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_buku_id := (v_item ->> 'buku_id')::uuid;
    exception when others then
      raise exception 'buku_id pada form tidak valid';
    end;

    v_jumlah := (v_item ->> 'jumlah')::int;
    v_kondisi := coalesce(nullif(v_item ->> 'kondisi', ''), 'baik');

    if v_jumlah is null or v_jumlah <= 0 then
      raise exception 'Jumlah setiap buku harus lebih dari 0';
    end if;
    if v_kondisi not in ('baik','rusak','hilang') then
      raise exception 'Kondisi buku tidak valid';
    end if;

    select * into v_buku
    from books b
    where b.id = v_buku_id
      and b.aktif = true
      and b.kelas_target = v_rombel.kelas_target
    for update;

    if not found then
      raise exception 'Buku/mapel tidak tersedia untuk kelas rombel ini';
    end if;

    if p_jenis_transaksi = 'pinjam' then
      select coalesce(s.tersedia, 0) into v_tersedia
      from v_stok s where s.id = v_buku_id;

      if coalesce(v_tersedia, 0) < v_jumlah then
        raise exception 'Stok % tidak cukup (tersedia %, diminta %)',
          v_buku.judul, coalesce(v_tersedia, 0), v_jumlah;
      end if;
      v_tipe_mutasi := 'pinjam';
    else
      select coalesce(sum(
        case when t.jenis_transaksi = 'pinjam' then ci.jumlah else -ci.jumlah end
      ), 0)::int into v_sisa
      from circulation_transactions t
      join circulation_items ci on ci.transaction_id = t.id
      where t.rombel_barcode_id = v_rombel.id
        and ci.buku_id = v_buku_id;

      if v_sisa < v_jumlah then
        raise exception 'Jumlah kembali untuk % melebihi sisa rombel (sisa %, diminta %)',
          v_buku.judul, v_sisa, v_jumlah;
      end if;

      if v_kondisi = 'baik' then
        v_tipe_mutasi := 'kembali';
      else
        v_tipe_mutasi := v_kondisi;
      end if;
    end if;

    insert into circulation_items (transaction_id, buku_id, jumlah, kondisi)
    values (v_transaksi.id, v_buku_id, v_jumlah, v_kondisi);

    insert into stock_movements (
      buku_id, transaksi_id, rombel_barcode_id, tipe, jumlah,
      tanggal, keterangan
    ) values (
      v_buku_id, v_transaksi.id, v_rombel.id, v_tipe_mutasi, v_jumlah,
      current_date, 'Form scan ' || p_jenis_transaksi || ' • ' || v_rombel.rombel
    );

    v_total := v_total + v_jumlah;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'kode_transaksi', v_transaksi.kode_transaksi,
    'jenis_transaksi', v_transaksi.jenis_transaksi,
    'barcode', v_transaksi.barcode,
    'rombel', v_transaksi.rombel,
    'nama_guru', v_transaksi.nama_guru,
    'jumlah_total', v_total,
    'tanggal', v_transaksi.tanggal
  );
end;
$$;

-- Fungsi dipanggil oleh Apps Script melalui koneksi PostgreSQL server-side.
-- Tidak ada role service_role pada Neon; akses publik tidak dibuka.

-- ============================================================
-- VIEWS MONITORING
-- ============================================================

create or replace view v_stok as
select
  b.id,
  b.kode_buku,
  b.judul,
  b.mata_pelajaran,
  b.kelas_target,
  b.sumber_dana,
  b.aktif,
  coalesce(sum(case when s.tipe = 'masuk' then s.jumlah else 0 end), 0)::int as total_masuk,
  coalesce(sum(case when s.tipe = 'pinjam' then s.jumlah else 0 end), 0)::int as total_pinjam,
  coalesce(sum(case when s.tipe = 'kembali' then s.jumlah else 0 end), 0)::int as total_kembali,
  coalesce(sum(case when s.tipe in ('rusak','hilang') then s.jumlah else 0 end), 0)::int as total_rusak_hilang,
  (
    coalesce(sum(case when s.tipe in ('masuk','kembali') then s.jumlah else 0 end), 0)
    - coalesce(sum(case when s.tipe in ('pinjam','rusak','hilang') then s.jumlah else 0 end), 0)
  )::int as tersedia
from books b
left join stock_movements s on s.buku_id = b.id
group by b.id, b.kode_buku, b.judul, b.mata_pelajaran,
         b.kelas_target, b.sumber_dana, b.aktif;

create or replace view v_peminjaman_aktif as
select
  t.rombel_barcode_id,
  t.barcode,
  t.rombel,
  t.kelas_target,
  ci.buku_id,
  b.kode_buku,
  b.judul,
  b.mata_pelajaran,
  sum(case when t.jenis_transaksi = 'pinjam' then ci.jumlah else 0 end)::int as total_pinjam,
  sum(case when t.jenis_transaksi = 'kembali' then ci.jumlah else 0 end)::int as total_kembali,
  (
    sum(case when t.jenis_transaksi = 'pinjam' then ci.jumlah else 0 end)
    - sum(case when t.jenis_transaksi = 'kembali' then ci.jumlah else 0 end)
  )::int as sisa,
  max(t.nama_guru) as guru_terakhir,
  max(t.tanggal) as transaksi_terakhir
from circulation_transactions t
join circulation_items ci on ci.transaction_id = t.id
join books b on b.id = ci.buku_id
group by t.rombel_barcode_id, t.barcode, t.rombel, t.kelas_target,
         ci.buku_id, b.kode_buku, b.judul, b.mata_pelajaran
having (
  sum(case when t.jenis_transaksi = 'pinjam' then ci.jumlah else 0 end)
  - sum(case when t.jenis_transaksi = 'kembali' then ci.jumlah else 0 end)
) > 0;

create or replace view v_transaksi_admin as
select
  t.id,
  t.kode_transaksi,
  t.tanggal,
  t.jenis_transaksi,
  t.nama_guru,
  t.barcode,
  t.rombel,
  t.kelas_target,
  t.created_at,
  string_agg(
    b.judul || ' ×' || ci.jumlah || ' (' || ci.kondisi || ')',
    '; ' order by b.judul
  ) as rincian,
  sum(ci.jumlah)::int as jumlah_total
from circulation_transactions t
join circulation_items ci on ci.transaction_id = t.id
join books b on b.id = ci.buku_id
group by t.id, t.kode_transaksi, t.tanggal, t.jenis_transaksi,
         t.nama_guru, t.barcode, t.rombel, t.kelas_target, t.created_at
order by t.created_at desc;

create or replace view v_mutasi_bulanan as
select
  to_char(s.tanggal, 'YYYY-MM') as bulan,
  b.kode_buku,
  b.judul,
  sum(case when s.tipe = 'masuk' then s.jumlah else 0 end)::int as masuk,
  sum(case when s.tipe = 'pinjam' then s.jumlah else 0 end)::int as dipinjam,
  sum(case when s.tipe = 'kembali' then s.jumlah else 0 end)::int as kembali,
  sum(case when s.tipe in ('rusak','hilang') then s.jumlah else 0 end)::int as rusak_hilang,
  string_agg(distinct s.sumber_perolehan, ', ')
    filter (where s.sumber_perolehan is not null) as sumber
from stock_movements s
join books b on b.id = s.buku_id
group by 1, 2, 3
order by 1 desc, 2;

-- Selesai. Lanjutkan dengan seed.sql. policies.sql versi Supabase tidak digunakan pada Neon.
