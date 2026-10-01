// Lyric UI host runtime: DOM rendering of the semantic widget set
// (docs/65 §7.1). Implements `TreeObserver`, so every mirror change made by
// tree.ts is reflected in the DOM.
//
// Each element node's `host` is a `HostEl`: `root` is the DOM node placed in
// its parent's container, `container` is where its children's DOM goes (null
// for widgets without children). Non-child chrome (a field's <label>, a
// card's title) lives outside `container`, so child indices map directly to
// container child positions.

import type { MNode, TreeObserver } from "./tree.js";

export interface HostEl {
  root: Node;
  container: HTMLElement | null;
  // Text inputs: the latest local edit number, sent as `iv` with input
  // events. A server `value` carrying an older `iv` is a stale echo.
  localVersion: number;
  // Data grids: the last viewport reported, so scrolling within it does
  // not report it again. Cleared when the grid's rows change.
  lastViewport?: string;
  viewportPending?: boolean;
}

export type EventSink = (node: MNode, event: string, data: string, inputVersion: number) => void;

let nextId = 1;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  e.className = cls;
  return e;
}

export function hostOf(n: MNode): HostEl {
  return n.host as HostEl;
}

export class DomRenderer implements TreeObserver {
  constructor(private readonly mount: HTMLElement, private readonly sink: EventSink) {}

  created(node: MNode): void {
    if (node.kind === "text") {
      node.host = { root: document.createTextNode(node.text), container: null, localVersion: 0 };
      return;
    }
    if (node.kind === "empty") {
      node.host = { root: document.createComment("empty"), container: null, localVersion: 0 };
      return;
    }
    const h = this.createElement(node);
    node.host = h;
    for (const [k, v] of Object.entries(node.props)) {
      this.applyProp(node, k, v);
    }
    if (h.container) {
      for (const c of node.children) {
        h.container.appendChild(hostOf(c).root);
      }
    }
    this.afterChildrenChanged(node);
  }

  inserted(parent: MNode, index: number, node: MNode): void {
    const c = hostOf(parent).container;
    if (!c) {
      return;
    }
    c.insertBefore(hostOf(node).root, c.childNodes[index] ?? null);
    this.afterChildrenChanged(parent);
  }

  removed(parent: MNode, _index: number, node: MNode): void {
    const r = hostOf(node).root;
    r.parentNode?.removeChild(r);
    this.afterChildrenChanged(parent);
  }

  replaced(old: MNode, node: MNode): void {
    const r = hostOf(old).root;
    if (r.parentNode) {
      r.parentNode.replaceChild(hostOf(node).root, r);
    } else {
      this.mount.replaceChildren(hostOf(node).root);
    }
    if (node.parent) {
      this.afterChildrenChanged(node.parent);
    }
  }

  propSet(node: MNode, name: string, value: string, inputVersion: number | undefined): void {
    if (name === "value" && inputVersion !== undefined && inputVersion < hostOf(node).localVersion) {
      return;
    }
    this.applyProp(node, name, value);
  }

  propRemoved(node: MNode, name: string): void {
    this.applyProp(node, name, null);
  }

  textSet(node: MNode, value: string): void {
    (hostOf(node).root as Text).data = value;
  }

