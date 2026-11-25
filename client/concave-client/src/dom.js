import { createRoot, effect, onCleanup, signal } from "./signals.js";

const URL_ATTRS = new Set([
  "href",
  "src",
  "action",
  "formaction",
  "data",
  "xlink:href",
  "poster",
]);

const FORBIDDEN_KEYS = new Set(["__proto__", "constructor", "prototype"]);

function isSafeUrl(raw) {
  const trimmed = String(raw).replace(/[\u0000-\u0020\u007f-\u009f]+/g, "");
  if (!trimmed) return true;
  if (trimmed.startsWith("//")) return false;
  if (
    trimmed.startsWith("/") ||
    trimmed.startsWith("./") ||
    trimmed.startsWith("../") ||
    trimmed.startsWith("#") ||
    trimmed.startsWith("?")
  ) {
    return true;
  }
  const colon = trimmed.indexOf(":");
  if (colon === -1) return true;
  let end = trimmed.length;
  for (const ch of ["/", "?", "#"]) {
    const idx = trimmed.indexOf(ch);
    if (idx !== -1 && idx < end) end = idx;
  }
  if (colon > end) return true;
  const scheme = trimmed.slice(0, colon).toLowerCase();
  return (
    scheme === "https" ||
    scheme === "http" ||
    scheme === "mailto" ||
    scheme === "tel" ||
    scheme === "blob"
  );
}

function setProp(node, key, value) {
  if (FORBIDDEN_KEYS.has(key)) return;
  const lower = key.toLowerCase();
  // Never allow inline event handler attributes (on*) or iframe srcdoc via setAttribute.
  if ((lower.length > 2 && lower.startsWith("on")) || lower === "srcdoc") {
    return;
  }
  if (key === "class" || key === "className") {
    node.className = value == null ? "" : String(value);
  } else if (key === "style") {
    if (typeof value === "string") {
      node.setAttribute("style", value);
    } else if (value && typeof value === "object") {
      for (const [sk, sv] of Object.entries(value)) {
        if (FORBIDDEN_KEYS.has(sk) || sk.toLowerCase() === "csstext") continue;
        if (sk.startsWith("--")) {
          node.style.setProperty?.(sk, sv == null ? "" : String(sv));
        } else {
          node.style[sk] = sv == null ? "" : String(sv);
        }
      }
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
  } else if (URL_ATTRS.has(lower)) {
    const urlStr = value === true ? "" : String(value);
    if (!isSafeUrl(urlStr)) {
      node.removeAttribute(key);
      return;
    }
    node.setAttribute(key, urlStr);
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

function bindProp(node, key, raw) {
  if (typeof raw === "function") effect(() => setProp(node, key, raw()));
  else setProp(node, key, raw);
}

export function el(tag, props, ...children) {
  const node = document.createElement(tag);
  let refFn, val;

  if (props) {
    for (const [k, raw] of Object.entries(props)) {
      if (FORBIDDEN_KEYS.has(k)) continue;
      if (k === "ref" && typeof raw === "function") refFn = raw;
      else if (k === "value") val = [raw];
      else if (k.length > 2 && k.slice(0, 2).toLowerCase() === "on") {
        if (typeof raw === "function") {
          const ev = k.slice(2).toLowerCase();
          node.addEventListener(ev, raw);
          onCleanup(() => node.removeEventListener(ev, raw));
        }
      } else bindProp(node, k, raw);
    }
  }

  for (const child of children) appendChild(node, child);
  if (val) bindProp(node, "value", val[0]);
  refFn?.(node);
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

export const bindValue = (sig, onInput) => ({
  value: () => sig(),
  onInput: (e) => {
    const v = e.target.value;
    sig.set(v);
    onInput?.(v, e);
  },
});

export const bindChecked = (sig, onChange) => ({
  checked: () => Boolean(sig()),
  onChange: (e) => {
    const v = Boolean(e.target.checked);
    sig.set(v);
    onChange?.(v, e);
  },
});

export const tags = new Proxy(Object.create(null), {
  get: (_, tag) =>
    typeof tag === "string"
      ? (first, ...rest) =>
          first !== null && typeof first === "object" && !(first instanceof Node) && !Array.isArray(first)
            ? el(tag, first, ...rest)
            : el(tag, null, first, ...rest)
      : undefined,
});

export function mount(container, renderRoot) {
  container.textContent = "";
  let rootDispose = () => {};
  createRoot((dispose) => {
    rootDispose = dispose;
    appendChild(container, renderRoot());
  });
  return () => {
    rootDispose();
    container.textContent = "";
  };
}
