import type { Accessor, Dispose, Signal } from "./signals.js";
import type { Child, ElementProps } from "./dom.js";

export type RouteParams = Record<string, string>;
export type RouteQuery = Record<string, string>;

export interface RouteMatch<R extends RouteDefinition = RouteDefinition> {
  readonly route: R | null;
  readonly params: RouteParams;
  readonly path: string;
  readonly query: RouteQuery;
}

export interface RouteDefinition {
  readonly path: string;
  readonly name?: string;
  readonly render?: (match: RouteMatch<RouteDefinition>) => Child;
}

export interface RouterOptions {
  initialPath?: string;
}

export interface NavigateOptions {
  replace?: boolean;
}

export interface Router<R extends RouteDefinition = RouteDefinition> {
  readonly path: Signal<string>;
  readonly query: Signal<RouteQuery>;
  readonly current: Accessor<RouteMatch<R>>;
  navigate(to: string, options?: NavigateOptions): void;
  link(to: string, props?: ElementProps | null, ...children: Child[]): HTMLAnchorElement;
  link(to: string, ...children: Child[]): HTMLAnchorElement;
  dispose: Dispose;
}

export function matchRoute(
  pattern: string,
  pathname: string,
): RouteParams | null;

export function createRouter<R extends RouteDefinition = RouteDefinition>(
  routes: readonly R[],
  options?: RouterOptions,
): Router<R>;
