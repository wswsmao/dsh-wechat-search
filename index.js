import { fileURLToPath } from 'node:url';
import { WechatTaskManager } from './lib/task-manager.js';
import { registerWechatSearch } from './lib/service.js';

export const inject = ['tools', 'subprocess'];

export function apply(ctx) {
  const packageDir = fileURLToPath(new URL('.', import.meta.url));
  const manager = new WechatTaskManager({ packageDir, subprocess: ctx.subprocess });
  // Context owns both tool registrations and the managed worker's asynchronous teardown.
  ctx.effect(() => registerWechatSearch(ctx, manager));
}
