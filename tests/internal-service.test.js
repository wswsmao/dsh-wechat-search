import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WechatTaskManager, readJson, writeJsonAtomic } from '../lib/task-manager.js';
import { validateStartOptions } from '../lib/validation.js';
import { createWechatSearchService, registerWechatSearch } from '../lib/service.js';
import { createToolDefinitions } from '../lib/tools.js';
const project=fileURLToPath(new URL('..',import.meta.url));
const now=new Date('2026-10-26T08:00:00+08:00');
async function fixture(t){
  const root=path.join(project,'.runtime','tests');await fs.mkdir(root,{recursive:true});
  const dir=await fs.mkdtemp(path.join(root,'service-'));const handles=[];
  const subprocess={terminalEnvironment:async()=>({platform:'windows'}),resolveExecutable:async()=> 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',spawn(spec){let resolve;const done=new Promise(yes=>resolve=yes);const h={done,spec,resolve,terminated:0,terminate(){this.terminated++;resolve({exitCode:1,signal:null});}};handles.push(h);return h;}};
  const manager=new WechatTaskManager({packageDir:dir,subprocess,clock:()=>now,cancelGraceMs:10,shutdownGraceMs:100});await manager.ready;
  t.after(async()=>{await manager.dispose();assert(dir.startsWith(path.join(project,'.runtime','tests')));await fs.rm(dir,{recursive:true,force:true});});
  return {manager,service:createWechatSearchService(manager),handles,dir};
}
const input={keyword:'Agentic OS',lookback_days:2};
test('internal options validate strict frozen timestamp and body flag without changing public inputs',()=>{
  assert.equal(validateStartOptions({reference_time:'2026-10-25T23:00:00+08:00',include_body:true},now).reference_time,'2026-10-25T15:00:00.000Z');
  assert.equal(validateStartOptions({},now).include_body,false);
  for(const value of ['2026-10-26T01:00:00Z','2026-02-30T00:00:00Z','2026-10-25','x','2026-10-25T25:00:00Z'])assert.throws(()=>validateStartOptions({reference_time:value},now),{code:'INVALID_REFERENCE_TIME'});
  assert.throws(()=>validateStartOptions({include_body:'true'},now),{code:'INVALID_INCLUDE_BODY'});
  assert.throws(()=>validateStartOptions({signal:{}},now),{code:'INVALID_SIGNAL'});
  assert.throws(()=>validateStartOptions({unknown:1},now),{code:'INVALID_OPTIONS'});
});
test('internal start writes chosen fixed time/body flag and defaults old public tool to no body',async(t)=>{
  const f=await fixture(t);const job=await f.service.start(input,{reference_time:'2026-10-25T08:00:00+08:00',include_body:true});
  const request=await readJson(f.manager.paths(job.job_id).request);assert.equal(request.reference_time,'2026-10-25T00:00:00.000Z');assert.equal(request.cutoff_time,'2026-10-23T00:00:00.000Z');assert.equal(request.include_body,true);assert.equal(request.keyword,input.keyword);
  const tools=createToolDefinitions(f.manager);assert.deepEqual(Object.keys(tools[0].parameters.properties),['keyword','lookback_days']);
  await f.service.cancel(job.job_id);const old=await f.service.start(input);assert.equal((await readJson(f.manager.paths(old.job_id).request)).include_body,false);
});
test('wait drains terminal worker; getResult returns full private body and status never returns it',async(t)=>{
  const f=await fixture(t);const j=await f.service.start(input,{include_body:true});const p=f.manager.paths(j.job_id);
  await assert.rejects(()=>f.service.getResult(j.job_id),{code:'RESULT_NOT_READY'});
  const body='private body '.repeat(2000);const rows=Array.from({length:8},(_,i)=>({title:`a${i}`,url:`https://mp.weixin.qq.com/s?__biz=abc&mid=${i}&idx=1&sn=hash`,account:'acct',body_text:body,body_status:'ok',body_chars:body.length,body_complete:true}));
  const state=await readJson(p.status);await writeJsonAtomic(p.json,{schema_version:1,job:{...state,status:'complete'},records:rows});await writeJsonAtomic(p.status,{...state,status:'complete',preview:rows.slice(0,5),counts:{matched:8},coverage:{scope_complete:true,body_requested:true,body_complete:true}});
  let settled=false;const waiting=f.service.wait(j.job_id).then(value=>{settled=true;return value;});await new Promise(r=>setTimeout(r,20));assert.equal(settled,false);
  f.handles[0].resolve({exitCode:0,signal:null});const terminal=await waiting;assert.equal(terminal.status,'complete');assert.equal(terminal.preview.length,5);assert(!JSON.stringify(terminal).includes('private body'));const result=await f.service.getResult(j.job_id);assert.equal(result.records.length,8);assert.equal(result.records[0].body_text,body);
});
test('start signal preabort creates no job and poststart abort cancels managed worker',async(t)=>{
  const f=await fixture(t);const pre=new AbortController();pre.abort();await assert.rejects(()=>f.service.start(input,{signal:pre.signal}),{name:'AbortError'});assert.equal((await f.manager.list()).total_jobs,0);
  const running=new AbortController();const j=await f.service.start(input,{signal:running.signal});running.abort();await f.service.wait(j.job_id);assert.equal((await f.service.status(j.job_id)).status,'cancelled');assert.equal(f.handles[0].terminated,1);
});
test('wait aborted signal requests cancellation, rejects and preserves fixed request on resume',async(t)=>{
  const f=await fixture(t);const j=await f.service.start(input,{include_body:true,reference_time:'2026-10-25T08:00:00+08:00'});const p=f.manager.paths(j.job_id);const prior=await readJson(p.request);
  const controller=new AbortController();const waiting=f.service.wait(j.job_id,{signal:controller.signal});controller.abort();await assert.rejects(()=>waiting,{name:'AbortError'});assert.equal((await f.service.status(j.job_id)).status,'cancelled');
  await f.service.resume(j.job_id);const next=await readJson(p.request);assert.equal(next.reference_time,prior.reference_time);assert.equal(next.cutoff_time,prior.cutoff_time);assert.equal(next.include_body,true);
});
test('registration uses actual ctx.provide contract and public tools over one shared manager',async(t)=>{
  const f=await fixture(t);const saved=[];const tools=[];const ctx={provide(name,value){saved.push({name,value});return async()=>{saved.push({removed:name});};},tools:{register(tool){tools.push(tool);return ()=>{};}}};
  const cleanup=registerWechatSearch(ctx,f.manager);assert.equal(saved[0].name,'wechatSearch');assert.deepEqual(Object.keys(saved[0].value),['start','status','cancel','resume','wait','getResult','checkpointPath']);assert.equal(tools.length,2);const job=await saved[0].value.start(input);assert.equal((await f.manager.status(job.job_id)).keyword,input.keyword);await cleanup();assert.equal(saved[1].removed,'wechatSearch');
});
