import {
  type Accessor,
  type Dispose,
  createRoot,
  effect,
  onCleanup,
  signal,
} from "./signals.ts";

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

function setProp(node: HTMLElement, key: string, value: unknown): void {
  if (key === "class" || key === "className") {
    node.className = value == null ? "" : String(value);
  } else if (key === "style") {
    if (typeof value === "string") {
      node.setAttribute("style", value);
    } else if (value && typeof value === "object") {
      Object.assign(node.style, value);
    }
  } else if (key === "value" && "value" in node) {
    const next = value == null ? "" : String(value);
    if ((node as HTMLInputElement).value !== next) {
      (node as HTMLInputElement).value = next;
    }
  } else if (key === "disabled" || key === "checked" || key === "hidden") {
    (node as unknown as Record<string, unknown>)[key] = Boolean(value);
  } else if (value === false || value === null || value === undefined) {
    node.removeAttribute(key);
  } else {
    node.setAttribute(key, value === true ? "" : String(value));
  }
}

function appendChild(parent: Node, child: Child): void {
  if (child === null || child === undefined || typeof child === "boolean") {
    return;
  }
  if (Array.isArray(child)) {
    for (const c of child) {
      appendChild(parent, c);
    }
    return;
  }
  if (typeof child === "function") {
    const start = document.createComment("c:dyn");
    const end = document.createComment("/c:dyn");
    parent.appendChild(start);
    parent.appendChild(end);

    let currentNodes: Node[] = [];
    let currentDispose: Dispose | null = null;

    effect(() => {
      const value = (child as Accessor<Child>)();

      if (
        (typeof value === "string" || typeof value === "number") &&
        currentNodes.length === 1 &&
        currentNodes[0].nodeType === Node.TEXT_NODE
      ) {
        currentNodes[0].textContent = String(value);
        return;
      }

      currentDispose?.();
      currentDispose = null;

      const frag = document.createDocumentFragment();
      createRoot((dispose) => {
        currentDispose = dispose;
        appendChild(frag, value);
      });
      const nextNodes = Array.from(frag.childNodes);

      const container = end.parentNode;
      if (container) {
        for (const old of currentNodes) {
          container.removeChild(old);
        }
        container.insertBefore(frag, end);
      }
      currentNodes = nextNodes;
    });

    onCleanup(() => {
      currentDispose?.();
      currentDispose = null;
    });
    return;
  }
  if (child instanceof Node) {
    parent.appendChild(child);
  } else {
    parent.appendChild(document.createTextNode(String(child)));
  }
}

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props?: ElementProps | null,
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);

  if (props) {
    for (const [key, raw] of Object.entries(props)) {
      if (key === "ref" && typeof raw === "function") {
        (raw as (el: HTMLElement) => void)(node);
      } else if (key.startsWith("on") && typeof raw === "function") {
        const eventName = key.slice(2).toLowerCase();
        node.addEventListener(eventName, raw as EventListener);
        onCleanup(() => node.removeEventListener(eventName, raw as EventListener));
      } else if (typeof raw === "function") {
        effect(() => {
          setProp(node, key, (raw as Accessor<unknown>)());
        });
      } else {
        setProp(node, key, raw);
      }
    }
  }

  for (const child of children) {
    appendChild(node, child);
  }

  return node;
}

export function show<T>(
  when: Accessor<T | null | undefined | false>,
  renderThen: (value: T) => Child,
  renderElse?: () => Child,
): Child {
  return () => {
    const val = when();
    if (val) {
      return renderThen(val);
    }
    return renderElse ? renderElse() : null;
  };
}

export function each<T, K>(
  items: Accessor<readonly T[]>,
  keyFn: (item: T) => K,
  renderItem: (item: Accessor<T>) => Node,
): Node {
  const frag = document.createDocumentFragment();
  const start = document.createComment("c:each");
  const end = document.createComment("/c:each");
  frag.appendChild(start);
  frag.appendChild(end);

  interface Entry {
    node: Node;
    dispose: Dispose;
    updateItem: (next: T) => void;
  }

  const entries = new Map<K, Entry>();

  effect(() => {
    const nextList = items();
    const container = end.parentNode;
    if (!container) return;

    const nextKeys = new Set<K>();
    const orderedNodes: Node[] = [];

    for (const item of nextList) {
      const k = keyFn(item);
      nextKeys.add(k);
      let entry = entries.get(k);
      if (!entry) {
        const rowSignal = signal<T>(item);
        let rowDispose: Dispose = () => {};
        const node = createRoot((dispose) => {
          rowDispose = dispose;
          return renderItem(() => rowSignal());
        });
        entry = {
          node,
          dispose: rowDispose,
          updateItem: (next) => rowSignal.set(next),
        };
        entries.set(k, entry);
      } else {
        entry.updateItem(item);
      }
      orderedNodes.push(entry.node);
    }

    for (const [k, entry] of entries) {
      if (!nextKeys.has(k)) {
        entry.dispose();
        if (entry.node.parentNode === container) {
          container.removeChild(entry.node);
        }
        entries.delete(k);
      }
    }

    let cursor: Node = end;
    for (let i = orderedNodes.length - 1; i >= 0; i -= 1) {
      const node = orderedNodes[i];
      if (node.nextSibling !== cursor) {
        container.insertBefore(node, cursor);
      }
      cursor = node;
    }
  });

  onCleanup(() => {
    for (const entry of entries.values()) {
      entry.dispose();
    }
    entries.clear();
  });

  return frag;
}

export function mount(container: Element, renderRoot: () => Child): Dispose {
  container.innerHTML = "";
  let rootDispose: Dispose = () => {};
  createRoot((dispose) => {
    rootDispose = dispose;
    appendChild(container, renderRoot());
  });
  return () => {
    rootDispose();
    container.innerHTML = "";
  };
}
