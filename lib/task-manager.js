import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { ACTIVE, TERMINAL, JOB_ID, WechatSearchError, validateSearch, validateJobId } from './validation.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const iso = (date) => new Date(date).toISOString();
const emptyCounts = () => ({ discovered: 0, processed: 0, matched: 0, failed: 0 });
const finiteCount = (n) => Number.isSafeInteger(n) && n >= 0 ? n : 0;

export async function readJson(file) {
  try { return JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/u, '')); }
  catch (error) { if (error.code === 'ENOENT') return undefined; throw error; }
}

export async function writeJsonAtomic(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${randomUUID()}.tmp`;
  await fs.writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  try {
    for (let retry = 0; ; retry++) {
      try { await fs.rename(tmp, file); break; }
      catch (error) { if (retry >= 5 || !['EPERM', 'EACCES', 'EBUSY'].includes(error.code)) throw error; await sleep(40 * (retry + 1)); }
    }
  } finally { await fs.rm(tmp, { force: true }).catch(() => {}); }
}

function isProcessAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

function publicUrl(value) {
  if (typeof value !== 'string') return undefined;
  try {
    const u = new URL(value);
    if (u.protocol !== 'https:' || u.hostname !== 'mp.weixin.qq.com') return undefined;
    if (/^\/s\/[A-Za-z0-9_-]{22}$/u.test(u.pathname)) return `${u.origin}${u.pathname}`;
    const names = ['__biz', 'mid', 'idx', 'sn'];
    if (!names.every((key) => u.searchParams.has(key))) return undefined;
    const q = new URLSearchParams(); names.forEach((key) => q.set(key, u.searchParams.get(key)));
    return `${u.origin}/s?${q}`;
  } catch { return undefined; }
}

function publicPreview(row) {
  if (!row || typeof row !== 'object') return undefined;
  const url = publicUrl(row.url ?? row.link);
  if (!url) return undefined;
  const title = String(row.title ?? '');
  return {
    title: title.slice(0, 500), title_truncated: title.length > 500, url, author: String(row.author ?? '').slice(0, 200), account: String(row.account ?? '').slice(0, 200),
    date: String(row.date ?? ''), published_at: row.published_at ?? row.published_at_iso ?? null,
    publication_precision: row.publication_precision ?? (row.published_at_iso ? 'minute' : 'day'),
  };
}

export class WechatTaskManager {
  constructor({ packageDir, subprocess, clock = () => new Date(), uuid = randomUUID, ownerPid = process.pid, processAlive = isProcessAlive, cancelGraceMs = 3000, shutdownGraceMs = 8000, settings = {} }) {
    this.packageDir = path.resolve(packageDir);
    this.runtimeDir = path.join(this.packageDir, '.runtime');
    this.jobsDir = path.join(this.runtimeDir, 'jobs');
    this.subprocess = subprocess;
    this.clock = clock; this.uuid = uuid; this.ownerPid = ownerPid; this.processAlive = processAlive;
    this.ownerToken = randomUUID(); this.cancelGraceMs = cancelGraceMs; this.shutdownGraceMs = shutdownGraceMs;
    this.settings = { timeout_minutes: 30, delay_ms: 600, max_retries: 2, ...settings };
    this.active = undefined; this.closed = false; this.serial = Promise.resolve();
    this.ready = this.initialize();
  }

  jobDir(id) { return path.join(this.jobsDir, validateJobId(id)); }
  paths(id) { const dir = this.jobDir(id); return { dir, request: path.join(dir, 'request.json'), status: path.join(dir, 'status.json'), cancel: path.join(dir, 'cancel.flag'), json: path.join(dir, 'results', 'result.json'), csv: path.join(dir, 'results', 'result.csv') }; }
  now() { return iso(this.clock()); }
  async exclusive(callback) {
    const next = this.serial.then(callback, callback);
    this.serial = next.catch(() => {});
    return next;
  }

  async initialize() {
    await fs.mkdir(this.jobsDir, { recursive: true });
    const dirs = await fs.readdir(this.jobsDir, { withFileTypes: true });
    for (const entry of dirs) {
      if (!entry.isDirectory() || !JOB_ID.test(entry.name)) continue;
      const p = this.paths(entry.name);
      let status, request;
      try { status = await readJson(p.status); request = await readJson(p.request); } catch { continue; }
      if (!status || !ACTIVE.has(status.status)) continue;
      // Never disturb a worker owned by another live manager. The collector's file lock arbitrates races.
      if (this.processAlive(request?.manager_owner_pid) || this.processAlive(status.worker_pid)) continue;
      await writeJsonAtomic(p.status, { ...status, status: 'interrupted', phase: 'interrupted', updated_at: this.now(), stop_reason: 'previous_manager_not_running', coverage: { ...status.coverage, scope_complete: false, global_complete: false } });
    }
  }

  async assertAvailable() {
    if (this.closed) throw new WechatSearchError('PLUGIN_UNLOADED', '插件已停用，不能启动新任务。');
    if (this.active) throw new WechatSearchError('BUSY', '当前电脑已有微信采集任务，请先等待或取消。', { job_id: this.active.id });
    const entries = await fs.readdir(this.jobsDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory() || !JOB_ID.test(entry.name)) continue;
      const p = this.paths(entry.name);
      const status = await readJson(p.status).catch(() => undefined);
      if (status && ACTIVE.has(status.status)) {
        throw new WechatSearchError('BUSY', '存在未结束的微信采集任务；请检查其状态。', { job_id: entry.name });
      }
    }
  }

  async start(input) {
    const args = validateSearch(input);
    await this.ready;
    return this.exclusive(async () => {
      await this.assertAvailable();
      const id = validateJobId(this.uuid()); const p = this.paths(id);
      await fs.mkdir(p.dir, { recursive: false });
      const reference = new Date(this.clock());
      const request = { id, ...args, reference_time: iso(reference), cutoff_time: iso(reference.getTime() - args.lookback_days * 86400000), resume: false, settings: this.settings, worker_runtime_root: this.runtimeDir, manager_owner_pid: this.ownerPid, manager_owner_token: this.ownerToken };
      await writeJsonAtomic(p.request, request);
      await writeJsonAtomic(p.status, { id, ...args, status: 'starting', phase: 'starting', started_at: this.now(), reference_time: request.reference_time, cutoff_time: request.cutoff_time, updated_at: this.now(), counts: emptyCounts(), stop_reason: null, coverage: { search_boundary_reached: false, scope_complete: false, global_complete: false }, files: { json: p.json, csv: p.csv }, preview: [], errors: [] });
      await this.spawnWorker(id);
      return this.status(id);
    });
  }

  async spawnWorker(id) {
    const p = this.paths(id);
    const environment = await this.subprocess.terminalEnvironment();
    if (environment.platform !== 'windows') {
      await this.patchTerminal(id, 'failed', 'windows_desktop_required');
      throw new WechatSearchError('WINDOWS_REQUIRED', '本插件需要Windows本机交互式桌面。');
    }
    let executable;
    try { executable = await this.subprocess.resolveExecutable('powershell.exe'); }
    catch (error) { await this.patchTerminal(id, 'failed', 'powershell_unavailable'); throw error; }
    const controller = new AbortController();
    let handle;
    try {
      handle = this.subprocess.spawn({
        argv: [executable, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', path.join(this.packageDir, 'collector', 'main.ps1'), '-RequestPath', p.request, '-JobDir', p.dir],
        cwd: this.packageDir, stdio: { stdin: 'ignore', stdout: 'inherit', stderr: 'inherit' }, graceMs: 1200, signal: controller.signal,
      });
    } catch (error) { await this.patchTerminal(id, 'failed', 'worker_spawn_failed'); throw error; }
    const owned = { id, handle, controller, unloading: false, cancellationRequested: false };
    this.active = owned;
    owned.completion = Promise.resolve(handle.done).then(
      (outcome) => this.workerDone(owned, outcome),
      () => this.workerDone(owned, { exitCode: null, signal: null, providerFailure: true }),
    ).catch(async () => {
      if (this.active === owned) this.active = undefined;
    });
  }

  async patchTerminal(id, status, reason) {
    const p = this.paths(id); const old = await readJson(p.status);
    if (!old) return;
    await writeJsonAtomic(p.status, { ...old, status, phase: status, updated_at: this.now(), stop_reason: reason, coverage: { ...old.coverage, scope_complete: false, global_complete: false } });
  }

  async workerDone(owned, outcome) {
    const p = this.paths(owned.id);
    const old = await readJson(p.status);
    if (old && (owned.unloading && old.status !== 'complete' || !TERMINAL.has(old.status))) {
      const state = owned.unloading ? 'interrupted' : owned.cancellationRequested ? 'cancelled' : 'failed';
      const reason = owned.unloading ? 'plugin_unloaded' : owned.cancellationRequested ? 'cancel_requested' : outcome.providerFailure ? 'worker_provider_failure' : 'worker_exited_without_terminal_status';
      await this.patchTerminal(owned.id, state, reason);
    }
    if (this.active === owned) this.active = undefined;
  }

  async status(id) {
    await this.ready; const p = this.paths(id);
    const state = await readJson(p.status);
    if (!state) throw new WechatSearchError('NOT_FOUND', '没有找到该微信检索任务。');
    return this.summarize(state, p);
  }

  async summarize(state, p, includePreview = true) {
    let result;
    const rawPreview = Array.isArray(state.preview) ? state.preview : [];
    if (includePreview && !rawPreview.length && TERMINAL.has(state.status)) {
      try { result = await readJson(p.json); } catch { /* status remains available if result write failed */ }
    }
    const rows = rawPreview.length ? rawPreview : Array.isArray(result?.records) ? result.records : [];
    const counts = Object.fromEntries(['discovered', 'processed', 'matched', 'failed'].map((key) => [key, finiteCount(state.counts?.[key])]));
    const total = finiteCount(state.total_count ?? result?.matching_count ?? result?.total_count ?? counts.matched);
    const preview = includePreview ? rows.slice(0, 5).map(publicPreview).filter(Boolean) : [];
    return {
      job_id: state.id ?? path.basename(p.dir), keyword: state.keyword ?? '', lookback_days: state.lookback_days,
      status: state.status, phase: state.phase ?? state.status, started_at: state.started_at ?? null,
      reference_time: state.reference_time ?? null, cutoff_time: state.cutoff_time ?? null, updated_at: state.updated_at ?? null,
      counts, total_count: total, stop_reason: state.stop_reason ?? null,
      coverage: { search_boundary_reached: state.coverage?.search_boundary_reached === true, scope_complete: state.coverage?.scope_complete === true, global_complete: false },
      files: { json: p.json, csv: p.csv }, preview, preview_limit: 5, preview_omitted: Math.max(0, total - preview.length),
      errors: (Array.isArray(state.errors) ? state.errors : []).slice(0, 5), error_count: Array.isArray(state.errors) ? state.errors.length : counts.failed,
      requirements: '需保持Windows桌面解锁、微信已登录；采集可能切换微信窗口和使用剪贴板。不读取聊天、不发送消息、不自动登录。',
    };
  }

  async list() {
    await this.ready;
    const rows = [];
    for (const entry of await fs.readdir(this.jobsDir, { withFileTypes: true })) {
      if (!entry.isDirectory() || !JOB_ID.test(entry.name)) continue;
      const p = this.paths(entry.name);
      const state = await readJson(p.status).catch(() => undefined);
      if (state) rows.push(await this.summarize(state, p, false));
    }
    rows.sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)));
    return { jobs: rows.slice(0, 100), total_jobs: rows.length, omitted_jobs: Math.max(0, rows.length - 100), jobs_directory: this.jobsDir };
  }

  async cancel(id) {
    await this.ready; id = validateJobId(id); const p = this.paths(id);
    const owned = await this.exclusive(async () => {
      const state = await readJson(p.status);
      if (!state) throw new WechatSearchError('NOT_FOUND', '没有找到该微信检索任务。');
      if (TERMINAL.has(state.status)) return undefined;
      await fs.writeFile(p.cancel, `${this.now()}\n`, 'utf8');
      await writeJsonAtomic(p.status, { ...state, status: 'cancelling', phase: 'cancelling', updated_at: this.now() });
      if (this.active?.id === id) { this.active.cancellationRequested = true; return this.active; }
      return undefined; // A live foreign manager observes the same flag; never signal its PID directly.
    });
    if (owned) {
      const settled = await Promise.race([owned.completion.then(() => true), sleep(this.cancelGraceMs).then(() => false)]);
      if (!settled) {
        owned.handle.terminate();
        await Promise.race([owned.completion, sleep(this.shutdownGraceMs)]);
      }
    }
    return this.status(id);
  }

  async resume(id) {
    await this.ready; id = validateJobId(id);
    return this.exclusive(async () => {
      await this.assertAvailable(); const p = this.paths(id);
      const state = await readJson(p.status); const request = await readJson(p.request);
      if (!state || !request) throw new WechatSearchError('NOT_FOUND', '没有找到该微信检索任务或请求文件。');
      if (!TERMINAL.has(state.status) || state.status === 'complete') throw new WechatSearchError('NOT_RESUMABLE', '只有未完整完成的终止任务可以续采。');
      validateSearch({ keyword: request.keyword, lookback_days: request.lookback_days });
      await fs.rm(p.cancel, { force: true });
      await writeJsonAtomic(p.request, { ...request, resume: true, manager_owner_pid: this.ownerPid, manager_owner_token: this.ownerToken, worker_runtime_root: this.runtimeDir, settings: this.settings });
      await writeJsonAtomic(p.status, { ...state, status: 'starting', phase: 'resuming', updated_at: this.now(), stop_reason: null, coverage: { ...state.coverage, scope_complete: false, global_complete: false } });
      await this.spawnWorker(id); return this.status(id);
    });
  }

  async dispose() {
    this.closed = true;
    await this.ready.catch(() => {}); await this.serial;
    const owned = this.active;
    if (!owned) return;
    owned.unloading = true;
    await fs.writeFile(this.paths(owned.id).cancel, `${this.now()} plugin_unloaded\n`, 'utf8').catch(() => {});
    const settled = await Promise.race([owned.completion.then(() => true), sleep(this.cancelGraceMs).then(() => false)]);
    if (!settled) {
      owned.handle.terminate();
      await Promise.race([owned.completion, sleep(this.shutdownGraceMs)]);
    }
    const current = await readJson(this.paths(owned.id).status).catch(() => undefined);
    if (current && current.status !== 'complete') await this.patchTerminal(owned.id, 'interrupted', 'plugin_unloaded');
  }
}
