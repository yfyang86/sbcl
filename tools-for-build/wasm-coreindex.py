#!/usr/bin/env python3
"""Map Wasm function/table indices of the core module back to Lisp names.

Also: --annotate reads text on stdin (an SBCL_WASM_TRACE_ENTRIES trace, a
backtrace) and appends the Lisp name after every "table N" and "func N"
occurrence, using the module's name section (XEPs are named after their
entry, other environments lambdaN of the entry before them).

Reads obj/xbuild/wasm.core (simple-fun self slots hold table indices) and
the genesis map obj/xbuild/wasm.map (fdefn -> function address -> name).
Usage: coreindex.py [--core C] [--map M] [--module M] [--annotate] (N | func:N | table:N | addr:HEX | off:HEX)...
A bare N or func:N is a core-module function index (as in a Wasmtime
backtrace: the first 4 are the runtime imports, so func:N is table index
4096+N-4); table:N a table index; addr:HEX a heap address (which code
object and function it falls in); header:HEX the boxed constants of the
code object holding the function at that address; off:HEX a code offset in the module
(as in a Wasmtime backtrace) mapped through the module's code section
(--module M, default obj/xbuild/wasm-core.wasm)."""
import struct, sys, re
core, mapf, modf = 'obj/xbuild/wasm.core', 'obj/xbuild/wasm.map', 'obj/xbuild/wasm-core.wasm'
args = sys.argv[1:]
annotate = False
while args and args[0].startswith('--'):
    if args[0] == '--core': core = args[1]; args = args[2:]
    elif args[0] == '--map': mapf = args[1]; args = args[2:]
    elif args[0] == '--module': modf = args[1]; args = args[2:]
    elif args[0] == '--annotate': annotate = True; args = args[1:]
    else: sys.exit("unknown option " + args[0])
_bodies = None
def bodies():
    "(start, end) module offsets of each defined function's body, in order"
    global _bodies
    if _bodies is not None: return _bodies
    b = open(modf, 'rb').read()
    def uleb(pos):
        r, sh = 0, 0
        while True:
            x = b[pos]; pos += 1
            r |= (x & 0x7F) << sh; sh += 7
            if not x & 0x80: return r, pos
    pos = 8; _bodies = []
    while pos < len(b):
        sid = b[pos]; size, p = uleb(pos + 1); end = p + size
        if sid == 10:
            n, p = uleb(p)
            for i in range(n):
                sz, p = uleb(p)
                _bodies.append((p, p + sz)); p += sz
            break
        pos = end
    return _bodies
