// The SBCL WebAssembly worker (Sprint 14): runs src/runtime/sbcl.wasm
// with the sbcl_host contract over V8 instead of Wasmtime, on a
// worker's own thread — synchronous WebAssembly.Module compilation is
// allowed off the main thread, the engine's stack (deep Lisp
// recursion) is the worker's, and the page stays responsive.
//
// Messages from the page:
//   {type: "start", runtimeUrl, coreUrl, coreModuleUrl, files,
//    args, dynamicSpaceSize}   fetch everything, boot, run _start
//   {type: "stdin", bytes: Uint8Array}     feed the Lisp stdin (when
//                                          no SharedArrayBuffer: the
//                                          worker is then not blocked
//                                          in a read at the time)
//   {type: "interrupt"}                    request Ctrl-C (bit 1)
// Messages to the page:
//   {type: "stdin-ring", buffer}   the SharedArrayBuffer of the input
//                                  ring: write into it directly, the
//                                  worker's thread cannot service
//                                  postMessage while Lisp runs
//   {type: "booted", fetchMs, coreModuleBytes}
//   {type: "stdout"|"stderr", bytes: Uint8Array}
//   {type: "startupMs", startupMs}          the first REPL prompt
//   {type: "exit", code} | {type: "error", message, stack}
//
// files: [{path, url | bytes}] fetched before the start and installed
// into the in-memory file system (the test files the Playwright suite
// loads).
import { SBCLHost, trapUnknownImports } from "./sbcl-host.js";
import { WasiShim, ProcExit } from "./wasi.js";
import { RingStdin, ringBuffer } from "./ring.js";

const post = (m) => self.postMessage(m);

let stdin = null;
let host = null;

self.onmessage = async (event) => {
  const message = event.data;
  if (message.type === "stdin") {
    // the fallback path: no SharedArrayBuffer, the queue is drained by
    // fd_read's polling (wasi.js reads it when the ring is not shared)
    stdin?.fallbackPush(message.bytes);
    return;
  }
  if (message.type === "interrupt") { if (host) host.interruptRequested = true; return; }
  if (message.type !== "start") return;

  try {
    await boot(message);
  } catch (e) {
    post({ type: "error", message: String(e), stack: e?.stack });
  }
};

async function boot({ runtimeUrl, coreUrl, coreModuleUrl, files = [], args, dynamicSpaceSize }) {
  const t0 = performance.now();
  const fetchBytes = async (url) => new Uint8Array(await (await fetch(url)).arrayBuffer());

  const runtimeBytes = await fetchBytes(runtimeUrl);
  const coreBytes = await fetchBytes(coreUrl);
  const coreModuleBytes = await fetchBytes(coreModuleUrl);

  const fileMap = new Map([
    ["/sbcl.core", coreBytes],
    ["/sbcl-core.wasm", coreModuleBytes],
  ]);
  for (const f of files) fileMap.set(f.path, f.bytes ?? await fetchBytes(f.url));

  // the input ring: shared when the page is crossOriginIsolated (the
  // dev server sets COOP/COEP), a plain queue otherwise
  const shared = self.crossOriginIsolated === true;
  stdin = new RingStdin(ringBuffer(shared));
  stdin.fallbackQueue = [];
  stdin.fallbackPush = (bytes) => {
    for (const b of bytes) stdin.fallbackQueue.push(b);
  };
  stdin.ready = () => stdin.shared ? RingStdin.prototype.ready.call(stdin)
                                   : stdin.fallbackQueue.length > 0;
  stdin.read = (dst) => {
    if (!stdin.shared) {
      let n = 0;
      while (n < dst.length && stdin.fallbackQueue.length) dst[n++] = stdin.fallbackQueue.shift();
      return n;
    }
    return RingStdin.prototype.read.call(stdin, dst);
  };
  if (shared) post({ type: "stdin-ring", buffer: stdin.int32.buffer });
  host = new SBCLHost(null);

  // the REPL is up when SBCL writes its first "* " prompt; that is the
  // page's "running" and the startup time worth recording
  let transcript = "";
  let sawPrompt = false;
  const notePrompt = (bytes) => {
    if (sawPrompt) return;
    transcript += new TextDecoder().decode(bytes);
    if (/(^|\n)\* ?$/.test(transcript)) {
      sawPrompt = true;
      post({ type: "startupMs", startupMs: Math.round(performance.now() - t0) });
    }
  };

  const shim = new WasiShim({
    args: ["sbcl.wasm", "--core", "/sbcl.core",
           ...(dynamicSpaceSize ? ["--dynamic-space-size", dynamicSpaceSize] : []),
           ...(args ?? ["--noinform"])],
    env: { PWD: "/", HOME: "/" },
    files: fileMap,
    stdin,
    // the bytes are views into the wasm memory (half a gigabyte, and
    // it grows): postMessage clones a view with its whole buffer, so
    // copy what was written
    onStdout: (b) => { const copy = b.slice(); post({ type: "stdout", bytes: copy }); notePrompt(copy); },
    onStderr: (b) => post({ type: "stderr", bytes: b.slice() }),
    onExit: (code) => post({ type: "exit", code }),
    host,
  });

  const runtimeModule = new WebAssembly.Module(runtimeBytes);
  const imports = trapUnknownImports({
    wasi_snapshot_preview1: shim.imports(),
    sbcl_host: host.imports(),
    env: {
      // the symbols the runtime leaves undefined (SBCL-Handoff.md 4.2)
      madvise: () => 0,
      list_lisp_threads: () => 0,
      generate_elfcore_obj: () => { throw new Error("generate_elfcore_obj: no core dumps in the browser"); },
    },
  }, runtimeModule, "runtime import");
  const runtime = new WebAssembly.Instance(runtimeModule, imports);
  host.runtime = runtime;
  host.exports = runtime.exports;
  shim.attach(runtime.exports.memory);
  post({ type: "booted", fetchMs: Math.round(performance.now() - t0),
         coreModuleBytes: coreModuleBytes.length });

  // the Lisp run: _start does not return until the Lisp side exits
  try {
    runtime.exports._start();
    post({ type: "exit", code: 0 });
  } catch (e) {
    if (e instanceof ProcExit) return; // proc_exit already posted
    throw e;
  }
}
