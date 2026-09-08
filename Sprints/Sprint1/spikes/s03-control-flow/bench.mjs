import { readFileSync } from "node:fs";
const N = { fib: 32, tak: [24, 16, 8], loop: 50_000_000, scan: 60_000 };
async function run(name) {
  const bytes = readFileSync(new URL(`./${name}.wasm`, import.meta.url));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const e = instance.exports;
  e.fill(N.scan);
  const time = (f) => { f(); const t = performance.now(); const r = f(); return [r, +(performance.now() - t).toFixed(1)]; };
  return {
    fib: time(() => e.fib(N.fib)),
    tak: time(() => e.tak(...N.tak)),
    loop: time(() => e.loop(N.loop)),
    scan: time(() => { let s = 0; for (let i = 0; i < 2000; i++) s += e.scan(N.scan); return s; }),
  };
}
const s = await run("structured"), d = await run("dispatch");
const out = { node: process.version };
for (const k of Object.keys(s)) {
  if (s[k][0] !== d[k][0]) throw new Error(`result mismatch ${k}: ${s[k][0]} vs ${d[k][0]}`);
  out[k] = { result: s[k][0], structured_ms: s[k][1], dispatch_ms: d[k][1], ratio: +(d[k][1] / s[k][1]).toFixed(2) };
}
console.log(JSON.stringify(out, null, 1));
