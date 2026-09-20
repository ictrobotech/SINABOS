import {test,before,after,beforeEach} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {database,admin,addBook,addRombel,circulate,call,hash,bookData,root} from './helpers.mjs';
let db,a,g,teacher;
const ok=r=>{assert.equal(r.ok,true,JSON.stringify(r));return r;};
const stock=async id=>(await db.query('select * from sinabos_stock where id=$1',[id])).rows[0];
const counts=async()=>(await db.query('select (select count(*) from circulation_transactions)::int t,(select count(*) from circulation_items)::int i,(select count(*) from stock_movements)::int m')).rows[0];
before(async()=>{db=await database();a=await admin(db);await addRombel(db,a);const u=ok(await call(db,'saveUser',a,{username:'guru.test',full_name:'Guru Terverifikasi',role:'guru',password:'Teacher-Test-2026!',request_id:randomUUID()}));teacher=u.id;await db.query('update sinabos_users set must_change_password=false where id=$1',[teacher]);g=hash('teacher-test');ok(await call(db,'login','',{username:'guru.test',password:'Teacher-Test-2026!',new_session_hash:g}));});
after(async()=>{await db.close();});
beforeEach(async()=>{await db.exec('delete from sinabos_limits');});
test('master dan stok awal 50 dibuat atomik, ledger hanya satu',async()=>{const b=await addBook(db,a);assert.equal(b.tersedia,50);assert.equal(b.total_buku,50);assert.equal((await db.query('select count(*)::int n from stock_movements where buku_id=$1',[b.id])).rows[0].n,1);});
test('edit master tidak menimpa saldo; revision mencegah lost update',async()=>{const b=await addBook(db,a);const p={...bookData(),...b,judul:'Judul diperbarui',request_id:randomUUID()};const r=ok(await call(db,'saveBook',a,p));assert.equal(r.book.tersedia,50);assert.equal(r.book.revision,2);const conflict=await call(db,'saveBook',a,{...p,request_id:randomUUID()});assert.equal(conflict.code,'CONFLICT');});
test('50 - pinjam 10 + kembali baik 4; rusak 2 dan hilang 1 tidak dikurangi kedua kali',async()=>{const b=await addBook(db,a);ok(await circulate(db,g,b.id,'pinjam',10));ok(await call(db,'circulate',g,{barcode:'RBL-VII-A',jenis_transaksi:'kembali',items:[{buku_id:b.id,jumlah:4,kondisi:'baik'},{buku_id:b.id,jumlah:2,kondisi:'rusak'},{buku_id:b.id,jumlah:1,kondisi:'hilang'}],request_id:randomUUID()}));const s=await stock(b.id);assert.equal(s.tersedia,44);assert.equal(s.dipinjam,3);assert.equal(s.total_rusak,2);assert.equal(s.total_hilang,1);});
test('pengembalian campuran divalidasi secara agregat',async()=>{const b=await addBook(db,a);ok(await circulate(db,g,b.id,'pinjam',5));const c=await counts();const r=await call(db,'circulate',g,{barcode:'RBL-VII-A',jenis_transaksi:'kembali',items:[{buku_id:b.id,jumlah:4,kondisi:'baik'},{buku_id:b.id,jumlah:2,kondisi:'rusak'}],request_id:randomUUID()});assert.equal(r.code,'VALIDATION');assert.deepEqual(await counts(),c);});
test('item kedua gagal membatalkan header, items, ledger dan saldo semuanya',async()=>{const b=await addBook(db,a);const second=await addBook(db,a,{total_awal:1});const c=await counts();const r=await call(db,'circulate',g,{barcode:'RBL-VII-A',jenis_transaksi:'pinjam',items:[{buku_id:b.id,jumlah:2,kondisi:'baik'},{buku_id:second.id,jumlah:20,kondisi:'baik'}],request_id:randomUUID()});assert.equal(r.ok,false);assert.deepEqual(await counts(),c);assert.equal((await stock(b.id)).tersedia,50);});
test('baris duplikat kondisi sama, jumlah nol/pecahan/string, dan pinjam hilang ditolak',async()=>{const b=await addBook(db,a);for(const qty of [0,1.5,'2',100001]){const r=await circulate(db,g,b.id,'pinjam',qty);assert.equal(r.ok,false,JSON.stringify(r));}assert.equal((await circulate(db,g,b.id,'pinjam',1,'hilang')).ok,false);const r=await call(db,'circulate',g,{barcode:'RBL-VII-A',jenis_transaksi:'pinjam',items:[{buku_id:b.id,jumlah:1,kondisi:'baik'},{buku_id:b.id,jumlah:2,kondisi:'baik'}],request_id:randomUUID()});assert.equal(r.ok,false);});
test('buku kelas salah dan peminjaman melebihi stok ditolak',async()=>{const b=await addBook(db,a,{kelas_target:'VIII'});assert.equal((await circulate(db,g,b.id,'pinjam',1)).ok,false);const c=await addBook(db,a,{total_awal:1});assert.equal((await circulate(db,g,c.id,'pinjam',2)).ok,false);});
test('nama guru diambil dari sesi, input spoofing diabaikan',async()=>{const b=await addBook(db,a);const r=ok(await circulate(db,g,b.id,'pinjam',1,'baik',{nama_guru:'Nama Palsu',actor_id:randomUUID()}));assert.equal(r.receipt.nama_guru,'Guru Terverifikasi');assert.equal(r.receipt.actor_id,teacher);});
test('perubahan kelas atau nonaktif master berpinjaman aktif ditolak',async()=>{const b=await addBook(db,a);ok(await circulate(db,g,b.id,'pinjam',2));for(const change of [{kelas_target:'VIII'},{aktif:false}]){const r=await call(db,'saveBook',a,{...bookData(),...b,...change,request_id:randomUUID()});assert.equal(r.ok,false);assert.match(r.error,/pinjaman aktif/);}});
test('pengembalian historis tetap bisa walau buku/barcode lama nonaktif atau beda kelas',async()=>{const b=await addBook(db,a);const rb=await addRombel(db,a,{barcode:'RBL-LEGACY',rombel:'VII-LEG'});ok(await circulate(db,g,b.id,'pinjam',3,'baik',{barcode:rb.barcode}));await db.query("update books set kelas_target='VIII',aktif=false where id=$1",[b.id]);await db.query('update rombel_barcodes set aktif=false where id=$1',[rb.id]);const scan=ok(await call(db,'scan',g,{barcode:rb.barcode}));assert.ok(scan.books.some(x=>x.id===b.id&&x.sisa===3));ok(await circulate(db,g,b.id,'kembali',3,'baik',{barcode:rb.barcode}));assert.equal((await stock(b.id)).tersedia,50);});
test('judul historis memakai snapshot walau master diubah',async()=>{const b=await addBook(db,a,{judul:'Judul Asli'});const tx=ok(await circulate(db,g,b.id,'pinjam',1));await db.query("update books set judul='Judul Baru' where id=$1",[b.id]);const r=ok(await call(db,'history',g));const h=r.rows.find(x=>x.id===tx.receipt.id);assert.equal(h.items[0].judul,'Judul Asli');});
test('retry request identik menghasilkan satu transaksi; payload lain mendapat konflik',async()=>{const b=await addBook(db,a);const rid=randomUUID();const p={barcode:'RBL-VII-A',jenis_transaksi:'pinjam',items:[{buku_id:b.id,jumlah:2,kondisi:'baik'}],request_id:rid};const x=ok(await call(db,'circulate',g,p));const y=ok(await call(db,'circulate',g,p));assert.equal(y.replayed,true);assert.equal(x.receipt.id,y.receipt.id);assert.equal((await stock(b.id)).tersedia,48);const z=await call(db,'circulate',g,{...p,items:[{buku_id:b.id,jumlah:3,kondisi:'baik'}]});assert.equal(z.code,'CONFLICT');assert.equal((await call(db,'requestStatus',g,{request_id:rid})).found,true);});
test('guru tidak dapat membaca data admin atau mengelola master',async()=>{for(const action of ['books','dashboard','users','report','active','audit','saveBook','saveRombel','saveUser']){const r=await call(db,action,g,{request_id:randomUUID()});assert.equal(r.code,'FORBIDDEN',action+':'+JSON.stringify(r));}});
test('riwayat guru dibatasi actor_id, admin melihat keduanya',async()=>{const b=await addBook(db,a);const mine=ok(await circulate(db,g,b.id,'pinjam',1));const other=ok(await circulate(db,a,b.id,'pinjam',1));const r=ok(await call(db,'history',g,{limit:100}));assert.ok(r.rows.some(x=>x.id===mine.receipt.id));assert.ok(!r.rows.some(x=>x.id===other.receipt.id));});
test('session tidak ada/kedaluwarsa ditolak dan logout menghapus server session',async()=>{assert.equal((await call(db,'me','')).code,'UNAUTHENTICATED');const token=hash('expiring');await db.query("insert into sinabos_sessions(token_hash,user_id,expires_at) values($1,$2,now()-interval '1 second')",[token,teacher]);assert.equal((await call(db,'me',token)).code,'UNAUTHENTICATED');await db.query("insert into sinabos_sessions(token_hash,user_id,expires_at) values($1,$2,now()+interval '1 hour') on conflict (token_hash) do update set expires_at=now()+interval '1 hour'",[token,teacher]);ok(await call(db,'logout',token));assert.equal((await call(db,'me',token)).code,'UNAUTHENTICATED');});
test('password sementara wajib diganti dan pergantian password merotasi sesi',async()=>{const u=ok(await call(db,'saveUser',a,{username:'new.teacher',full_name:'Guru Baru',role:'guru',password:'Temporary-2026!',request_id:randomUUID()}));const token=hash('newteacher'),newToken=hash('rotatedteacher');ok(await call(db,'login','',{username:'new.teacher',password:'Temporary-2026!',new_session_hash:token}));assert.equal((await call(db,'scan',token,{barcode:'RBL-VII-A'})).code,'FORBIDDEN');ok(await call(db,'changePassword',token,{old_password:'Temporary-2026!',new_password:'New-Personal-2026!',new_session_hash:newToken}));assert.equal((await call(db,'me',token)).code,'UNAUTHENTICATED');assert.equal(ok(await call(db,'me',newToken)).user.must_change_password,false);});
test('reset admin mencabut sesi akun yang direset dan force password kembali',async()=>{const u=ok(await call(db,'saveUser',a,{username:'reset.teacher',full_name:'Guru Reset',role:'guru',password:'Temporary-2026!',request_id:randomUUID()}));const tok=hash('resetteacher');ok(await call(db,'login','',{username:'reset.teacher',password:'Temporary-2026!',new_session_hash:tok}));ok(await call(db,'resetPassword',a,{id:u.id,password:'Replacement-2026!',request_id:randomUUID()}));assert.equal((await call(db,'me',tok)).code,'UNAUTHENTICATED');const r=ok(await call(db,'login','',{username:'reset.teacher',password:'Replacement-2026!',new_session_hash:hash('newreset')}));assert.equal(r.user.must_change_password,true);});
test('admin tidak dapat menonaktifkan atau menurunkan role sendiri',async()=>{const me=ok(await call(db,'me',a)).user;const r=await call(db,'saveUser',a,{...me,full_name:me.full_name,revision:1,role:'guru',request_id:randomUUID()});assert.equal(r.ok,false);});
test('rate limit percobaan password salah tersimpan walau auth gagal',async()=>{for(let i=0;i<5;i++){const r=await call(db,'login','',{username:'unknown.user',password:'wrong-pass',new_session_hash:hash('bad'+i)});assert.equal(r.code,'LOGIN_FAILED');}const r=await call(db,'login','',{username:'unknown.user',password:'wrong-pass',new_session_hash:hash('bad6')});assert.equal(r.code,'RATE_LIMIT');});
test('pengurangan stok rusak dari rak berkurang sekali dan tidak melebihi tersedia',async()=>{const b=await addBook(db,a);ok(await call(db,'stockLoss',a,{buku_id:b.id,jumlah:3,kondisi:'rusak',keterangan:'Pemeriksaan rak lokal',request_id:randomUUID()}));assert.equal((await stock(b.id)).tersedia,47);assert.equal((await call(db,'stockLoss',a,{buku_id:b.id,jumlah:48,kondisi:'hilang',keterangan:'Uji melebihi saldo',request_id:randomUUID()})).ok,false);});
test('angka master lama tanpa ledger wajib konfirmasi eksplisit sebelum stok masuk',async()=>{const b=await addBook(db,a,{total_awal:0});await db.query('update books set legacy_total_buku=50 where id=$1',[b.id]);assert.equal((await stock(b.id)).needs_opening_review,true);const p={buku_id:b.id,jumlah:45,sumber_perolehan:'BOS lama',keterangan:'Hasil hitung fisik 45, bukan menambah 50 otomatis',request_id:randomUUID()};assert.equal((await call(db,'stockIn',a,p)).ok,false);ok(await call(db,'stockIn',a,{...p,acknowledge_legacy:true}));assert.equal((await stock(b.id)).tersedia,45);assert.equal((await stock(b.id)).needs_opening_review,false);});
test('dashboard hitung seluruh transaksi, bukan limit riwayat 100',async()=>{const b=await addBook(db,a,{total_awal:200});for(let i=0;i<105;i++)ok(await circulate(db,g,b.id,'pinjam',1));const dash=ok(await call(db,'dashboard',a));assert.ok(dash.hari_ini>100);const h=ok(await call(db,'history',a,{limit:25}));assert.equal(h.rows.length,26);const last=h.rows[24];const next=ok(await call(db,'history',a,{limit:25,cursor_time:last.created_at,cursor_id:last.id}));assert.ok(!next.rows.some(x=>h.rows.slice(0,25).some(y=>y.id===x.id)));});
test('kalender transaksi eksplisit Makassar walau timezone koneksi UTC',async()=>{await db.exec("set time zone 'UTC'");const b=await addBook(db,a);const tx=ok(await circulate(db,g,b.id,'pinjam',1));const correct=(await db.query("select (now() at time zone 'Asia/Makassar')::date::text d")).rows[0].d;assert.equal(tx.receipt.tanggal,correct);assert.equal(tx.server_date,correct);});
test('role aplikasi hanya dapat menjalankan API, tidak membaca password/tabel/helper',async()=>{const permissions=(await db.query("select has_table_privilege('sinabos_app','sinabos_users','SELECT') read_users,has_table_privilege('sinabos_app','books','INSERT') write_books,has_function_privilege('sinabos_app','public.sinabos_v4_api(text,text,jsonb,text)','EXECUTE') rpc,has_function_privilege('sinabos_app','public.sinabos_v4_bootstrap(text,text,text)','EXECUTE') bootstrap")).rows[0];assert.deepEqual(permissions,{read_users:false,write_books:false,rpc:true,bootstrap:false});await db.exec('set role sinabos_app');try{ok(await call(db,'me',a));await assert.rejects(()=>db.query('select password_hash from public.sinabos_users'));}finally{await db.exec('reset role');}});
test('mengulang migrasi tidak menggandakan ledger dan tetap memelihara constraints',async()=>{const c=await counts();await db.exec(await fs.readFile(root+'sql/001-v4.sql','utf8'));assert.deepEqual(await counts(),c);const nullability=(await db.query("select is_nullable from information_schema.columns where table_name='books' and column_name='total_buku'")).rows[0].is_nullable;assert.equal(nullability,'NO');});

