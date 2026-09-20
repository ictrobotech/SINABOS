import {defineConfig} from '@playwright/test';
const base=process.env.PREVIEW_URL||'http://127.0.0.1:3000';
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(base).hostname))throw new Error('Uji browser hanya untuk demo lokal, bukan URL produksi.');
export default defineConfig({testDir:'./tests/browser',fullyParallel:false,workers:1,timeout:45000,expect:{timeout:12000},use:{baseURL:base,headless:true,screenshot:'only-on-failure',trace:'retain-on-failure'},reporter:[['list'],['json',{outputFile:'artifacts/browser-results.json'}]],outputDir:'.cache/browser-results'});
