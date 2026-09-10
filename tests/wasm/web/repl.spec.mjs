// The Sprint 14 UAT in the browser: boot, REPL round trip, compile of a
// function, a subset of the pure tests run in the worker. Exit criteria
// from doc/wasm-port/04-sprints.md "Sprint 14: browser host".
import { test, expect } from "@playwright/test";

/// The page with a live SBCL worker; resolves when the REPL is up
/// (the status line turns "running"), with the startup milliseconds.
/// query is appended to the page URL (the suite's ?load=).
async function sbclPage(browser, query = "") {
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(`/${query}`);
  await expect(page.locator("#status")).toHaveClass(/running/, { timeout: 90_000 });
  const startupMs = Number((await page.locator("#status").textContent())
    .match(/([\d.]+) s to REPL/)?.[1] ?? 0) * 1000;
  return { page, context, errors, startupMs };
}

/// Evaluate a form at the REPL and return the transcript it produced
/// (the form's echo included): send it and wait for SBCL's next "* "
/// prompt after where the output stood.
async function repl(page, form) {
  const before = await page.locator("#output").textContent();
  await page.locator("#input").fill(form);
  await page.keyboard.press("Enter");
  await page.waitForFunction(
    ([prev, sent]) => {
      const t = document.getElementById("output").textContent;
      return t.length > prev.length + sent.length &&
             /\*\s*$/.test(t.slice(prev.length));
    }, [before, form], { timeout: 60_000 });
  const after = await page.locator("#output").textContent();
  return after.slice(before.length);
}

test("boot: the page runs SBCL to its REPL", async ({ browser }) => {
  const { page, context, errors, startupMs } = await sbclPage(browser);
  const heading = await page.locator(".title").textContent();
  expect(heading).toContain("SBCL");
  // the core module's size is shown in the header
  expect(await page.locator("#version").textContent()).toMatch(/\d+ MB/);
  console.log(`startup: ${(startupMs / 1000).toFixed(1)} s`);
  expect(errors).toEqual([]);
  await context.close();
});

test("REPL round trip: an arithmetic form evaluates", async ({ browser }) => {
  const { page, context, errors } = await sbclPage(browser);
  const transcript = await repl(page, "(+ 1 2)");
  expect(transcript).toContain("3");
  const values = await repl(page, "(values :a :b)");
  expect(values).toContain(":A");
  expect(values).toContain(":B");
  expect(errors).toEqual([]);
  await context.close();
});

test("compile: a function compiled at run time runs", async ({ browser }) => {
  const { page, context, errors } = await sbclPage(browser);
  const transcript = await repl(page,
    "(defun sq (x) (* x x))");
  expect(transcript).toMatch(/SQ/);
  const compiled = await repl(page,
    "(compile 'sq)");
  expect(compiled).toContain("SQ");
  const result = await repl(page, "(sq 12)");
  expect(result).toContain("144");
  expect(errors).toEqual([]);
  await context.close();
});

test("pure tests in the worker: the ansi-style subset", async ({ browser }) => {
  // the page fetches the checks into the worker's file system
  const { page, context, errors } = await sbclPage(browser, "?load=/data/pure-checks.lisp");
  const transcript = await repl(page, '(load "/pure-checks.lisp")');
  expect(transcript).not.toMatch(/FAIL/);
  const run = await repl(page, "(pure-checks:run)");
  expect(run).not.toMatch(/FAIL/);
  const summary = await repl(page, "(pure-checks:report)");
  expect(summary).toMatch(/PURE-CHECKS: \d+\/\d+/);
  const [pass, total] = summary.match(/PURE-CHECKS: (\d+)\/(\d+)/).slice(1)
      .map(Number);
  expect(pass).toBe(total);
  expect(errors).toEqual([]);
  await context.close();
});
