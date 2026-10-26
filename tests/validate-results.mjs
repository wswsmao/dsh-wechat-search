import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('..',import.meta.url));
const jobs=path.join(root,'.runtime','jobs');
for(const id of await fs.readdir(jobs)){
  let s,r;try{s=JSON.parse((await fs.readFile(path.join(jobs,id,'status.json'),'utf8')).replace(/^\uFEFF/,''));r=JSON.parse((await fs.readFile(path.join(jobs,id,'results','result.json'),'utf8')).replace(/^\uFEFF/,''));}catch{continue;}
  assert.equal(s.keyword,r.job.keyword);assert.equal(s.coverage.global_complete,false);
  if(!['starting','running','cancelling'].includes(s.status)){assert.equal(s.status,r.job.status);assert.equal(s.coverage.scope_complete,r.job.coverage.scope_complete);}
  assert.equal(r.records.length,s.counts.matched);const cut=Date.parse(s.cutoff_time),ref=Date.parse(s.reference_time);
  const identities=new Set();
  for(const row of r.records){
    assert(row.title && row.url && row.account && row.date);const u=new URL(row.url);assert.equal(u.hostname,'mp.weixin.qq.com');
    assert(!['key','uin','pass_ticket','exportkey','search_click_id'].some(x=>u.searchParams.has(x)));
    if(row.published_at_iso){const t=Date.parse(row.published_at_iso);assert(t>=cut&&t<=ref);}
    else{assert.equal(row.publication_precision,'day');const t=Date.parse(row.date+'T00:00:00+08:00');assert(t>=cut&&t+86400000<=ref);}
    assert(!identities.has(row.identity));identities.add(row.identity);
  }
  console.log(JSON.stringify({id,keyword:s.keyword,days:s.lookback_days,status:s.status,counts:s.counts,coverage:s.coverage}));
}
console.log('PASS: real-result bounds, identity dedup, safe URLs, metadata counts');
