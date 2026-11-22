export type Accessor<T> = () => T;
export type Dispose = () => void;

export interface Signal<T> extends Accessor<T> {
  set(next: T): void;
  update(fn: (prev: T) => T): void;
  peek(): T;
}

export function batch<T>(fn: () => T): T;
export function untrack<T>(fn: () => T): T;
export function onCleanup(fn: () => void): void;
export function createRoot<T>(fn: (dispose: Dispose) => T): T;
export function signal<T>(
  initial: T,
  equals?: (a: T, b: T) => boolean,
): Signal<T>;
export function effect(fn: () => void | (() => void)): Dispose;
export function computed<T>(
  fn: () => T,
  equals?: (a: T, b: T) => boolean,
): Accessor<T>;
