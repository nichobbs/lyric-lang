// Browser test of the code editor widget (docs/65 §13.10): drives `CodeEditor`
// in Chromium with real keyboard input. It needs no application: a small
// server serves the compiled runtime (dist/) and ui.css, and a page mounts
// one editor. Run after `npm run build`, with `playwright` installed:
//
//   node --test e2e/editor.e2e.mjs

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

const page = `<!doctype html><meta charset="utf-8">
<link rel="stylesheet" href="/ui.css">
<body>
<button id="before">before</button>
<div id="mount" style="width: 480px"></div>
<button id="after">after</button>
<script type="module">
  import { CodeEditor } from "/dist/editor.js";
  window.reports = [];
  const editor = new CodeEditor((v) => window.reports.push(v));
  editor.setLanguage("lyric");
  editor.setTabSize(2);
  document.getElementById("mount").appendChild(editor.root);
  window.editor = editor;
</script>`;

let server;
let base;
let browser;

before(async () => {
  server = createServer((req, res) => {
    const path = new URL(req.url, "http://x").pathname;
    try {
      if (path === "/") {
        res.writeHead(200, { "content-type": "text/html" }).end(page);
      } else if (path === "/ui.css") {
        res.writeHead(200, { "content-type": "text/css" }).end(readFileSync(join(root, "ui.css")));
      } else if (path.startsWith("/dist/") && path.endsWith(".js") && !path.includes("..")) {
        res.writeHead(200, { "content-type": "text/javascript" }).end(readFileSync(join(root, path)));
      } else {
        res.writeHead(404).end();
      }
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${server.address().port}/`;
  browser = await chromium.launch();
});

after(async () => {
  await browser?.close();
  server?.close();
});

async function open() {
  const p = await browser.newPage();
  await p.goto(base);
  await p.waitForFunction(() => window.editor);
  await p.locator(".lui-code-input").focus();
  return p;
}

const valueOf = (p) => p.locator(".lui-code-input").inputValue();
const reports = (p) => p.evaluate(() => window.reports);

test("typing reports each edit and numbers the lines", async () => {
  const p = await open();
  await p.keyboard.type("val a = 1");
  assert.equal(await valueOf(p), "val a = 1");
  assert.equal((await reports(p)).at(-1), "val a = 1");
  assert.equal(await p.locator(".lui-code-gutter").innerText(), "1");
  await p.keyboard.press("Shift+Enter");
  await p.keyboard.type("x");
  await p.keyboard.press("Enter");
  assert.equal((await p.locator(".lui-code-gutter").innerText()).split("\n").length >= 2, true);
  await p.close();
});

test("the text is highlighted as its language", async () => {
  const p = await open();
  await p.keyboard.type('val Count: Int = 10 // n');
  assert.equal(await p.locator(".lui-code-highlight .lui-tok-keyword").first().innerText(), "val");
  assert.equal(await p.locator(".lui-code-highlight .lui-tok-type").first().innerText(), "Count");
  assert.equal(await p.locator(".lui-code-highlight .lui-tok-number").first().innerText(), "10");
  assert.equal(await p.locator(".lui-code-highlight .lui-tok-comment").first().innerText(), "// n");
  // The highlight layer shows the same text as the textarea.
  assert.equal((await p.locator(".lui-code-highlight code").innerText()).trimEnd(), "val Count: Int = 10 // n");
  await p.evaluate(() => window.editor.setLanguage("plain"));
  assert.equal(await p.locator(".lui-code-highlight span").count(), 0);
  await p.close();
});

test("Tab indents, Shift+Tab outdents and Enter keeps the indentation", async () => {
  const p = await open();
  await p.keyboard.press("Tab");
  await p.keyboard.type("a {");
  await p.keyboard.press("Enter");
  assert.equal(await valueOf(p), "  a {\n    ");
  await p.keyboard.type("b");
  await p.keyboard.press("Shift+Tab");
  assert.equal(await valueOf(p), "  a {\n  b");
  assert.equal((await reports(p)).at(-1), "  a {\n  b");
  await p.close();
});

test("Enter between brackets opens an indented line", async () => {
  const p = await open();
  await p.keyboard.type("f() {}");
  await p.keyboard.press("ArrowLeft");
  await p.keyboard.press("Enter");
  assert.equal(await valueOf(p), "f() {\n  \n}");
  await p.keyboard.type("x");
  assert.equal(await valueOf(p), "f() {\n  x\n}");
  await p.close();
});

test("Tab over several selected lines indents all of them, and undo restores", async () => {
  const p = await open();
  await p.evaluate(() => {
    window.editor.textarea.value = "one\ntwo\nthree";
    window.editor.refresh();
  });
  await p.keyboard.press("Control+a");
  await p.keyboard.press("Tab");
  assert.equal(await valueOf(p), "  one\n  two\n  three");
  await p.keyboard.press("Control+z");
  assert.equal(await valueOf(p), "one\ntwo\nthree");
  await p.close();
});

test("Escape then Tab leaves the editor", async () => {
  const p = await open();
  await p.keyboard.press("Escape");
  await p.keyboard.press("Tab");
  assert.equal(await p.evaluate(() => document.activeElement?.id), "after");
  assert.equal(await valueOf(p), "");
  // Without Escape, Tab stays inside.
  await p.locator(".lui-code-input").focus();
  await p.keyboard.press("Tab");
  assert.equal(await p.evaluate(() => document.activeElement?.className), "lui-code-input");
  await p.close();
});

test("a value from the server replaces the text, and an echo leaves the caret", async () => {
  const p = await open();
  await p.keyboard.type("abcdef");
  await p.keyboard.press("ArrowLeft");
  await p.keyboard.press("ArrowLeft");
  await p.evaluate(() => window.editor.setValue("abcdef"));
  assert.equal(await p.locator(".lui-code-input").evaluate((e) => e.selectionStart), 4);
  await p.evaluate(() => window.editor.setValue("xyz\n123"));
  assert.equal(await valueOf(p), "xyz\n123");
  assert.equal(await p.locator(".lui-code-gutter").innerText(), "1\n2");
  await p.close();
});

test("the gutter and highlight follow the textarea's scroll", async () => {
  const p = await open();
  await p.evaluate(() => {
    window.editor.setValue(Array.from({ length: 200 }, (_, i) => `line ${i + 1}`).join("\n"));
  });
  await p.locator(".lui-code-input").evaluate((e) => {
    e.scrollTop = 300;
    e.dispatchEvent(new Event("scroll"));
  });
  const moved = await p.evaluate(() => ({
    gutter: document.querySelector(".lui-code-gutter > div").style.transform,
    code: document.querySelector(".lui-code-highlight").style.transform,
  }));
  assert.match(moved.gutter, /-300px/);
  assert.match(moved.code, /-300px/);
  await p.close();
});

test("a read-only editor takes no Tab or Enter edits", async () => {
  const p = await open();
  await p.evaluate(() => {
    window.editor.setValue("fixed");
    window.editor.textarea.readOnly = true;
  });
  await p.keyboard.press("Enter");
  assert.equal(await valueOf(p), "fixed");
  assert.deepEqual(await reports(p), []);
  await p.close();
});
