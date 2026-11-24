import type { Accessor, Dispose, Signal } from "./signals.js";

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

export interface ValueBindingProps {
  value: Accessor<string>;
  onInput: (e: Event) => void;
}

export interface CheckedBindingProps {
  checked: Accessor<boolean>;
  onChange: (e: Event) => void;
}

export function bindValue(
  sig: Signal<string>,
  onInput?: (value: string, e: Event) => void,
): ValueBindingProps;

export function bindChecked(
  sig: Signal<boolean>,
  onChange?: (checked: boolean, e: Event) => void,
): CheckedBindingProps;

export type TagHelper<K extends keyof HTMLElementTagNameMap> = {
  (props?: ElementProps | null, ...children: Child[]): HTMLElementTagNameMap[K];
  (...children: Child[]): HTMLElementTagNameMap[K];
};

export type Tags = {
  readonly [K in keyof HTMLElementTagNameMap]: TagHelper<K>;
};

export const tags: Tags;

export function mount(container: Element, renderRoot: () => Child): Dispose;
