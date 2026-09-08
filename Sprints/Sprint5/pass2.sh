#!/bin/sh
# Run crossbuild pass 2 (cross-compile the tree with the real dumper, then
# genesis: cold core and core module) for the wasm target. Needs pass-1.
cd "$(dirname "$0")/../.."
rm -rf obj/xbuild/wasm/from-xc obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm
sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
  wasm < crossbuild-runner/pass-2.lisp > Sprints/Sprint5/pass-2.log 2>&1
code=$?
echo "pass-2 exit=$code" >> Sprints/Sprint5/pass-2.log
echo "pass-2 exit=$code"
exit $code
