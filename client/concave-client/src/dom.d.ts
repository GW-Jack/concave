import type { Accessor, Dispose } from "./signals.js";

export interface ChildArray extends Array<Child> {}

export type Child =
  | Node
  | string
  | number
  | boolean
  | null
  | undefined
  | (() => Child)
  | ChildArray;

export type PropValue<V = unknown> = V | Accessor<V>;

export interface ElementProps {
  class?: PropValue<string>;
  className?: PropValue<string>;
  id?: PropValue<string>;
  style?: PropValue<string | Partial<CSSStyleDeclaration>>;
  value?: PropValue<string>;
  placeholder?: PropValue<string>;
  disabled?: PropValue<boolean>;
  type?: PropValue<string>;
  href?: PropValue<string>;
  target?: PropValue<string>;
  title?: PropValue<string>;
  ref?: (el: HTMLElement) => void;
  [key: string]: unknown;
}

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props?: ElementProps | null,
  ...children: Child[]
): HTMLElementTagNameMap[K];

export function show<T>(
  when: Accessor<T | null | undefined | false>,
  renderThen: (value: T) => Child,
  renderElse?: () => Child,
): Child;

export function each<T, K>(
  items: Accessor<readonly T[]>,
  keyFn: (item: T) => K,
  renderItem: (item: Accessor<T>) => Node,
): Node;

export function mount(container: Element, renderRoot: () => Child): Dispose;