test('retry akun/password idempotent, password berbeda konflik, audit tidak menyimpan plaintext',async()=>{
 const pass='Replay-Secret-2026!',p={username:'replay.teacher',full_name:'Guru Replay',role:'guru',password:pass,request_id:randomUUID()};
 const first=ok(await call(db,'saveUser',a,p));const again=ok(await call(db,'saveUser',a,p));assert.equal(again.replayed,true);assert.equal(again.id,first.id);
 assert.equal((await call(db,'saveUser',a,{...p,password:'Different-Secret-2026!'})).code,'CONFLICT');
 assert.equal((await call(db,'requestStatus',g,{request_id:p.request_id})).found,false);
 const rec=(await db.query('select to_jsonb(r) r from sinabos_requests r where request_id=$1',[p.request_id])).rows[0].r;assert.ok(!JSON.stringify(rec).includes(pass));assert.match(rec.secret_hash,/^\$2[ab]\$12\$/);
 const reset={id:first.id,password:'Reset-Replay-2026!',request_id:randomUUID()};ok(await call(db,'resetPassword',a,reset));const revision=(await db.query('select revision from sinabos_users where id=$1',[first.id])).rows[0].revision;
 assert.equal(ok(await call(db,'resetPassword',a,reset)).replayed,true);assert.equal((await db.query('select revision from sinabos_users where id=$1',[first.id])).rows[0].revision,revision);
 assert.ok(!JSON.stringify((await db.query('select detail from sinabos_audit where request_id=$1',[reset.request_id])).rows).includes(reset.password));
});
test('whitespace username tidak dapat menghindari batas login',async()=>{
 for(let i=0;i<5;i++)assert.equal((await call(db,'login','',{username:'guru.test'+' '.repeat(i),password:'Definitely-wrong',new_session_hash:hash('space'+i)})).code,'LOGIN_FAILED');
 assert.equal((await call(db,'login','',{username:'  guru.test  ',password:'Definitely-wrong',new_session_hash:hash('space-limit')})).code,'RATE_LIMIT');
});
test('edit nama akun sendiri terkonfirmasi tanpa mencabut sesi sendiri',async()=>{
 const me=ok(await call(db,'me',a)).user;const row=(await db.query('select revision from sinabos_users where id=$1',[me.id])).rows[0];
 ok(await call(db,'saveUser',a,{...me,revision:row.revision,full_name:'Admin Diperbarui',active:true,request_id:randomUUID()}));
 assert.equal(ok(await call(db,'me',a)).user.full_name,'Admin Diperbarui');
});
test('skrip verifikasi dan maintenance valid; bootstrap runtime hanya pemilik',async()=>{
 await db.exec(await fs.readFile(root+'sql/002-verify.sql','utf8'));await db.exec(await fs.readFile(root+'sql/003-maintenance.sql','utf8'));
 assert.equal((await db.query("select has_function_privilege('sinabos_app','public.sinabos_v4_runtime_role(text,text)','EXECUTE') allowed")).rows[0].allowed,false);
});

