import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { mkdtemp } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { registerScreenTool } from './app/screen-tool.mjs';

const requirePackage = createRequire(new URL('./dsh-runtime/package.json', import.meta.url));
const load = name => import(pathToFileURL(requirePackage.resolve(name)));
process.env.DSH_HOME = await mkdtemp(join(tmpdir(), 'dsh-screen-tool-test-'));
process.env.DSH_TELEMETRY_DISABLED = '1';
process.chdir(process.env.DSH_HOME);

const { runProfile } = await load('@deepseek-ai/dsh/profile-boot');
const { loadLayeredEnv } = await load('@deepseek-ai/dsh-app-boot');
const { defineTool } = await load('@deepseek-ai/dsh-tools');
const writeStdout = process.stdout.write;
let runtime;
try {
  // The upstream web startup prints its temporary login URL.
  process.stdout.write = () => true;
  runtime = await runProfile({
    environment: loadLayeredEnv('dsh'), profile: 'web', patchFiles: [],
    args: ['--host', '127.0.0.1', '--port', '0', '--no-open'],
  });
} finally {
  process.stdout.write = writeStdout;
}
let mock;
try {
  const tools = runtime.ctx.get('tools');
  const name = 'iphone_read_settings';
  assert.ok(tools, 'web profile provides the official tool registry');
  const unregister = registerScreenTool(tools, defineTool);
  assert.equal(tools.get(name)?.name, name);
  let id = 0;
  const run = (args = {}) => tools.execute({
    callId: `screen-test-${++id}`, name, arguments: args, signal: AbortSignal.timeout(3000),
  });

  const absent = await run();
  assert.deepEqual(absent.value, { status: 'broadcast_unavailable' });
  mock = createSocket('udp4');
  let reply = [5];
  mock.on('message', (request, peer) => {
    assert.equal(request.toString(), 'R');
    assert.equal(peer.address, '127.0.0.1');
    mock.send(Buffer.from(reply), peer.port, peer.address);
  });
  mock.bind(46031, '127.0.0.1');
  await once(mock, 'listening');
  assert.deepEqual((await run()).value, { status: 'matched', labels: ['通用', '关于本机'] });
  reply = [4];
  assert.deepEqual((await run()).value, { status: 'no_match' });
  reply = [5, 6];
  assert.deepEqual((await run()).value, { status: 'invalid_reply' });
  unregister();
  assert.equal(tools.get(name), undefined);
  console.log('PASS official registry discovery, loopback query, absent broadcast, OCR match, no match, and malformed reply. Model requests: 0.');
} finally {
  mock?.close();
  await runtime.ctx.fiber.dispose();
}
