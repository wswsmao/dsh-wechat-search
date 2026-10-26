import { validateJobAction } from './validation.js';

const output = {
  schema: { type: 'object', additionalProperties: true },
  render(_args, value) { return [{ type: 'text', text: JSON.stringify(value, null, 2) }]; },
};

export function createToolDefinitions(manager) {
  return [
    {
      name: 'wechat_search',
      description: '后台检索本机已登录微信搜一搜可见的近期公众号文章，不追加日期关键词、不设条数上限。返回任务ID；用wechat_search_job查进度并获取完整CSV/JSON。需要Windows桌面解锁，可能切换微信窗口/剪贴板；不读取聊天、不发送消息或自动登录。不保证微信索引之外的全网完整性。',
      parameters: {
        type: 'object', properties: {
          keyword: { type: 'string', minLength: 1, maxLength: 200, description: '原始搜索关键词，非空单行字符串，最多200字符；不增加日期、同义词或标题包含条件。' },
          lookback_days: { type: 'integer', minimum: 1, maximum: 7, description: '回溯天数，整数1～7；按任务开始时刻回溯lookback_days×24小时，固定时间窗、北京时间。' },
        }, required: ['keyword', 'lookback_days'], additionalProperties: false,
      },
      output,
      timeoutMs: 30000,
      isConcurrencySafe: () => false,
      async execute(args) { return manager.start(args); },
      presentCall(args) { return { card: 'generic', title: '检索微信公众号文章', kind: 'execute', rawInput: args }; },
    },
    {
      name: 'wechat_search_job',
      description: '管理微信公众号检索后台任务：查看状态/最近任务、取消或续采。状态含数量、停止原因、覆盖标记、最多5条预览和完整CSV/JSON路径；续采保留原始关键词与原时间窗，不把部分成功误称全部完成。',
      parameters: {
        type: 'object', properties: {
          action: { type: 'string', enum: ['status', 'list', 'cancel', 'resume'], description: 'status查看进度与结果；list列出最近100项并提供全部任务目录；cancel请求停止；resume续采未完整完成的终止任务。' },
          job_id: { type: 'string', description: 'status/cancel/resume必填：wechat_search返回的UUID；list时不填写。' },
        }, required: ['action'], additionalProperties: false,
      },
      output,
      timeoutMs: 30000,
      isConcurrencySafe: (args) => args?.action === 'status' || args?.action === 'list',
      async execute(args) {
        const request = validateJobAction(args);
        if (request.action === 'list') return manager.list();
        return manager[request.action](request.job_id);
      },
      presentCall(args) { return { card: 'generic', title: '微信公众号检索任务', kind: ['status', 'list'].includes(args?.action) ? 'read' : 'execute', rawInput: args }; },
    },
  ];
}
