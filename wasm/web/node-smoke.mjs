// Run sbcl.wasm under V8 in Node with the Sprint 14 host (the same
// sbcl-host.js/wasi.js the browser worker uses), feeding a fixed stdin
// script — the fast iteration path for the web host, and the Node half
// of the "browser host" story for machines without a browser:
//   node wasm/web/node-smoke.mjs output/sbcl.core output/sbcl-core.wasm
// stdin forms are read from the file named by the third argument or
// /dev/stdin.
import { readFileSync } from "node:fs";
import { SBCLHost, trapUnknownImports } from "./sbcl-host.js";
import { WasiShim, ProcExit } from "./wasi.js";

const [coreFile, coreModuleFile, stdinFile] = process.argv.slice(2);
if (!coreFile || !coreModuleFile) {
  console.error("usage: node node-smoke.mjs CORE.core CORE-core.wasm [STDIN.lisp]");
  process.exit(2);
}

class QueueStdin {
  constructor(bytes) { this.queue = [...bytes]; }
  ready() { return this.queue.length > 0; }
  read(dst) {
    let n = 0;
    while (n < dst.length && this.queue.length) dst[n++] = this.queue.shift();
    return n;
  }
}

const args = ["sbcl.wasm", "--core", "/sbcl.core", "--noinform"];
const coreBytes = readFileSync(coreFile);
const fileMap = new Map([
  ["/sbcl.core", coreBytes],
  ["/sbcl-core.wasm", readFileSync(coreModuleFile)],
]);
const stdinBytes = readFileSync(stdinFile ?? "/dev/stdin");

let out = "";
const host = new SBCLHost(null, {
  onInstantiate: (size, base, count) =>
    console.error(`# module: ${count} functions at ${base}..${base + count} (${size} bytes)`),
});
const shim = new WasiShim({
  args,
  env: { PWD: "/", HOME: "/" },
  files: fileMap,
  stdin: new QueueStdin(stdinBytes),
  onStdout: (b) => { out += new TextDecoder().decode(b); },
  onStderr: (b) => process.stderr.write(b),
  onExit: (code) => console.error(`# exit ${code}`),
  host,
});

const t0 = performance.now();
const runtimeModule = new WebAssembly.Module(readFileSync(new URL("../../src/runtime/sbcl.wasm", import.meta.url)));
const imports = trapUnknownImports({
  wasi_snapshot_preview1: shim.imports(),
  sbcl_host: host.imports(),
  env: {
    madvise: () => 0,
    list_lisp_threads: () => 0,
    generate_elfcore_obj: () => { throw new Error("no core dumps in node-smoke"); },
  },
}, runtimeModule, "runtime import");
const runtime = new WebAssembly.Instance(runtimeModule, imports);
host.runtime = runtime;
host.exports = runtime.exports;
shim.attach(runtime.exports.memory);

try {
  runtime.exports._start();
  console.error(`# _start returned in ${Math.round(performance.now() - t0)} ms`);
} catch (e) {
  if (!(e instanceof ProcExit)) throw e;
  console.error(`# exit ${e.code} in ${Math.round(performance.now() - t0)} ms`);
}
process.stdout.write(out);
