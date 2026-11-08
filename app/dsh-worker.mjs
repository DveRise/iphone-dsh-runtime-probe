// The upstream CLI's process.exit paths must never own the UIKit process.
import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const requirePackage = createRequire(join(workerData.installRoot, 'package.json'));
const load = name => import(pathToFileURL(requirePackage.resolve(name)).href);
let runtime;
try {
  const { runProfile } = await load('@deepseek-ai/dsh/profile-boot');
  const { loadLayeredEnv } = await load('@deepseek-ai/dsh-app-boot');
  runtime = await runProfile({
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
  parentPort.once('message', async message => {
    if (message.type !== 'stop') return;
    try {
      await runtime.ctx.fiber.dispose();
      parentPort.postMessage({ type: 'disposed' });
    } catch (error) {
      parentPort.postMessage({ type: 'cleanup-error', message: String(error.message) });
    }
  });
} catch (error) {
  // No model credentials are supplied to this startup-only probe.
  const failures = error.entries?.map(entry => ({
    id: entry.id, module: entry.module, kind: entry.outcome?.kind,
    missing: entry.outcome?.missing, error: String(entry.outcome?.error ?? ''),
  }));
  parentPort.postMessage({ type: 'startup-error', message: String(error.message), failures });
}
