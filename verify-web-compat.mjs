import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile, writeFile } from 'node:fs/promises';
const source = await readFile(new URL('./app/web-compat.js',import.meta.url),'utf8');
const descriptor = Object.getOwnPropertyDescriptor(AbortSignal,'any');
const checks = [];
try {
  const original = AbortSignal.any;
  vm.runInThisContext(source);
  assert.equal(AbortSignal.any,original);
  checks.push('Preserve existing native implementation');
  delete AbortSignal.any;
  vm.runInThisContext(source);
  const shim = AbortSignal.any;
  vm.runInThisContext(source); assert.equal(AbortSignal.any,shim);
  assert.equal(AbortSignal.any([]).aborted,false);
  checks.push('Install once on a runtime missing the API; empty iterable remains active');
  const first = new AbortController(), second = new AbortController();
  const combined = AbortSignal.any([first.signal,second.signal,first.signal]);
  let events = 0; combined.addEventListener('abort',()=>events++);
  second.abort(0); first.abort('later');
  assert.equal(combined.aborted,true); assert.equal(combined.reason,0); assert.equal(events,1);
  checks.push('First cancellation wins, preserves falsy reason, handles duplicate signals');
  const a = new AbortController(), b = new AbortController(); a.abort('first-in-list');b.abort('second-in-list');
  assert.equal(AbortSignal.any(new Set([a.signal,b.signal])).reason,'first-in-list');
  assert.throws(()=>AbortSignal.any([a.signal,{}]),TypeError);
  for (const value of [undefined,null,7,{length:0}]) assert.throws(()=>AbortSignal.any(value),TypeError);
  assert.throws(()=>AbortSignal.any([Object.create(AbortSignal.prototype)]),TypeError);
  checks.push('Already-aborted ordering and native signal brand/input validation');
  const c = new AbortController();
  const nested = AbortSignal.any([AbortSignal.any([c.signal])]); c.abort(null);
  assert.equal(nested.aborted,true); assert.equal(nested.reason,null);
  checks.push('Nested combined signals propagate cancellation');
  // Match the failing directory-picker request: combine a view token with a caller token.
  const view = new AbortController(), caller = new AbortController();
  const request = new Promise((resolve,reject)=> {
    const signal=AbortSignal.any([view.signal,caller.signal]);
    signal.addEventListener('abort',()=>reject(signal.reason),{once:true});
  });
  const expected = new Error('caller cancelled'); caller.abort(expected);
  await assert.rejects(request,error=>error===expected);
  checks.push('Directory-picker-shaped asynchronous request cancellation');
} finally { Object.defineProperty(AbortSignal,'any',descriptor); }

// Exercise the shipped Models settings controller with the API missing.
const bundle = await readFile(new URL(
  './dsh-runtime/node_modules/@deepseek-ai/dsh-client-ui-settings-models/lib/client.js',
  import.meta.url,
), 'utf8');
const exportMarker = 'exports.refreshIfLoaded = refreshIfLoaded;';
assert.ok(bundle.includes(exportMarker));
let models;
const context = vm.createContext({
  window: { __ModuleLoader__: { load({ factory }) {
    models = factory(id => id === '@deepseek-ai/dsh-client-store' ? {
      createSnapshotStore(snapshot) {
        return { update: fn => fn(snapshot), getSnapshot: () => snapshot };
      },
    } : {});
  } } },
  AbortSignal, AbortController, EventTarget,
});
vm.runInContext(bundle.replace(exportMarker, exportMarker + ' exports.ModelsSettingsStore = ModelsSettingsStore;'), context);
const ok = value => ({ ok: true, value });
const store = new models.ModelsSettingsStore({
  remote: {
    llm: {
      listProviders: async () => ok([{ id: 'deepseek-official', name: 'DeepSeek' }]),
      listConfigurableProviders: async () => ok([{
        provider: 'deepseek-official', displayName: 'DeepSeek',
        settingsNs: 'deepseek', settingsPath: [],
      }]),
    },
    credentials: { describe: async () => ok({}) },
  },
}, { getPath: value => value }, {
  ensure: async () => {},
  getSnapshot: () => ({ view: {
    writable: true, namespaces: [{ ns: 'deepseek', value: { apiKeyEnv: 'DEEPSEEK_API_KEY' } }],
  } }),
});
vm.runInContext('delete Promise.withResolvers', context);
assert.throws(() => store.load(), /withResolvers/);
vm.runInContext(source, context);
await store.load();
const snapshot = store.store.getSnapshot();
assert.equal(snapshot.status, 'ready');
assert.equal(snapshot.writable, true);
assert.equal(snapshot.rows[0].entry.provider, 'deepseek-official');
assert.equal(snapshot.rows[0].apiKeyEnv, 'DEEPSEEK_API_KEY');
checks.push('Shipped Models settings fails without Promise.withResolvers and loads a writable provider with the shim');

const nativePromiseMethod = Promise.withResolvers;
vm.runInThisContext(source);
assert.equal(Promise.withResolvers, nativePromiseMethod);
const promiseContract = await vm.runInContext(`(async () => {
  class DerivedPromise extends Promise {}
  const resolved = DerivedPromise.withResolvers();
  resolved.resolve('ok');
  const rejected = Promise.withResolvers();
  rejected.reject('error');
  return resolved.promise instanceof DerivedPromise && await resolved.promise === 'ok'
    && await rejected.promise.catch(reason => reason) === 'error';
})()`, context);
assert.equal(promiseContract, true);
checks.push('Preserve native Promise.withResolvers and support resolution, rejection, and Promise subclasses');

await writeFile(new URL('./web-compat-verification.json',import.meta.url),JSON.stringify({passed:true,nodeVersion:process.version,checks,actualIOSWebViewTested:false},null,2));
console.log(JSON.stringify({passed:true,checks}));
