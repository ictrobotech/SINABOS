-- SINABOS 4.2.1 — tema halaman login: pengunjung yang belum login melihat tema pilihan admin (baca publik, tanpa data pengguna).
-- Idempotent — aman dijalankan ulang, TIDAK mengubah tabel/data. Jalankan utuh sekali jalan (psql atau SQL Editor web).
-- Urutan: aman kapan saja setelah 4.2.0; idealnya sebelum upload deploy 4.2.1 agar halaman login langsung bertema.
BEGIN;
SELECT pg_advisory_xact_lock(734120260002::bigint);

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

GRANT EXECUTE ON FUNCTION public.sinabos_v4_api(text,text,jsonb,text) TO sinabos_app;
INSERT INTO public.sinabos_migrations(version) VALUES('4.2.1') ON CONFLICT DO NOTHING;
COMMIT;
