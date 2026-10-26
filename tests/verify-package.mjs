import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('..',import.meta.url));
const p=JSON.parse(await fs.readFile(path.join(root,'package.json'),'utf8'));
for(const file of ['index.js','cordis.patch.yml','icon.svg','README.md','VALIDATION.md','.gitignore'])assert((await fs.stat(path.join(root,file))).isFile());
assert.equal(p.name,'@local/dsh-wechat-search');assert(!p.dependencies);assert(!p.scripts.install);
assert.equal(p.exports['./icon'],'./icon.svg');
for(const lang of ['zh','en']){const l=JSON.parse(await fs.readFile(path.join(root,'locale',lang+'.json'),'utf8'));assert(l.meta.title&&l.meta.description);}
const icon=await fs.readFile(path.join(root,'icon.svg'),'utf8');assert(icon.startsWith('<svg')&&icon.includes('</svg>')&&Buffer.byteLength(icon)<262144);
const ignore=await fs.readFile(path.join(root,'.gitignore'),'utf8');assert(ignore.includes('.runtime/'));
console.log('PASS: package/runtime exports, bilingual metadata, original SVG, runtime Git exclusion, no install scripts');
