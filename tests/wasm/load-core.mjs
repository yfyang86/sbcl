// Loads (compiles and instantiates, without running) the core module in
// V8 through Node, against the same stub environment as the Rust loader
// (wasm/crates/sbcl-wasm-test/src/bin/load-core.rs); reports size and
// compile/instantiate times. Needs a Node whose V8 supports tail calls
// and the try_table exception handling:
//   node --experimental-wasm-exnref tests/wasm/load-core.mjs CORE.wasm
import { readFileSync } from "node:fs";

const file = process.argv[2];
if (!file) { console.error("usage: node --experimental-wasm-exnref load-core.mjs CORE.wasm"); process.exit(2); }
const bytes = readFileSync(file);

// the "sbcl.core.table" custom section: base and count, little-endian u32
function tableRange(bytes) {
  const sections = WebAssembly.Module.customSections(mod, "sbcl.core.table");
  if (sections.length === 0) throw new Error("no sbcl.core.table section");
  const v = new DataView(sections[0]);
  return [v.getUint32(0, true), v.getUint32(4, true)];
}

console.log(`size: ${bytes.length} bytes`);
const t0 = performance.now();
const mod = await WebAssembly.compile(bytes);
console.log(`compile: ${((performance.now() - t0) / 1000).toFixed(3)} s`);
const [base, count] = tableRange(bytes);
console.log(`table: base ${base}, ${count} functions`);

const memory = new WebAssembly.Memory({ initial: 1 });
const table = new WebAssembly.Table({ element: "anyfunc", initial: base + count });
const imports = {
  env: {
    memory,
    __indirect_function_table: table,
    thread: new WebAssembly.Global({ value: "i32", mutable: false }, 0),
    table_base: new WebAssembly.Global({ value: "i32", mutable: false }, base),
    lisp_unwind: new WebAssembly.Tag({ parameters: [] }),
    internal_error: () => {},
    alloc: (n) => n,
    alloc_list: (n) => n,
    pending_interrupt: () => {},
  },
};
const t1 = performance.now();
await WebAssembly.instantiate(mod, imports);
console.log(`instantiate: ${((performance.now() - t1) / 1000).toFixed(3)} s`);
const filled = table.get(base) !== null && table.get(base + count - 1) !== null;
console.log(`table filled: ${filled ? "yes" : "no"}`);
if (!filled) process.exit(1);
console.log("load-core: ok");