  // ─── Element construction ───────────────────────────────────────────────────
  private createElement(node: MNode): HostEl {
    const w = node.widget;
    const plain = (root: HTMLElement, container: HTMLElement | null = root): HostEl => ({ root, container, localVersion: 0 });
    switch (w) {
      case "column":
        return plain(el("div", "lui-column"));
      case "row":
        return plain(el("div", "lui-row"));
      case "card":
      case "section": {
        const root = el("section", `lui-${w}`);
        const title = el(w === "card" ? "h2" : "h3", `lui-${w}-title`);
        const body = el("div", `lui-${w}-body`);
        root.append(title, body);
        return plain(root, body);
      }
      case "spacer":
        return plain(el("div", "lui-spacer"), null);
      case "heading": {
        const level = Math.min(3, Math.max(1, Number(node.props.level ?? "1")));
        return plain(el(`h${level}` as "h1", "lui-heading"));
      }
      case "paragraph":
        return plain(el("p", "lui-paragraph"));
      case "label":
        return plain(el("span", "lui-label"));
      case "badge":
        return plain(el("span", "lui-badge"));
      case "banner": {
        const root = el("div", "lui-banner");
        root.setAttribute("role", "status");
        return plain(root);
      }
      case "spinner": {
        const root = el("div", "lui-spinner");
        root.setAttribute("role", "status");
        return plain(root, null);
      }
      case "fieldError": {
        const root = el("div", "lui-field-error");
        root.id = `lui-${nextId++}`;
        return plain(root);
      }
      case "field": {
        const root = el("div", "lui-field");
        const label = el("label", "lui-field-label");
        const body = el("div", "lui-field-body");
        root.append(label, body);
        return plain(root, body);
      }
      case "textInput":
      case "numberInput":
      case "dateInput":
        return this.input(node, el("input", "lui-input"));
      case "textArea":
        return this.input(node, el("textarea", "lui-input lui-textarea"));
      case "checkbox": {
        const root = el("label", "lui-checkbox");
        const box = el("input", "");
        box.type = "checkbox";
        box.id = `lui-${nextId++}`;
        const text = el("span", "");
        root.append(box, text);
        box.addEventListener("change", () => this.fire(node, "change", box.checked ? "true" : "false", 0));
        return plain(root, null);
      }
      case "select": {
        const root = el("select", "lui-select");
        root.id = `lui-${nextId++}`;
        root.addEventListener("change", () => this.fire(node, "change", root.value, 0));
        return plain(root);
      }
      case "option":
        return plain(el("option", ""));
      case "button": {
        const root = el("button", "lui-button");
        root.type = "button";
        root.addEventListener("click", (ev) => {
          ev.preventDefault();
          this.fire(node, "click", "", 0);
        });
        return plain(root, null);
      }
      case "link":
        return plain(el("a", "lui-link"));
      case "table":
        return plain(el("table", "lui-table"));
      case "tableRow": {
        const root = el("tr", "lui-table-row");
        root.addEventListener("click", () => this.fire(node, "click", "", 0));
        root.addEventListener("keydown", (ev) => {
          if (ev.key === "Enter") {
            this.fire(node, "click", "", 0);
          }
        });
        return plain(root);
      }
      case "tableCell":
        return plain(el(node.props.header === "true" ? "th" : "td", "lui-table-cell"));
      case "dataGrid":
        return this.dataGrid(node);
      case "gridRow": {
        const root = el("div", "lui-grid-row");
        root.setAttribute("role", "row");
        root.tabIndex = -1;
        root.addEventListener("click", () => this.fire(node, "click", "", 0));
        root.addEventListener("keydown", (ev) => {
          if (ev.target !== root) {
            return;
          }
          if (ev.key === "Enter" || ev.key === " ") {
            ev.preventDefault();
            this.fire(node, "click", "", 0);
          } else if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
            ev.preventDefault();
            const next = ev.key === "ArrowDown" ? root.nextElementSibling : root.previousElementSibling;
            if (next instanceof HTMLElement) {
              next.focus();
            }
          }
        });
        return plain(root);
      }
      case "gridCell": {
        const root = el("div", "lui-grid-cell");
        root.setAttribute("role", "gridcell");
        return plain(root);
      }
      case "form": {
        const root = el("form", "lui-form");
        root.noValidate = true;
        root.addEventListener("submit", (ev) => {
          ev.preventDefault();
          this.fire(node, "submit", "", 0);
        });
        return plain(root);
      }
      case "dialog": {
        const backdrop = el("div", "lui-dialog-backdrop");
        const dialog = el("div", "lui-dialog");
        dialog.setAttribute("role", "dialog");
        dialog.setAttribute("aria-modal", "true");
        backdrop.append(dialog);
        return plain(backdrop, dialog);
      }
      default: {
        const root = el("div", "lui-unknown");
        root.textContent = `Unsupported widget: ${w}`;
        return plain(root, null);
      }
    }
  }

  // A data grid: a header row, then a scrolling body whose padding stands in
  // for the rows not rendered, so the scrollbar spans every row. Rows are
  // the children, placed in `rows`; `layoutGrid` keeps the rest in step
  // with the props. Ui.Html renders the same structure for the first paint.
  private dataGrid(node: MNode): HostEl {
    const root = el("div", "lui-grid");
    root.setAttribute("role", "grid");
    const header = el("div", "lui-grid-header");
    header.setAttribute("role", "rowgroup");
    const headerRow = el("div", "lui-grid-row");
    headerRow.setAttribute("role", "row");
    headerRow.setAttribute("aria-rowindex", "1");
    header.append(headerRow);
    const body = el("div", "lui-grid-body");
    body.tabIndex = 0;
    const rows = el("div", "lui-grid-rows");
    rows.setAttribute("role", "rowgroup");
    body.append(rows);
    root.append(header, body);
    body.addEventListener("scroll", () => this.scheduleViewport(node));
    body.addEventListener("keydown", (ev) => {
      if (ev.target === body && ev.key === "ArrowDown") {
        const first = rows.firstElementChild;
        if (first instanceof HTMLElement) {
          ev.preventDefault();
          first.focus();
        }
      }
    });
    return { root, container: rows, localVersion: 0 };
  }

  // Checks the grid's viewport on the next frame: after a scroll, and after
  // its rows change, since the new rows may not cover what is in view (an
  // answer to a sort made while scrolled elsewhere).
  private scheduleViewport(node: MNode): void {
    const h = hostOf(node);
    if (h.viewportPending) {
      return;
    }
    h.viewportPending = true;
    requestAnimationFrame(() => {
      h.viewportPending = false;
      if ((h.root as HTMLElement).isConnected) {
        this.reportViewport(node);
      }
    });
  }

  // Reports the rows the grid's viewport shows when they are not all
  // rendered, so the session can fetch them.
  private reportViewport(node: MNode): void {
    const h = hostOf(node);
    const body = (h.root as HTMLElement).querySelector(".lui-grid-body") as HTMLElement;
    const rowHeight = gridNumber(node, "rowHeight", 36) || 36;
    const total = gridNumber(node, "rowCount", 0);
    const first = Math.floor(body.scrollTop / rowHeight);
    const count = Math.min(1000, Math.ceil(body.clientHeight / rowHeight) + 1);
    const end = Math.min(first + count, total);
    if (end <= first) {
      return;
    }
    const loaded = gridNumber(node, "firstRow", 0);
    if (first >= loaded && end <= loaded + node.children.length) {
      return;
    }
    const data = `${first},${count}`;
    if (h.lastViewport === data) {
      return;
    }
    h.lastViewport = data;
    this.fire(node, "viewport", data, 0);
  }

  // The header cells, from the `columns` property.
  private gridHeader(node: MNode): void {
    const root = hostOf(node).root as HTMLElement;
    const headerRow = root.querySelector(".lui-grid-header .lui-grid-row") as HTMLElement;
    let columns: { id?: unknown; title?: unknown; sort?: unknown }[] = [];
    try {
      const parsed: unknown = JSON.parse(node.props.columns ?? "[]");
      columns = Array.isArray(parsed) ? parsed : [];
    } catch {
      columns = [];
    }
    headerRow.replaceChildren(
      ...columns.map((c) => {
        const cell = el("div", "lui-grid-colheader");
        cell.setAttribute("role", "columnheader");
        const title = typeof c.title === "string" ? c.title : "";
        if (typeof c.sort === "string") {
          cell.setAttribute("aria-sort", c.sort);
          const button = el("button", "lui-grid-sort");
          button.type = "button";
          button.textContent = title;
          const id = typeof c.id === "string" ? c.id : "";
          button.addEventListener("click", () => this.fire(node, "sort", id, 0));
          cell.append(button);
        } else {
          cell.textContent = title;
        }
        return cell;
      }),
    );
    root.setAttribute("aria-colcount", String(columns.length));
    root.style.setProperty("--lui-grid-cols", String(columns.length));
  }

  // Sizes, padding and row numbers, from the props and the rendered rows.
  private layoutGrid(node: MNode): void {
    const root = hostOf(node).root as HTMLElement;
    const body = root.querySelector(".lui-grid-body") as HTMLElement;
    const rows = root.querySelector(".lui-grid-rows") as HTMLElement;
    const rowHeight = gridNumber(node, "rowHeight", 36) || 36;
    const total = gridNumber(node, "rowCount", 0);
    const first = gridNumber(node, "firstRow", 0);
    const after = Math.max(0, total - first - node.children.length);
    root.setAttribute("aria-rowcount", String(total + 1));
    root.style.setProperty("--lui-grid-row-height", `${rowHeight}px`);
    body.style.height = `${gridNumber(node, "visibleRows", 10) * rowHeight}px`;
    rows.style.paddingTop = `${first * rowHeight}px`;
    rows.style.paddingBottom = `${after * rowHeight}px`;
    node.children.forEach((c, i) => {
      if (c.widget === "gridRow" && c.host) {
        (hostOf(c).root as HTMLElement).setAttribute("aria-rowindex", String(first + i + 2));
      }
    });
  }

  private input(node: MNode, input: HTMLInputElement | HTMLTextAreaElement): HostEl {
    input.id = `lui-${nextId++}`;
    if (input instanceof HTMLInputElement) {
      // Number inputs hold draft text ("12a" is a legitimate state that
      // validation reports), so they are text inputs with a numeric keyboard.
      input.type = node.widget === "dateInput" ? "date" : "text";
      if (node.widget === "numberInput") {
        input.inputMode = "numeric";
      }
    }
    const h: HostEl = { root: input, container: null, localVersion: 0 };
    input.addEventListener("input", () => {
      h.localVersion += 1;
      this.fire(node, "input", input.value, h.localVersion);
    });
    return h;
  }

  private fire(node: MNode, event: string, data: string, inputVersion: number): void {
    if (node.events.includes(event)) {
      this.sink(node, event, data, inputVersion);
    }
  }

  // ─── Properties ─────────────────────────────────────────────────────────────
  private applyProp(node: MNode, name: string, value: string | null): void {
    const h = hostOf(node);
    const root = h.root as HTMLElement;
    const flag = value === "true";
    switch (name) {
      case "value":
        if (root instanceof HTMLInputElement || root instanceof HTMLTextAreaElement || root instanceof HTMLSelectElement) {
          if (root.value !== (value ?? "")) {
            root.value = value ?? "";
          }
        } else if (root instanceof HTMLOptionElement) {
          root.value = value ?? "";
        }
        return;
      case "label":
        if (node.widget === "button") {
          root.textContent = value ?? "";
        } else if (node.widget === "field") {
          root.querySelector(".lui-field-label")!.textContent = value ?? "";
        } else if (node.widget === "checkbox") {
          root.querySelector("span")!.textContent = value ?? "";
        } else if (node.widget === "spinner" || node.widget === "dataGrid") {
          root.setAttribute("aria-label", value ?? "");
        }
        return;
      case "columns":
        if (node.widget === "dataGrid") {
          this.gridHeader(node);
        }
        return;
      case "rowCount":
      case "firstRow":
      case "rowHeight":
      case "visibleRows":
        if (node.widget === "dataGrid") {
          hostOf(node).lastViewport = undefined;
          this.layoutGrid(node);
          this.scheduleViewport(node);
        }
        return;
      case "title":
        root.querySelector(`.lui-${node.widget}-title`)!.textContent = value ?? "";
        return;
      case "checked":
        (root.querySelector("input") as HTMLInputElement).checked = flag;
        return;
      case "disabled":
      case "readonly":
      case "required": {
        const target = node.widget === "checkbox" ? root.querySelector("input")! : root;
        const attr = name === "readonly" ? "readOnly" : name;
        (target as unknown as Record<string, boolean>)[attr] = flag;
        if (name === "required") {
          target.setAttribute("aria-required", String(flag));
        }
        return;
      }
      case "busy":
        root.setAttribute("aria-busy", String(flag));
        (root as HTMLButtonElement).disabled = flag || node.props.disabled === "true";
        return;
      case "invalid":
        root.classList.toggle("lui-invalid", flag);
        this.afterChildrenChanged(node);
        return;
      case "placeholder":
      case "min":
      case "max":
      case "href":
        if (value === null) {
          root.removeAttribute(name);
        } else {
          root.setAttribute(name, value);
        }
        return;
      case "maxLength":
        if (value === null) {
          root.removeAttribute("maxlength");
        } else {
          root.setAttribute("maxlength", value);
        }
        return;
      case "variant":
      case "tone":
        root.dataset[name] = value ?? "";
        if (node.widget === "banner" && name === "tone") {
          root.setAttribute("role", value === "error" || value === "warning" ? "alert" : "status");
        }
        return;
      case "type":
        if (root instanceof HTMLInputElement && node.widget === "textInput") {
          root.type = value ?? "text";
        }
        return;
      default:
        return;
    }
  }

  // Keeps a field's label and error messages associated with its input.
  private afterChildrenChanged(node: MNode): void {
    if (node.widget === "dataGrid" && node.host) {
      hostOf(node).lastViewport = undefined;
      this.layoutGrid(node);
      this.scheduleViewport(node);
      return;
    }
    if (node.widget !== "field" || !node.host) {
      return;
    }
    const root = hostOf(node).root as HTMLElement;
    const [input, ...rest] = node.children;
    if (!input || !input.host) {
      return;
    }
    const target = hostOf(input).root as HTMLElement;
    const control = target instanceof HTMLLabelElement ? target.querySelector("input") : target;
    if (!(control instanceof HTMLElement)) {
      return;
    }
    root.querySelector(".lui-field-label")!.setAttribute("for", control.id);
    const errorIds = rest.filter((c) => c.widget === "fieldError" && c.host).map((c) => (hostOf(c).root as HTMLElement).id);
    if (errorIds.length > 0) {
      control.setAttribute("aria-describedby", errorIds.join(" "));
      control.setAttribute("aria-invalid", "true");
    } else {
      control.removeAttribute("aria-describedby");
      control.removeAttribute("aria-invalid");
    }
  }
}

// A non-negative integer property of a grid, or `fallback`.
function gridNumber(node: MNode, name: string, fallback: number): number {
  const n = Number(node.props[name]);
  return Number.isInteger(n) && n >= 0 ? n : fallback;
}
