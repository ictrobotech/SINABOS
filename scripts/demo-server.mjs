// Hanya demonstrasi lokal: database in-memory, tidak pernah memakai DATABASE_URL.
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {randomBytes} from 'node:crypto';
import {demoDatabase,root} from '../tests/helpers.mjs';
import {handleAPI} from '../server/api.js';
const db=await demoDatabase();const env={APP_SECRET:randomBytes(40).toString('hex')};
const adapter={async call(action,token,data,ip){const r=await db.query('select public.sinabos_v4_api($1,$2,$3::jsonb,$4) as result',[action,token,JSON.stringify(data),ip]);return r.rows[0]?.result;}};
const server=http.createServer(async(req,res)=>{
 try{
  const protocol=req.headers['x-forwarded-proto']?.split(',')[0] || 'http';
  const url=new URL(req.url,`${protocol}://${req.headers.host}`);
  if(url.pathname==='/api'){
   const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>65536){res.writeHead(413,{'Content-Type':'application/json'});res.end('{"ok":false,"error":"Payload terlalu besar"}');return;}chunks.push(chunk);}
   const headers=new Headers();for(const [k,v] of Object.entries(req.headers))if(v)headers.set(k,Array.isArray(v)?v.join(','):v);
   headers.set('CF-Connecting-IP',req.socket.remoteAddress||'demo-local');
   const request=new Request(url,{method:req.method,headers,...(!['GET','HEAD'].includes(req.method)?{body:Buffer.concat(chunks)}:{})});
   const r=await handleAPI(request,env,adapter);const outHeaders=Object.fromEntries(r.headers);
   // Hanya demo HTTPS dalam iframe: cookie terpartisi, bukan kebijakan produksi.
   if(protocol==='https'&&outHeaders['set-cookie'])outHeaders['set-cookie']=outHeaders['set-cookie'].replace('SameSite=Strict','SameSite=None')+'; Partitioned';
   res.writeHead(r.status,outHeaders);res.end(Buffer.from(await r.arrayBuffer()));return;
  }
  // Pratinjau Arena di sini sengaja boleh di-iframe. Produksi memakai _headers DENY.
  let pathname=decodeURIComponent(url.pathname);if(pathname==='/'||pathname==='/index.html')pathname='/index.html';
  const file=path.resolve(root+'public','.'+pathname);if(!file.startsWith(path.resolve(root+'public')+path.sep)){res.writeHead(403);res.end();return;}
  let contents=await fs.readFile(file);
  if(pathname==='/index.html')contents=Buffer.from(contents.toString().replace('name="sinabos-demo" content="false"','name="sinabos-demo" content="true"'));
  const types={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png','.svg':'image/svg+xml','.json':'application/json'};
  res.writeHead(200,{'Content-Type':types[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(contents);
 }catch(e){if(e.code==='ENOENT'){res.writeHead(404);res.end('Not found');}else{console.error(e.message);res.writeHead(500,{'Content-Type':'application/json'});res.end('{"ok":false,"error":"Gangguan demo lokal"}');}}
});
server.listen(Number(process.env.PORT||3000),'0.0.0.0',()=>console.log('SINABOS preview ready on 0.0.0.0:'+Number(process.env.PORT||3000)+' — data simulasi, bukan produksi'));
async function stop(){server.close();await db.close();process.exit(0);}process.on('SIGTERM',stop);process.on('SIGINT',stop);
