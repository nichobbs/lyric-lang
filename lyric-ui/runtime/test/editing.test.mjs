// What Tab, Shift+Tab and Enter do in the code editor (docs/65 §13.10).
import { test } from "node:test";
import assert from "node:assert/strict";
import { indent, outdent, newline, lineCount } from "../dist/editing.js";

// Applies an edit to a value and returns the new value and selection.
function run(value, e) {
  return { value: value.slice(0, e.start) + e.text + value.slice(e.end), sel: [e.selStart, e.selEnd] };
}

test("Tab inserts spaces up to the next tab stop", () => {
  assert.deepEqual(run("ab", indent("ab", 2, 2, 4)), { value: "ab  ", sel: [4, 4] });
  assert.deepEqual(run("", indent("", 0, 0, 2)), { value: "  ", sel: [2, 2] });
  assert.deepEqual(run("abcd", indent("abcd", 4, 4, 4)), { value: "abcd    ", sel: [8, 8] });
});

test("Tab with a selection inside one line replaces it", () => {
  assert.deepEqual(run("abcdef", indent("abcdef", 1, 3, 2)), { value: "a def", sel: [2, 2] });
});

test("Tab over several lines indents each line the selection touches", () => {
  const v = "one\ntwo\nthree";
  const r = run(v, indent(v, 2, 9, 2));
  assert.equal(r.value, "  one\n  two\n  three");
  assert.deepEqual(r.sel, [4, 15]);
});

test("a selection ending at the start of a line does not touch that line", () => {
  const v = "one\ntwo\nthree";
  const r = run(v, indent(v, 0, 8, 2));
  assert.equal(r.value, "  one\n  two\nthree");
});

test("Shift+Tab removes up to a tab stop from each line, or one tab", () => {
  const v = "    a\n  b\nc\n\td";
  const r = run(v, outdent(v, 0, v.length, 4));
  assert.equal(r.value, "a\nb\nc\nd");
  assert.equal(outdent("x", 0, 0, 2), null);
});

test("Shift+Tab with the caret in a line outdents that line and moves the caret", () => {
  const r = run("    ab", outdent("    ab", 5, 5, 4));
  assert.deepEqual(r, { value: "ab", sel: [1, 1] });
});

test("Enter keeps the line's indentation", () => {
  assert.deepEqual(run("  foo", newline("  foo", 5, 5, 2)), { value: "  foo\n  ", sel: [8, 8] });
  assert.deepEqual(run("\tfoo", newline("\tfoo", 4, 4, 2)), { value: "\tfoo\n\t", sel: [6, 6] });
  assert.deepEqual(run("", newline("", 0, 0, 2)), { value: "\n", sel: [1, 1] });
});

test("Enter after an opening bracket indents one more level", () => {
  assert.deepEqual(run("  f() {", newline("  f() {", 7, 7, 2)), { value: "  f() {\n    ", sel: [12, 12] });
});

test("Enter between a bracket pair opens an indented blank line", () => {
  const v = "  {}";
  const r = run(v, newline(v, 3, 3, 2));
  assert.equal(r.value, "  {\n    \n  }");
  assert.deepEqual(r.sel, [8, 8]);
  // Mismatched brackets do not.
  assert.equal(run("(]", newline("(]", 1, 1, 2)).value, "(\n  ]");
});

test("Enter over a selection replaces it", () => {
  assert.equal(run("ab cd", newline("ab cd", 2, 3, 2)).value, "ab\ncd");
});

test("lineCount counts a trailing newline as a new line", () => {
  assert.equal(lineCount(""), 1);
  assert.equal(lineCount("a\nb"), 2);
  assert.equal(lineCount("a\n"), 2);
});
