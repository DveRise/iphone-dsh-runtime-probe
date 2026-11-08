// Installed before page scripts, only when the WebKit implementation is absent.
(() => {
  const Signal = globalThis.AbortSignal;
  if (!Signal || typeof Signal.any === 'function') return;
  const aborted = Object.getOwnPropertyDescriptor(Signal.prototype, 'aborted').get;
  const reason = Object.getOwnPropertyDescriptor(Signal.prototype, 'reason')?.get;
  const add = EventTarget.prototype.addEventListener;
  const remove = EventTarget.prototype.removeEventListener;
  function any(input) {
    if (input == null || typeof input[Symbol.iterator] !== 'function') throw new TypeError('AbortSignal.any requires an iterable');
    const signals = Array.from(input);
    // Validate every input before returning an already-aborted result.
    for (const signal of signals) aborted.call(signal);
    const controller = new AbortController();
    for (const signal of signals) {
      if (aborted.call(signal)) {
        controller.abort(reason ? reason.call(signal) : undefined);
        return controller.signal;
      }
    }
    const listeners = new Map();
    const cleanup = () => {
      for (const [signal, handler] of listeners) remove.call(signal, 'abort', handler);
      listeners.clear();
    };
    for (const signal of signals) {
      if (listeners.has(signal)) continue;
      const handler = () => {
        if (controller.signal.aborted) return;
        cleanup();
        controller.abort(reason ? reason.call(signal) : undefined);
      };
      listeners.set(signal, handler);
      add.call(signal, 'abort', handler, { once: true });
    }
    return controller.signal;
  }
  Object.defineProperty(Signal, 'any', { value: any, configurable: true, writable: true });
})();
