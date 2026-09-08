#!/bin/sh
# Run make-host-1 for the wasm target and show the first failure, if any.
cd "$(dirname "$0")/../.."
sh make-host-1.sh > Sprints/Sprint2/make-host-1.log 2>&1; code=$?
echo "exit=$code" >> Sprints/Sprint2/make-host-1.log
if [ $code -ne 0 ]; then
  grep -a -n -m1 -B14 -A10 "Unhandled\|caught ERROR" Sprints/Sprint2/make-host-1.log | grep -av "^[0-9]*-[0-9]*: (HOST-SB" | head -45
fi
echo "make-host-1 exit=$code"
