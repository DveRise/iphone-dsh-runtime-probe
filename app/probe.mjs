import { Worker } from 'node:worker_threads';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const [stateArgument, installArgument] = process.argv.slice(2);
if (!stateArgument || !installArgument) throw new Error('Explicit probe state and dsh installation paths required');
const state = resolve(stateArgument), installRoot = resolve(installArgument);
const manifest = JSON.parse(await readFile(join(installRoot, 'node_modules/@deepseek-ai/dsh/package.json'), 'utf8'));
if (manifest.version !== '0.2.1-rc.5') throw new Error('Unexpected dsh version');
await mkdir(join(state, 'workspace'), { recursive: true });
process.chdir(join(state, 'workspace'));
const env = {};
for (const [key, value] of Object.entries(process.env)) {
  if (['path', 'systemroot', 'windir', 'comspec', 'pathext', 'temp', 'tmp'].includes(key.toLowerCase())) env[key] = value;
}
env.DSH_HOME = join(state, 'dsh-home');
env.DSH_TELEMETRY_DISABLED = '1';
const report = { schema: 1, type: 'official-dsh-embedded-startup', dshVersion: manifest.version,
  nodeVersion: process.version, platform: process.platform, arch: process.arch,
  modelCalls: 0, passed: false, checks: [], deviceTested: false };
const redact = value => String(value).replace(/https?:\/\/[^\s"'<>]+/g, '[URL REDACTED]');
let diagnostics = '', settled = false;
const worker = new Worker(new URL('./dsh-worker.mjs', import.meta.url), {
  workerData: { installRoot }, env, stdout: true, stderr: true,
  execArgv: ['--expose-internals', '--no-addons'],
});
worker.stdout.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-16000); });
worker.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-16000); });
const exited = new Promise(resolveExit => worker.once('exit', code => {
  report.workerExitCode = code;
  resolveExit();
}));
let timeout;
await new Promise(resolveDone => {
  const finish = async () => {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    await worker.terminate();
    resolveDone();
  };
  timeout = setTimeout(() => { report.error = 'Startup or cleanup deadline exceeded'; void finish(); }, 60000);
  worker.once('error', error => { report.error = redact(error.message); void finish(); });
  worker.once('exit', () => {
    if (!settled) { report.error = 'Worker exited before completing checks'; void finish(); }
  });
  worker.on('message', async message => {
    if (settled) return;
    if (message.type === 'ready') {
      try {
        const origin = new URL(message.origin);
        const launch = new URL(message.launch);
        if (origin.hostname !== '127.0.0.1' || launch.origin !== origin.origin) throw new Error('Unexpected listener or launch origin');
        report.checks.push({ name: 'Official profile boots in worker', ok: true });
        const denied = await fetch(origin, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
        await denied.arrayBuffer();
        report.checks.push({ name: 'Unauthenticated access denied', ok: denied.status === 401, status: denied.status });
        const exchange = await fetch(launch, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
        const cookie = exchange.headers.get('set-cookie')?.split(';')[0];
        const location = exchange.headers.get('location');
        await exchange.arrayBuffer();
        const target = new URL(location ?? '/', origin);
        if (![302, 303].includes(exchange.status) || !cookie || target.origin !== origin.origin) throw new Error(`Authentication exchange rejected (HTTP ${exchange.status})`);
        report.checks.push({ name: 'Launch-token cookie exchange', ok: true, status: exchange.status });
        const response = await fetch(target, { headers: { cookie }, redirect: 'manual', signal: AbortSignal.timeout(5000) });
        const html = await response.text();
        report.checks.push({ name: 'Authenticated official frontend', ok: response.status === 200 && /<!doctype html|<html/i.test(html), status: response.status });
        worker.postMessage({ type: 'stop' });
      } catch (error) { report.error = redact(error.message); await finish(); }
    } else if (message.type === 'disposed') {
      report.checks.push({ name: 'Official context disposed without exiting host', ok: true });
      report.passed = report.checks.length === 5 && report.checks.every(check => check.ok);
      await finish();
    } else if (message.type.endsWith('error')) {
      report.error = redact(message.message);
      if (message.failures) report.failures = JSON.parse(redact(JSON.stringify(message.failures)));
      await finish();
    }
  });
});
await exited;
report.diagnostics = redact(diagnostics);
await writeFile(join(state, 'runtime-report.json'), JSON.stringify(report, null, 2), { mode: 0o600 });
console.log(JSON.stringify({ passed: report.passed, checks: report.checks, error: report.error, failures: report.failures }));
console.log(`Official Harness startup probe finished: ${report.passed ? 'PASS' : 'FAIL'}`);
// Return naturally: this entry is also intended for a future NodeMobile host.
process.exitCode = report.passed ? 0 : 1;