test('edit rombel menolak revision lama; identitas snapshot transaksi tetap',async()=>{
 const r=await addRombel(db,a,{barcode:'RBL-REVISION',rombel:'VII-Revision'});const b=await addBook(db,a);const tx=ok(await circulate(db,g,b.id,'pinjam',1,'baik',{barcode:r.barcode}));
 const payload={...r,rombel:'VII-Revisi-Nama',request_id:randomUUID()};const edited=ok(await call(db,'saveRombel',a,payload));assert.equal(edited.rombel.revision,2);
 assert.equal((await call(db,'saveRombel',a,{...payload,request_id:randomUUID()})).code,'CONFLICT');
 const h=(await db.query('select rombel from circulation_transactions where id=$1',[tx.receipt.id])).rows[0];assert.equal(h.rombel,'VII-Revision');
});
test('kode buku legacy beda kapital atau spasi tidak dapat diduplikasi',async()=>{
 const b=await addBook(db,a,{kode_buku:'SAME-LEGACY'});await db.query("update books set kode_buku='same-legacy ' where id=$1",[b.id]);
 const r=await call(db,'saveBook',a,{...bookData(),kode_buku:'SAME-LEGACY',request_id:randomUUID()});assert.equal(r.code,'CONFLICT');
});

const f004=()=>fs.readFile(new URL('../sql/004-v4.1.sql',import.meta.url),'utf8');
test('004 menambah ISBN/Edisi, tampil di stok, dan idempotent dijalankan ulang',async()=>{
 const db2=await database({migrate:true});
 await db2.exec(await f004());await db2.exec(await f004());
 const a2=await admin(db2);
 const b=await addBook(db2,a2,{isbn:'978-602-1234-56-7',edisi:'Edisi ke-3'});
 assert.equal(b.isbn,'978-602-1234-56-7');assert.equal(b.edisi,'Edisi ke-3');
 const list=ok(await call(db2,'books',a2));assert.ok(list.rows.some(x=>x.isbn==='978-602-1234-56-7'));
 const v=(await db2.query('select version from public.sinabos_migrations order by applied_at desc limit 1')).rows[0].version;
 assert.equal(v,'4.1.0');
 await db2.close();
});
test('resetBooks: guru ditolak, admin ditolak saat ada transaksi, sukses saat kosong dan bisa replay',async()=>{
 const db2=await database({migrate:true});await db2.exec(await f004());
 const a2=await admin(db2);
 const romb=await addRombel(db2,a2);await addBook(db2,a2);await addBook(db2,a2);
 const guru=ok(await call(db2,'saveUser',a2,{username:'guru.reset',full_name:'Guru Reset',role:'guru',password:'Demo-Guru-2026!',request_id:randomUUID()}));
 await db2.query('update public.sinabos_users set must_change_password=false where id=$1',[guru.id]);
 const g2=hash('GURU-RESET-SESI');ok(await call(db2,'login','',{username:'guru.reset',password:'Demo-Guru-2026!',new_session_hash:g2}));
 const denied=await call(db2,'resetBooks',g2,{request_id:randomUUID()});assert.equal(denied.code,'FORBIDDEN');
 const books=ok(await call(db2,'books',a2)).rows;
 await circulate(db2,g2,books[0].id,'pinjam',1,'baik',{barcode:romb.barcode});
 const blocked=await call(db2,'resetBooks',a2,{request_id:randomUUID()});
 assert.equal(blocked.code,'CONFLICT');assert.match(blocked.error,/sebelum ada transaksi/);
 await db2.close();
 const db3=await database({migrate:true});await db3.exec(await f004());
 const a3=await admin(db3);await addRombel(db3,a3);await addBook(db3,a3,{isbn:'978-1'});await addBook(db3,a3);
 const rid=randomUUID();const r1=ok(await call(db3,'resetBooks',a3,{request_id:rid}));
 assert.equal(r1.ok,true);assert.equal(r1.reset.buku,2);
 const r2=ok(await call(db3,'resetBooks',a3,{request_id:rid}));assert.equal(r2.reset.buku,2);
 const n=(await db3.query('select (select count(*) from public.books) as buku,(select count(*) from public.stock_movements) as mutasi,(select count(*) from public.rombel_barcodes) as rombel')).rows[0];
 assert.equal(n.buku,0);assert.equal(n.mutasi,0);assert.equal(n.rombel,1);
 await db3.close();
});

