// Buat login database terpisah, tanpa hak tabel/owner. Tidak ada secret dicetak ke terminal.
import {neon} from '@neondatabase/serverless';
import {randomBytes} from 'node:crypto';
import fs from 'node:fs/promises';
try{process.loadEnvFile?.('.env.admin.local');}catch(e){if(e.code!=='ENOENT')throw e;}
if(!process.env.DATABASE_URL_ADMIN)throw new Error('Isi DATABASE_URL_ADMIN pada .env.admin.local lokal.');
const role=process.env.RUNTIME_ROLE_NAME||'sinabos_runtime_v4';
if(!/^[a-z][a-z0-9_]{2,50}$/.test(role))throw new Error('Nama role harus identifier PostgreSQL sederhana.');
const file='.runtime.secrets';
try{await fs.access(file);throw new Error(file+' sudah ada. Pindahkan secara aman sebelum membuat role baru.');}catch(e){if(e.code!=='ENOENT')throw e;}
const sql=neon(process.env.DATABASE_URL_ADMIN);const password=randomBytes(32).toString('base64url');
try{
 const existing=await sql.query('select 1 from pg_roles where rolname=$1',[role]);if(existing.length)throw new Error('Role sudah ada. Jangan rotasi password secara tidak sengaja; gunakan nama role baru melalui RUNTIME_ROLE_NAME.');
 // Query terparameterisasi; SQL privileged helper hanya dapat dieksekusi pemilik migrasi.
 await sql.query('select public.sinabos_v4_runtime_role($1::text,$2::text)',[role,password]);
 const runtime=new URL(process.env.DATABASE_URL_ADMIN);runtime.username=role;runtime.password=password;
 await fs.writeFile(file,`# Rahasia lokal — salin nilai ke Secrets Cloudflare, jangan commit/kirim ke chat.\nDATABASE_URL=${runtime.toString()}\nAPP_SECRET=${randomBytes(40).toString('hex')}\n`,{flag:'wx',mode:0o600});
 console.log('Role runtime dibuat. Nilai DATABASE_URL dan APP_SECRET disimpan privat dalam '+file+'.');
 console.log('Salin ke Cloudflare Variables & Secrets (encrypted). Jangan gunakan DATABASE_URL_ADMIN pada aplikasi.');
}catch(e){console.error('Pembuatan role gagal. '+(e.code?'Kode database: '+e.code:e.message));process.exitCode=1;}
