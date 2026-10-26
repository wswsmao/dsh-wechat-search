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
