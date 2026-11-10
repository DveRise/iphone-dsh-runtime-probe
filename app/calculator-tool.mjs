export function registerCalculatorTool(tools, defineTool, port) {
  let nextId = 0;
  let pending;
  const receive = message => {
    if (message.type === 'calculator-result' && pending?.id === message.id) {
      pending.finish(message.status);
    }
  };
  const unregister = tools.register(defineTool({
    name: 'iphone_request_calculator',
    description: 'When the user explicitly asks to open Calculator, request the native iPhone confirmation for the fixed shortcut 助手测试计算器. Call once. The result awaiting_confirmation means the user can confirm on the phone. It does not mean Calculator has opened. Tell the user the actual request status.',
    parameters: {},
    output: {
      schema: { type: 'json' },
      render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }],
    },
    execute(_args, { signal }) {
      signal.throwIfAborted();
      if (pending) return Promise.resolve({ status: 'busy' });
      return new Promise((resolve, reject) => {
        const id = ++nextId;
        const finish = status => {
          clearTimeout(timer);
          signal.removeEventListener('abort', cancel);
          pending = undefined;
          if (signal.aborted) reject(signal.reason);
          else resolve({ status });
        };
        const cancel = () => {
          port.postMessage({ type: 'calculator-cancel', id });
          finish('unavailable');
        };
        const timer = setTimeout(cancel, 4000);
        pending = { id, finish };
        signal.addEventListener('abort', cancel, { once: true });
        port.postMessage({ type: 'calculator-request', id });
      });
    },
    presentCall: () => ({ card: 'generic', kind: 'execute', title: '请求打开计算器' }),
  }));
  port.on('message', receive);
  return () => {
    port.off('message', receive);
    if (pending) pending.finish('unavailable');
    unregister();
  };
}
