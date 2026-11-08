import { Worker } from 'node:worker_threads';
import { connect } from 'node:net';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';

const [stateArg, installArg, portArg, nonce] = process.argv.slice(2);
const port = Number(portArg);
if (!stateArg || !installArg || !Number.isInteger(port) || port < 1 || port > 65535 || !/^[a-zA-Z0-9-]{32,64}$/.test(nonce ?? '')) throw new Error('Invalid native host arguments');
const state = resolve(stateArg), installRoot = resolve(installArg);
const manifest = JSON.parse(await readFile(join(installRoot, 'node_modules/@deepseek-ai/dsh/package.json'), 'utf8'));
if (manifest.version !== '0.2.1-rc.5') throw new Error('Unexpected Harness version');
await mkdir(join(state, 'workspace'), { recursive: true });
process.chdir(join(state, 'workspace'));
const env = { DSH_HOME: join(state, 'dsh-home'), DSH_TELEMETRY_DISABLED: '1' };
for (const [key, value] of Object.entries(process.env)) {
  if (['path', 'systemroot', 'windir', 'comspec', 'pathext', 'temp', 'tmp'].includes(key.toLowerCase())) env[key] = value;
}

// Launch URLs and cookies exist only in the bridge's memory. Never log them.
const bridge = connect({ host: '127.0.0.1', port });
const report = { schema: 1, type: 'interactive-harness', dshVersion: manifest.version,
  status: 'starting', nativeAddonsEnabled: false, backgroundOperationVerified: false,
  crossAppControlAvailable: false, checks: [] };
const send = message => { if (!bridge.destroyed) bridge.write(JSON.stringify({ ...message, nonce }) + '\n'); };
const save = () => writeFile(join(state, 'runtime-report.json'), JSON.stringify(report, null, 2), { mode: 0o600 });
let worker, closing = false, ready = false, buffer = '', timer;
let resolveDone;
const done = new Promise(resolve => { resolveDone = resolve; });
const finish = async (reason, clean = false) => {
  if (closing) return;
  closing = true;
  clearTimeout(timer);
  report.status = clean ? 'stopped' : 'failed';
  report.reason = reason;
  report.cleanedUp = clean;
  try {
    if (worker) await worker.terminate();
    await save();
    send({ type: clean ? 'stopped' : 'error', code: reason });
    console.log(clean ? 'Harness stopped.' : `Harness unavailable: ${reason}`);
  } catch { console.log('Harness cleanup or status write failed.'); }
  finally { bridge.end(); resolveDone(); }
};
const requestStop = () => {
  if (closing || report.status === 'stopping') return;
  report.status = 'stopping';
  clearTimeout(timer);
  timer = setTimeout(() => { void finish('cleanup-timeout'); }, 10000);
  if (worker && ready) worker.postMessage({ type: 'stop' });
  else void finish('stopped-before-ready');
};
bridge.setNoDelay(true);
bridge.once('error', () => { void finish('native-bridge-error'); });
bridge.once('close', () => { if (!closing) requestStop(); });
bridge.on('data', chunk => {
  if (closing) return;
  buffer += chunk.toString('utf8');
  if (Buffer.byteLength(buffer) > 8192) { void finish('invalid-native-message'); return; }
  while (buffer.includes('\n')) {
    const cut = buffer.indexOf('\n'), line = buffer.slice(0, cut);
    buffer = buffer.slice(cut + 1);
    try {
      const message = JSON.parse(line);
      if (message.nonce !== nonce || message.type !== 'stop') throw new Error();
      requestStop();
    } catch { void finish('invalid-native-message'); }
  }
});
bridge.once('connect', () => {
  send({ type: 'starting' });
  worker = new Worker(new URL('./dsh-worker.mjs', import.meta.url), {
    workerData: { installRoot }, env, stdout: true, stderr: true,
    execArgv: ['--expose-internals', '--no-addons'],
  });
  // Raw upstream errors may contain settings. Do not forward them to export logs.
  worker.stdout.resume(); worker.stderr.resume();
  worker.once('error', () => { void finish('worker-error'); });
  worker.once('exit', () => { if (!closing) void finish('worker-exited'); });
  timer = setTimeout(() => { void finish('startup-timeout'); }, 90000);
  worker.on('message', async message => {
    if (closing) return;
    if (message.type === 'ready') {
      try {
        const origin = new URL(message.origin), launch = new URL(message.launch);
        if (origin.protocol !== 'http:' || origin.hostname !== '127.0.0.1' || !origin.port || launch.origin !== origin.origin || launch.username || launch.password) throw new Error();
        const denied = await fetch(origin, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
        await denied.arrayBuffer();
        if (denied.status !== 401) throw new Error();
        if (closing || report.status === 'stopping') return;
        report.checks.push({ name: 'Unauthenticated access denied', ok: true, status: 401 });
        clearTimeout(timer);
        ready = true;
        report.status = 'ready';
        await save();
        send({ type: 'ready', url: launch.href });
        console.log('Harness ready. Keep the app in the foreground.');
      } catch { await finish('listener-check-failed'); }
    } else if (message.type === 'disposed') {
      report.checks.push({ name: 'Official context disposed', ok: true });
      await finish('user-stopped', true);
    } else if (message.type.endsWith('error')) {
      await finish(message.type === 'startup-error' ? 'profile-startup-failed' : 'cleanup-failed');
    }
  });
});
await done;
process.exitCode = report.cleanedUp ? 0 : 1;
