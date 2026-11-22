/**
 * Zero-dependency fine-grained reactive signal primitives for Concave.
 * Transpiled to browser ESM on the fly by Concave's Rust server via `oxc` (zero npm).
 */

export type Accessor<T> = () => T;
export type Dispose = () => void;

export interface Signal<T> extends Accessor<T> {
  set(next: T): void;
  update(fn: (prev: T) => T): void;
  peek(): T;
}

interface Computation {
  execute(): void;
  dependencies: Set<Set<Computation>>;
  cleanups: Array<() => void>;
  disposed: boolean;
}

let currentObserver: Computation | null = null;
let batchDepth = 0;
const pendingComputations = new Set<Computation>();
const noopExecute = () => {};

function cleanupComputation(comp: Computation): void {
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

function scheduleComputation(comp: Computation): void {
  if (comp.disposed) return;
  if (batchDepth > 0) {
    pendingComputations.add(comp);
  } else {
    comp.execute();
  }
}

export function batch<T>(fn: () => T): T {
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

export function untrack<T>(fn: () => T): T {
  const prev = currentObserver;
  currentObserver = null;
  try {
    return fn();
  } finally {
    currentObserver = prev;
  }
}

export function onCleanup(fn: () => void): void {
  if (currentObserver) {
    currentObserver.cleanups.push(fn);
  }
}

export function createRoot<T>(fn: (dispose: Dispose) => T): T {
  const scope: Computation = {
    dependencies: new Set(),
    cleanups: [],
    disposed: false,
    execute: noopExecute,
  };

  const dispose: Dispose = () => {
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

export function signal<T>(
  initial: T,
  equals: (a: T, b: T) => boolean = Object.is,
): Signal<T> {
  let value = initial;
  const subscribers = new Set<Computation>();

  const read = (() => {
    if (
      currentObserver &&
      !currentObserver.disposed &&
      currentObserver.execute !== noopExecute
    ) {
      subscribers.add(currentObserver);
      currentObserver.dependencies.add(subscribers);
    }
    return value;
  }) as Signal<T>;

  read.peek = () => value;

  read.set = (next: T) => {
    if (equals(value, next)) return;
    value = next;
    const toRun = Array.from(subscribers);
    batch(() => {
      for (const comp of toRun) {
        scheduleComputation(comp);
      }
    });
  };

  read.update = (fn: (prev: T) => T) => {
    read.set(fn(value));
  };

  return read;
}

export function effect(fn: () => void | (() => void)): Dispose {
  const comp: Computation = {
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

  const dispose: Dispose = () => {
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

export function computed<T>(
  fn: () => T,
  equals: (a: T, b: T) => boolean = Object.is,
): Accessor<T> {
  const out = signal<T>(undefined as unknown as T, equals);
  const dispose = effect(() => {
    out.set(fn());
  });
  if (currentObserver) {
    onCleanup(dispose);
  }
  return () => out();
}
