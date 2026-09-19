import fs from 'node:fs/promises';
const lock=JSON.parse(await fs.readFile(new URL('../package-lock.json',import.meta.url),'utf8'));
const root=new URL('../',import.meta.url);const entries=[];
for(const [path,meta] of Object.entries(lock.packages)){
 if(!path||meta.dev||meta.devOptional)continue;
 let p,files;try{p=JSON.parse(await fs.readFile(new URL(path+'/package.json',root),'utf8'));files=await fs.readdir(new URL(path+'/',root),{withFileTypes:true});}catch{continue;}
 const sections=[];for(const file of files.filter(x=>x.isFile()&&/^(license|licence|copying|notice)([.-]|$)/i.test(x.name))){sections.push('--- '+file.name+' ---\n'+await fs.readFile(new URL(path+'/'+file.name,root),'utf8'));}
 entries.push({name:p.name,version:p.version,license:p.license||'See package metadata',text:sections.join('\n\n')});
}
entries.sort((a,b)=>a.name.localeCompare(b.name));
await fs.writeFile(new URL('THIRD_PARTY_NOTICES.txt',root),'SINABOS 4.0 — Third-party runtime dependency notices\n\nEach dependency retains its own license. School logo and original school materials retain their respective ownership. This file does not relicense those materials. Development/build tools remain referenced in package-lock.json and are not bundled here.\n\n'+entries.map(e=>'='.repeat(78)+'\n'+e.name+'@'+e.version+' | '+JSON.stringify(e.license)+'\n\n'+(e.text||'No separate license file shipped in this installed package. See its package metadata and upstream repository.')).join('\n\n'));
console.log('Notices written for '+entries.length+' installed runtime packages.');
