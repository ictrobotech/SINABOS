-- SINABOS 4.1.0 — tambahan untuk database yang SUDAH menjalankan 001-v4.sql (4.0.0).
-- Isi: kolom ISBN & Edisi pada master buku + aksi admin resetBooks (reset inventaris sebelum transaksi pertama).
-- File kecil: aman dijalankan lewat SQL Editor web Neon maupun psql. Idempotent — boleh dijalankan ulang.
-- Instalasi baru tidak perlu file ini (001-v4.sql sudah memuat semuanya); menjalankannya tetap aman.
BEGIN;
SELECT pg_advisory_xact_lock(734120260001::bigint);
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS isbn text;
ALTER TABLE public.books ADD COLUMN IF NOT EXISTS edisi text;

CREATE OR REPLACE VIEW public.sinabos_stock AS
SELECT b.id,b.kode_buku,b.judul,b.mata_pelajaran,b.kelas_target,b.tahun_terbit,b.penulis,b.penerbit,b.kurikulum,b.sumber_buku,b.isbn,b.edisi,b.sumber_dana,b.aktif,b.revision,
 s.total_masuk AS total_buku,s.total_masuk,s.total_pinjam,s.total_kembali,(s.total_rusak+s.total_hilang)::int AS total_rusak_hilang,
 s.total_rusak,s.total_hilang,s.tersedia,
 coalesce((SELECT sum(l.sisa)::int FROM public.sinabos_loan_balances l WHERE l.buku_id=b.id AND l.sisa>0),0) AS dipinjam,
 b.legacy_total_buku,(coalesce(b.legacy_total_buku,0)>0 AND b.legacy_reviewed_at IS NULL AND s.total_masuk=0) AS needs_opening_review
FROM public.books b JOIN public.sinabos_book_balances s ON s.buku_id=b.id;

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
 IF p_action='me' THEN
  RETURN jsonb_build_object('user',jsonb_build_object('id',u.id,'username',u.username,'full_name',u.full_name,'role',u.role,'must_change_password',u.must_change_password));
 END IF;
 IF u.must_change_password AND p_action NOT IN ('changePassword','logout') THEN RAISE EXCEPTION USING ERRCODE='S0403',MESSAGE='Ganti password sementara sebelum menggunakan aplikasi'; END IF;
 IF p_action IN ('dashboard','books','saveBook','stockIn','stockLoss','rombel','saveRombel','users','saveUser','resetPassword','resetBooks','report','audit','active','health') AND u.role<>'admin' THEN
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
 rid uuid; fingerprint text; is_mutation boolean:=p_action IN ('circulate','saveBook','stockIn','stockLoss','saveRombel','saveUser','resetPassword','resetBooks');
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

INSERT INTO public.sinabos_migrations(version) VALUES('4.1.0') ON CONFLICT DO NOTHING;
COMMIT;