PAGE = 32768; TABLE_BASE = 4096; N_IMPORTS = 4
data = open(core, 'rb').read()
w = lambda off: struct.unpack_from('<I', data, off)[0]
assert w(0) == 0x5342434C, "not a core"
spaces = []
pos = 4
while pos < 100000:
    t, n = w(pos), w(pos + 4)
    if t == 3861:
        for i in range((n - 2) // 5):
            b = pos + 8 + i * 20
            spaces.append(tuple(w(b + 4 * j) for j in range(5)))
    if n == 0 or t == 3865: break
    pos += 4 * n
def rd(addr):
    for (_, nw, pg, base, npages) in spaces:
        if base <= addr < base + npages * PAGE:
            return w((1 + pg) * PAGE + (addr - base))
    raise KeyError(hex(addr))
# map: "FDEFN FUNCTION NAME" lines
funs = {}   # function descriptor -> name
for line in open(mapf, errors='replace'):
    m = re.match(r'^([0-9A-F]{10}) ([0-9A-F]{10})  (.*)$', line)
    if m:
        f = int(m.group(2), 16)
        if f & 7 == 5 and f not in funs:
            funs[f] = m.group(3).strip()
by_table = {}
for f, name in funs.items():
    try:
        hdr = rd(f - 5)
        if hdr & 0xFF == 0x3A:
            by_table[rd(f - 5 + 4)] = (name, f)
    except KeyError:
        pass
_names = None
def module_names():
    "function index -> name from the module's name section"
    global _names
    if _names is not None: return _names
    b = open(modf, 'rb').read()
    def uleb(pos):
        r, sh = 0, 0
        while True:
            x = b[pos]; pos += 1
            r |= (x & 0x7F) << sh; sh += 7
            if not x & 0x80: return r, pos
    pos = 8; _names = {}
    while pos < len(b):
        sid = b[pos]; size, p = uleb(pos + 1); end = p + size
        if sid == 0:
            n, q = uleb(p); nm = b[q:q + n]; q += n
            if nm == b'name':
                while q < end:
                    sub = b[q]; ssz, q2 = uleb(q + 1); send = q2 + ssz
                    if sub == 1:
                        cnt, q3 = uleb(q2)
                        for i in range(cnt):
                            idx, q3 = uleb(q3); ln, q3 = uleb(q3)
                            _names[idx] = b[q3:q3 + ln].decode('utf8', 'replace'); q3 += ln
                    q = send
        pos = end
    return _names
def table_name(t):
    "a readable name for table index T"
    hit = by_table.get(t)
    if hit: return hit[0]
    nm = module_names().get(t - TABLE_BASE + N_IMPORTS)
    if nm and not nm.startswith('lambda') and nm != 'top level form': return nm
    below = [k for k in by_table if k < t]
    if below:
        k = max(below)
        return "%s of %s" % (nm or "+%d" % (t - k), by_table[k][0])
    return nm or "?"
def lisp_string(v):
    hdr = rd(v - 7); n = rd(v - 3) >> 2
    wt = hdr & 0xFF
    if wt == 0xD6:
        return ''.join(chr(rd(v - 7 + 8 + (i // 4) * 4) >> (8 * (i % 4)) & 0xFF) for i in range(n))
    if wt == 0xDA:
        return ''.join(chr(rd(v - 7 + 8 + 4 * i)) for i in range(n))
    return "#<string?>"
fdefn_names = {}
def describe(v):
    "a short description of a boxed constant word"
    if not fdefn_names:
        for line in open(mapf, errors='replace'):
            m = re.match(r'^([0-9A-F]{10}) ([0-9A-F]{10})  (.*)$', line)
            if m: fdefn_names[int(m.group(1), 16)] = m.group(3).strip()
    if v in fdefn_names: return "fdefn " + fdefn_names[v]
    if v == 0x1100033: return "NIL"
    if v & 7 == 7:
        try:
            wt = rd(v - 7) & 0xFF
            if wt == 0x26: return "symbol " + lisp_string(rd(v - 7 + 16))
            if wt == 0x56: return "fdefn (not in map)"
            if wt == 0x2E: return "code"
            if wt in (0xD6, 0xDA): return '"%s"' % lisp_string(v)
            return "other widetag %#x" % wt
        except KeyError: return "?"
    if v & 7 == 3: return "list"
    if v & 7 == 1: return "instance"
    if v & 7 == 5: return "function"
    if v & 3 == 0: return "fixnum %d" % (v >> 2)
    return ""
def show_header(fun):
    "the boxed constants of the code object holding function FUN (a descriptor)"
    hdr = rd(fun - 5)
    code = fun - 5 - (hdr >> 8) * 4
    boxed = rd(code + 4) & 0xFFFF
    print("code object %#x, %d boxed words; word N is at offset N*4-7 from CODE" % (code, boxed // 4))
    for i in range(2, boxed // 4):
        v = rd(code + 4 * i)
        print("%3d (offset %4d) %#010x %s" % (i, i * 4 - 7, v, describe(v)))
def show_table(t):
    hit = by_table.get(t)
    if hit:
        print("table %d: %s (function %#x)" % (t, hit[0], hit[1]))
    else:
        # nearest named function below (same component's other entries, or a local function)
        below = [k for k in by_table if k < t]
        if below:
            k = max(below)
            print("table %d: no fdefn; nearest named entry below is table %d: %s (+%d)" % (t, k, by_table[k][0], t - k))
        else:
            print("table %d: unknown" % t)
if annotate:
    import re as _re
    def repl(m):
        n = int(m.group(2))
        t = n if m.group(1) == 'table' else TABLE_BASE + n - N_IMPORTS
        return "%s %d [%s]" % (m.group(1), n, table_name(t))
    for line in sys.stdin:
        sys.stdout.write(_re.sub(r'\b(table|func) (\d+)', repl, line))
    sys.exit()
for a in args:
    if a.startswith('table:'): show_table(int(a[6:]))
    elif a.startswith('off:'):
        off = int(a[4:], 16)
        for i, (st, en) in enumerate(bodies()):
            if st <= off < en:
                print("offset %#x: function %d (+%d)" % (off, i + N_IMPORTS, off - st), end='; ')
                show_table(TABLE_BASE + i)
                break
        else:
            print("offset %#x: not in a function body" % off)
    elif a.startswith('header:'):
        show_header(int(a[7:], 16))
    elif a.startswith('addr:'):
        addr = int(a[5:], 16)
        cands = [(f, n) for f, n in funs.items() if f <= addr]
        if cands:
            f, n = max(cands)
            print("addr %#x: after %s (function %#x, +%d)" % (addr, n, f, addr - f))
    else:
        n = int(a[5:] if a.startswith('func:') else a)
        show_table(TABLE_BASE + n - N_IMPORTS)
