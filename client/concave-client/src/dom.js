import { createRoot, effect, onCleanup, signal } from "./signals.js";

function setProp(node, key, value) {
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
    if (node.value !== next) {
      node.value = next;
    }
  } else if (key === "disabled" || key === "checked" || key === "hidden") {
    node[key] = Boolean(value);
  } else if (value === false || value === null || value === undefined) {
    node.removeAttribute(key);
  } else {
    node.setAttribute(key, value === true ? "" : String(value));
  }
}

function appendChild(parent, child) {
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

    let currentNodes = [];
    let currentDispose = null;

    effect(() => {
      const value = child();

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

export function el(tag, props, ...children) {
  const node = document.createElement(tag);

  if (props) {
    for (const [key, raw] of Object.entries(props)) {
      if (key === "ref" && typeof raw === "function") {
        raw(node);
      } else if (key.startsWith("on") && typeof raw === "function") {
        const eventName = key.slice(2).toLowerCase();
        node.addEventListener(eventName, raw);
        onCleanup(() => node.removeEventListener(eventName, raw));
      } else if (typeof raw === "function") {
        effect(() => {
          setProp(node, key, raw());
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

export function show(when, renderThen, renderElse) {
  return () => {
    const val = when();
    if (val) {
      return renderThen(val);
    }
    return renderElse ? renderElse() : null;
  };
}

export function each(items, keyFn, renderItem) {
  const frag = document.createDocumentFragment();
  const start = document.createComment("c:each");
  const end = document.createComment("/c:each");
  frag.appendChild(start);
  frag.appendChild(end);

  const entries = new Map();

  effect(() => {
    const nextList = items();
    const container = end.parentNode;
    if (!container) return;

    const nextKeys = new Set();
    const orderedNodes = [];

    for (const item of nextList) {
      const k = keyFn(item);
      nextKeys.add(k);
      let entry = entries.get(k);
      if (!entry) {
        const rowSignal = signal(item);
        let rowDispose = () => {};
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

    let cursor = end;
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

export function mount(container, renderRoot) {
  container.innerHTML = "";
  let rootDispose = () => {};
  createRoot((dispose) => {
    rootDispose = dispose;
    appendChild(container, renderRoot());
  });
  return () => {
    rootDispose();
    container.innerHTML = "";
  };
}
