// Toasts carried across a session-driven navigation (src/toasts.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { stashToasts, takeStashedToasts } from "../dist/toasts.js";

function memoryStore() {
  const m = new Map();
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    size: () => m.size,
  };
}

test("stashed toasts come back once, in order", () => {
  const s = memoryStore();
  stashToasts(s, [{ m: "Customer saved", level: "success" }, { m: "Synced", level: "info" }]);
  assert.deepEqual(takeStashedToasts(s), [
    { m: "Customer saved", level: "success" },
    { m: "Synced", level: "info" },
  ]);
  assert.deepEqual(takeStashedToasts(s), []);
  assert.equal(s.size(), 0);
});

test("nothing to stash leaves the store untouched", () => {
  const s = memoryStore();
  stashToasts(s, []);
  assert.equal(s.size(), 0);
  assert.deepEqual(takeStashedToasts(s), []);
});

test("a malformed entry yields no toasts and is cleared", () => {
  const s = memoryStore();
  s.setItem("lyric-ui:toasts", "{not json");
  assert.deepEqual(takeStashedToasts(s), []);
  s.setItem("lyric-ui:toasts", JSON.stringify([{ m: "ok", level: "info" }, { m: 3 }, null, "x"]));
  assert.deepEqual(takeStashedToasts(s), [{ m: "ok", level: "info" }]);
  assert.equal(s.size(), 0);
});

test("an unavailable store loses the toasts, not the navigation", () => {
  const broken = {
    getItem: () => {
      throw new Error("blocked");
    },
    setItem: () => {
      throw new Error("blocked");
    },
    removeItem: () => {
      throw new Error("blocked");
    },
  };
  assert.doesNotThrow(() => stashToasts(broken, [{ m: "x", level: "info" }]));
  assert.deepEqual(takeStashedToasts(broken), []);
});
