import { fileURLToPath } from 'node:url';
import { WechatTaskManager } from './lib/task-manager.js';
import { createToolDefinitions } from './lib/tools.js';

export const inject = ['tools', 'subprocess'];

export function apply(ctx) {
  const packageDir = fileURLToPath(new URL('.', import.meta.url));
  const manager = new WechatTaskManager({ packageDir, subprocess: ctx.subprocess });
  // Context owns both tool registrations and the managed worker's asynchronous teardown.
  ctx.effect(() => {
    const disposers = createToolDefinitions(manager).map((tool) => ctx.tools.register(tool));
    return async () => {
      for (const dispose of disposers.reverse()) dispose();
      await manager.dispose();
    };
  });
}
