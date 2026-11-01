(() => {
  const environment = __environment;
  delete globalThis.__environment;
  const filters = {};
  const listeners = {command: [], directory: [], status: []};
  const keys = new Map();
  const items = new Map();
  const host = __host;
  const identifier = __identifier;
  delete globalThis.__host;
  delete globalThis.__identifier;
  let activePane = null;
  function emit(action) { host(JSON.stringify(action)); }
  function pane(id) {
    return Object.freeze({
      id,
      write(text) { emit({kind: 'write', pane: id, text: String(text)}); },
      close() { emit({kind: 'close', pane: id}); },
      split(direction) {
        if (!['horizontal', 'vertical'].includes(direction)) {
          throw new TypeError('Split direction must be horizontal or vertical');
        }
        const child = identifier();
        emit({kind: 'split', pane: id, id: child, direction});
        return pane(child);
      }
    });
  }
  function color(value) {
    if (value == null || typeof value === 'string') return value;
    if (typeof value !== 'object') throw new TypeError('Invalid status color');
    const {red, green, blue, alpha = 1} = value;
    if (![red, green, blue, alpha].every(x => Number.isFinite(x) && x >= 0 && x <= 1)) {
      throw new TypeError('Color channels must be in 0...1');
    }
    return {red, green, blue, alpha};
  }
  function refresh(id) {
    const item = items.get(id);
    if (!item) return;
    const output = item.render();
    const result = typeof output === 'string' ? {text: output} : output;
    if (!result || typeof result.text !== 'string') throw new TypeError('Status render must return text');
    emit({kind: 'status', status: {
      id, align: item.align, text: result.text,
      color: color(result.color), backgroundColor: color(result.backgroundColor)
    }});
  }
  function callback(value) {
    if (typeof value !== 'function') throw new TypeError('Expected a function');
    return value;
  }
  function shortcut(value) {
    return String(value).toLowerCase().split('+').map(x => x.trim()).sort().join('+');
  }
  globalThis.swiftty = {
    get currentPane() {
      if (!activePane) throw new Error('No active terminal pane');
      return pane(activePane);
    },
    ui: {
      setBadge(text) { emit({kind: 'badge', text: String(text)}); },
      setTabIcon(text) { emit({kind: 'tabIcon', pane: activePane, text: String(text)}); },
      notify(title, text) { emit({kind: 'notification', title: String(title), text: String(text)}); },
      registerStatusItem(id, options) {
        id = String(id);
        if (!id || !options || !['left', 'right'].includes(options.align)) {
          throw new TypeError('Status item requires an id and left/right alignment');
        }
        const interval = options.refreshInterval;
        if (interval !== undefined && (!Number.isFinite(interval) || interval <= 0)) {
          throw new TypeError('Refresh interval must be positive and finite');
        }
        items.set(id, {align: options.align, render: callback(options.render),
          interval: interval === undefined ? 0 : interval * 1000,
          next: Date.now() + (interval || 0) * 1000});
        refresh(id);
      },
      refreshStatusItem(id) { refresh(String(id)); }
    },
    env(key, fallback = '') {
      return Object.prototype.hasOwnProperty.call(environment, key)
        ? environment[key] : String(fallback ?? '');
    },
    filter: {
      onStdout(fn) { filters.stdout = callback(fn); },
      onStdin(fn) { filters.stdin = callback(fn); }
    },
    events: {
      onStatusChanged(fn) { listeners.status.push(callback(fn)); },
      onCommandFinished(fn) { listeners.command.push(callback(fn)); },
      onDirectoryChanged(fn) { listeners.directory.push(callback(fn)); },
      bindKey(key, fn) {
        const normalized = shortcut(key);
        keys.set(normalized, callback(fn));
        emit({kind: 'keybinding', text: normalized});
      }
    }
  };
  function inPane(id, fn) {
    const previous = activePane;
    if (id != null) activePane = id;
    try { return fn(); } finally { activePane = previous; }
  }
  globalThis.__filter = (stream, text, id) => inPane(id, () => {
    const result = filters[stream]?.(text);
    if (result == null) return text;
    if (typeof result !== 'string') throw new TypeError('Filter must return a string');
    return result;
  });
  globalThis.__emit = (event, args, id) => inPane(id, () => {
    for (const fn of [...listeners[event]]) {
      try { fn(...args); } catch (error) { emit({kind: 'error', text: String(error)}); }
    }
  });
  globalThis.__status = (json, id) => globalThis.__emit("status", [JSON.parse(json)], id);
  globalThis.__key = (key, id) => inPane(id, () => {
    const fn = keys.get(shortcut(key));
    if (!fn) return false;
    try { fn(); } catch (error) { emit({kind: 'error', text: String(error)}); }
    return true;
  });
  globalThis.__activePane = id => { activePane = id; };
  globalThis.__tick = now => {
    for (const [id, item] of items) {
      if (item.interval && now >= item.next) {
        item.next = now + item.interval;
        try { refresh(id); } catch (error) { emit({kind: 'error', text: String(error)}); }
      }
    }
  };
})();
