import { createSocket } from 'node:dgram';

// Keep the request and reply codes in sync with replaykit-probe/ProbeStatus.h.
const port = 46031;
const states = ['invalid_reply', 'waiting_for_frames', 'waiting_for_ocr',
  'ocr_error', 'no_match', 'matched', 'matched'];

async function readSettingsLabels(signal) {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const socket = createSocket('udp4');
    let finished = false;
    const finish = result => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal.removeEventListener('abort', abort);
      socket.close();
      if (signal.aborted) reject(signal.reason);
      else resolve(result);
    };
    const abort = () => finish();
    const timer = setTimeout(() => finish({ status: 'broadcast_unavailable' }), 700);
    signal.addEventListener('abort', abort, { once: true });
    socket.once('error', () => finish({ status: 'broadcast_unavailable' }));
    socket.once('message', reply => {
      const code = reply.length === 1 ? reply[0] : 0;
      const status = states[code] ?? 'invalid_reply';
      if (status !== 'matched') finish({ status });
      else finish({ status, labels: code === 5 ? ['通用', '关于本机'] : ['General', 'About'] });
    });
    socket.connect(port, '127.0.0.1', () => {
      if (!finished) socket.send('R', error => {
        if (error) finish({ status: 'broadcast_unavailable' });
      });
    });
  });
}

export function registerScreenTool(tools, defineTool) {
  return tools.register(defineTool({
    name: 'iphone_read_settings',
    description: 'Check the current iPhone screen-reading test. After the user starts the 录屏读屏测试 broadcast and visits 设置 → 通用, this read-only tool returns whether the test detected 通用 and 关于本机 (or General and About). A broadcast_unavailable result means the extension is not responding. Report that status instead of guessing. The tool only returns the test status and fixed menu labels.',
    parameters: {},
    output: {
      schema: { type: 'json' },
      render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }],
    },
    execute: (_args, { signal }) => readSettingsLabels(signal),
    presentCall: () => ({ card: 'generic', kind: 'read', title: '读取 iPhone 设置测试结果' }),
  }));
}
