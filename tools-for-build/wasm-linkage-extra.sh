#!/bin/sh
# Print the linkage-table entries ("index kind name") to add to the core's
# symbol list SYMBOLS for code loaded at run time: every foreign name the
# Lisp sources reference (extern-alien, define-alien-routine,
# define-alien-variable) or tools-for-build/wasm-linkage-extra.txt lists,
# that the runtime's objects define or import (llvm-nm), and that the list
# does not have yet. Functions get kind "function", everything else "data".
#   tools-for-build/wasm-linkage-extra.sh obj/xbuild/wasm-core.wasm.symbols
set -e
export LC_ALL=C
cd "$(dirname "$0")/.."
. tools-for-build/wasm-env.sh
symbols=$1
nm="$WASI_SDK/bin/llvm-nm"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# names the Lisp sources mention
{ grep -rhoE 'extern-alien "[A-Za-z_0-9]+"|alien-routine \(?"[A-Za-z_0-9]+"|alien-variable \(?"[A-Za-z_0-9]+"' \
      src/code src/pcl src/compiler/generic src/compiler/*.lisp contrib 2>/dev/null \
      | grep -oE '"[A-Za-z_0-9]+"' | tr -d '"'
  grep -v '^#' tools-for-build/wasm-linkage-extra.txt 2>/dev/null || true
} | sort -u > "$tmp/wanted"
grep -v '^#' tools-for-build/wasm-linkage-extra.txt 2>/dev/null | sort -u > "$tmp/listed" || true
# what the runtime defines (functions T/t/W/w, data D/B/R/C and their
# lowercase) or only imports from libc (U), minus the table itself; a
# definition wins over a reference
ls src/runtime/*.o | grep -v wasm-linkage-table.o | xargs "$nm" 2>/dev/null \
    | awk 'NF==3 || NF==2 {print $NF, $(NF-1)}' > "$tmp/nm"
awk '$2 ~ /^[TtWw]$/ {print $1}' "$tmp/nm" | sort -u > "$tmp/functions"
awk '$2 ~ /^[DdBbRrCc]$/ {print $1}' "$tmp/nm" | sort -u > "$tmp/data"
awk '$2 == "U" {print $1}' "$tmp/nm" | sort -u > "$tmp/imported"
awk '{print $3}' "$symbols" | sort -u > "$tmp/present"
next=$(awk 'END {print $1 + 1}' "$symbols")
while read -r name; do
    grep -qx "$name" "$tmp/present" && continue
    if grep -qx "$name" "$tmp/functions"; then kind=function
    elif grep -qx "$name" "$tmp/data"; then kind=data
    elif grep -qx "$name" "$tmp/imported"; then
        # a libc symbol: functions, except the few data ones
        case "$name" in errno|environ|stdin|stdout|stderr) continue ;; esac
        kind=function
    elif grep -qx "$name" "$tmp/listed"; then
        # listed in wasm-linkage-extra.txt but not referenced by the runtime:
        # a libc function (the linker resolves it), or an import the host
        # answers with a trap
        kind=function
    else continue
    fi
    echo "$next $kind $name"
    next=$((next + 1))
done < "$tmp/wanted"