test('004 upgrade dari view 4.0 (tanpa isbn/edisi): berhasil, idempotent, dan kolom muncul di ujung',async()=>{
 const db2=await database({migrate:true});
 await db2.exec("DROP VIEW public.v_stok; DROP VIEW public.sinabos_stock;");
 await db2.exec(`CREATE VIEW public.sinabos_stock AS SELECT b.id,b.kode_buku,b.judul,b.mata_pelajaran,b.kelas_target,b.tahun_terbit,b.penulis,b.penerbit,b.kurikulum,b.sumber_buku,b.sumber_dana,b.aktif,b.revision, s.total_masuk AS total_buku,s.total_masuk,s.total_pinjam,s.total_kembali,(s.total_rusak+s.total_hilang)::int AS total_rusak_hilang, s.total_rusak,s.total_hilang,s.tersedia, coalesce((SELECT sum(l.sisa)::int FROM public.sinabos_loan_balances l WHERE l.buku_id=b.id AND l.sisa>0),0) AS dipinjam, b.legacy_total_buku,(coalesce(b.legacy_total_buku,0)>0 AND b.legacy_reviewed_at IS NULL AND s.total_masuk=0) AS needs_opening_review FROM public.books b JOIN public.sinabos_book_balances s ON s.buku_id=b.id;`);
 await db2.exec("CREATE VIEW public.v_stok AS SELECT id,kode_buku,judul,mata_pelajaran,kelas_target,total_buku,sumber_dana,aktif,total_masuk,total_pinjam,total_kembali,total_rusak_hilang,tersedia FROM public.sinabos_stock;");
 const f004=()=>fs.readFile(new URL('../sql/004-v4.1.sql',import.meta.url),'utf8');
 await db2.exec(await f004());await db2.exec(await f004());
 const a2=await admin(db2);
 const b=await addBook(db2,a2,{isbn:'978-602-9999-99-9',edisi:'Cetak ke-2'});
 assert.equal(b.isbn,'978-602-9999-99-9');assert.equal(b.edisi,'Cetak ke-2');
 const row=(await db2.query('select to_jsonb(s) r from public.sinabos_stock s limit 1')).rows[0].r;
 assert.ok('isbn' in row && 'edisi' in row);
 const cnt=(await db2.query("select count(*)::int n from public.v_stok")).rows[0].n;
 assert.ok(cnt>=0);
 await db2.close();
});

