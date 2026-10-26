import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WechatTaskManager, readJson, writeJsonAtomic } from '../lib/task-manager.js';
import { validateSearch, validateJobAction } from '../lib/validation.js';
import { createToolDefinitions } from '../lib/tools.js';

const project = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const testRoot = path.join(project, '.runtime', 'tests');
const tick = () => new Promise((resolve) => setImmediate(resolve));

async function fixture(t, options = {}) {
  await fs.mkdir(testRoot, { recursive: true });
  const dir = await fs.mkdtemp(path.join(testRoot, 'manager-'));
  const handles = []; const calls = [];
  const subprocess = {
    async terminalEnvironment() { return { platform: options.platform ?? 'windows' }; },
    async resolveExecutable(name) { assert.equal(name, 'powershell.exe'); return 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'; },
    spawn(spec) {
      calls.push(spec);
      let resolve, reject;
      const done = new Promise((yes, no) => { resolve = yes; reject = no; });
      const handle = { done, resolve, reject, terminated: 0, terminate() { this.terminated++; resolve({ exitCode: 1, signal: null }); }, async waitForExit() { await done; return true; } };
      handles.push(handle); return handle;
    },
  };
  const manager = new WechatTaskManager({ packageDir: dir, subprocess, clock: () => new Date('2026-10-26T10:00:00+08:00'), cancelGraceMs: 5, shutdownGraceMs: 20, ...options });
  await manager.ready;
  t.after(async () => { await manager.dispose(); await fs.rm(dir, { recursive: true, force: true }); });
  return { manager, dir, handles, calls, subprocess };
}

const input = { keyword: 'DeepSeek', lookback_days: 3 };

test('validation preserves original keyword and bounds lookback', () => {
  assert.deepEqual(validateSearch({ keyword: '  DeepSeek & $(test)  ', lookback_days: 1 }), { keyword: '  DeepSeek & $(test)  ', lookback_days: 1 });
  assert.equal(validateSearch({ keyword: 'a'.repeat(200), lookback_days: 7 }).keyword.length, 200);
  for (const value of [0, 8, 1.5, '1', null, undefined]) assert.throws(() => validateSearch({ keyword: 'x', lookback_days: value }), { code: 'INVALID_LOOKBACK' });
  for (const value of ['', '   ', 'x\ny', '\u0000', 'a'.repeat(201), 1]) assert.throws(() => validateSearch({ keyword: value, lookback_days: 1 }), { code: 'INVALID_KEYWORD' });
  assert.throws(() => validateSearch({ ...input, output_path: 'C:\\anywhere' }), { code: 'INVALID_ARGUMENT' });
  assert.throws(() => validateJobAction({ action: 'status', job_id: '../escape' }), { code: 'INVALID_JOB_ID' });
  assert.throws(() => validateJobAction({ action: 'list', job_id: 'anything' }), { code: 'INVALID_ARGUMENT' });
});

test('start durable request uses argv, fixed rolling window and inherited output', async (t) => {
  const f = await fixture(t);
  const receipt = await f.manager.start({ keyword: 'DeepSeek; & calc.exe', lookback_days: 1 });
  assert.equal(receipt.status, 'starting'); assert.equal(receipt.keyword, 'DeepSeek; & calc.exe');
  const p = f.manager.paths(receipt.job_id); const request = await readJson(p.request);
  assert.equal(request.reference_time, '2026-10-26T02:00:00.000Z'); assert.equal(request.cutoff_time, '2026-10-25T02:00:00.000Z');
  assert.equal(request.resume, false); assert.equal(request.worker_runtime_root, path.join(f.dir, '.runtime'));
  const spec = f.calls[0];
  assert.deepEqual(spec.stdio, { stdin: 'ignore', stdout: 'inherit', stderr: 'inherit' });
  assert.ok(spec.argv.includes('-STA')); assert.ok(spec.argv.includes('-File')); assert.ok(!spec.argv.includes(request.keyword));
  assert.ok(spec.argv.includes(p.request)); assert.equal(spec.cwd, f.dir);
  assert.equal(receipt.coverage.global_complete, false);
});

test('concurrent starts permit one local worker and return BUSY', async (t) => {
  const f = await fixture(t);
  const values = await Promise.allSettled([f.manager.start(input), f.manager.start(input)]);
  assert.equal(values.filter((v) => v.status === 'fulfilled').length, 1);
  assert.equal(values.find((v) => v.status === 'rejected').reason.code, 'BUSY'); assert.equal(f.calls.length, 1);
});

test('status preview bounded to five; full files remain retrievable and unsafe URL tokens removed', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  const rows = Array.from({ length: 12 }, (_, i) => ({ title: `article ${i}`, url: `https://mp.weixin.qq.com/s?__biz=abc&mid=${i}&idx=1&sn=hash&key=SECRET&pass_ticket=SECRET`, author: '署名', account: '公众号', date: '2026-10-25' }));
  await writeJsonAtomic(p.json, { matching_count: 12, records: rows });
  const old = await readJson(p.status); await writeJsonAtomic(p.status, { ...old, status: 'complete', counts: { ...old.counts, matched: 12 }, coverage: { search_boundary_reached: true, scope_complete: true, global_complete: true }, files: { csv: 'C:\\untrusted.csv', json: 'C:\\untrusted.json' } });
  f.handles[0].resolve({ exitCode: 0, signal: null }); await tick();
  const state = await f.manager.status(receipt.job_id);
  assert.equal(state.preview.length, 5); assert.equal(state.preview_omitted, 7); assert.equal(state.total_count, 12);
  assert.equal(state.files.csv, p.csv); assert.equal(state.coverage.global_complete, false); assert.equal(state.coverage.scope_complete, true);
  assert.ok(!JSON.stringify(state.preview).includes('SECRET')); assert.ok(!JSON.stringify(state.preview).includes('pass_ticket'));
});

