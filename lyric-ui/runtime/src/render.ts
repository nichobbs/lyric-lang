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
        } else if (node.widget === "spinner") {
          root.setAttribute("aria-label", value ?? "");
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
