#!/bin/sh
# Regression check: the generic-file edits made for the wasm target must
# not break make-host-1 for the primary native target. Reconfigures for
# x86-64, runs make-host-1, then restores the wasm configuration.
cd "$(dirname "$0")/../.."
XC='sbcl --dynamic-space-size 2GB --lose-on-corruption --disable-ldb --disable-debugger'
sh make-config.sh --arch=x86-64 --xc-host="$XC" > Sprints/Sprint2/x86-64-make-config.log 2>&1
sh make-host-1.sh > Sprints/Sprint2/x86-64-make-host-1.log 2>&1; code=$?
echo "x86-64 make-host-1 exit=$code"
sh make-config.sh --arch=wasm --xc-host="$XC" > Sprints/Sprint2/make-config.log 2>&1
exit $code
