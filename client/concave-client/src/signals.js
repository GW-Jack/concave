/**
 * Zero-dependency glitch-free fine-grained reactive signal primitives for Concave.
 * Native browser ESM — zero npm, zero transpiler, zero bundler.
 *
 * Uses push-pull dirty propagation with dependency version checking so diamond
 * graphs (`src -> {left, right} -> sum -> effect`) never glitch and never
 * over-execute when a memoized `computed` produces an equal value.
 */

let currentObserver = null;
let batchDepth = 0;
const pendingEffects = new Set();
const noopExecute = () => {};

function cleanupComputation(comp) {
  for (const dep of comp.dependencies.keys()) {
    dep.subscribers.delete(comp);
  }
  comp.dependencies.clear();
  for (const fn of comp.cleanups) {
    try {
      fn();
    } catch (err) {
      console.error("[concave-signals] cleanup error:", err);
    }
  }
  comp.cleanups.length = 0;
}

function notifySubscribers(source) {
  const subs = Array.from(source.subscribers);
  for (const sub of subs) {
    if (sub.disposed) continue;
    if (sub.isComputed) {
      sub.markDirty();
    } else {
      pendingEffects.add(sub);
    }
  }
}

function flushEffects() {
  if (batchDepth > 0) return;
  while (pendingEffects.size > 0) {
    const queue = Array.from(pendingEffects);
    pendingEffects.clear();
    for (const eff of queue) {
      if (eff.disposed) continue;
      // Pull any dirty computed dependencies first; skip if no dependency version actually changed.
      let changed = eff.dependencies.size === 0;
      for (const [dep, seenVersion] of eff.dependencies) {
        if (dep.refresh) dep.refresh();
        if (dep.version !== seenVersion) {
          changed = true;
          break;
        }
      }
      if (changed) {
        eff.execute();
      }
    }
  }
}

export function batch(fn) {
  batchDepth += 1;
  try {
    return fn();
  } finally {
    batchDepth -= 1;
    if (batchDepth === 0) {
      flushEffects();
    }
  }
}

export function untrack(fn) {
  const prev = currentObserver;
  currentObserver = null;
  try {
    return fn();
  } finally {
    currentObserver = prev;
  }
}

export function onCleanup(fn) {
  if (currentObserver) {
    currentObserver.cleanups.push(fn);
  }
}

export function createRoot(fn) {
  const scope = {
    isComputed: false,
    dependencies: new Map(),
    cleanups: [],
    disposed: false,
    execute: noopExecute,
  };

  const dispose = () => {
    if (scope.disposed) return;
    scope.disposed = true;
    cleanupComputation(scope);
  };

  const prev = currentObserver;
  currentObserver = scope;
  try {
    return fn(dispose);
  } finally {
    currentObserver = prev;
  }
}

export function signal(initial, equals = Object.is) {
  const node = {
    value: initial,
    version: 0,
    subscribers: new Set(),
    refresh: null,
  };

  const read = () => {
    if (
      currentObserver &&
      !currentObserver.disposed &&
      currentObserver.execute !== noopExecute
    ) {
      node.subscribers.add(currentObserver);
      currentObserver.dependencies.set(node, node.version);
    }
    return node.value;
  };

  read.peek = () => node.value;

  read.set = (next) => {
    if (equals(node.value, next)) return;
    node.value = next;
    node.version += 1;
    batch(() => {
      notifySubscribers(node);
    });
  };

  read.update = (fn) => {
    read.set(fn(node.value));
  };

  return read;
}

export function effect(fn) {
  const comp = {
    isComputed: false,
    dependencies: new Map(),
    cleanups: [],
    disposed: false,
    execute() {
      if (comp.disposed) return;
      cleanupComputation(comp);
      const prev = currentObserver;
      currentObserver = comp;
      try {
        const ret = fn();
        if (typeof ret === "function") {
          comp.cleanups.push(ret);
        }
      } finally {
        currentObserver = prev;
      }
    },
  };

  comp.execute();

  const dispose = () => {
    if (comp.disposed) return;
    comp.disposed = true;
    pendingEffects.delete(comp);
    cleanupComputation(comp);
  };

  if (currentObserver) {
    onCleanup(dispose);
  }

  return dispose;
}

export function computed(fn, equals = Object.is) {
  const node = {
    isComputed: true,
    value: undefined,
    initialized: false,
    dirty: true,
    version: 0,
    subscribers: new Set(),
    dependencies: new Map(),
    cleanups: [],
    disposed: false,
    execute: null,
    markDirty() {
      if (node.dirty) return;
      node.dirty = true;
      notifySubscribers(node);
    },
    refresh() {
      if (!node.dirty) return;
      if (node.initialized) {
        let depChanged = false;
        for (const [dep, seenVersion] of node.dependencies) {
          if (dep.refresh) dep.refresh();
          if (dep.version !== seenVersion) {
            depChanged = true;
            break;
          }
        }
        if (!depChanged) {
          node.dirty = false;
          return;
        }
      }

      cleanupComputation(node);
      const prev = currentObserver;
      currentObserver = node;
      let next;
      try {
        next = fn();
      } finally {
        currentObserver = prev;
      }

      node.dirty = false;
      if (!node.initialized || !equals(node.value, next)) {
        node.initialized = true;
        node.value = next;
        node.version += 1;
      }
    },
  };
  node.execute = node.refresh;

  const dispose = () => {
    if (node.disposed) return;
    node.disposed = true;
    cleanupComputation(node);
    node.subscribers.clear();
  };
  if (currentObserver) {
    onCleanup(dispose);
  }

  return () => {
    node.refresh();
    if (
      currentObserver &&
      !currentObserver.disposed &&
      currentObserver.execute !== noopExecute
    ) {
      node.subscribers.add(currentObserver);
      currentObserver.dependencies.set(node, node.version);
    }
    return node.value;
  };
}
