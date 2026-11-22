/**
 * Zero-dependency fine-grained reactive signal primitives for Concave.
 * Native browser ESM — zero npm, zero transpiler, zero bundler.
 */

let currentObserver = null;
let batchDepth = 0;
const pendingComputations = new Set();
const noopExecute = () => {};

function cleanupComputation(comp) {
  for (const dep of comp.dependencies) {
    dep.delete(comp);
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

function scheduleComputation(comp) {
  if (comp.disposed) return;
  if (batchDepth > 0) {
    pendingComputations.add(comp);
  } else {
    comp.execute();
  }
}

export function batch(fn) {
  batchDepth += 1;
  try {
    return fn();
  } finally {
    batchDepth -= 1;
    if (batchDepth === 0 && pendingComputations.size > 0) {
      const queue = Array.from(pendingComputations);
      pendingComputations.clear();
      for (const comp of queue) {
        if (!comp.disposed) {
          comp.execute();
        }
      }
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
    dependencies: new Set(),
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
  let value = initial;
  const subscribers = new Set();

  const read = () => {
    if (
      currentObserver &&
      !currentObserver.disposed &&
      currentObserver.execute !== noopExecute
    ) {
      subscribers.add(currentObserver);
      currentObserver.dependencies.add(subscribers);
    }
    return value;
  };

  read.peek = () => value;

  read.set = (next) => {
    if (equals(value, next)) return;
    value = next;
    const toRun = Array.from(subscribers);
    batch(() => {
      for (const comp of toRun) {
        scheduleComputation(comp);
      }
    });
  };

  read.update = (fn) => {
    read.set(fn(value));
  };

  return read;
}

export function effect(fn) {
  const comp = {
    dependencies: new Set(),
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
    pendingComputations.delete(comp);
    cleanupComputation(comp);
  };

  if (currentObserver) {
    onCleanup(dispose);
  }

  return dispose;
}

export function computed(fn, equals = Object.is) {
  const out = signal(undefined, equals);
  const dispose = effect(() => {
    out.set(fn());
  });
  if (currentObserver) {
    onCleanup(dispose);
  }
  return () => out();
}
