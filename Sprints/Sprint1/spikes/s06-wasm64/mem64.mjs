import { readFileSync } from "node:fs";
const bytes = readFileSync(new URL("./mem64.wasm", import.meta.url));
try {
  const { instance } = await WebAssembly.instantiate(bytes, {});
  console.log("node", process.version, "memory64 probe:", instance.exports.probe().toString(16), "pages:", instance.exports.size_pages());
} catch (e) { console.log("node", process.version, "memory64 FAILED:", String(e).slice(0, 200)); }
