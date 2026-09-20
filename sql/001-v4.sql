-- SINABOS 4.0.0 — migration atomik: instalasi baru atau upgrade schema v3 terlampir.
-- WAJIB: backup, branch staging, jalankan 000-preflight.sql, hentikan penulisan v3 saat cutover.
-- Tidak memuat seed produksi, tidak menebak stok awal, tidak mengubah tanggal transaksi lama.
BEGIN;
SELECT pg_advisory_xact_lock(734120260001::bigint);
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE TABLE IF NOT EXISTS public.sinabos_migrations(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.books (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kode_buku text UNIQUE NOT NULL, judul text NOT NULL,
 mata_pelajaran text, kelas_target text NOT NULL, tahun_terbit text, penulis text, penerbit text,
 kurikulum text, sumber_buku text, isbn text, edisi text, total_buku integer NOT NULL DEFAULT 0 CHECK(total_buku>=0),
 sumber_dana text NOT NULL DEFAULT 'BOS', aktif boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS tahun_terbit text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS penulis text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS penerbit text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS kurikulum text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS sumber_buku text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS isbn text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS edisi text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS total_buku integer DEFAULT 0;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;
CREATE UNIQUE INDEX IF NOT EXISTS sinabos_books_code_normalized ON public.books(lower(trim(kode_buku)));
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS legacy_total_buku integer;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS legacy_reviewed_at timestamptz;
CREATE TABLE IF NOT EXISTS public.rombel_barcodes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), barcode text UNIQUE NOT NULL, rombel text NOT NULL,
 kelas_target text NOT NULL, keterangan text, aktif boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.rombel_barcodes ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;
CREATE UNIQUE INDEX IF NOT EXISTS uq_rombel_barcodes_lower ON public.rombel_barcodes(lower(barcode));
CREATE TABLE IF NOT EXISTS public.circulation_transactions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kode_transaksi text UNIQUE NOT NULL,
 rombel_barcode_id uuid NOT NULL REFERENCES public.rombel_barcodes(id) ON DELETE RESTRICT,
 barcode text NOT NULL, rombel text NOT NULL, kelas_target text NOT NULL, nama_guru text NOT NULL,
 jenis_transaksi text NOT NULL CHECK(jenis_transaksi IN ('pinjam','kembali')),
 tanggal date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Makassar')::date, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.circulation_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), transaction_id uuid NOT NULL REFERENCES public.circulation_transactions(id) ON DELETE CASCADE,
 buku_id uuid NOT NULL REFERENCES public.books(id) ON DELETE RESTRICT, jumlah integer NOT NULL CHECK(jumlah>0),
 kondisi text NOT NULL DEFAULT 'baik' CHECK(kondisi IN ('baik','rusak','hilang')), keterangan text
);
CREATE TABLE IF NOT EXISTS public.stock_movements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), buku_id uuid NOT NULL REFERENCES public.books(id) ON DELETE RESTRICT,
 transaksi_id uuid REFERENCES public.circulation_transactions(id) ON DELETE SET NULL,
 rombel_barcode_id uuid REFERENCES public.rombel_barcodes(id) ON DELETE SET NULL,
 tipe text NOT NULL CHECK(tipe IN ('masuk','pinjam','kembali','rusak','hilang')), jumlah integer NOT NULL CHECK(jumlah>0),
 sumber_perolehan text, tanggal date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Makassar')::date,
 keterangan text, created_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT sumber_masuk_wajib CHECK(tipe<>'masuk' OR nullif(trim(sumber_perolehan),'') IS NOT NULL)
);
LOCK TABLE public.books, public.rombel_barcodes, public.circulation_transactions, public.circulation_items, public.stock_movements IN SHARE ROW EXCLUSIVE MODE;

CREATE TABLE IF NOT EXISTS public.sinabos_users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), username text NOT NULL UNIQUE CHECK(username ~ '^[a-z0-9][a-z0-9._-]{2,39}$'),
 full_name text NOT NULL CHECK(length(trim(full_name)) BETWEEN 2 AND 100),
 role text NOT NULL CHECK(role IN ('admin','guru')), password_hash text NOT NULL,
 active boolean NOT NULL DEFAULT true, must_change_password boolean NOT NULL DEFAULT true,
 tema text NOT NULL DEFAULT 'modern' CHECK(tema IN ('modern','profesional','emerald')),
 revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.sinabos_sessions (
 token_hash text PRIMARY KEY CHECK(token_hash ~ '^[0-9a-f]{64}$'), user_id uuid NOT NULL REFERENCES public.sinabos_users(id),
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sinabos_sessions_user ON public.sinabos_sessions(user_id);
CREATE INDEX IF NOT EXISTS sinabos_sessions_expiry ON public.sinabos_sessions(expires_at);
CREATE TABLE IF NOT EXISTS public.sinabos_limits (key text PRIMARY KEY, hits integer NOT NULL, expires_at timestamptz NOT NULL);
CREATE INDEX IF NOT EXISTS sinabos_limits_expiry ON public.sinabos_limits(expires_at);
CREATE TABLE IF NOT EXISTS public.sinabos_requests (
 request_id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES public.sinabos_users(id), action text NOT NULL,
 payload_hash text NOT NULL, secret_hash text, result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.sinabos_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, actor_id uuid REFERENCES public.sinabos_users(id),
 action text NOT NULL, object_id text, request_id uuid, detail jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sinabos_audit_time ON public.sinabos_audit(created_at DESC,id DESC);
ALTER TABLE public.circulation_transactions ADD COLUMN IF NOT EXISTS actor_id uuid REFERENCES public.sinabos_users(id);
ALTER TABLE public.circulation_transactions ADD COLUMN IF NOT EXISTS request_id uuid;
CREATE UNIQUE INDEX IF NOT EXISTS sinabos_transactions_request ON public.circulation_transactions(request_id) WHERE request_id IS NOT NULL;
ALTER TABLE public.circulation_items ADD COLUMN IF NOT EXISTS judul_snapshot text;
ALTER TABLE public.circulation_items ADD COLUMN IF NOT EXISTS mapel_snapshot text;
ALTER TABLE public.circulation_items ADD COLUMN IF NOT EXISTS kode_snapshot text;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS available_delta integer;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS actor_id uuid REFERENCES public.sinabos_users(id);
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS request_id uuid;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS migration_note text;
ALTER TABLE public.circulation_transactions ALTER COLUMN tanggal SET DEFAULT (now() AT TIME ZONE 'Asia/Makassar')::date;
ALTER TABLE public.stock_movements ALTER COLUMN tanggal SET DEFAULT (now() AT TIME ZONE 'Asia/Makassar')::date;

-- Master v3 bukan ledger. Simpan angka asal, jangan otomatis menjadikannya stok tambahan.
UPDATE public.books SET legacy_total_buku=coalesce(total_buku,0)
WHERE legacy_total_buku IS NULL AND NOT EXISTS(SELECT 1 FROM public.sinabos_migrations WHERE version='4.0.0');
UPDATE public.books SET total_buku=0 WHERE total_buku IS NULL;
ALTER TABLE public.books ALTER COLUMN total_buku SET NOT NULL;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.books'::regclass AND conname='sinabos_total_nonnegative') THEN
  ALTER TABLE public.books ADD CONSTRAINT sinabos_total_nonnegative CHECK(total_buku>=0);
 END IF;
END $$;
UPDATE public.circulation_items i SET judul_snapshot=b.judul,mapel_snapshot=coalesce(b.mata_pelajaran,''),kode_snapshot=b.kode_buku
FROM public.books b WHERE b.id=i.buku_id AND i.judul_snapshot IS NULL;
-- Snapshot historis ini menggunakan master saat migrasi; tidak mengklaim memulihkan judul asli masa lalu.
UPDATE public.stock_movements SET available_delta=CASE WHEN tipe IN ('masuk','kembali') THEN jumlah ELSE -jumlah END
WHERE available_delta IS NULL AND tipe IN ('masuk','kembali','pinjam');
UPDATE public.stock_movements m SET available_delta=0
FROM public.circulation_transactions t
WHERE m.available_delta IS NULL AND m.tipe IN ('rusak','hilang') AND m.transaksi_id=t.id AND t.jenis_transaksi='kembali';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.stock_movements WHERE available_delta IS NULL) THEN
  RAISE EXCEPTION 'MIGRASI DIHENTIKAN: klasifikasikan mutasi rusak/hilang tanpa pengembalian yang jelas. Baca docs/MIGRASI.md; tidak ada data yang diubah.';
 END IF;
 IF EXISTS(SELECT 1 FROM public.stock_movements GROUP BY buku_id HAVING sum(available_delta)<0) THEN
  RAISE EXCEPTION 'MIGRASI DIHENTIKAN: saldo ledger negatif. Rekonsiliasi pada branch staging dengan stok fisik; jangan menebak stok awal.';
 END IF;
 IF EXISTS(SELECT 1 FROM public.circulation_items i JOIN public.circulation_transactions t ON t.id=i.transaction_id
   GROUP BY t.rombel_barcode_id,i.buku_id HAVING sum(CASE WHEN t.jenis_transaksi='pinjam' THEN i.jumlah ELSE -i.jumlah END)<0) THEN
  RAISE EXCEPTION 'MIGRASI DIHENTIKAN: ada pengembalian melebihi peminjaman pada data lama.';
 END IF;
END $$;
ALTER TABLE public.stock_movements ALTER COLUMN available_delta SET NOT NULL;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.stock_movements'::regclass AND conname='sinabos_delta_valid') THEN
  ALTER TABLE public.stock_movements ADD CONSTRAINT sinabos_delta_valid CHECK(
   (tipe IN ('masuk','kembali') AND available_delta=jumlah) OR
   (tipe='pinjam' AND available_delta=-jumlah) OR
   (tipe IN ('rusak','hilang') AND available_delta IN (0,-jumlah))
  );
 END IF;
END $$;

-- Saldo materialized, diperbarui DALAM transaksi yang sama dengan ledger.
CREATE TABLE IF NOT EXISTS public.sinabos_book_balances (
 buku_id uuid PRIMARY KEY REFERENCES public.books(id), tersedia integer NOT NULL DEFAULT 0 CHECK(tersedia>=0),
 total_masuk integer NOT NULL DEFAULT 0, total_pinjam integer NOT NULL DEFAULT 0, total_kembali integer NOT NULL DEFAULT 0,
 total_rusak integer NOT NULL DEFAULT 0, total_hilang integer NOT NULL DEFAULT 0
);
INSERT INTO public.sinabos_book_balances(buku_id,tersedia,total_masuk,total_pinjam,total_kembali,total_rusak,total_hilang)
SELECT b.id,coalesce(sum(m.available_delta),0)::int,
 coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='masuk'),0)::int,coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='pinjam'),0)::int,
 coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='kembali'),0)::int,coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='rusak'),0)::int,
 coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='hilang'),0)::int
