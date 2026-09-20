// KHUSUS database uji lokal. Guard menolak host non-loopback dan nama database non-test.
import {Pool} from 'pg';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {root,hash,call,admin,addBook,addRombel,circulate} from './helpers.mjs';
const url=new URL(process.env.PG_TEST_URL||'postgresql://user@127.0.0.1:5434/sinabos_test');
if(!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||!/^\/sinabos_test(?:_[a-z0-9]+)?$/.test(url.pathname))throw new Error('Uji ditolak: hanya database lokal bernama sinabos_test.');
const db=new Pool({connectionString:url.toString(),max:12});
const result=[];let a,g1,g2;
const ok=r=>{assert.equal(r.ok,true,JSON.stringify(r));return r;};
async function check(name,fn){const start=performance.now();await db.query('delete from sinabos_limits');await fn();result.push({name,passed:true,duration_ms:Math.round(performance.now()-start)});}
try{
 await db.query('drop schema public cascade; create schema public');
 await db.query(await fs.readFile(root+'sql/001-v4.sql','utf8'));
 a=await admin(db);await addRombel(db,a);await addRombel(db,a,{barcode:'RBL-VII-B',rombel:'VII-B'});
 for(const [name,token] of [['guru.one',hash('one')],['guru.two',hash('two')]]){
  const user=ok(await call(db,'saveUser',a,{username:name,full_name:name,role:'guru',password:'Teacher-Concurrent-2026!',request_id:randomUUID()}));
  await db.query('update sinabos_users set must_change_password=false where id=$1',[user.id]);ok(await call(db,'login','',{username:name,password:'Teacher-Concurrent-2026!',new_session_hash:token}));
 }
 g1=hash('one');g2=hash('two');
 await check('Dua guru/rombel bersamaan: stok 50, masing-masing pinjam 30, hanya satu diterima',async()=>{
  const b=await addBook(db,a);const r=await Promise.all([circulate(db,g1,b.id,'pinjam',30),circulate(db,g2,b.id,'pinjam',30,'baik',{barcode:'RBL-VII-B'})]);
  assert.equal(r.filter(x=>x.ok).length,1);assert.equal((await db.query('select tersedia from sinabos_stock where id=$1',[b.id])).rows[0].tersedia,20);
 });
 await check('Multi-item urutan terbalik, guru/rombel berbeda: tidak deadlock, saldo masing-masing 10',async()=>{
  const x=await addBook(db,a),y=await addBook(db,a);const mk=(barcode,ids)=>({barcode,jenis_transaksi:'pinjam',request_id:randomUUID(),items:ids.map(id=>({buku_id:id,jumlah:20,kondisi:'baik'}))});
  const r=await Promise.all([call(db,'circulate',g1,mk('RBL-VII-A',[x.id,y.id])),call(db,'circulate',g2,mk('RBL-VII-B',[y.id,x.id]))]);r.forEach(ok);
  for(const b of [x,y])assert.equal((await db.query('select tersedia from sinabos_stock where id=$1',[b.id])).rows[0].tersedia,10);
 });
 await check('Sepuluh retry bersamaan dengan ID sama menghasilkan tepat satu header/item/mutasi',async()=>{
  const b=await addBook(db,a);const p={barcode:'RBL-VII-A',jenis_transaksi:'pinjam',request_id:randomUUID(),items:[{buku_id:b.id,jumlah:5,kondisi:'baik'}]};
  const r=await Promise.all(Array.from({length:10},()=>call(db,'circulate',g1,p)));r.forEach(ok);assert.equal(new Set(r.map(x=>x.receipt.id)).size,1);assert.equal((await db.query('select count(*)::int n from circulation_transactions where request_id=$1',[p.request_id])).rows[0].n,1);assert.equal((await db.query('select tersedia from sinabos_stock where id=$1',[b.id])).rows[0].tersedia,45);
 });
 await check('Dua pengembalian bersamaan tidak melebihi sisa rombel',async()=>{
  const b=await addBook(db,a);ok(await circulate(db,g1,b.id,'pinjam',20));const r=await Promise.all([circulate(db,g1,b.id,'kembali',15),circulate(db,g2,b.id,'kembali',15)]);assert.equal(r.filter(x=>x.ok).length,1);const s=(await db.query('select tersedia,dipinjam from sinabos_stock where id=$1',[b.id])).rows[0];assert.equal(s.tersedia,45);assert.equal(s.dipinjam,5);
 });
 await check('Hak minimum pada PostgreSQL asli: runtime API boleh, tabel password dan bootstrap tidak',async()=>{
  const conn=await db.connect();try{await conn.query('set role sinabos_app');ok(await call(conn,'me',g1));await assert.rejects(()=>conn.query('select password_hash from sinabos_users'));await assert.rejects(()=>conn.query("select sinabos_v4_bootstrap('unauthorized','X','Not-a-real-password')"));}finally{await conn.query('reset role');conn.release();}
 });
 await check('Bootstrap runtime membuat role LOGIN minimum, hanya owner boleh memanggil helper',async()=>{
  const role='sinabos_runtime_test_'+Date.now();const password='Local-Random-'+randomUUID();const conn=await db.connect();
  try{
   await conn.query('select public.sinabos_v4_runtime_role($1,$2)',[role,password]);
   const flags=(await conn.query('select rolcanlogin,rolsuper,rolcreatedb,rolcreaterole,rolbypassrls from pg_roles where rolname=$1',[role])).rows[0];assert.deepEqual(flags,{rolcanlogin:true,rolsuper:false,rolcreatedb:false,rolcreaterole:false,rolbypassrls:false});
   await conn.query('set role "'+role+'"');ok(await call(conn,'me',g1));await assert.rejects(()=>conn.query('select * from sinabos_users'));await assert.rejects(()=>conn.query('select public.sinabos_v4_runtime_role($1,$2)',['invalid_new_role',password]));
  }finally{await conn.query('reset role');await conn.query('drop role if exists "'+role+'"');conn.release();}
 });
 const b=await addBook(db,a,{total_awal:100000,judul:'Fixture benchmark 10000 transaksi'});const uid=(await db.query("select id from sinabos_users where username='guru.one'")).rows[0].id;
 await db.query("insert into circulation_transactions(kode_transaksi,rombel_barcode_id,barcode,rombel,kelas_target,nama_guru,jenis_transaksi,actor_id) select 'BENCH-'||g,(select id from rombel_barcodes where barcode='RBL-VII-A'),'RBL-VII-A','VII-A','VII','Fixture benchmark','pinjam',$1 from generate_series(1,10000) g",[uid]);
 await db.query("insert into circulation_items(transaction_id,buku_id,jumlah,kondisi,judul_snapshot,mapel_snapshot,kode_snapshot) select id,$1,1,'baik','Fixture benchmark','Matematika','BENCH' from circulation_transactions where kode_transaksi like 'BENCH-%'",[b.id]);
 await db.query("insert into stock_movements(buku_id,transaksi_id,rombel_barcode_id,tipe,jumlah,available_delta) select $1,id,rombel_barcode_id,'pinjam',1,-1 from circulation_transactions where kode_transaksi like 'BENCH-%'",[b.id]);
 const benchmark=[];await db.query('analyze');
 for(const [action,p] of [['dashboard',{}],['scan',{barcode:'RBL-VII-A'}],['books',{limit:25}],['history',{limit:25}]]){
  await db.query('delete from sinabos_limits');for(let i=0;i<3;i++)ok(await call(db,action,a,p));const times=[];
  for(let i=0;i<30;i++){const start=performance.now();ok(await call(db,action,a,p));times.push(performance.now()-start);}times.sort((x,y)=>x-y);benchmark.push({action,samples:30,median_ms:Number(((times[14]+times[15])/2).toFixed(2)),p95_ms:Number(times[28].toFixed(2))});
 }
 const output={version:(await db.query('select version() v')).rows[0].v,environment:'PostgreSQL lokal, koneksi TCP loopback; BUKAN latency Neon/Cloudflare produksi',concurrency:result,synthetic_transactions:10000,benchmark};
 await fs.writeFile(root+'artifacts/postgres-concurrency-performance.json',JSON.stringify(output,null,2));console.log(JSON.stringify(output,null,2));
}finally{await db.end();}
