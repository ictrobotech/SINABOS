import { neon } from '@neondatabase/serverless';

export const VERSION = '4.0.0';
const COOKIE = '__Host-sinabos';
const MAX_BODY = 64 * 1024;
const ACTIONS = new Set(['login','logout','me','changePassword','dashboard','books','scan','history','active','circulate','saveBook','stockIn','stockLoss','rombel','saveRombel','users','saveUser','resetPassword','resetBooks','report','audit','health','requestStatus']);
const encoder = new TextEncoder();
export const hex = buffer => Array.from(new Uint8Array(buffer), b => b.toString(16).padStart(2,'0')).join('');
export const digest = async value => hex(await crypto.subtle.digest('SHA-256',encoder.encode(value)));
const cookie = value => `${COOKIE}=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${value ? 28800 : 0}`;
function sessionCookie(request) {
  const match = (request.headers.get('Cookie') || '').split(';').map(x=>x.trim()).find(x=>x.startsWith(COOKIE+'='));
  const value = match?.slice(COOKIE.length+1) || '';
  return /^[0-9a-f]{64}$/.test(value) ? value : '';
}
function response(body, status=200, headers={}) {
  return new Response(JSON.stringify(body), {status,headers:{
    'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store, private',
    'X-Content-Type-Options':'nosniff','Referrer-Policy':'same-origin','Vary':'Cookie, Origin',
    ...headers
  }});
}
async function boundedJson(request) {
  const len=Number(request.headers.get('Content-Length') || 0);
  if (len>MAX_BODY) throw Object.assign(new Error('Payload terlalu besar'),{status:413});
  const reader=request.body?.getReader();
  if(!reader) throw new Error('Payload wajib diisi');
  const chunks=[];let size=0;
  try {
    for (;;) {const {value,done}=await reader.read();if(done)break;size+=value.byteLength;if(size>MAX_BODY){await reader.cancel();throw Object.assign(new Error('Payload terlalu besar'),{status:413});}chunks.push(value);}
  } finally {reader.releaseLock();}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  const value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  if(!value || typeof value!=='object' || Array.isArray(value)) throw new Error('Payload harus berupa objek JSON');
  return value;
}
async function ipKey(request, secret) {
  const ip=request.headers.get('CF-Connecting-IP') || 'unknown';
  const key=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return hex(await crypto.subtle.sign('HMAC',key,encoder.encode(ip)));
}
export function neonDatabase(env) {
  if(!env.DATABASE_URL) throw new Error('DATABASE_NOT_CONFIGURED');
  const sql=neon(env.DATABASE_URL);
  return { async call(action,sessionHash,data,ip) {
    const rows=await sql.query('select public.sinabos_v4_api($1::text,$2::text,$3::jsonb,$4::text) as result',
      [action,sessionHash,JSON.stringify(data),ip],{fetchOptions:{signal:AbortSignal.timeout(18000)}});
    return rows[0]?.result;
  }};
}

// dbOverride hanya dependency injection untuk pengujian/demo lokal; tidak bersumber dari request/env.
export async function handleAPI(request, env, dbOverride=null) {
  const started=performance.now();const requestId=crypto.randomUUID();
  const failure=(error,status=400,code='BAD_REQUEST')=>response({ok:false,error,code,request_id:requestId,version:VERSION},status);
  if(request.method==='GET') return response({ok:true,app:'SINABOS',version:VERSION,database_checked:false});
  if(request.method!=='POST') return response({ok:false,error:'Metode tidak diizinkan'},405,{'Allow':'GET, POST'});
  const url=new URL(request.url);
  if(request.headers.get('Origin')!==url.origin || request.headers.get('X-Sinabos-Request')!=='1') return failure('Origin permintaan tidak diizinkan',403,'ORIGIN_REJECTED');
  if(!/^application\/json(?:;|$)/i.test(request.headers.get('Content-Type') || '')) return failure('Gunakan application/json',415);
  let body;
  try { body=await boundedJson(request); } catch(e) { return failure(e.status===413?e.message:'Payload JSON tidak valid',e.status || 400); }
  const {action}=body;
  if(typeof action!=='string' || !ACTIONS.has(action)) return failure('Action tidak dikenal');
  if(!body.data || typeof body.data!=='object' || Array.isArray(body.data)) return failure('data harus berupa objek JSON');
  const data={...body.data};delete data.new_session_hash;
  if(encoder.encode(env.APP_SECRET || '').length<32) return failure('Konfigurasi aplikasi belum lengkap. Hubungi admin',503,'CONFIGURATION');
  let token=sessionCookie(request);
  if(action!=='login' && !token) return failure('Silakan login terlebih dahulu',401,'UNAUTHENTICATED');
  if(action==='login' && (typeof data.username!=='string' || !data.username.trim() || data.username.length>40 || typeof data.password!=='string' || encoder.encode(data.password).length>72 || !data.password)) return failure('Username dan password wajib diisi dengan format yang benar',422,'VALIDATION');
  const nextToken=(action==='login' || action==='changePassword') ? hex(crypto.getRandomValues(new Uint8Array(32))) : null;
  try {
    if(nextToken) data.new_session_hash=await digest(nextToken);
    const sessionHash=token ? await digest(token) : '';
    const ip=await ipKey(request,env.APP_SECRET);
    const db=dbOverride || neonDatabase(env);const dbStart=performance.now();
    const result=await db.call(action,sessionHash,data,ip);const dbTime=performance.now()-dbStart;
    if(!result || typeof result.ok!=='boolean') throw new Error('INVALID_DATABASE_RESPONSE');
    const status=result.ok ? 200 : ([400,401,403,409,413,422,429,500,503].includes(result.status) ? result.status : 500);
    const headers={'Server-Timing':`db;dur=${dbTime.toFixed(1)}, total;dur=${(performance.now()-started).toFixed(1)}`};
    if(result.ok && nextToken) headers['Set-Cookie']=cookie(nextToken);
    // Respons 401 lama tidak boleh menghapus cookie login/password baru yang tiba lebih dahulu.
    if(result.ok && action==='logout') headers['Set-Cookie']=cookie('');
    if(status===429) headers['Retry-After']=action==='login' || action==='changePassword' ? '600' : '60';
    const {status:_status,...clean}=result;
    return response({...clean,request_id:requestId,version:VERSION},status,headers);
  } catch(e) {
    // Jangan log query, payload, connection string, password, IP mentah, atau token.
    console.error(JSON.stringify({service:'sinabos',request_id:requestId,action,event:'database_unavailable',code:/^[A-Z0-9_]{1,32}$/.test(e.code || '')?e.code:'UPSTREAM'}));
    return failure('Layanan data belum merespons. Status simpan belum dapat dipastikan; periksa atau ulangi permintaan dengan ID yang sama',503,'SERVICE_UNAVAILABLE');
  }
}
