export class WechatSearchError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = 'WechatSearchError';
    this.code = code;
    this.details = details;
  }
}

export const JOB_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const TERMINAL = new Set(['complete', 'partial', 'cancelled', 'needs_user', 'failed', 'interrupted']);
export const ACTIVE = new Set(['starting', 'running', 'cancelling', 'queued']);

export function validateSearch(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new WechatSearchError('INVALID_ARGUMENT', 'Expected keyword and lookback_days.');
  }
  if (Object.keys(input).some((key) => !['keyword', 'lookback_days'].includes(key))) {
    throw new WechatSearchError('INVALID_ARGUMENT', 'Only keyword and lookback_days are accepted.');
  }
  if (typeof input.keyword !== 'string' || !input.keyword.trim() || input.keyword.length > 200 || /[\u0000-\u001f\u007f]/u.test(input.keyword)) {
    throw new WechatSearchError('INVALID_KEYWORD', '关键词须为非空单行字符串，最多200个字符。');
  }
  if (!Number.isInteger(input.lookback_days) || input.lookback_days < 1 || input.lookback_days > 7) {
    throw new WechatSearchError('INVALID_LOOKBACK', '回溯天数须为1至7的整数；1表示24小时。');
  }
  // Preserve the user's exact keyword; never add dates or synonyms.
  return { keyword: input.keyword, lookback_days: input.lookback_days };
}

export function validateStartOptions(options = {}, now = new Date()) {
  if (!options || typeof options !== 'object' || Array.isArray(options) || Object.keys(options).some((key) => !['reference_time', 'include_body', 'parallel_windows', 'list_only', 'open_keys', 'signal'].includes(key))) {
    throw new WechatSearchError('INVALID_OPTIONS', 'Internal options accept only reference_time, include_body, parallel_windows, list_only, open_keys and signal.');
  }
  if (options.include_body !== undefined && typeof options.include_body !== 'boolean') {
    throw new WechatSearchError('INVALID_INCLUDE_BODY', 'include_body must be boolean.');
  }
  if (options.list_only !== undefined && typeof options.list_only !== 'boolean') {
    throw new WechatSearchError('INVALID_LIST_ONLY', 'list_only must be boolean.');
  }
  let openKeys;
  if (options.open_keys !== undefined) {
    if (!Array.isArray(options.open_keys) || options.open_keys.some((k) => typeof k !== 'string' || !k || k.length > 500)) {
      throw new WechatSearchError('INVALID_OPEN_KEYS', 'open_keys must be an array of non-empty strings.');
    }
    openKeys = options.open_keys.slice(0, 2000);
  }
  const parallelWindows = options.parallel_windows ?? 6;
  if (!Number.isSafeInteger(parallelWindows) || parallelWindows < 1 || parallelWindows > 64) {
    throw new WechatSearchError('INVALID_PARALLEL_WINDOWS', 'parallel_windows must be an integer between 1 and 64.');
  }
  let reference = new Date(now);
  if (options.reference_time !== undefined) {
    const value = options.reference_time;
    const match = typeof value === 'string' && /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/iu.exec(value);
    if (!match) throw new WechatSearchError('INVALID_REFERENCE_TIME', 'reference_time must be an RFC3339 timestamp with an explicit offset.');
    const [, year, month, day, hour, minute, second, , zone] = match;
    const lastDay = new Date(Date.UTC(Number(year), Number(month), 0)).getUTCDate();
    const offset = zone.toUpperCase() === 'Z' ? [0, 0] : zone.slice(1).split(':').map(Number);
    if (Number(month) < 1 || Number(month) > 12 || Number(day) < 1 || Number(day) > lastDay || Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59 || offset[0] > 23 || offset[1] > 59) {
      throw new WechatSearchError('INVALID_REFERENCE_TIME', 'reference_time contains an invalid calendar date or offset.');
    }
    reference = new Date(value);
  }
  if (!Number.isFinite(reference.getTime()) || reference.getTime() > new Date(now).getTime()) {
    throw new WechatSearchError('INVALID_REFERENCE_TIME', 'reference_time must be valid and not in the future.');
  }
  return { reference_time: reference.toISOString(), include_body: options.include_body ?? false, parallel_windows: parallelWindows, list_only: options.list_only ?? false, open_keys: openKeys, signal: validateSignal(options.signal) };
}

export function validateSignal(signal) {
  if (signal !== undefined && (!signal || typeof signal.aborted !== 'boolean' || typeof signal.addEventListener !== 'function' || typeof signal.removeEventListener !== 'function')) {
    throw new WechatSearchError('INVALID_SIGNAL', 'signal must be an AbortSignal.');
  }
  return signal;
}

export function abortError() {
  const error = new Error('WeChat search operation was aborted.');
  error.name = 'AbortError'; error.code = 'ABORTED';
  return error;
}

export function throwIfAborted(signal) { if (signal?.aborted) throw abortError(); }

export function validateJobId(id) {
  if (typeof id !== 'string' || !JOB_ID.test(id)) {
    throw new WechatSearchError('INVALID_JOB_ID', '任务ID须为检索工具返回的UUID。');
  }
  return id.toLowerCase();
}

export function validateJobAction(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || !['status', 'list', 'cancel', 'resume'].includes(input.action)) {
    throw new WechatSearchError('INVALID_ACTION', 'action须为status、list、cancel或resume。');
  }
  if (Object.keys(input).some((key) => !['action', 'job_id'].includes(key))) {
    throw new WechatSearchError('INVALID_ARGUMENT', 'Only action and job_id are accepted.');
  }
  if (input.action === 'list') {
    if (input.job_id !== undefined) throw new WechatSearchError('INVALID_ARGUMENT', 'list不接受job_id。');
    return { action: 'list' };
  }
  return { action: input.action, job_id: validateJobId(input.job_id) };
}