test('cancel flag is durable and termination targets only managed worker', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input);
  const state = await f.manager.cancel(receipt.job_id);
  assert.equal(state.status, 'cancelled'); assert.equal(f.handles[0].terminated, 1);
  assert.ok((await fs.readFile(f.manager.paths(receipt.job_id).cancel, 'utf8')).length > 0);
  assert.equal(f.calls.length, 1);
});

test('cancel racing worker completion cannot overwrite terminal status or leave BUSY', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  const original = fs.writeFile; let injected = false;
  fs.writeFile = async (file, ...args) => {
    if (file === p.cancel && !injected) {
      injected = true;
      const state = await readJson(p.status);
      await writeJsonAtomic(p.status, { ...state, status: 'complete', phase: 'complete', coverage: { scope_complete: true, search_boundary_reached: true, global_complete: false } });
      f.handles[0].resolve({ exitCode: 0, signal: null });
    }
    return original.call(fs, file, ...args);
  };
  try {
    const cancelled = await f.manager.cancel(receipt.job_id);
    assert.equal(cancelled.status, 'complete'); assert.equal((await readJson(p.status)).status, 'complete');
    assert.equal(f.handles[0].terminated, 0);
    await f.manager.start(input); assert.equal(f.calls.length, 2);
  } finally { fs.writeFile = original; }
});

test('cancel derives cancelling from flag without mutating live worker status', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  await fs.writeFile(p.cancel, 'cancel requested');
  assert.equal((await f.manager.status(receipt.job_id)).status, 'cancelling');
  assert.equal((await readJson(p.status)).status, 'starting');
});

test('resume keeps reference time and records, clears cancellation flag', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  await writeJsonAtomic(p.json, { records: [{ title: 'retained' }] });
  await f.manager.cancel(receipt.job_id);
  const old = await readJson(p.request); const resumed = await f.manager.resume(receipt.job_id); const request = await readJson(p.request);
  assert.equal(request.resume, true); assert.equal(request.reference_time, old.reference_time); assert.equal(request.cutoff_time, old.cutoff_time);
  assert.equal(resumed.job_id, receipt.job_id); assert.equal(resumed.phase, 'resuming'); assert.equal(f.calls.length, 2);
  assert.equal(await fs.stat(p.cancel).catch(() => undefined), undefined);
  assert.equal((await readJson(p.json)).records[0].title, 'retained');
});

test('failed or provider-aborted worker records terminal failure rather than hanging running', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input);
  const finished = f.manager.active.completion; f.handles[0].reject(new Error('provider failed')); await finished;
  const state = await f.manager.status(receipt.job_id); assert.equal(state.status, 'failed'); assert.equal(state.stop_reason, 'worker_provider_failure');
});

test('plugin unload terminates owned worker and marks interrupted', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input);
  await f.manager.dispose(); const state = await f.manager.status(receipt.job_id);
  assert.equal(f.handles[0].terminated, 1); assert.equal(state.status, 'interrupted'); assert.equal(state.stop_reason, 'plugin_unloaded');
  await assert.rejects(() => f.manager.start(input), { code: 'PLUGIN_UNLOADED' });
});

test('plugin unload gives cooperative worker grace and still marks interrupted', async (t) => {
  const f = await fixture(t, { cancelGraceMs: 50 }); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  const stopping = f.manager.dispose();
  await new Promise((resolve) => setTimeout(resolve, 5));
  const old = await readJson(p.status); await writeJsonAtomic(p.status, { ...old, status: 'cancelled', phase: 'cancelled' });
  f.handles[0].resolve({ exitCode: 0, signal: null }); await stopping;
  assert.equal(f.handles[0].terminated, 0); assert.equal((await f.manager.status(receipt.job_id)).status, 'interrupted');
});

