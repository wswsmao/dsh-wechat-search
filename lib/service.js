import { createToolDefinitions } from './tools.js';

/** Same-Host API. No browser RPC exposure; public tools share the exact same manager. */
export function createWechatSearchService(manager) {
  return Object.freeze({
    start: (input, options) => manager.start(input, options),
    status: (id) => manager.status(id),
    cancel: (id) => manager.cancel(id),
    resume: (id) => manager.resume(id),
    wait: (id, options) => manager.wait(id, options),
    getResult: (id) => manager.getResult(id),
    // Absolute path of a running job's checkpoint. The collector rewrites it as it opens articles,
    // so a consumer can stream results instead of waiting for the whole pass to finish.
    checkpointPath: (id) => manager.checkpointPath(id),
  });
}

export function registerWechatSearch(ctx, manager) {
  const releaseService = ctx.provide('wechatSearch', createWechatSearchService(manager));
  const disposers = createToolDefinitions(manager).map((tool) => ctx.tools.register(tool));
  return async () => {
    for (const dispose of disposers.reverse()) dispose();
    await releaseService();
    await manager.dispose();
  };
}
