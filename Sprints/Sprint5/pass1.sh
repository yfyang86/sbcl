#!/bin/sh
# Run crossbuild pass 1 (make-host-1 for the wasm target) and record the log.
cd "$(dirname "$0")/../.."
sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
  wasm wasm "(:UNIX :LINUX :ELF :OS-PROVIDES-CLOCK-GETTIME :LITTLE-ENDIAN (NOT :OS-PROVIDES-DLOPEN))" \
  < crossbuild-runner/pass-1.lisp > Sprints/Sprint5/crossbuild-pass-1.log 2>&1
code=$?
echo "pass-1 exit=$code" >> Sprints/Sprint5/crossbuild-pass-1.log
echo "pass-1 exit=$code"
exit $code
