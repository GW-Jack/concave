import { batch, computed, signal } from "./signals.js";
import { el } from "./dom.js";

const FORBIDDEN = new Set(["__proto__", "constructor", "prototype"]);
const safeDecode = (s) => { try { return decodeURIComponent(s); } catch { return s; } };
const isSafeRelPath = (to) =>
  typeof to === "string" && to.startsWith("/") && !to.startsWith("//") && !to.startsWith("/\\") && !/[\u0000-\u001f\u007f]/.test(to);

function parseLocation(raw) {
  const noHash = String(raw || "/").split("#", 1)[0];
  const qIdx = noHash.indexOf("?");
  const pathname = (qIdx === -1 ? noHash : noHash.slice(0, qIdx)) || "/";
  const query = Object.create(null);
  if (qIdx !== -1) {
    for (const [k, v] of new URLSearchParams(noHash.slice(qIdx + 1))) {
      if (!FORBIDDEN.has(k)) query[k] = v;
    }
  }
  return { pathname, query };
}

export function matchRoute(pattern, pathname) {
  const patSegs = String(pattern || "/").split("/").filter(Boolean);
  const pathSegs = (String(pathname || "/").split(/[?#]/, 1)[0] || "/").split("/").filter(Boolean);
  const params = Object.create(null);
  for (let i = 0; i < patSegs.length; i += 1) {
    const pat = patSegs[i];
    if (pat === "*") {
      params["*"] = pathSegs.slice(i).map(safeDecode).join("/");
      return params;
    }
    if (i >= pathSegs.length) return null;
    if (pat.startsWith(":")) {
      const name = pat.slice(1);
      if (name && !FORBIDDEN.has(name)) params[name] = safeDecode(pathSegs[i]);
    } else if (pat !== pathSegs[i]) {
      return null;
    }
  }
  return pathSegs.length === patSegs.length ? params : null;
}

export function createRouter(routes, options = {}) {
  const win = globalThis.window;
  const initRaw = options.initialPath ?? (win?.location ? `${win.location.pathname || "/"}${win.location.search || ""}` : "/");
  const init = parseLocation(initRaw);
  const path = signal(init.pathname);
  const query = signal(init.query);

  const current = computed(() => {
    const p = path();
    const q = query();
    for (const route of routes) {
      const params = matchRoute(route.path, p);
      if (params) return { route, params, path: p, query: q };
    }
    return { route: null, params: Object.create(null), path: p, query: q };
  });

  const applyLoc = (raw) => {
    const next = parseLocation(raw);
    batch(() => { path.set(next.pathname); query.set(next.query); });
  };

  function navigate(to, { replace = false } = {}) {
    if (!isSafeRelPath(to)) throw new Error("Router path must be a relative same-origin path starting with '/'");
    globalThis.window?.history?.[replace ? "replaceState" : "pushState"]?.(null, "", to);
    applyLoc(to);
  }

  function link(to, props, ...children) {
    const isProps = props !== null && typeof props === "object" &&
      !(typeof Node !== "undefined" && props instanceof Node) && !Array.isArray(props);
    const attrs = isProps ? { ...props } : {};
    const kids = isProps ? children : props === undefined ? children : [props, ...children];
    const userClick = attrs.onClick;
    attrs.href = to;
    attrs.onClick = (e) => {
      userClick?.(e);
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      if ((attrs.target && attrs.target !== "_self") || !isSafeRelPath(to)) return;
      e.preventDefault();
      navigate(to);
    };
    return el("a", attrs, ...kids);
  }

  const onPopState = () => {
    const loc = globalThis.window?.location;
    if (loc) applyLoc(`${loc.pathname || "/"}${loc.search || ""}`);
  };
  win?.addEventListener?.("popstate", onPopState);
  const dispose = () => { win?.removeEventListener?.("popstate", onPopState); };

  return { path, query, current, navigate, link, dispose };
}
