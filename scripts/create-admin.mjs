// Node 22+, dijalankan hanya di komputer operator. Password tidak masuk argv/file/log.
import {neon} from '@neondatabase/serverless';
import {createInterface} from 'node:readline/promises';
import {Writable} from 'node:stream';
try{process.loadEnvFile?.('.env.admin.local');}catch(e){if(e.code!=='ENOENT')throw e;}
if(!process.env.DATABASE_URL_ADMIN)throw new Error('Isi DATABASE_URL_ADMIN dalam .env.admin.local lokal. Jangan commit file tersebut.');
if(!process.stdin.isTTY)throw new Error('Jalankan di terminal interaktif agar password dapat dimasukkan tanpa ditampilkan.');
let hidden=false;
const output=new Writable({write(chunk,encoding,callback){if(!hidden)process.stdout.write(chunk,encoding);callback();}});
const rl=createInterface({input:process.stdin,output,terminal:true});
async function secret(prompt){process.stdout.write(prompt);hidden=true;try{return await rl.question('');}finally{hidden=false;process.stdout.write('\n');}}
try{
 const username=(await rl.question('Username admin (huruf kecil, 3–40 karakter): ')).trim().toLowerCase();
 const name=(await rl.question('Nama lengkap admin: ')).trim();
 const password=await secret('Password pribadi (minimal 12 karakter, tidak terlihat): ');
 const confirm=await secret('Ulangi password: ');
 if(password!==confirm)throw new Error('Konfirmasi password berbeda.');
 if(password.length<12||Buffer.byteLength(password,'utf8')>72)throw new Error('Password minimal 12 karakter, maksimal 72 byte UTF-8.');
 const sql=neon(process.env.DATABASE_URL_ADMIN);
 await sql.query('select public.sinabos_v4_bootstrap($1::text,$2::text,$3::text)',[username,name,password]);
 console.log('Admin awal berhasil dibuat. Tidak ada akun demo/default di database ini.');
}catch(e){console.error('Bootstrap gagal. '+(e.code?'Kode database: '+e.code+'; periksa migrasi dan apakah admin sudah ada.':e.message));process.exitCode=1;}finally{rl.close();}
