import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {pg_trgm} from '@electric-sql/pglite/contrib/pg_trgm';
import fs from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createHash,randomBytes,randomUUID} from 'node:crypto';
export const root=fileURLToPath(new URL('../',import.meta.url));
export const hash=x=>createHash('sha256').update(x).digest('hex');
export async function database({legacy=null,migrate=true}={}) {
 const db=new PGlite({extensions:{pgcrypto,pg_trgm}});await db.waitReady;
 if(legacy) await db.exec(legacy);
 if(migrate) await db.exec(await fs.readFile(root+'sql/001-v4.sql','utf8'));
 return db;
}
export const call=async(db,action,token,data={},ip='ip-local-test-001')=>(await db.query('select public.sinabos_v4_api($1,$2,$3::jsonb,$4) as result',[action,token,JSON.stringify(data),ip])).rows[0].result;
export async function admin(db) {
 await db.query("select public.sinabos_v4_bootstrap('admin','Admin Pengujian',$1)",['Demo-Admin-2026!']);
 const token=hash('ADMIN-LOCAL-ONLY');const r=await call(db,'login','',{username:'admin',password:'Demo-Admin-2026!',new_session_hash:token});
 if(!r.ok) throw new Error(JSON.stringify(r));
 return token;
}
export const bookData=(patch={})=>({kode_buku:'BK-'+randomUUID().slice(0,8),judul:'Buku Matematika VII',mata_pelajaran:'Matematika',kelas_target:'VII',tahun_terbit:'2026',penulis:'Tim Pendidikan',penerbit:'Pusat Perbukuan',kurikulum:'Merdeka',sumber_buku:'BOS 2026',total_awal:50,...patch});
export async function addBook(db,token,patch={}) {const r=await call(db,'saveBook',token,{...bookData(patch),request_id:randomUUID()});if(!r.ok)throw new Error(JSON.stringify(r));return r.book;}
export async function addRombel(db,token,patch={}) {const r=await call(db,'saveRombel',token,{barcode:'RBL-VII-A',rombel:'VII-A',kelas_target:'VII',...patch,request_id:randomUUID()});if(!r.ok)throw new Error(JSON.stringify(r));return r.rombel;}
export const circulate=(db,token,buku,jenis,jumlah,kondisi='baik',extra={})=>call(db,'circulate',token,{barcode:'RBL-VII-A',jenis_transaksi:jenis,items:[{buku_id:buku,jumlah,kondisi}],request_id:randomUUID(),...extra});
export async function demoDatabase() {
 const db=await database();const a=await admin(db);
 await addRombel(db,a);await addRombel(db,a,{barcode:'RBL-VIII-A',rombel:'VIII-A',kelas_target:'VIII'});await addRombel(db,a,{barcode:'RBL-IX-A',rombel:'IX-A',kelas_target:'IX'});
 const books=[];
 for(const [kode,judul,mapel,kelas,total] of [['MTK-VII','Matematika untuk SMP Kelas VII','Matematika','VII',80],['IPA-VII','Ilmu Pengetahuan Alam VII','IPA','VII',72],['BIN-VII','Bahasa Indonesia VII','Bahasa Indonesia','VII',64],['IPS-VII','Ilmu Pengetahuan Sosial VII','IPS','VII',56],['MTK-VIII','Matematika untuk SMP Kelas VIII','Matematika','VIII',80],['IPA-VIII','Ilmu Pengetahuan Alam VIII','IPA','VIII',64],['BIN-IX','Bahasa Indonesia IX','Bahasa Indonesia','IX',48]]) {
  books.push(await addBook(db,a,{kode_buku:kode,judul,mata_pelajaran:mapel,kelas_target:kelas,total_awal:total}));
 }
 const teacher=await call(db,'saveUser',a,{username:'guru.demo',full_name:'Guru Simulasi',role:'guru',password:'Demo-Guru-2026!',request_id:randomUUID()});
 await db.query('update public.sinabos_users set must_change_password=false where id=$1',[teacher.id]);
 const g=hash('TEACHER-LOCAL-ONLY');await call(db,'login','',{username:'guru.demo',password:'Demo-Guru-2026!',new_session_hash:g});
 await circulate(db,g,books[0].id,'pinjam',24);await circulate(db,g,books[1].id,'pinjam',20);await circulate(db,g,books[0].id,'kembali',4);
 await db.exec('delete from public.sinabos_sessions; delete from public.sinabos_limits');
 return db;
}