FROM public.books b LEFT JOIN public.stock_movements m ON m.buku_id=b.id GROUP BY b.id
ON CONFLICT(buku_id) DO UPDATE SET tersedia=excluded.tersedia,total_masuk=excluded.total_masuk,total_pinjam=excluded.total_pinjam,
 total_kembali=excluded.total_kembali,total_rusak=excluded.total_rusak,total_hilang=excluded.total_hilang;
UPDATE public.books b SET total_buku=s.total_masuk FROM public.sinabos_book_balances s WHERE s.buku_id=b.id;
CREATE TABLE IF NOT EXISTS public.sinabos_loan_balances (
 rombel_barcode_id uuid NOT NULL REFERENCES public.rombel_barcodes(id), buku_id uuid NOT NULL REFERENCES public.books(id),
 total_pinjam integer NOT NULL DEFAULT 0, total_kembali integer NOT NULL DEFAULT 0, sisa integer NOT NULL DEFAULT 0 CHECK(sisa>=0),
 pelaku_terakhir text, updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(rombel_barcode_id,buku_id)
);
INSERT INTO public.sinabos_loan_balances(rombel_barcode_id,buku_id,total_pinjam,total_kembali,sisa,pelaku_terakhir,updated_at)
SELECT t.rombel_barcode_id,i.buku_id,
 sum(i.jumlah) FILTER(WHERE t.jenis_transaksi='pinjam'),coalesce(sum(i.jumlah) FILTER(WHERE t.jenis_transaksi='kembali'),0),
 sum(CASE WHEN t.jenis_transaksi='pinjam' THEN i.jumlah ELSE -i.jumlah END),
 (array_agg(t.nama_guru ORDER BY t.created_at DESC,t.id DESC))[1],max(t.created_at)
FROM public.circulation_transactions t JOIN public.circulation_items i ON i.transaction_id=t.id GROUP BY t.rombel_barcode_id,i.buku_id
ON CONFLICT(rombel_barcode_id,buku_id) DO UPDATE SET total_pinjam=excluded.total_pinjam,total_kembali=excluded.total_kembali,
 sisa=excluded.sisa,pelaku_terakhir=excluded.pelaku_terakhir,updated_at=excluded.updated_at;
