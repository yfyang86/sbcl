#!/bin/sh
# Rerun genesis alone (as Sprints/Sprint5/genesis-only.sh) and also write
# the map file obj/xbuild/wasm.map: addresses of every fdefn, symbol and
# code component, for decoding registers in runtime error reports.
cd "$(dirname "$0")/../.."
sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
  wasm < Sprints/Sprint6/genesis-map.lisp > Sprints/Sprint6/genesis-map.log 2>&1
code=$?
echo "genesis exit=$code" >> Sprints/Sprint6/genesis-map.log
echo "genesis exit=$code"
exit $code
