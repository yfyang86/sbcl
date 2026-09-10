// The Playwright suite of the browser host (Sprint 14). The dev server
// (wasm/web/serve.mjs) must be running; WEB_URL overrides its address.
// Chromium uses the installed Google Chrome (channel "chrome") so no
// browser is downloaded; Firefox uses the Playwright build when
// PLAYWRIGHT_FIREFOX=1 (installed with `npx playwright install firefox`).
import { defineConfig } from "@playwright/test";

const baseURL = process.env.WEB_URL ?? "http://127.0.0.1:8625";

export default defineConfig({
  testDir: ".",
  timeout: 120_000,
  retries: 0,
  workers: 1, // one SBCL image per page; the core module is 44 MB
  reporter: [["list"]],
  use: { baseURL },
  projects: [
    { name: "chromium", use: { channel: "chrome" } },
    ...(process.env.PLAYWRIGHT_FIREFOX === "1"
        ? [{ name: "firefox", use: { browserName: "firefox" } }] : []),
  ],
});
