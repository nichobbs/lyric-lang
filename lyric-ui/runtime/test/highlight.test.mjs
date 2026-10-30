// The code editor's tokenizers (docs/65 §13.10).
import { test } from "node:test";
import assert from "node:assert/strict";
import { tokenize } from "../dist/highlight.js";

const join = (ts) => ts.map((t) => t.text).join("");
const types = (ts) => ts.filter((t) => t.type !== "plain").map((t) => `${t.type}:${t.text}`);

test("tokenizing is lossless in every language", () => {
  const sources = [
    'pub func f(x: in Int): Int {\n  // c\n  return x + 0x1Fi64 /* a /* nested */ b */\n}\n',
    '{"a": [1, -2.5e3, true, null], "b\\"": "c"}',
    "plain text, anything: at all\n\n",
    "",
    '"unterminated\nnext',
  ];
  for (const lang of ["lyric", "json", "plain", "unknown"]) {
    for (const s of sources) {
      assert.equal(join(tokenize(lang, s)), s, `${lang}: ${JSON.stringify(s)}`);
    }
  }
});

test("lyric: keywords, types, literals, numbers, strings and comments", () => {
  const ts = tokenize("lyric", 'val Total: Int = 10i64 // sum\nif true { "a\\"b" }');
  assert.deepEqual(types(ts), [
    "keyword:val",
    "type:Total",
    "punct::",
    "type:Int",
    "punct:=",
    "number:10i64",
    "comment:// sum",
    "keyword:if",
    "literal:true",
    "punct:{",
    'string:"a\\"b"',
    "punct:}",
  ]);
});

test("lyric: block comments nest and a comment-looking string stays a string", () => {
  assert.deepEqual(types(tokenize("lyric", "/* a /* b */ still */ x")), ["comment:/* a /* b */ still */"]);
  assert.deepEqual(types(tokenize("lyric", '"// not a comment"')), ['string:"// not a comment"']);
});

test("lyric: numbers with fractions, exponents, separators and prefixes", () => {
  for (const n of ["1_000", "0.5f32", "1e9", "2.5E-3", "0xFFu8", "0b1010"]) {
    assert.deepEqual(types(tokenize("lyric", n)), [`number:${n}`], n);
  }
});

test("json: keys are told from string values", () => {
  assert.deepEqual(types(tokenize("json", '{"k": "v", "n": [1, false]}')), [
    "punct:{",
    'key:"k"',
    "punct::",
    'string:"v"',
    "punct:,",
    'key:"n"',
    "punct::",
    "punct:[",
    "number:1",
    "punct:,",
    "literal:false",
    "punct:]}",
  ]);
});

test("an unterminated string ends at its line", () => {
  assert.deepEqual(types(tokenize("lyric", '"abc\nval')), ['string:"abc', "keyword:val"]);
});