test('saveTheme: admin menyimpan tema ke akun (terbaca via me), guru ditolak, tema asing ditolak',async()=>{
 const r1=ok(await call(db,'saveTheme',a,{tema:'emerald',request_id:randomUUID()}));
 assert.equal(r1.tema,'emerald');
 const me=ok(await call(db,'me',a));assert.equal(me.user.tema,'emerald');
 const denied=await call(db,'saveTheme',g,{tema:'profesional',request_id:randomUUID()});
 assert.equal(denied.code,'FORBIDDEN');
 const bad=await call(db,'saveTheme',a,{tema:'ungu-neon',request_id:randomUUID()});
 assert.equal(bad.ok,false);
 const r2=ok(await call(db,'saveTheme',a,{tema:'profesional',request_id:randomUUID()}));
 assert.equal(r2.tema,'profesional');
 ok(await call(db,'saveTheme',a,{tema:'modern',request_id:randomUUID()}));
});

test('siteTheme publik: halaman login mengikuti tema admin, tanpa sesi',async()=>{
 const db=await database({migrate:true});
 const baca=async()=>ok(await db.query("select public.sinabos_v4_api('siteTheme','', '{}'::jsonb,'ip-site-001') as r")).rows[0].result??(await db.query("select public.sinabos_v4_api('siteTheme','', '{}'::jsonb,'ip-site-001') as r")).rows[0].r;
 const awal=await db.query("select public.sinabos_v4_api('siteTheme','', '{}'::jsonb,'ip-site-001') as r");
 const v=awal.rows[0].r; assert.equal(v.ok,true); assert.equal(v.tema,'modern');
 const a=await admin(db);
 ok(await call(db,'saveTheme',a,{tema:'emerald',request_id:randomUUID()}));
 const sesudah=await db.query("select public.sinabos_v4_api('siteTheme','', '{}'::jsonb,'ip-site-002') as r");
 assert.equal(sesudah.rows[0].r.tema,'emerald');
 ok(await call(db,'saveTheme',a,{tema:'modern',request_id:randomUUID()}));
 await db.close();
});