CREATE INDEX IF NOT EXISTS sinabos_loans_open ON public.sinabos_loan_balances(buku_id,rombel_barcode_id) WHERE sisa>0;
CREATE INDEX IF NOT EXISTS sinabos_tx_cursor ON public.circulation_transactions(created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS sinabos_tx_actor_cursor ON public.circulation_transactions(actor_id,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS sinabos_tx_local_day ON public.circulation_transactions(tanggal);
CREATE INDEX IF NOT EXISTS sinabos_items_tx ON public.circulation_items(transaction_id);
CREATE INDEX IF NOT EXISTS sinabos_movements_book ON public.stock_movements(buku_id);
CREATE INDEX IF NOT EXISTS sinabos_movements_date ON public.stock_movements(tanggal,buku_id);
CREATE INDEX IF NOT EXISTS sinabos_books_order ON public.books(kelas_target,kode_buku,id);
CREATE INDEX IF NOT EXISTS sinabos_books_search ON public.books USING gin(lower(kode_buku||' '||judul||' '||coalesce(mata_pelajaran,'')) gin_trgm_ops);

CREATE OR REPLACE FUNCTION public.sinabos_v4_stock_trigger() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 INSERT INTO public.sinabos_book_balances(buku_id) VALUES(NEW.buku_id) ON CONFLICT DO NOTHING;
 UPDATE public.sinabos_book_balances SET tersedia=tersedia+NEW.available_delta,
 total_masuk=total_masuk+CASE WHEN NEW.tipe='masuk' THEN NEW.jumlah ELSE 0 END,
 total_pinjam=total_pinjam+CASE WHEN NEW.tipe='pinjam' THEN NEW.jumlah ELSE 0 END,
 total_kembali=total_kembali+CASE WHEN NEW.tipe='kembali' THEN NEW.jumlah ELSE 0 END,
 total_rusak=total_rusak+CASE WHEN NEW.tipe='rusak' THEN NEW.jumlah ELSE 0 END,
 total_hilang=total_hilang+CASE WHEN NEW.tipe='hilang' THEN NEW.jumlah ELSE 0 END WHERE buku_id=NEW.buku_id;
 IF NEW.tipe='masuk' THEN
  UPDATE public.books SET total_buku=(SELECT total_masuk FROM public.sinabos_book_balances WHERE buku_id=NEW.buku_id) WHERE id=NEW.buku_id;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER sinabos_stock_insert AFTER INSERT ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION public.sinabos_v4_stock_trigger();
CREATE OR REPLACE FUNCTION public.sinabos_v4_loan_trigger() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE t public.circulation_transactions%rowtype;
BEGIN
 SELECT * INTO STRICT t FROM public.circulation_transactions WHERE id=NEW.transaction_id;
 INSERT INTO public.sinabos_loan_balances(rombel_barcode_id,buku_id) VALUES(t.rombel_barcode_id,NEW.buku_id) ON CONFLICT DO NOTHING;
 UPDATE public.sinabos_loan_balances SET
 total_pinjam=total_pinjam+CASE WHEN t.jenis_transaksi='pinjam' THEN NEW.jumlah ELSE 0 END,
 total_kembali=total_kembali+CASE WHEN t.jenis_transaksi='kembali' THEN NEW.jumlah ELSE 0 END,
 sisa=sisa+CASE WHEN t.jenis_transaksi='pinjam' THEN NEW.jumlah ELSE -NEW.jumlah END,
 pelaku_terakhir=t.nama_guru,updated_at=now() WHERE rombel_barcode_id=t.rombel_barcode_id AND buku_id=NEW.buku_id;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER sinabos_loan_insert AFTER INSERT ON public.circulation_items FOR EACH ROW EXECUTE FUNCTION public.sinabos_v4_loan_trigger();
CREATE OR REPLACE VIEW public.sinabos_stock AS
SELECT b.id,b.kode_buku,b.judul,b.mata_pelajaran,b.kelas_target,b.tahun_terbit,b.penulis,b.penerbit,b.kurikulum,b.sumber_buku,b.sumber_dana,b.aktif,b.revision,
 s.total_masuk AS total_buku,s.total_masuk,s.total_pinjam,s.total_kembali,(s.total_rusak+s.total_hilang)::int AS total_rusak_hilang,
 s.total_rusak,s.total_hilang,s.tersedia,
 coalesce((SELECT sum(l.sisa)::int FROM public.sinabos_loan_balances l WHERE l.buku_id=b.id AND l.sisa>0),0) AS dipinjam,
 b.legacy_total_buku,(coalesce(b.legacy_total_buku,0)>0 AND b.legacy_reviewed_at IS NULL AND s.total_masuk=0) AS needs_opening_review,b.isbn,b.edisi
FROM public.books b JOIN public.sinabos_book_balances s ON s.buku_id=b.id;
-- Pertahankan urutan/tipe kolom view v3 yang ada; perbaiki sumber saldonya tanpa DROP VIEW.
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(quote_ident(column_name),',' ORDER BY ordinal_position) INTO cols FROM information_schema.columns WHERE table_schema='public' AND table_name='v_stok';
 IF cols IS NULL THEN cols:='id,kode_buku,judul,mata_pelajaran,kelas_target,total_buku,sumber_dana,aktif,total_masuk,total_pinjam,total_kembali,total_rusak_hilang,tersedia'; END IF;
 EXECUTE 'CREATE OR REPLACE VIEW public.v_stok AS SELECT '||cols||' FROM public.sinabos_stock';
END $$;

CREATE OR REPLACE FUNCTION public.sinabos_v4_limit(p_key text,p_max int,p_seconds int) RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE n int; k text:=p_key||':'||floor(extract(epoch FROM now())/p_seconds)::text;
BEGIN
 INSERT INTO public.sinabos_limits(key,hits,expires_at) VALUES(k,1,now()+make_interval(secs=>p_seconds*2))
 ON CONFLICT(key) DO UPDATE SET hits=sinabos_limits.hits+1 RETURNING hits INTO n;
 RETURN n<=p_max;
END $$;
CREATE OR REPLACE FUNCTION public.sinabos_v4_require_text(p_value text,p_label text,p_max int) RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF nullif(trim(p_value),'') IS NULL OR length(trim(p_value))>p_max THEN RAISE EXCEPTION '% wajib diisi (maksimum % karakter)',p_label,p_max; END IF;
 RETURN trim(p_value);
END $$;
CREATE OR REPLACE FUNCTION public.sinabos_v4_password(p_password text) RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF p_password IS NULL OR length(p_password)<12 OR octet_length(p_password)>72 THEN RAISE EXCEPTION 'Password minimal 12 karakter dan maksimal 72 byte UTF-8'; END IF;
 RETURN public.crypt(p_password,public.gen_salt('bf',12));
END $$;

-- Hanya pemilik migrasi boleh bootstrap, tidak diberikan kepada role aplikasi.
CREATE OR REPLACE FUNCTION public.sinabos_v4_bootstrap(p_username text,p_name text,p_password text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE id_out uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(734120260002::bigint);
 IF EXISTS(SELECT 1 FROM public.sinabos_users WHERE role='admin') THEN RAISE EXCEPTION 'Admin sudah ada; gunakan pengelolaan akun di aplikasi'; END IF;
 INSERT INTO public.sinabos_users(username,full_name,role,password_hash,must_change_password)
 VALUES(lower(trim(p_username)),public.sinabos_v4_require_text(p_name,'Nama',100),'admin',public.sinabos_v4_password(p_password),false) RETURNING id INTO id_out;
 INSERT INTO public.sinabos_audit(actor_id,action,object_id) VALUES(id_out,'bootstrap',id_out::text);
 RETURN id_out;
END $$;

-- Parameterized bootstrap role: rahasia tidak dirangkai dalam query SQL sisi klien.
-- SECURITY INVOKER: hanya pemilik yang memang punya CREATEROLE dapat menjalankannya.
CREATE OR REPLACE FUNCTION public.sinabos_v4_runtime_role(p_role text,p_password text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF p_role IS NULL OR p_role !~ '^[a-z][a-z0-9_]{2,50}$' OR length(coalesce(p_password,''))<32 THEN RAISE EXCEPTION 'Nama role atau password runtime tidak memenuhi syarat'; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=p_role) THEN RAISE EXCEPTION 'Role runtime sudah ada; pilih nama baru untuk rotasi terencana'; END IF;
 EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L IN ROLE sinabos_app',p_role,p_password);
END $$;

-- Dispatch hanya dijalankan setelah sesi valid. Runtime tidak memperoleh EXECUTE langsung.
CREATE OR REPLACE FUNCTION public.sinabos_v4_dispatch(p_action text,u public.sinabos_users,p jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
 result jsonb; rows_out jsonb; r public.rombel_barcodes%rowtype; b public.books%rowtype; t public.circulation_transactions%rowtype;
 target_user public.sinabos_users%rowtype; x jsonb; g record; qty int; avail int; remaining int;
 entity uuid; rid uuid; page_size int:=least(greatest(coalesce((p->>'limit')::int,25),1),100);
 skip int:=least(greatest(coalesce((p->>'offset')::int,0),0),100000);
 search text:=lower(left(coalesce(p->>'q',''),80)); tx_kind text; cond text; actor_label text:=u.full_name;
 month_start date; month_end date; code text; title text; subject text; class_name text; src text; v_isbn text; v_edisi text;
BEGIN
 IF p_action='saveTheme' THEN
  IF u.role<>'admin' THEN RAISE EXCEPTION USING ERRCODE='S0403',MESSAGE='Hanya admin yang dapat mengubah tema'; END IF;
  DECLARE v_tema text:=lower(coalesce(p->>'tema','')); BEGIN
   IF v_tema NOT IN ('modern','profesional','emerald') THEN RAISE EXCEPTION 'Tema tidak dikenal'; END IF;
   UPDATE public.sinabos_users SET tema=v_tema,revision=revision+1 WHERE id=u.id;
   RETURN jsonb_build_object('tema',v_tema);
  END;
 ELSIF p_action='me' THEN
  RETURN jsonb_build_object('user',jsonb_build_object('id',u.id,'username',u.username,'full_name',u.full_name,'role',u.role,'must_change_password',u.must_change_password,'tema',u.tema));
 END IF;
 IF u.must_change_password AND p_action NOT IN ('changePassword','logout') THEN RAISE EXCEPTION USING ERRCODE='S0403',MESSAGE='Ganti password sementara sebelum menggunakan aplikasi'; END IF;
 IF p_action IN ('dashboard','books','saveBook','stockIn','stockLoss','rombel','saveRombel','users','saveUser','resetPassword','resetBooks','saveTheme','report','audit','active','health') AND u.role<>'admin' THEN
  RAISE EXCEPTION USING ERRCODE='S0403',MESSAGE='Akses ini hanya untuk admin';
 END IF;
 IF p_action='logout' THEN RETURN '{}'::jsonb;
 ELSIF p_action='health' THEN RETURN jsonb_build_object('schema_version',(SELECT version FROM public.sinabos_migrations ORDER BY applied_at DESC LIMIT 1),'database','Terhubung');
 ELSIF p_action='dashboard' THEN
  SELECT jsonb_build_object('jenis',(SELECT count(*) FROM public.books WHERE aktif),'tersedia',coalesce(sum(s.tersedia),0),
  'dipinjam',(SELECT coalesce(sum(sisa),0) FROM public.sinabos_loan_balances WHERE sisa>0),
  'rusak',coalesce(sum(s.total_rusak),0),'hilang',coalesce(sum(s.total_hilang),0),
  'hari_ini',(SELECT count(*) FROM public.circulation_transactions WHERE tanggal=(now() AT TIME ZONE 'Asia/Makassar')::date),
  'review',(SELECT count(*) FROM public.sinabos_stock WHERE needs_opening_review)) INTO result FROM public.sinabos_book_balances s;
  RETURN result;
 ELSIF p_action='books' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.kelas_target,a.kode_buku,a.id),'[]'::jsonb) INTO rows_out FROM (
   SELECT s.* FROM public.sinabos_stock s WHERE (search='' OR lower(s.kode_buku||' '||s.judul||' '||coalesce(s.mata_pelajaran,'')) LIKE '%'||search||'%')
   AND (coalesce(p->>'kelas','')='' OR s.kelas_target=p->>'kelas') AND (coalesce((p->>'review')::boolean,false)=false OR s.needs_opening_review) ORDER BY s.kelas_target,s.kode_buku,s.id LIMIT page_size+1 OFFSET skip
  ) a;
  RETURN jsonb_build_object('rows',rows_out,'limit',page_size);
 ELSIF p_action='scan' THEN
  SELECT * INTO r FROM public.rombel_barcodes WHERE lower(barcode)=lower(trim(p->>'barcode'));
  IF NOT FOUND THEN RAISE EXCEPTION 'Barcode rombel tidak ditemukan'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',b2.id,'kode_buku',b2.kode_buku,'judul',b2.judul,'mata_pelajaran',b2.mata_pelajaran,
    'tersedia',s.tersedia,'sisa',coalesce(l.sisa,0),'can_borrow',r.aktif AND b2.aktif AND b2.kelas_target=r.kelas_target) ORDER BY b2.judul),'[]') INTO rows_out
  FROM public.books b2 JOIN public.sinabos_book_balances s ON s.buku_id=b2.id
  LEFT JOIN public.sinabos_loan_balances l ON l.buku_id=b2.id AND l.rombel_barcode_id=r.id
  WHERE (r.aktif AND b2.aktif AND b2.kelas_target=r.kelas_target) OR coalesce(l.sisa,0)>0;
  RETURN jsonb_build_object('rombel',to_jsonb(r),'books',rows_out);
 ELSIF p_action='history' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC,a.id DESC),'[]') INTO rows_out FROM (
   SELECT t2.id,t2.kode_transaksi,t2.barcode,t2.rombel,t2.kelas_target,t2.nama_guru,t2.jenis_transaksi,t2.tanggal,t2.created_at,
    (SELECT jsonb_agg(jsonb_build_object('judul',i.judul_snapshot,'mapel',i.mapel_snapshot,'jumlah',i.jumlah,'kondisi',i.kondisi) ORDER BY i.judul_snapshot,i.kondisi) FROM public.circulation_items i WHERE i.transaction_id=t2.id) AS items
   FROM public.circulation_transactions t2 WHERE (u.role='admin' OR t2.actor_id=u.id)
    AND (nullif(p->>'cursor_time','') IS NULL OR (t2.created_at,t2.id)<((p->>'cursor_time')::timestamptz,(p->>'cursor_id')::uuid))
    AND (nullif(p->>'from','') IS NULL OR t2.tanggal>=(p->>'from')::date)
    AND (nullif(p->>'to','') IS NULL OR t2.tanggal<=(p->>'to')::date)
   ORDER BY t2.created_at DESC,t2.id DESC LIMIT page_size+1
  ) a;
  RETURN jsonb_build_object('rows',rows_out,'limit',page_size);
 ELSIF p_action='active' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.rombel,a.judul),'[]') INTO rows_out FROM (
   SELECT r2.rombel,r2.barcode,b2.judul,l.* FROM public.sinabos_loan_balances l JOIN public.rombel_barcodes r2 ON r2.id=l.rombel_barcode_id JOIN public.books b2 ON b2.id=l.buku_id
   WHERE l.sisa>0 AND (search='' OR lower(r2.rombel||' '||b2.judul) LIKE '%'||search||'%') ORDER BY r2.rombel,b2.judul,l.buku_id LIMIT page_size+1 OFFSET skip
  ) a; RETURN jsonb_build_object('rows',rows_out,'limit',page_size);
 ELSIF p_action='requestStatus' THEN
  SELECT a.result INTO result FROM public.sinabos_requests a WHERE a.request_id=(p->>'request_id')::uuid AND a.user_id=u.id;
  RETURN jsonb_build_object('found',FOUND,'result',result);
 ELSIF p_action='circulate' THEN
  rid:=(p->>'request_id')::uuid; tx_kind:=p->>'jenis_transaksi';
  IF tx_kind IS NULL OR tx_kind NOT IN ('pinjam','kembali') THEN RAISE EXCEPTION 'Jenis transaksi tidak valid'; END IF;
  IF jsonb_typeof(p->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Rincian buku harus berupa daftar'; END IF;
  IF jsonb_array_length(p->'items') NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'Isi 1 sampai 30 baris buku'; END IF;
  SELECT * INTO r FROM public.rombel_barcodes WHERE lower(barcode)=lower(trim(p->>'barcode')) FOR UPDATE;
  IF NOT FOUND OR (tx_kind='pinjam' AND NOT r.aktif) THEN RAISE EXCEPTION 'Barcode tidak ditemukan atau tidak aktif'; END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p->'items') LOOP
   IF jsonb_typeof(x->'jumlah') IS DISTINCT FROM 'number' OR coalesce(x->>'jumlah','') !~ '^[0-9]+$' THEN RAISE EXCEPTION 'Jumlah tiap baris harus bilangan bulat'; END IF;
   qty:=(x->>'jumlah')::int;
   IF qty NOT BETWEEN 1 AND 100000 OR x->>'buku_id' IS NULL THEN RAISE EXCEPTION 'Buku dan jumlah (1–100000) wajib diisi'; END IF;
   cond:=x->>'kondisi';
   IF cond IS NULL OR cond NOT IN ('baik','rusak','hilang') OR (tx_kind='pinjam' AND cond<>'baik') THEN RAISE EXCEPTION 'Peminjaman hanya untuk buku baik; kondisi pengembalian harus valid'; END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p->'items') AS elem(value) GROUP BY (elem.value->>'buku_id')::uuid,elem.value->>'kondisi' HAVING count(*)>1) THEN RAISE EXCEPTION 'Gabungkan baris buku dengan kondisi yang sama'; END IF;
  -- Semua jalur sirkulasi memakai urutan rombel lalu UUID buku yang konsisten.
  FOR g IN SELECT (value->>'buku_id')::uuid AS id,sum((value->>'jumlah')::int)::int AS jumlah FROM jsonb_array_elements(p->'items') GROUP BY 1 ORDER BY 1 LOOP
   SELECT * INTO b FROM public.books WHERE id=g.id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Buku tidak ditemukan'; END IF;
   IF tx_kind='pinjam' THEN
    IF NOT b.aktif OR b.kelas_target<>r.kelas_target THEN RAISE EXCEPTION 'Buku tidak tersedia untuk kelas rombel'; END IF;
    SELECT tersedia INTO avail FROM public.sinabos_book_balances WHERE buku_id=b.id;
    IF coalesce(avail,0)<g.jumlah THEN RAISE EXCEPTION 'Stok % tidak cukup (tersedia %, diminta %)',b.judul,coalesce(avail,0),g.jumlah; END IF;
   ELSE
    SELECT sisa INTO remaining FROM public.sinabos_loan_balances WHERE buku_id=b.id AND rombel_barcode_id=r.id;
    IF coalesce(remaining,0)<g.jumlah THEN RAISE EXCEPTION 'Pengembalian % melebihi sisa rombel (%)',b.judul,coalesce(remaining,0); END IF;
   END IF;
  END LOOP;
  entity:=gen_random_uuid(); code:='TRX-'||to_char((now() AT TIME ZONE 'Asia/Makassar')::date,'YYYYMMDD')||'-'||upper(replace(entity::text,'-',''));
  INSERT INTO public.circulation_transactions(id,kode_transaksi,rombel_barcode_id,barcode,rombel,kelas_target,nama_guru,jenis_transaksi,actor_id,request_id)
  VALUES(entity,code,r.id,r.barcode,r.rombel,r.kelas_target,u.full_name,tx_kind,u.id,rid) RETURNING * INTO t;
  FOR x IN SELECT value FROM jsonb_array_elements(p->'items') ORDER BY (value->>'buku_id')::uuid,value->>'kondisi' LOOP
   SELECT * INTO b FROM public.books WHERE id=(x->>'buku_id')::uuid; qty:=(x->>'jumlah')::int;cond:=x->>'kondisi';
   INSERT INTO public.circulation_items(transaction_id,buku_id,jumlah,kondisi,judul_snapshot,mapel_snapshot,kode_snapshot)
   VALUES(t.id,b.id,qty,cond,b.judul,coalesce(b.mata_pelajaran,''),b.kode_buku);
   INSERT INTO public.stock_movements(buku_id,transaksi_id,rombel_barcode_id,tipe,jumlah,available_delta,actor_id,request_id,keterangan)
   VALUES(b.id,t.id,r.id,CASE WHEN tx_kind='pinjam' THEN 'pinjam' WHEN cond='baik' THEN 'kembali' ELSE cond END,qty,
   CASE WHEN tx_kind='pinjam' THEN -qty WHEN cond='baik' THEN qty ELSE 0 END,u.id,rid,'Sirkulasi rombel '||r.rombel);
  END LOOP;
  SELECT coalesce(jsonb_agg(jsonb_build_object('judul',i.judul_snapshot,'jumlah',i.jumlah,'kondisi',i.kondisi) ORDER BY i.judul_snapshot,i.kondisi),'[]') INTO rows_out FROM public.circulation_items i WHERE transaction_id=t.id;
  RETURN jsonb_build_object('receipt',to_jsonb(t)||jsonb_build_object('items',rows_out));
 ELSIF p_action='saveBook' THEN
  code:=upper(public.sinabos_v4_require_text(p->>'kode_buku','Kode buku',60)); title:=public.sinabos_v4_require_text(p->>'judul','Judul',200);
  subject:=public.sinabos_v4_require_text(p->>'mata_pelajaran','Mapel',100);class_name:=p->>'kelas_target';src:=public.sinabos_v4_require_text(p->>'sumber_buku','Sumber',150);
  IF class_name IS NULL OR class_name NOT IN ('VII','VIII','IX') THEN RAISE EXCEPTION 'Pilih kelas VII, VIII, atau IX'; END IF;
  IF coalesce(p->>'tahun_terbit','') !~ '^(19|20)[0-9]{2}$' THEN RAISE EXCEPTION 'Tahun terbit harus empat digit (1900–2099)'; END IF;
  PERFORM public.sinabos_v4_require_text(p->>'penulis','Penulis',150);PERFORM public.sinabos_v4_require_text(p->>'penerbit','Penerbit',150);PERFORM public.sinabos_v4_require_text(p->>'kurikulum','Kurikulum',100);
  v_isbn:=nullif(left(trim(coalesce(p->>'isbn','')),32),''); v_edisi:=nullif(left(trim(coalesce(p->>'edisi','')),40),'');
  IF v_isbn IS NOT NULL AND v_isbn !~ '^[0-9Xx][0-9Xx\- ]*$' THEN RAISE EXCEPTION 'ISBN hanya boleh berisi angka, spasi, tanda hubung, atau X'; END IF;
  entity:=nullif(p->>'id','')::uuid;
  IF entity IS NULL THEN
   IF coalesce(p->>'total_awal','') !~ '^[0-9]+$' OR (p->>'total_awal')::int NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION 'Stok awal harus bilangan bulat 0–100000'; END IF;
   qty:=(p->>'total_awal')::int;
   INSERT INTO public.books(kode_buku,judul,mata_pelajaran,kelas_target,tahun_terbit,penulis,penerbit,kurikulum,sumber_buku,isbn,edisi)
   VALUES(code,title,subject,class_name,p->>'tahun_terbit',trim(p->>'penulis'),trim(p->>'penerbit'),trim(p->>'kurikulum'),src,v_isbn,v_edisi) RETURNING id INTO entity;
   INSERT INTO public.sinabos_book_balances(buku_id) VALUES(entity);
   IF qty>0 THEN INSERT INTO public.stock_movements(buku_id,tipe,jumlah,available_delta,sumber_perolehan,keterangan,actor_id,request_id)
    VALUES(entity,'masuk',qty,qty,src,'Stok awal saat pembuatan buku',u.id,(p->>'request_id')::uuid); END IF;
  ELSE
   SELECT * INTO b FROM public.books WHERE id=entity FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Buku tidak ditemukan'; END IF;
   IF b.revision IS DISTINCT FROM (p->>'revision')::int THEN RAISE EXCEPTION USING ERRCODE='S0409',MESSAGE='Data telah berubah. Muat ulang sebelum mengedit'; END IF;
   IF (b.kelas_target<>class_name OR (coalesce((p->>'aktif')::boolean,true)=false)) AND EXISTS(SELECT 1 FROM public.sinabos_loan_balances WHERE buku_id=entity AND sisa>0) THEN
    RAISE EXCEPTION 'Kelas/status buku tidak dapat diubah selama ada pinjaman aktif'; END IF;
   UPDATE public.books SET kode_buku=code,judul=title,mata_pelajaran=subject,kelas_target=class_name,tahun_terbit=p->>'tahun_terbit',
    penulis=trim(p->>'penulis'),penerbit=trim(p->>'penerbit'),kurikulum=trim(p->>'kurikulum'),isbn=v_isbn,edisi=v_edisi,sumber_buku=src,aktif=coalesce((p->>'aktif')::boolean,true),revision=revision+1 WHERE id=entity;
  END IF;
  RETURN jsonb_build_object('book',(SELECT to_jsonb(s) FROM public.sinabos_stock s WHERE id=entity));
 ELSIF p_action IN ('stockIn','stockLoss') THEN
  entity:=(p->>'buku_id')::uuid;SELECT * INTO b FROM public.books WHERE id=entity FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Buku tidak ditemukan'; END IF;
  IF coalesce(p->>'jumlah','') !~ '^[0-9]+$' OR (p->>'jumlah')::int NOT BETWEEN 1 AND 100000 THEN RAISE EXCEPTION 'Jumlah harus bilangan bulat 1–100000'; END IF;
  qty:=(p->>'jumlah')::int; title:=public.sinabos_v4_require_text(p->>'keterangan','Alasan/catatan',300);
  SELECT tersedia INTO avail FROM public.sinabos_book_balances WHERE buku_id=entity;
  IF p_action='stockIn' THEN
   src:=public.sinabos_v4_require_text(p->>'sumber_perolehan','Sumber perolehan',150);
   IF EXISTS(SELECT 1 FROM public.sinabos_stock WHERE id=entity AND needs_opening_review) AND coalesce((p->>'acknowledge_legacy')::boolean,false)=false THEN
    RAISE EXCEPTION 'Periksa stok fisik dan setujui rekonsiliasi angka master lama terlebih dahulu'; END IF;
   INSERT INTO public.stock_movements(buku_id,tipe,jumlah,available_delta,sumber_perolehan,keterangan,actor_id,request_id) VALUES(entity,'masuk',qty,qty,src,title,u.id,(p->>'request_id')::uuid);
   UPDATE public.books SET legacy_reviewed_at=now() WHERE id=entity;
  ELSE
   cond:=p->>'kondisi';IF cond IS NULL OR cond NOT IN ('rusak','hilang') THEN RAISE EXCEPTION 'Pilih rusak atau hilang'; END IF;
   IF coalesce(avail,0)<qty THEN RAISE EXCEPTION 'Jumlah melebihi stok tersedia di rak'; END IF;
   INSERT INTO public.stock_movements(buku_id,tipe,jumlah,available_delta,keterangan,actor_id,request_id) VALUES(entity,cond,qty,-qty,title,u.id,(p->>'request_id')::uuid);
  END IF;
  RETURN jsonb_build_object('book',(SELECT to_jsonb(s) FROM public.sinabos_stock s WHERE id=entity));
 ELSIF p_action='resetBooks' THEN
  IF EXISTS(SELECT 1 FROM public.circulation_transactions) THEN RAISE EXCEPTION USING ERRCODE='S0409',MESSAGE='Reset data buku hanya dapat dilakukan sebelum ada transaksi tersimpan. Gunakan Stok masuk / Kerusakan untuk koreksi angka.'; END IF;
  SELECT count(*) INTO qty FROM public.books;
  SELECT count(*) INTO remaining FROM public.stock_movements;
  DELETE FROM public.stock_movements;
  DELETE FROM public.sinabos_book_balances;
  DELETE FROM public.books;
  RETURN jsonb_build_object('ok',true,'reset',jsonb_build_object('buku',qty,'mutasi',remaining));
 ELSIF p_action='rombel' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.kelas_target,a.rombel),'[]') INTO rows_out FROM public.rombel_barcodes a;
  RETURN jsonb_build_object('rows',rows_out);
 ELSIF p_action='saveRombel' THEN
  code:=upper(public.sinabos_v4_require_text(p->>'barcode','Barcode',60));title:=public.sinabos_v4_require_text(p->>'rombel','Rombel',40);class_name:=p->>'kelas_target';
  IF code !~ '^[A-Z0-9_-]{3,60}$' OR class_name IS NULL OR class_name NOT IN ('VII','VIII','IX') THEN RAISE EXCEPTION 'Format barcode atau kelas tidak valid'; END IF;
  entity:=nullif(p->>'id','')::uuid;
  IF entity IS NULL THEN INSERT INTO public.rombel_barcodes(barcode,rombel,kelas_target,keterangan) VALUES(code,title,class_name,left(coalesce(p->>'keterangan',''),200)) RETURNING id INTO entity;
  ELSE
   SELECT * INTO r FROM public.rombel_barcodes WHERE id=entity FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Rombel tidak ditemukan'; END IF;
   IF r.revision IS DISTINCT FROM (p->>'revision')::int THEN RAISE EXCEPTION USING ERRCODE='S0409',MESSAGE='Rombel telah berubah; muat ulang sebelum mengedit'; END IF;
   IF (r.kelas_target<>class_name OR coalesce((p->>'aktif')::boolean,true)=false) AND EXISTS(SELECT 1 FROM public.sinabos_loan_balances WHERE rombel_barcode_id=entity AND sisa>0) THEN RAISE EXCEPTION 'Selesaikan pinjaman sebelum mengubah kelas atau menonaktifkan rombel'; END IF;
   UPDATE public.rombel_barcodes SET barcode=code,rombel=title,kelas_target=class_name,keterangan=left(coalesce(p->>'keterangan',''),200),aktif=coalesce((p->>'aktif')::boolean,true),revision=revision+1 WHERE id=entity;
  END IF;
  RETURN jsonb_build_object('rombel',(SELECT to_jsonb(a) FROM public.rombel_barcodes a WHERE id=entity));
 ELSIF p_action='users' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.full_name),'[]') INTO rows_out FROM (
   SELECT id,username,full_name,role,active,must_change_password,revision FROM public.sinabos_users WHERE search='' OR lower(username||' '||full_name) LIKE '%'||search||'%' ORDER BY full_name,id LIMIT page_size+1 OFFSET skip
  ) a;RETURN jsonb_build_object('rows',rows_out,'limit',page_size);
 ELSIF p_action IN ('saveUser','resetPassword') THEN
  PERFORM pg_advisory_xact_lock(734120260002::bigint);
  entity:=nullif(p->>'id','')::uuid;
  IF p_action='resetPassword' THEN
   IF entity=u.id THEN RAISE EXCEPTION 'Gunakan menu Ganti Password untuk akun sendiri'; END IF;
   UPDATE public.sinabos_users SET password_hash=public.sinabos_v4_password(p->>'password'),must_change_password=true,revision=revision+1 WHERE id=entity;
   IF NOT FOUND THEN RAISE EXCEPTION 'Akun tidak ditemukan'; END IF;
   DELETE FROM public.sinabos_sessions WHERE user_id=entity;
  ELSE
   code:=lower(trim(p->>'username'));title:=public.sinabos_v4_require_text(p->>'full_name','Nama',100);cond:=p->>'role';
   IF code IS NULL OR code !~ '^[a-z0-9][a-z0-9._-]{2,39}$' OR cond IS NULL OR cond NOT IN ('admin','guru') THEN RAISE EXCEPTION 'Username atau peran tidak valid'; END IF;
   IF entity IS NULL THEN
    INSERT INTO public.sinabos_users(username,full_name,role,password_hash) VALUES(code,title,cond,public.sinabos_v4_password(p->>'password')) RETURNING id INTO entity;
   ELSE
    SELECT * INTO target_user FROM public.sinabos_users WHERE id=entity FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Akun tidak ditemukan'; END IF;
    IF target_user.revision IS DISTINCT FROM (p->>'revision')::int THEN RAISE EXCEPTION USING ERRCODE='S0409',MESSAGE='Akun telah berubah; muat ulang'; END IF;
    IF entity=u.id AND (cond<>'admin' OR coalesce((p->>'active')::boolean,true)=false) THEN RAISE EXCEPTION 'Tidak dapat menurunkan akses atau menonaktifkan akun sendiri'; END IF;
    IF target_user.role='admin' AND target_user.active AND (cond<>'admin' OR coalesce((p->>'active')::boolean,true)=false) AND (SELECT count(*) FROM public.sinabos_users WHERE role='admin' AND active)<=1 THEN RAISE EXCEPTION 'Minimal satu admin aktif harus dipertahankan'; END IF;
    UPDATE public.sinabos_users SET username=code,full_name=title,role=cond,active=coalesce((p->>'active')::boolean,true),revision=revision+1 WHERE id=entity;
    IF entity<>u.id THEN DELETE FROM public.sinabos_sessions WHERE user_id=entity; END IF;
   END IF;
  END IF;
  RETURN jsonb_build_object('id',entity);
 ELSIF p_action='changePassword' THEN
  IF coalesce(p->>'old_password','')='' OR u.password_hash<>public.crypt(p->>'old_password',u.password_hash) THEN RAISE EXCEPTION 'Password lama tidak sesuai'; END IF;
  UPDATE public.sinabos_users SET password_hash=public.sinabos_v4_password(p->>'new_password'),must_change_password=false,revision=revision+1 WHERE id=u.id;
  DELETE FROM public.sinabos_sessions WHERE user_id=u.id;
  INSERT INTO public.sinabos_sessions(token_hash,user_id,expires_at) VALUES(p->>'new_session_hash',u.id,now()+interval '8 hours');
  RETURN jsonb_build_object('message','Password diperbarui. Sesi perangkat lain telah ditutup');
 ELSIF p_action='report' THEN
  IF coalesce(p->>'month','') !~ '^20[0-9]{2}-(0[1-9]|1[0-2])$' THEN RAISE EXCEPTION 'Format bulan tidak valid'; END IF;
  month_start:=(p->>'month'||'-01')::date;month_end:=(month_start+interval '1 month')::date;
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.kode_buku),'[]') INTO rows_out FROM (
   SELECT b2.kode_buku,b2.judul,b2.kelas_target,
   coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='masuk'),0) AS masuk,coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='pinjam'),0) AS pinjam,
   coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='kembali'),0) AS kembali_baik,coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='rusak'),0) AS rusak,
   coalesce(sum(m.jumlah) FILTER(WHERE m.tipe='hilang'),0) AS hilang,sum(m.available_delta) AS perubahan_tersedia,
   string_agg(DISTINCT m.sumber_perolehan,', ') AS sumber
   FROM public.stock_movements m JOIN public.books b2 ON b2.id=m.buku_id WHERE m.tanggal>=month_start AND m.tanggal<month_end
   GROUP BY b2.id,b2.kode_buku,b2.judul,b2.kelas_target ORDER BY b2.kode_buku LIMIT 10001
  ) a;
  IF jsonb_array_length(rows_out)>10000 THEN RAISE EXCEPTION 'Laporan melebihi batas 10000 jenis buku; gunakan ekspor terjadwal'; END IF;
  RETURN jsonb_build_object('rows',rows_out,'month',p->>'month');
 ELSIF p_action='audit' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.id DESC),'[]') INTO rows_out FROM (
   SELECT a2.id,a2.created_at,a2.action,a2.object_id,a2.detail,u2.full_name FROM public.sinabos_audit a2 LEFT JOIN public.sinabos_users u2 ON u2.id=a2.actor_id
   WHERE nullif(p->>'cursor','') IS NULL OR a2.id<(p->>'cursor')::bigint ORDER BY a2.id DESC LIMIT page_size+1
  ) a;RETURN jsonb_build_object('rows',rows_out,'limit',page_size);
 END IF;
 RAISE EXCEPTION 'Action tidak dikenal';
