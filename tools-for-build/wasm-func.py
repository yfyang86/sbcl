#!/usr/bin/env python3
"""Print one function of the core module as text, with binary offsets.

Usage: wasmfunc.py [--module M] (func:N | off:HEX) [context-lines]
func:N is a module function index (Wasmtime backtrace numbering, the first
4 being the runtime imports); off:HEX a module code offset: the function
containing it is printed and the instruction at the offset is marked.
The body is wrapped in a throw-away module that shares the real module's
type section, so wasm-tools can print it without loading 38 MB."""
import sys, subprocess, struct
modf = 'obj/xbuild/wasm-core.wasm'
args = sys.argv[1:]
if args and args[0] == '--module': modf = args[1]; args = args[2:]
N_IMPORTS = 4
b = open(modf, 'rb').read()
def uleb(pos):
    r, sh = 0, 0
    while True:
        x = b[pos]; pos += 1
        r |= (x & 0x7F) << sh; sh += 7
        if not x & 0x80: return r, pos
def enc(n):
    out = bytearray()
    while True:
        x = n & 0x7F; n >>= 7
        if n: out.append(x | 0x80)
        else: out.append(x); return bytes(out)
pos = 8; type_section = b''; func_types = []; bodies = []
while pos < len(b):
    sid = b[pos]; size, p = uleb(pos + 1); end = p + size
    if sid == 1: type_section = b[pos:end]
    elif sid == 3:
        n, p2 = uleb(p)
        for i in range(n):
            t, p2 = uleb(p2); func_types.append(t)
    elif sid == 10:
        n, p2 = uleb(p)
        for i in range(n):
            sz, p2 = uleb(p2); bodies.append((p2, p2 + sz)); p2 += sz
        break
    pos = end
target = None
sel = args[0]
if sel.startswith('off:'):
    off = int(sel[4:], 16)
    for i, (st, en) in enumerate(bodies):
        if st <= off < en: fi = i; target = off - st; break
    else: sys.exit("offset not in a function body")
else:
    fi = int(sel.split(':')[-1]) - N_IMPORTS
context = int(args[1]) if len(args) > 1 else 40
st, en = bodies[fi]; body = b[st:en]
code = enc(1) + enc(len(body)) + body
funcs = enc(1) + enc(func_types[fi])
mini = b'\0asm\x01\0\0\0' + type_section + bytes([3]) + enc(len(funcs)) + funcs + bytes([10]) + enc(len(code)) + code
body_start_mini = len(mini) - len(body)
text = subprocess.run(['wasm-tools', 'print', '-p', '-'], input=mini, capture_output=True).stdout.decode()
print("function %d (table %d), body %d bytes at %#x..%#x" % (fi + N_IMPORTS, 4096 + fi, len(body), st, en))
lines = text.splitlines()
if target is None:
    print("\n".join(lines)); sys.exit()
want = body_start_mini + target
import re
hit = None
for i, l in enumerate(lines):
    m = re.search(r'\(;@([0-9a-f]+)\s*;\)', l)
    if m and int(m.group(1), 16) <= want: hit = i
for i in range(max(0, (hit or 0) - context), min(len(lines), (hit or 0) + 8)):
    print(("==> " if i == hit else "    ") + lines[i])
