// Patch semantics of the mirror tree (no DOM). These cases mirror
// lyric-ui/tests/diff_tests.l, whose Lyric reference applier
// (Ui.Diff.applyPatches) defines the same semantics.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Tree, toWire, pathOf, nodeAt, PatchError } from "../dist/tree.js";

const text = (v) => ({ t: "text", v });
const el = (k, c = [], p = {}, e = [], key) => (key ? { t: "el", k, key, p, e, c } : { t: "el", k, p, e, c });
const para = (key) => el("paragraph", [text(key)], {}, [], key);
const list = (...keys) => el("column", keys.map(para));

function treeOf(w) {
  const t = new Tree(null);
  t.apply({ op: "replace", p: [], n: w });
  return t;
}

test("replace at the root", () => {
  const t = treeOf(el("column", [text("a")]));
  assert.deepEqual(toWire(t.root), el("column", [text("a")]));
});

test("insert, remove and move keep children ordered", () => {
  const t = treeOf(list("a", "b", "c"));
  t.apply({ op: "move", p: [], from: 2, to: 0 });
  assert.deepEqual(toWire(t.root), list("c", "a", "b"));
  t.apply({ op: "remove", p: [], i: 1 });
  assert.deepEqual(toWire(t.root), list("c", "b"));
  t.apply({ op: "insert", p: [], i: 1, n: para("x") });
  assert.deepEqual(toWire(t.root), list("c", "x", "b"));
});

test("props, text and events", () => {
  const t = treeOf(el("button", [], { label: "Save", busy: "true" }, []));
  t.apply({ op: "setProp", p: [], k: "label", v: "Store" });
  t.apply({ op: "removeProp", p: [], k: "busy" });
  t.apply({ op: "setEvents", p: [], e: ["click"] });
  assert.deepEqual(toWire(t.root), el("button", [], { label: "Store" }, ["click"]));
  const u = treeOf(el("heading", [text("A")]));
  u.apply({ op: "setText", p: [0], v: "B" });
  assert.deepEqual(toWire(u.root), el("heading", [text("B")]));
});

test("paths are recomputed from parents", () => {
  const t = treeOf(el("column", [el("row", [text("x"), el("button", [], {}, ["click"])])]));
  const button = nodeAt(t.root, [0, 1]);
  assert.deepEqual(pathOf(button), [0, 1]);
  t.apply({ op: "insert", p: [], i: 0, n: text("before") });
  assert.deepEqual(pathOf(button), [1, 1]);
});

test("unresolvable paths throw PatchError", () => {
  const t = treeOf(list("a"));
  assert.throws(() => t.apply({ op: "setText", p: [5, 0], v: "x" }), PatchError);
  assert.throws(() => t.apply({ op: "remove", p: [], i: 3 }), PatchError);
});