END $$;

CREATE OR REPLACE FUNCTION public.sinabos_v4_api(p_action text,p_session_hash text,p_payload jsonb,p_ip_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE u public.sinabos_users%rowtype; p jsonb:=coalesce(p_payload,'{}'); result jsonb; previous public.sinabos_requests%rowtype;
 rid uuid; fingerprint text; is_mutation boolean:=p_action IN ('circulate','saveBook','stockIn','stockLoss','saveRombel','saveUser','resetPassword','resetBooks','saveTheme');
 code text; public_message text;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR octet_length(p::text)>65536 OR length(coalesce(p_ip_key,'')) NOT BETWEEN 8 AND 100 THEN RETURN jsonb_build_object('ok',false,'code','BAD_REQUEST','error','Payload tidak valid','status',400); END IF;
 IF random()<0.01 THEN
  DELETE FROM public.sinabos_limits WHERE key IN (SELECT key FROM public.sinabos_limits WHERE expires_at<now() LIMIT 500);
  DELETE FROM public.sinabos_sessions WHERE token_hash IN (SELECT token_hash FROM public.sinabos_sessions WHERE expires_at<now() LIMIT 500);
 END IF;
 IF p_action='login' THEN
  IF NOT public.sinabos_v4_limit('login-ip:'||p_ip_key,60,60) OR NOT public.sinabos_v4_limit('login-user:'||encode(public.digest(left(lower(trim(coalesce(p->>'username',''))),40),'sha256'),'hex'),5,600) THEN
   RETURN jsonb_build_object('ok',false,'code','RATE_LIMIT','error','Terlalu banyak percobaan login. Tunggu 10 menit','status',429);
  END IF;
  SELECT * INTO u FROM public.sinabos_users WHERE username=lower(trim(p->>'username')) AND active;
  -- Hash dummy tetap menjalankan bcrypt untuk username yang tidak dikenal.
  IF u.id IS NULL THEN PERFORM public.crypt(left(coalesce(p->>'password',''),72),'$2a$12$abcdefghijklmnopqrstuuE7.TbbrK7mMmiuA.k.IpGNfgBdFYFk6');
   RETURN jsonb_build_object('ok',false,'code','LOGIN_FAILED','error','Username atau password tidak sesuai','status',401);
  END IF;
  IF octet_length(coalesce(p->>'password','')) NOT BETWEEN 1 AND 72 OR u.password_hash<>public.crypt(p->>'password',u.password_hash) THEN
   INSERT INTO public.sinabos_audit(actor_id,action) VALUES(u.id,'login_failed');
   RETURN jsonb_build_object('ok',false,'code','LOGIN_FAILED','error','Username atau password tidak sesuai','status',401);
  END IF;
  INSERT INTO public.sinabos_sessions(token_hash,user_id,expires_at) VALUES(p->>'new_session_hash',u.id,now()+interval '8 hours');
  INSERT INTO public.sinabos_audit(actor_id,action) VALUES(u.id,'login');
  result:=public.sinabos_v4_dispatch('me',u,'{}');
  RETURN result||jsonb_build_object('ok',true,'server_date',(now() AT TIME ZONE 'Asia/Makassar')::date);
 END IF;
 -- Tema untuk halaman login (sebelum sesi): mengikuti tema akun admin aktif pertama. Hanya baca; perubahan tetap lewat saveTheme admin.
 IF p_action='siteTheme' THEN
  IF NOT public.sinabos_v4_limit('site:'||p_ip_key,60,60) THEN RETURN jsonb_build_object('ok',false,'code','RATE_LIMIT','error','Terlalu banyak permintaan; tunggu satu menit','status',429); END IF;
  RETURN jsonb_build_object('ok',true,'tema',coalesce((SELECT tema FROM public.sinabos_users WHERE role='admin' AND active ORDER BY id LIMIT 1),'modern'),'server_date',(now() AT TIME ZONE 'Asia/Makassar')::date);
 END IF;
 SELECT a.* INTO u FROM public.sinabos_sessions s JOIN public.sinabos_users a ON a.id=s.user_id WHERE s.token_hash=p_session_hash AND s.expires_at>now() AND a.active;
 IF u.id IS NULL THEN
  IF NOT public.sinabos_v4_limit('unauth:'||p_ip_key,120,60) THEN RETURN jsonb_build_object('ok',false,'code','RATE_LIMIT','error','Terlalu banyak permintaan; tunggu satu menit','status',429); END IF;
  RETURN jsonb_build_object('ok',false,'code','UNAUTHENTICATED','error','Silakan login; sesi tidak tersedia atau sudah berakhir','status',401); END IF;
 IF NOT public.sinabos_v4_limit('user:'||u.id::text,180,60) THEN RETURN jsonb_build_object('ok',false,'code','RATE_LIMIT','error','Terlalu banyak permintaan; tunggu satu menit','status',429); END IF;
 IF p_action='changePassword' AND NOT public.sinabos_v4_limit('password:'||u.id::text,5,600) THEN RETURN jsonb_build_object('ok',false,'code','RATE_LIMIT','error','Tunggu 10 menit sebelum mencoba mengganti password lagi','status',429); END IF;
 -- Error operasi di bawah rollback subtransaksi, tetapi penghitung rate limit di atas tetap tersimpan.
 BEGIN
  IF is_mutation THEN
   rid:=(p->>'request_id')::uuid;
   IF rid IS NULL THEN RAISE EXCEPTION 'request_id wajib diisi'; END IF;
   fingerprint:=encode(public.digest((p-'password')::text,'sha256'),'hex');
   -- Password tidak masuk fingerprint cepat. Pada replay akun, verifikasi bcrypt terpisah.
   PERFORM pg_advisory_xact_lock(hashtextextended(rid::text,2026));
   SELECT * INTO previous FROM public.sinabos_requests WHERE request_id=rid;
   IF FOUND THEN
    IF previous.user_id<>u.id OR previous.action<>p_action OR previous.payload_hash<>fingerprint OR (previous.secret_hash IS NOT NULL AND (p->>'password' IS NULL OR public.crypt(p->>'password',previous.secret_hash)<>previous.secret_hash)) THEN RAISE EXCEPTION USING ERRCODE='S0409',MESSAGE='Request ID sudah dipakai untuk data lain'; END IF;
    -- Tetap periksa otorisasi saat replay, termasuk role yang mungkin berubah.
    IF u.must_change_password OR (p_action<>'circulate' AND u.role<>'admin') THEN RAISE EXCEPTION USING ERRCODE='S0403',MESSAGE='Akses tidak diizinkan'; END IF;
    RETURN previous.result||jsonb_build_object('replayed',true);
   END IF;
  END IF;
  result:=public.sinabos_v4_dispatch(p_action,u,p)||jsonb_build_object('ok',true,'server_date',(now() AT TIME ZONE 'Asia/Makassar')::date);
  IF p_action='logout' THEN DELETE FROM public.sinabos_sessions WHERE token_hash=p_session_hash; END IF;
  IF is_mutation THEN
   INSERT INTO public.sinabos_requests(request_id,user_id,action,payload_hash,secret_hash,result) VALUES(rid,u.id,p_action,fingerprint,CASE WHEN p_action IN ('saveUser','resetPassword') AND p->>'password' IS NOT NULL THEN (SELECT password_hash FROM public.sinabos_users WHERE id=(result->>'id')::uuid) ELSE NULL END,result);
   INSERT INTO public.sinabos_audit(actor_id,action,object_id,request_id,detail) VALUES(u.id,p_action,coalesce(result#>>'{book,id}',result#>>'{receipt,id}',result#>>'{rombel,id}',result->>'id'),rid,
    CASE WHEN p_action IN ('stockIn','stockLoss') THEN jsonb_build_object('jumlah',p->'jumlah','catatan',p->>'keterangan') ELSE '{}'::jsonb END);
  ELSIF p_action IN ('logout','changePassword') THEN INSERT INTO public.sinabos_audit(actor_id,action) VALUES(u.id,p_action); END IF;
  RETURN result;
 EXCEPTION
  WHEN SQLSTATE 'S0403' THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN','error',SQLERRM,'status',403);
  WHEN SQLSTATE 'S0409' THEN RETURN jsonb_build_object('ok',false,'code','CONFLICT','error',SQLERRM,'status',409);
  WHEN unique_violation THEN RETURN jsonb_build_object('ok',false,'code','CONFLICT','error','Kode buku, barcode, atau username sudah digunakan','status',409);
  WHEN invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow OR check_violation OR not_null_violation THEN
   RETURN jsonb_build_object('ok',false,'code','VALIDATION','error','Format, jumlah, atau kelengkapan data tidak valid','status',422);
  WHEN raise_exception THEN RETURN jsonb_build_object('ok',false,'code','VALIDATION','error',SQLERRM,'status',422);
  WHEN deadlock_detected OR serialization_failure THEN RETURN jsonb_build_object('ok',false,'code','RETRY_SAME_REQUEST','error','Data sedang diproses bersamaan. Ulangi permintaan dengan ID yang sama','status',503);
  WHEN OTHERS THEN
   RAISE LOG 'SINABOS action=% SQLSTATE=%',p_action,SQLSTATE;
   RETURN jsonb_build_object('ok',false,'code','DATABASE_ERROR','error','Operasi dibatalkan karena gangguan database. Hubungi admin dengan ID permintaan','status',500);
 END;
END $$;

-- Nonaktifkan jalur tulis sirkulasi v3 saat cutover. Jangan mengaktifkannya lagi tanpa rollback terencana.
CREATE OR REPLACE FUNCTION public.simpan_transaksi_scan(p_barcode text,p_jenis_transaksi text,p_nama_guru text,p_items jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN RAISE EXCEPTION 'API lama dinonaktifkan. Gunakan SINABOS v4 dengan akun guru'; END $$;
DO $$ DECLARE f record; BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='sinabos_app') THEN CREATE ROLE sinabos_app NOLOGIN; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='sinabos_app' AND (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls))
 OR EXISTS(SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.member WHERE r.rolname='sinabos_app')
 OR EXISTS(SELECT 1 FROM pg_class c JOIN pg_roles r ON r.oid=c.relowner JOIN pg_namespace n ON n.oid=c.relnamespace WHERE r.rolname='sinabos_app' AND n.nspname='public')
 OR EXISTS(SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner JOIN pg_namespace n ON n.oid=p.pronamespace WHERE r.rolname='sinabos_app' AND n.nspname='public')
 THEN RAISE EXCEPTION 'Role sinabos_app lama memiliki privilege/membership/ownership berlebihan. Hentikan migrasi dan audit role; jangan gunakan role owner sebagai runtime'; END IF;

 FOR f IN SELECT p.oid::regprocedure AS name FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND (p.proname LIKE 'sinabos_v4_%' OR p.proname IN ('simpan_transaksi_scan','lookup_rombel_barcode')) LOOP
  EXECUTE 'REVOKE ALL ON FUNCTION '||f.name||' FROM PUBLIC, sinabos_app';
 END LOOP;
END $$;
DO $$ DECLARE v record; BEGIN
 FOR v IN SELECT table_name FROM information_schema.views WHERE table_schema='public' AND table_name IN ('v_stok','v_peminjaman_aktif','v_transaksi_admin','v_mutasi_bulanan','v_barcode_aktif','sinabos_stock') LOOP
  EXECUTE 'REVOKE ALL ON public.'||quote_ident(v.table_name)||' FROM PUBLIC,sinabos_app';
 END LOOP;
END $$;
REVOKE ALL ON public.books,public.rombel_barcodes,public.stock_movements,public.circulation_items,public.circulation_transactions,
 public.sinabos_users,public.sinabos_sessions,public.sinabos_requests,public.sinabos_limits,public.sinabos_audit,public.sinabos_migrations,public.sinabos_book_balances,public.sinabos_loan_balances FROM PUBLIC,sinabos_app;
GRANT USAGE ON SCHEMA public TO sinabos_app;
GRANT EXECUTE ON FUNCTION public.sinabos_v4_api(text,text,jsonb,text) TO sinabos_app;
INSERT INTO public.sinabos_migrations(version) VALUES('4.0.0') ON CONFLICT DO NOTHING;
COMMIT;
