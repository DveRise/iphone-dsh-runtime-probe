import { mkdir, readFile, writeFile, unlink } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';

const output = process.argv[2];
if (!output) throw new Error('An explicit writable output directory is required');
await mkdir(output, { recursive: true });
const checks = [];
async function check(name, operation) {
  try {
    const details = await operation();
    checks.push({ name, ok: true, details });
    console.log(`PASS ${name}`);
  } catch (error) {
    checks.push({ name, ok: false, error: String(error.message ?? error) });
    console.log(`FAIL ${name}: ${String(error.message ?? error)}`);
  }
}

await check('Node >=24.9', async () => {
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 24 || (major === 24 && minor < 9)) throw new Error('runtime is too old');
  return { version: process.version, mobile: process.versions.mobile ?? null,
    platform: process.platform, arch: process.arch };
});
await check('ESM entry and import.meta.main', async () => {
  if (import.meta.main !== true) throw new Error('ESM entry detection unavailable');
  return { main: true };
});
await check('Chinese Intl support', async () => {
  const supported = Intl.Collator.supportedLocalesOf(['zh-CN']);
  if (supported.length !== 1) throw new Error('Chinese locale is unavailable');
  return { locale: new Intl.Collator('zh-CN').resolvedOptions().locale };
});
await check('Read/write in the test app data directory', async () => {
  const file = join(output, 'filesystem-probe.txt');
  try {
    await writeFile(file, 'iPhone Harness 环境测试', { flag: 'wx' });
    const value = await readFile(file, 'utf8');
    if (value !== 'iPhone Harness 环境测试') throw new Error('file contents differ');
  } finally {
    await unlink(file).catch(() => {});
  }
  return { roundtrip: true };
});
await check('Loopback HTTP server and fetch', async () => {
  const server = createServer((req, res) => { res.end('runtime-loopback-ok'); });
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const response = await fetch(`http://127.0.0.1:${server.address().port}/`, {
      signal: AbortSignal.timeout(10000), redirect: 'error',
    });
    if (response.status !== 200 || await response.text() !== 'runtime-loopback-ok') {
      throw new Error('loopback request failed');
    }
    return { status: 200 };
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
await check('Public HTTPS metadata request, no model credentials', async () => {
  const response = await fetch('https://registry.npmjs.org/@deepseek-ai/dsh/0.2.1-rc.5', {
    signal: AbortSignal.timeout(15000), redirect: 'error',
  });
  if (!response.ok) throw new Error(`HTTPS response ${response.status}`);
  const value = await response.json();
  if (value.name !== '@deepseek-ai/dsh' || value.version !== '0.2.1-rc.5') {
    throw new Error('unexpected metadata');
  }
  return { status: response.status, package: value.name, version: value.version };
});

const report = { schema: 1, type: 'runtime-probe', timestamp: new Date().toISOString(),
  passed: checks.every(check => check.ok), checks,
  notTested: ['DeepSeek Harness startup', 'model inference', 'native addons',
    'child processes', 'background operation', 'screen capture and touch injection'] };
await writeFile(join(output, 'runtime-report.json'), JSON.stringify(report, null, 2));
console.log(`Runtime probe finished: ${report.passed ? 'PASS' : 'FAIL'}`);
// Return naturally to node_start; never call process.exit() in the UIKit process.
