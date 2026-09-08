#!/usr/bin/env python3
"""Replace the DEFINE-VOP form named NAME in FILE with the text on stdin
(or delete it with --delete). Usage: replace-vop.py FILE NAME [--delete]"""
import re, sys
path, name = sys.argv[1], sys.argv[2]
s = open(path).read()
m = re.search(r"\n\(define-vop \(%s[ )]" % re.escape(name), s)
if not m:
    sys.exit("no VOP %s in %s" % (name, path))
start = m.start() + 1; depth = 0; i = start
while True:
    c = s[i]
    if c == '(': depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0: break
    i += 1
new = "" if "--delete" in sys.argv else sys.stdin.read().rstrip("\n") + "\n"
s = s[:start] + new + s[i+2:]
open(path, "w").write(s)
