// Browser end-to-end test for the server-driven web host (docs/65 §10.1,
// #7836): drives examples/ui-customers in Chromium against a running host.
//
// Run through scripts/ci/ui-browser-e2e.sh, which builds and starts the
// example on the requested target and sets LYRIC_UI_E2E_URL (the page) and
// LYRIC_UI_E2E_TARGET (for the report).

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { chromium } from "playwright";

const pageUrl = process.env.LYRIC_UI_E2E_URL;
const target = process.env.LYRIC_UI_E2E_TARGET ?? "dotnet";
if (!pageUrl) {
  throw new Error("LYRIC_UI_E2E_URL is not set; run scripts/ci/ui-browser-e2e.sh");
}

const timeout = 15_000;
let browser;

before(async () => {
  browser = await chromium.launch();
});

after(async () => {
  await browser?.close();
});

async function openEditor() {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(pageUrl);
  // The prerendered page is inert; wait for the live tree to replace it.
  await page.locator("#lyric-ui:not([aria-busy])").waitFor({ timeout });
  await page.getByRole("heading", { level: 1, name: "Customer 1" }).waitFor({ timeout });
  return { page, errors };
}

test(`${target}: the page arrives prerendered, then the session takes over`, async () => {
  const response = await fetch(pageUrl);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const html = await response.text();
  assert.match(html, /<div id="lyric-ui" aria-busy="true" data-ws="[^"]+" data-sid="[0-9A-Fa-f]{32}">/);
  // The edit screen starts by loading the customer: its first view is the
  // loading spinner, or the editor if the load already finished.
  assert.ok(html.includes("lui-spinner") || html.includes("Customer 1"), html);
  const { page, errors } = await openEditor();
  assert.equal(await page.getByLabel("Name").inputValue(), "Acme Pty Ltd");
  assert.deepEqual(errors, []);
  await page.close();
});

test(`${target}: the editor renders the stored customer`, async () => {
  const { page, errors } = await openEditor();
  assert.equal(await page.getByLabel("Name").inputValue(), "Acme Pty Ltd");
  assert.equal(await page.getByLabel("Email").inputValue(), "accounts@acme.test");
  assert.deepEqual(errors, []);
  await page.close();
});

test(`${target}: an invalid edit shows a field error, and a valid save succeeds`, async () => {
  const { page, errors } = await openEditor();
  const name = page.getByLabel("Name");
  await name.fill("");
  await page.getByRole("button", { name: "Save" }).click();
  await page.locator("#" + (await name.getAttribute("id")) + "[aria-invalid=true]").waitFor({ timeout });

  await name.fill("Acme Holdings");
  // Fixing the field clears its error once the session revalidates.
  await page.locator("#" + (await name.getAttribute("id")) + ":not([aria-invalid])").waitFor({ timeout });
  await page.getByRole("button", { name: "Save" }).click();

  // A save notifies and returns to the list; the toast survives the page change.
  await page.getByRole("heading", { level: 1, name: "Customers" }).waitFor({ timeout });
  await page.locator(".lui-toast", { hasText: "Customer saved" }).waitFor({ timeout });
  await page.getByRole("link", { name: "Acme Holdings" }).waitFor({ timeout });
  assert.deepEqual(errors, []);
  await page.close();
});

test(`${target}: the list opens a customer`, async () => {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(new URL("/customers", pageUrl).href);
  await page.getByRole("heading", { level: 1, name: "Customers" }).waitFor({ timeout });
  await page.getByRole("link", { name: "Birchwood Joinery" }).click();
  await page.getByRole("heading", { level: 1, name: "Customer 2" }).waitFor({ timeout });
  assert.equal(await page.getByLabel("Name").inputValue(), "Birchwood Joinery");
  assert.deepEqual(errors, []);
  await page.close();
});

test(`${target}: a dropped connection resumes the same session`, async () => {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  const servers = [];
  await page.routeWebSocket(/\/_ui/, (ws) => {
    servers.push(ws.connectToServer());
  });
  await page.goto(pageUrl);
  await page.getByRole("heading", { level: 1, name: "Customer 1" }).waitFor({ timeout });

  // An unsaved edit lives only in the session's model.
  await page.getByLabel("Notes").fill("Call before delivery");
  await page.getByLabel("Notes").blur();
  await page.waitForTimeout(300);

  await servers[0].close();
  await page.waitForFunction(() => document.getElementById("lyric-ui")?.getAttribute("aria-busy") === "true", null, {
    timeout,
  });
  await page.waitForFunction(() => !document.getElementById("lyric-ui")?.hasAttribute("aria-busy"), null, { timeout });
  assert.ok(servers.length >= 2, "the runtime reconnected");

  // Resumed, not restarted: a new session would reload the stored customer
  // and render empty notes; the resumed one still holds the unsaved edit.
  await page.waitForTimeout(300);
  assert.equal(await page.getByLabel("Notes").inputValue(), "Call before delivery");
  assert.deepEqual(errors, []);
  await page.close();
});