test('startup rehydrates dead owners as interrupted but preserves live foreign owners', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  const request = await readJson(p.request); await writeJsonAtomic(p.request, { ...request, manager_owner_pid: 123456 });
  const second = new WechatTaskManager({ packageDir: f.dir, subprocess: f.subprocess, processAlive: () => false }); await second.ready;
  assert.equal((await second.status(receipt.job_id)).status, 'interrupted'); await second.dispose();
  const state = await readJson(p.status); await writeJsonAtomic(p.status, { ...state, status: 'running', worker_pid: 4321 });
  const third = new WechatTaskManager({ packageDir: f.dir, subprocess: f.subprocess, processAlive: (pid) => pid === 4321 }); await third.ready;
  assert.equal((await third.status(receipt.job_id)).status, 'running'); await assert.rejects(() => third.start(input), { code: 'BUSY' }); await third.dispose();
});

test('same Host PID old generation without live worker rehydrates; live worker is protected', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  const sameHost = new WechatTaskManager({ packageDir: f.dir, subprocess: f.subprocess, ownerPid: f.manager.ownerPid, processAlive: (pid) => pid === f.manager.ownerPid });
  await sameHost.ready; assert.equal((await sameHost.status(receipt.job_id)).status, 'interrupted'); await sameHost.dispose();
  const old = await readJson(p.status); await writeJsonAtomic(p.status, { ...old, status: 'running', worker_pid: 4567 });
  const liveWorker = new WechatTaskManager({ packageDir: f.dir, subprocess: f.subprocess, ownerPid: f.manager.ownerPid, processAlive: (pid) => pid === f.manager.ownerPid || pid === 4567 });
  await liveWorker.ready; assert.equal((await liveWorker.status(receipt.job_id)).status, 'running'); await liveWorker.dispose();
});

test('all pre-spawn failures produce durable failed state and do not leave BUSY', async (t) => {
  for (const stage of ['environment', 'resolve', 'spawn']) {
    const f = await fixture(t);
    if (stage === 'environment') f.subprocess.terminalEnvironment = async () => { throw new Error('environment failed'); };
    if (stage === 'resolve') f.subprocess.resolveExecutable = async () => { throw new Error('resolve failed'); };
    if (stage === 'spawn') f.subprocess.spawn = () => { throw new Error('spawn failed'); };
    await assert.rejects(() => f.manager.start(input));
    const rows = (await f.manager.list()).jobs; assert.equal(rows[0].status, 'failed');
    await assert.rejects(() => f.manager.start(input), (error) => error.code !== 'BUSY');
  }
});

test('manager terminal fallback synchronizes exported job metadata while preserving article rows', async (t) => {
  const f = await fixture(t); const receipt = await f.manager.start(input); const p = f.manager.paths(receipt.job_id);
  await writeJsonAtomic(p.json, { job: { id: receipt.job_id, status: 'running', coverage: { scope_complete: true, global_complete: true } }, records: [{ title: 'keep', url: 'https://mp.weixin.qq.com/s/fxT7NxktgU8PMeHXY28ftQ' }], coverage: { scope_complete: true, global_complete: true } });
  await f.manager.cancel(receipt.job_id);
  const result = await readJson(p.json);
  assert.equal(result.job.status, 'cancelled'); assert.equal(result.job.coverage.scope_complete, false); assert.equal(result.coverage.global_complete, false);
  assert.equal(result.records[0].title, 'keep');
});

test('non-Windows rejects cleanly and writes durable failed state', async (t) => {
  const f = await fixture(t, { platform: 'posix' }); await assert.rejects(() => f.manager.start(input), { code: 'WINDOWS_REQUIRED' });
  const list = await f.manager.list(); assert.equal(list.jobs[0].status, 'failed'); assert.equal(f.calls.length, 0);
});

test('tool definitions expose exactly two business inputs and classify reads as parallel', async (t) => {
  const f = await fixture(t); const [search, job] = createToolDefinitions(f.manager);
  assert.deepEqual(Object.keys(search.parameters.properties), ['keyword', 'lookback_days']); assert.equal(search.isConcurrencySafe(), false);
  assert.equal(job.isConcurrencySafe({ action: 'status' }), true); assert.equal(job.isConcurrencySafe({ action: 'list' }), true);
  assert.equal(job.isConcurrencySafe({ action: 'cancel' }), false); assert.equal(job.isConcurrencySafe({ action: 'resume' }), false);
  assert.deepEqual(search.output.render({}, { status: 'starting' })[0], { type: 'text', text: '{\n  "status": "starting"\n}' });
});
