// The dev server of the browser host (Sprint 14): serves the page, the
// worker and the build products with the COOP/COEP headers that make
// the page crossOriginIsolated, so the worker's stdin can block on a
// SharedArrayBuffer (SBCL-Handoff.md 4.5).
//   node wasm/web/serve.mjs [port]      (default 8625; SBCL_WASM_PORT)
// The build products come from src/runtime/sbcl.wasm, output/sbcl.core
// and output/sbcl-core.wasm; anything under tests/wasm/web/data/ is
// served under /data/ for the test files the suite loads into the FS.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const root = join(here, "..", "..");
const port = Number(process.env.SBCL_WASM_PORT ?? process.argv[2] ?? 8625);

const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".core": "application/octet-stream",
  ".lisp": "text/plain; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
};

const urls = {
  "/": join(here, "index.html"),
  "/repl.js": join(here, "repl.js"),
  "/repl.css": join(here, "repl.css"),
  "/worker.js": join(here, "worker.js"),
  "/ring.js": join(here, "ring.js"),
  "/sbcl-host.js": join(here, "sbcl-host.js"),
  "/wasi.js": join(here, "wasi.js"),
  "/sbcl.wasm": join(root, "src", "runtime", "sbcl.wasm"),
  "/sbcl.core": join(root, "output", "sbcl.core"),
  "/sbcl-core.wasm": join(root, "output", "sbcl-core.wasm"),
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  try {
    let file = urls[url.pathname];
    if (!file && url.pathname.startsWith("/data/")) {
      file = join(root, "tests", "wasm", "web", "data",
                  ...url.pathname.slice("/data/".length).split("/"));
    }
    if (!file) throw Object.assign(new Error("not found"), { code: "ENOENT" });
    const bytes = await readFile(file);
    res.writeHead(200, {
      "content-type": types[extname(file)] ?? "application/octet-stream",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
      "cache-control": "no-store",
    });
    res.end(bytes);
  } catch (e) {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end(`not found: ${url.pathname}\n`);
  }
});

server.listen(port, () => {
  console.log(`sbcl-wasm web host on http://127.0.0.1:${port}/ ` +
              `(crossOriginIsolated headers on; Ctrl-C to stop)`);
});
