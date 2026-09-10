#!/bin/sh
# Sprint 14 user-acceptance test. Exit criteria from
# doc/wasm-port/04-sprints.md "Sprint 14: browser host":
#   - the REPL page runs in Chromium and Firefox
#   - the Playwright suite (boot, REPL round trip, compile of a
#     function, a subset of pure tests executed in the worker)
#   - the sb-js contrib skeleton (js_call)
#   - startup time and core module size recorded
#   - nothing regressed: the smoke test, sb-js, the suites' baselines
#     unchanged (levels 0/1 and the regression suite run by
#     build-wasm.sh, not here; the compiler backend is untouched)
# UAT_FAST=1 skips the checks that need the browser tooling installed.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== the browser host pieces"
check "the host modules exist" "test -f wasm/web/sbcl-host.js -a -f wasm/web/wasi.js -a -f wasm/web/worker.js -a -f wasm/web/ring.js"
check "the REPL page exists" "test -f wasm/web/index.html -a -f wasm/web/repl.js -a -f wasm/web/repl.css"
check "the dev server exists" "test -f wasm/web/serve.mjs"
check "the Playwright suite exists" "test -f tests/wasm/web/repl.spec.mjs -a -f tests/wasm/web/playwright.config.mjs"
check "the pure checks exist" "test -f tests/wasm/web/data/pure-checks.lisp"
check "the build products exist" "test -s src/runtime/sbcl.wasm -a -s output/sbcl.core -a -s output/sbcl-core.wasm"

echo "== the Node smoke run (the same host code, no browser)"
if node --experimental-wasm-exnref wasm/web/node-smoke.mjs output/sbcl.core output/sbcl-core.wasm /dev/null > Sprints/Sprint14/node-smoke.txt 2>&1; then
  : # an empty stdin ends the REPL cleanly
fi
if [ "${UAT_FAST:-0}" != 1 ]; then
  printf '(print (+ 1 2))\n(sb-ext:exit)\n' > /tmp/s14-smoke-in.lisp
  if node --experimental-wasm-exnref wasm/web/node-smoke.mjs output/sbcl.core output/sbcl-core.wasm /tmp/s14-smoke-in.lisp > Sprints/Sprint14/node-smoke.txt 2>&1 \
     && grep -q '^3$' Sprints/Sprint14/node-smoke.txt; then
    ok "the Node smoke run evaluates (print (+ 1 2)) -> 3 ($(grep -o '# exit 0 in [0-9]* ms' Sprints/Sprint14/node-smoke.txt))"
  else
    bad "the Node smoke run (see Sprints/Sprint14/node-smoke.txt)"
  fi
fi

echo "== the browser suite (Chromium and Firefox)"
if [ "${UAT_FAST:-0}" != 1 ] && have node && [ -x tests/wasm/web/node_modules/.bin/playwright ]; then
  node wasm/web/serve.mjs > Sprints/Sprint14/serve.log 2>&1 &
  server=$!
  sleep 1
  if curl -fs http://127.0.0.1:8625/ >/dev/null 2>&1; then ok "the dev server serves the page (COOP/COEP: $(curl -s -D- -o /dev/null http://127.0.0.1:8625/ | grep -ci 'cross-origin') headers)"; else bad "the dev server (see Sprints/Sprint14/serve.log)"; fi
  (cd tests/wasm/web && PLAYWRIGHT_FIREFOX=1 ./node_modules/.bin/playwright test -c playwright.config.mjs > ../../../Sprints/Sprint14/playwright.txt 2>&1)
  if grep -q 'passed' Sprints/Sprint14/playwright.txt && ! grep -q 'failed' Sprints/Sprint14/playwright.txt; then
    ok "the Playwright suite in Chromium and Firefox: $(grep -E '[0-9]+ passed' Sprints/Sprint14/playwright.txt)"
  else
    bad "the Playwright suite (see Sprints/Sprint14/playwright.txt)"
  fi
  kill $server 2>/dev/null
else
  echo "SKIP  the browser suite (UAT_FAST or playwright not installed: cd tests/wasm/web && npm install @playwright/test && npx playwright install firefox)"
fi

echo "== the sb-js skeleton"
check "sb-js built" "test -s obj/sbcl-home/contrib/sb-js.fasl"
if SBCL_HOME=$PWD/obj/sbcl-home tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core output/sbcl.core \
     --noinform --no-sysinit --no-userinit --disable-debugger \
     --eval '(require :sb-js)' \
     --eval '(handler-case (progn (sb-js:js-call "alert") (error "no error")) (sb-js:js-call-error () :caught))' \
     --eval '(when (eq (sb-ext:exit-code) 0) (print :ok))' --quit 2>/dev/null | grep -q ':OK'; then
  ok "sb-js loads and js-call signals its error"
else
  # exit-code may not exist as a settable on this core; the simpler form
  if SBCL_HOME=$PWD/obj/sbcl-home tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core output/sbcl.core \
       --noinform --no-sysinit --no-userinit --disable-debugger \
       --eval '(require :sb-js)' \
       --eval '(print (handler-case (progn (sb-js:js-call "alert") :no-error) (sb-js:js-call-error () :caught)))' --quit 2>/dev/null | grep -q 'CAUGHT'; then
    ok "sb-js loads and js-call signals its error"
  else
    bad "sb-js (require or js-call)"
  fi
fi

echo "== measurements (the exit criterion asks for them recorded)"
echo "core module: $(ls -l output/sbcl-core.wasm 2>/dev/null | awk '{print $5}') bytes"
echo "runtime:     $(ls -l src/runtime/sbcl.wasm 2>/dev/null | awk '{print $5}') bytes"
echo "core:        $(ls -l output/sbcl.core 2>/dev/null | awk '{print $5}') bytes"
grep -o 'startup: [0-9.]* s' Sprints/Sprint14/playwright.txt 2>/dev/null | sed 's/^/REPL /'

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
