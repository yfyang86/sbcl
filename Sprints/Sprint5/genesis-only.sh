#!/bin/sh
# Rerun genesis on the pass-2 fasls (about three minutes); see genesis-only.lisp.
cd "$(dirname "$0")/../.."
rm -f obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm
sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
  wasm < Sprints/Sprint5/genesis-only.lisp > Sprints/Sprint5/genesis-only.log 2>&1
code=$?
echo "genesis exit=$code" >> Sprints/Sprint5/genesis-only.log
echo "genesis exit=$code"
exit $code
