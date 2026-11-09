// The upstream CLI's process.exit paths must never own the UIKit process.
import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { mkdtemp, open, unlink, rmdir } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const requirePackage = createRequire(join(workerData.installRoot, 'package.json'));
const load = name => import(pathToFileURL(requirePackage.resolve(name)).href);

async function prepareNativeLock() {
  let nextId = 0;
  const pending = new Map();
  parentPort.on('message', message => {
    if (message.type !== 'flock-result') return;
    const resolve = pending.get(message.id);
    if (!resolve) return;
    pending.delete(message.id);
    resolve(message.errno);
  });
  Object.defineProperty(globalThis, Symbol.for('iphone-harness.flock'), {
    value: fd => new Promise(resolve => {
      const id = ++nextId;
      pending.set(id, resolve);
      parentPort.postMessage({ type: 'flock', id, fd });
    }),
  });

  // Verify the actual device can lock, reject a competing descriptor, and release on close.
  const { tryLockExclusive } = await load('@deepseek-ai/node-addon-system/flock');
  const dir = await mkdtemp(join(workerData.state, '.flock-check-'));
  const file = join(dir, 'session.lock');
  let first, second;
  try {
    first = await open(file, 'wx', 0o600);
    second = await open(file, 'r+');
    await tryLockExclusive(first.fd);
    let contended = false;
    try { await tryLockExclusive(second.fd); }
    catch (error) {
      if (error?.code !== 'EAGAIN' && error?.code !== 'EWOULDBLOCK') throw error;
      contended = true;
    }
    if (!contended) throw new Error('Native lock did not reject contention');
    await first.close();
    first = undefined;
    await tryLockExclusive(second.fd);
  } finally {
    await first?.close();
    await second?.close();
    await unlink(file).catch(error => { if (error.code !== 'ENOENT') throw error; });
    await rmdir(dir);
  }
}

async function start() {
  if (workerData.nativeFlock) {
    try {
      await prepareNativeLock();
    } catch {
      parentPort.postMessage({ type: 'flock-error' });
      parentPort.close();
      return;
    }
  }
  try {
    const { runProfile } = await load('@deepseek-ai/dsh/profile-boot');
    const { loadLayeredEnv } = await load('@deepseek-ai/dsh-app-boot');
    const runtime = await runProfile({
      environment: loadLayeredEnv('dsh'), profile: 'web', patchFiles: [],
      args: ['--host', '127.0.0.1', '--port', '0', '--no-open'],
    });
    const server = runtime.ctx.get('webServer');
    const connection = runtime.ctx.get('connection');
    if (!server || !connection) throw new Error('Official Web services were not mounted');
    const origin = server.getOrigin();
    if (new URL(origin).hostname !== '127.0.0.1') throw new Error('Non-loopback listener refused');
    // This private URL travels only in memory, never in the exported report.
    parentPort.postMessage({ type: 'ready', origin, launch: connection.authenticatedUrl(origin) });
    const stop = async message => {
      if (message.type !== 'stop') return;
      parentPort.off('message', stop);
      try {
        await runtime.ctx.fiber.dispose();
        parentPort.postMessage({ type: 'disposed' });
      } catch (error) {
        parentPort.postMessage({ type: 'cleanup-error', message: String(error.message) });
      }
    };
    parentPort.on('message', stop);
  } catch {
    parentPort.postMessage({ type: 'startup-error' });
  }
}
await start();
