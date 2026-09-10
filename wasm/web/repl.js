// The REPL page's half of the worker protocol (worker.js documents the
// other): start the SBCL worker against the files the dev server
// serves, print what it writes, send what is typed.
import { RingStdin } from "./ring.js";

const worker = new Worker("/worker.js", { type: "module" });
const output = document.getElementById("output");
const input = document.getElementById("input");
const promptSpan = document.getElementById("prompt");
const status = document.getElementById("status");

const encoder = new TextEncoder();
// the input ring over the SharedArrayBuffer the worker sent: writes go
// straight into the buffer (the worker's thread is inside Wasm and
// cannot take postMessage)
let stdinRing = null;
let pendingStdin = [];

function append(bytes, className) {
  const text = new TextDecoder().decode(bytes);
  const span = document.createElement("span");
  if (className) span.className = className;
  span.textContent = text;
  output.appendChild(span);
  // keep the tail, and the last line, in view
  output.scrollTop = output.scrollHeight;
  return text;
}

// the echo of what was sent, so the transcript reads like a terminal
function echo(line) {
  const span = document.createElement("span");
  span.className = "echo";
  span.textContent = line;
  output.appendChild(span);
  output.scrollTop = output.scrollHeight;
}

function setStatus(text, cls) {
  status.textContent = text;
  status.className = `status ${cls}`;
}

worker.onmessage = (event) => {
  const m = event.data;
  switch (m.type) {
    case "stdin-ring":
      stdinRing = new RingStdin(m.buffer);
      for (const bytes of pendingStdin.splice(0)) stdinRing.push(bytes);
      break;
    case "booted":
      document.getElementById("version").textContent =
        `(core module ${Math.round(m.coreModuleBytes / 1e6)} MB)`;
      break;
    case "stdout": {
      const text = append(m.bytes);
      const line = text.split("\n").pop();
      // SBCL's prompt is a "* " at the start of a line
      if (/^\*\s?$/.test(line) || /^\*[^\n]*$/.test(line)) promptSpan.textContent = "";
      break;
    }
    case "stderr": append(m.bytes, "stderr"); break;
    case "startupMs":
      setStatus(`running (${(m.startupMs / 1000).toFixed(1)} s to REPL)`, "running");
      input.focus();
      break;
    case "exit":
      setStatus(`exited (${m.code})`, "exited");
      input.disabled = true;
      break;
    case "error":
      append(new TextEncoder().encode(`\n[host error] ${m.message}\n${m.stack ?? ""}\n`), "stderr");
      setStatus("error", "error");
      break;
  }
};

// ?load=<url>[,<url>...]: files fetched into the worker's in-memory
// file system before SBCL starts (the Playwright suite's test data).
const loadUrls = (new URLSearchParams(location.search).getAll("load")
                  .flatMap((s) => s.split(","))).filter(Boolean);
const files = await Promise.all(loadUrls.map(async (url) => ({
  path: `/${url.split("/").pop()}`,
  bytes: new Uint8Array(await (await fetch(url)).arrayBuffer()),
})));

worker.postMessage({
  type: "start",
  runtimeUrl: "/sbcl.wasm",
  coreUrl: "/sbcl.core",
  coreModuleUrl: "/sbcl-core.wasm",
  args: ["--noinform"],
  dynamicSpaceSize: "512MB",
  files,
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.ctrlKey && !event.shiftKey && !event.metaKey) {
    event.preventDefault();
    const line = input.value + "\n";
    echo(input.value + "\n");
    const bytes = encoder.encode(line);
    if (stdinRing) stdinRing.push(bytes);
    else { pendingStdin.push(bytes); worker.postMessage({ type: "stdin", bytes }); }
    input.value = "";
    input.style.height = "auto";
  } else if (event.key === "c" && event.ctrlKey && !event.shiftKey) {
    event.preventDefault();
    worker.postMessage({ type: "interrupt" });
  }
});
input.addEventListener("input", () => {
  input.style.height = "auto";
  input.style.height = `${input.scrollHeight}px`;
});
window.addEventListener("beforeunload", () => worker.terminate());
