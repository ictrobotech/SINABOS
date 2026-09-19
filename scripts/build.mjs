import {build} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {gzipSync} from 'node:zlib';
const root=fileURLToPath(new URL('../',import.meta.url));process.chdir(root);
await fs.mkdir('public/assets',{recursive:true});
await fs.rm('public/assets',{recursive:true,force:true});
await fs.copyFile('web/logo-sekolah.png','public/logo-sekolah.png');
const r=await build({entryPoints:{app:'web/app.js',style:'web/app.css'},outdir:'public/assets',bundle:true,splitting:true,format:'esm',platform:'browser',target:'es2022',minify:true,entryNames:'[name]-[hash]',chunkNames:'chunk-[hash]',assetNames:'asset-[hash]',metafile:true,legalComments:'none'});
const outputs=Object.entries(r.metafile.outputs);
const js=outputs.find(([,v])=>v.entryPoint==='web/app.js')[0];const css=outputs.find(([,v])=>v.entryPoint==='web/app.css')[0];
let html=await fs.readFile('web/index.html','utf8');html=html.replace('__APP_JS__','/'+path.relative('public',js)).replace('__APP_CSS__','/'+path.relative('public',css));
await fs.writeFile('public/index.html',html);
await fs.writeFile('public/_routes.json',JSON.stringify({version:1,include:['/api'],exclude:[]}));
await fs.writeFile('public/_headers',`/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  X-Frame-Options: DENY
  Permissions-Policy: camera=(self), microphone=(), geolocation=()
  Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; media-src 'self' blob:; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'
/
  Cache-Control: public, max-age=0, must-revalidate
/index.html
  Cache-Control: public, max-age=0, must-revalidate
/assets/*
  Cache-Control: public, max-age=31536000, immutable
/logo-sekolah.png
  Cache-Control: public, max-age=86400
`);
const sizes=[];for(const [name,meta] of outputs){const data=await fs.readFile(name);sizes.push({file:name,bytes:data.length,gzip_bytes:gzipSync(data).length,entry:meta.entryPoint||null});}
await fs.mkdir('artifacts',{recursive:true});await fs.writeFile('artifacts/bundle-size.json',JSON.stringify({version:'4.0.0',files:sizes},null,2));
await import('./notices.mjs');
await fs.copyFile('THIRD_PARTY_NOTICES.txt','public/THIRD_PARTY_NOTICES.txt');
console.table(sizes);console.log('Build selesai. Publish directory: public. Pages Function: functions/api.js');
