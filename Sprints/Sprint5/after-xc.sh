#!/bin/sh
# Cross-compile the whole tree with the wasm backend (tolerant placeholders)
# into obj/xbuild/wasm/after-xc.core, from a fresh host SBCL. Needs pass-1.
cd "$(dirname "$0")/../.."
rm -rf obj/xbuild/wasm/from-xc obj/xbuild/wasm/after-xc.core
sbcl --noinform --disable-debugger --no-userinit --no-sysinit \
  --load tests/wasm/make-after-xc.lisp > Sprints/Sprint5/after-xc.log 2>&1
code=$?
echo "after-xc exit=$code" >> Sprints/Sprint5/after-xc.log
echo "after-xc exit=$code"
