// Lyric UI host runtime: the mirror tree and patch semantics.
//
// This module has no DOM dependency. It keeps a mirror of the session's
// rendered tree and applies protocol patches to it (docs/65 §9.2). The DOM
// renderer (render.ts) observes the mirror through the `TreeObserver`
// callbacks, so patch semantics are defined once, here, and are tested in
// isolation under Node (test/tree.test.mjs). They must match the Lyric
// reference applier `Ui.Diff.applyPatches`.

export type Props = Record<string, string>;

export interface WireElement {
  t: "el";
  k: string;
  key?: string;
  p: Props;
  e: string[];
  c: WireNode[];
}
export interface WireText {
  t: "text";
  v: string;
}
export interface WireEmpty {
  t: "empty";
}
export type WireNode = WireElement | WireText | WireEmpty;

export type Patch =
  | { op: "replace"; p: number[]; n: WireNode }
  | { op: "insert"; p: number[]; i: number; n: WireNode }
  | { op: "remove"; p: number[]; i: number }
  | { op: "move"; p: number[]; from: number; to: number }
  | { op: "setProp"; p: number[]; k: string; v: string; iv?: number }
  | { op: "removeProp"; p: number[]; k: string }
  | { op: "setText"; p: number[]; v: string }
  | { op: "setEvents"; p: number[]; e: string[] };

/** A node of the mirror tree. `host` is renderer-owned state. */
export interface MNode {
  kind: "el" | "text" | "empty";
  widget: string;
  key: string;
  props: Props;
  events: string[];
  text: string;
  children: MNode[];
  parent: MNode | null;
  host: unknown;
}

/** Renderer hooks, called after the mirror has changed. */
export interface TreeObserver {
  created(node: MNode): void;
  inserted(parent: MNode, index: number, node: MNode): void;
  removed(parent: MNode, index: number, node: MNode): void;
  replaced(old: MNode, node: MNode): void;
  propSet(node: MNode, name: string, value: string, inputVersion: number | undefined): void;
  propRemoved(node: MNode, name: string): void;
  textSet(node: MNode, value: string): void;
}

export class PatchError extends Error {}

export function build(w: WireNode, parent: MNode | null, obs: TreeObserver | null): MNode {
  const node: MNode = {
    kind: w.t,
    widget: w.t === "el" ? w.k : "",
    key: w.t === "el" ? (w.key ?? "") : "",
    props: w.t === "el" ? { ...w.p } : {},
    events: w.t === "el" ? [...w.e] : [],
    text: w.t === "text" ? w.v : "",
    children: [],
    parent,
    host: null,
  };
  if (w.t === "el") {
    node.children = w.c.map((c) => build(c, node, null));
  }
  if (obs) {
    createDeep(node, obs);
  }
  return node;
}

// Children are announced to the renderer before their parent is, so a
// renderer can assemble a subtree bottom-up.
function createDeep(node: MNode, obs: TreeObserver): void {
  for (const c of node.children) {
    createDeep(c, obs);
  }
  obs.created(node);
}

/** The node at `path` below `root`. */
export function nodeAt(root: MNode, path: number[]): MNode {
  let n = root;
  for (const i of path) {
    if (i < 0 || i >= n.children.length) {
      throw new PatchError(`path ${path.join(".")} does not resolve`);
    }
    n = n.children[i];
  }
  return n;
}

/**
 * The event path of `node` below `root`: each step is the node's key when it
 * has one and its child index otherwise. The session resolves keys among
 * siblings, so an event still reaches (or is dropped for) the node it was
 * aimed at when the tree changed in between (D138, Q-UI-005). `null` when
 * `node` is no longer in the tree (a patch removed or replaced it after the
 * event was raised); the event then has no target and is not sent.
 */
export function eventPathOf(root: MNode, node: MNode): (number | string)[] | null {
  const path: (number | string)[] = [];
  let n = node;
  while (n.parent) {
    const index = n.parent.children.indexOf(n);
    if (index < 0) {
      return null;
    }
    path.push(n.key !== "" ? n.key : index);
    n = n.parent;
  }
  return n === root ? path.reverse() : null;
}

export class Tree {
  root: MNode;

  constructor(private readonly obs: TreeObserver | null) {
    this.root = build({ t: "empty" }, null, obs);
  }

  apply(patch: Patch): void {
    const obs = this.obs;
    switch (patch.op) {
      case "replace": {
        const old = nodeAt(this.root, patch.p);
        const node = build(patch.n, old.parent, obs);
        if (old.parent) {
          old.parent.children[old.parent.children.indexOf(old)] = node;
        } else {
          this.root = node;
        }
        obs?.replaced(old, node);
        old.parent = null;
        return;
      }
      case "insert": {
        const parent = nodeAt(this.root, patch.p);
        const index = clampIndex(patch.i, parent.children.length);
        const node = build(patch.n, parent, obs);
        parent.children.splice(index, 0, node);
        obs?.inserted(parent, index, node);
        return;
      }
      case "remove": {
        const parent = nodeAt(this.root, patch.p);
        checkIndex(patch.i, parent.children.length);
        const [node] = parent.children.splice(patch.i, 1);
        obs?.removed(parent, patch.i, node);
        node.parent = null;
        return;
      }
      case "move": {
        const parent = nodeAt(this.root, patch.p);
        checkIndex(patch.from, parent.children.length);
        const [node] = parent.children.splice(patch.from, 1);
        obs?.removed(parent, patch.from, node);
        const to = clampIndex(patch.to, parent.children.length);
        parent.children.splice(to, 0, node);
        obs?.inserted(parent, to, node);
        return;
      }
      case "setProp": {
        const node = nodeAt(this.root, patch.p);
        node.props[patch.k] = patch.v;
        obs?.propSet(node, patch.k, patch.v, patch.iv);
        return;
      }
      case "removeProp": {
        const node = nodeAt(this.root, patch.p);
        delete node.props[patch.k];
        obs?.propRemoved(node, patch.k);
        return;
      }
      case "setText": {
        const node = nodeAt(this.root, patch.p);
        node.text = patch.v;
        obs?.textSet(node, patch.v);
        return;
      }
      case "setEvents": {
        nodeAt(this.root, patch.p).events = [...patch.e];
        return;
      }
    }
  }
}

function checkIndex(i: number, length: number): void {
  if (i < 0 || i >= length) {
    throw new PatchError(`child index ${i} out of range (${length} children)`);
  }
}

function clampIndex(i: number, length: number): number {
  if (i < 0 || i > length) {
    throw new PatchError(`insert index ${i} out of range (${length} children)`);
  }
  return i;
}

/** The wire form of a mirror subtree (used by tests to compare trees). */
export function toWire(n: MNode): WireNode {
  if (n.kind === "text") {
    return { t: "text", v: n.text };
  }
  if (n.kind === "empty") {
    return { t: "empty" };
  }
  const w: WireElement = { t: "el", k: n.widget, p: { ...n.props }, e: [...n.events], c: n.children.map(toWire) };
  if (n.key) {
    w.key = n.key;
  }
  return w;
}
