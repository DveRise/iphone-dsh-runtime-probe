// Installed before page scripts, only when the WebKit implementation is absent.
(() => {
  if (typeof Promise.withResolvers === 'function') return;

  function withResolvers() {
    let resolve;
    let reject;
    const promise = new this((resolvePromise, rejectPromise) => {
      if (resolve !== undefined || reject !== undefined) {
        throw new TypeError('Promise executor has already run');
      }
      resolve = resolvePromise;
      reject = rejectPromise;
    });
    if (typeof resolve !== 'function' || typeof reject !== 'function') {
      throw new TypeError('Promise constructor did not supply resolvers');
    }
    return { promise, resolve, reject };
  }

  Object.defineProperty(Promise, 'withResolvers', {
    value: withResolvers,
    configurable: true,
    writable: true,
  });
})();

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

// Responsive overrides for the settings panel in the pinned Harness frontend.
if (typeof document !== 'undefined') {
  const installSettingsStyle = () => {
    const style = document.createElement('style');
    style.textContent = `
      @media (max-width: 600px) {
        .VOzbGW_panel {
          flex-direction: column;
          -webkit-text-size-adjust: 100%;
        }
        .VOzbGW_panel .VOzbGW_nav {
          box-sizing: border-box;
          width: 100%;
          padding: 12px 12px 8px;
          border-right: 0;
          border-bottom: 1px solid var(--dsw-alias-border-l2);
        }
        .VOzbGW_panel .VOzbGW_navTitle { margin: 0 48px 8px 0; }
        .VOzbGW_panel .VOzbGW_navList {
          display: grid;
          grid-template-columns: repeat(2, minmax(0, 1fr));
          gap: 4px;
          overflow: visible;
        }
        .VOzbGW_panel .VOzbGW_navCell {
          width: 100%;
          min-height: 44px;
          padding: 6px 8px;
        }
        .VOzbGW_panel .VOzbGW_content { min-width: 0; min-height: 0; width: 100%; }
        .VOzbGW_panel .VOzbGW_header { height: 0; min-height: 0; padding: 0; }
        .VOzbGW_panel .VOzbGW_actions { display: none; }
        .VOzbGW_panel .VOzbGW_close {
          position: absolute;
          top: 4px;
          right: 6px;
          width: 44px;
          height: 44px;
          z-index: 1;
        }
        .VOzbGW_panel .VOzbGW_options { padding: 12px 12px 20px; }
        .VOzbGW_panel .zGbnIq_rowCard,
        .VOzbGW_panel .zGbnIq_editor,
        .VOzbGW_panel .zGbnIq_setupCard { padding: 12px; min-width: 0; }
        .VOzbGW_panel .zGbnIq_rowCard > .zGbnIq_editor { padding: 8px 0 0; }
        .VOzbGW_panel .zGbnIq_editorHeader,
        .VOzbGW_panel .zGbnIq_rowHead { flex-wrap: wrap; }
        .VOzbGW_panel .zGbnIq_editorRoute { overflow-wrap: anywhere; }
        .VOzbGW_panel .zGbnIq_input {
          font-size: 16px;
          min-height: 44px;
        }
        .zGbnIq_keyInput { display: flex; flex-wrap: wrap; gap: 6px; min-width: 0; }
        .zGbnIq_keyInput .zGbnIq_input {
          min-height: 44px;
          font: 16px ui-monospace, Menlo, monospace;
          padding: 0 10px;
        }
        .zGbnIq_keyInput .zGbnIq_keyToggle,
        .zGbnIq_keyInput .iphone-key-clear {
          display: inline-flex;
          position: static;
          width: auto;
          min-height: 44px;
          align-items: center;
          padding: 0 10px;
          border: 1px solid var(--dsw-alias-border-l3);
          border-radius: 8px;
          background: transparent;
          color: var(--dsw-alias-label-secondary);
          font: inherit;
          white-space: nowrap;
        }
        .zGbnIq_keyInput .iphone-key-toggle-label { display: inline; }
        .zGbnIq_keyInput .zGbnIq_keyToggle svg { display: none; }
        .zGbnIq_keyInput .iphone-key-preview {
          display: block;
          box-sizing: border-box;
          width: 100%;
          padding: 8px;
          overflow-wrap: anywhere;
          white-space: pre-wrap;
          border-radius: 8px;
          background: var(--dsw-alias-bg-layer-1);
          color: var(--dsw-alias-label-primary);
          user-select: text;
          -webkit-user-select: text;
        }
        .VOzbGW_panel .zGbnIq_primaryButton,
        .VOzbGW_panel .zGbnIq_secondaryButton {
          min-height: 44px;
          white-space: nowrap;
        }
      }
    `;
    document.head.appendChild(style);
  };
  if (document.head) installSettingsStyle();
  else document.addEventListener('DOMContentLoaded', installSettingsStyle, { once: true });
}
