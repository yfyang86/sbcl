# Response to ConsCell's MOP-Coverage.md — go/no-go per gap

Branch: `sbcl-wasm-proposal` (off `wasm-dev`). Evidence gathered on the
port's build before deciding; every GO item is implemented and tested
on the branch, `tests/mop-coverage.impure.lisp` carries the battery.

## Summary

| # | Gap (their numbering) | Decision | State on the branch |
|---|---|---|---|
| 1 | `ensure-class` with programmatic `:direct-slots` | **go** | done: DEFCLASS source syntax accepted beside the canonical plists; their check 11's shape passes |
| 2 | AMOP completeness exports | **go, smaller than reported** | done: `slot-exists-p-using-class` added and exported; `slot-unbound`, `slot-missing`, `no-applicable-method`, `no-next-method` were already re-exported from `sb-mop` (their battery should re-check) |
| 3 | Condition metaobjects | **no-go for now** | read-only condition introspection is upstream design work (SBCL's condition classes are a separate braid); revisit after upstream discussion |
| 4 | `make-method-lambda` customization | **no-go** | a documented SBCL deviation with deep ties to method-function invariants; changing it belongs upstream, not in the port |
| 5 | Error-message divergence native vs wasm | **go, moot** | the divergent messages were the same bad input failing at two points of the old path; with item 1 both hosts accept the input — one code, one behavior |
| 6 | Parity checks (`specializer-*`, `compute-applicable-methods-using-classes`) | **go** | verified on the port and enforced in the battery |

## 1. What the investigation found

- The AMOP-canonical plist form — `(:name y :initargs (:y) :initform 7
  :initfunction <fn> ...)` — **already worked**; the failing input was
  the DEFCLASS *source* syntax `(y :initarg :y :initform 7)`. SBCL's
  `ensure-class` only accepted what its own macro expansion produces.
- The error texts differed because the malformed spec tripped different
  points of the old initargs path (an odd-length plist on wasm, a
  non-keyword key natively) — not a port-specific divergence.

## 2. What the branch changes (all in `src/pcl/` + one export)

1. **`std-class.lisp`**: `canonicalize-direct-slot-spec` rewrites a
   DEFCLASS-source slot spec into the canonical plist (readers/writers
   from `:accessor`/`:reader`/`:writer`, `:initargs` accumulated,
   `:initform` paired with `(constantly <value>)` as the initfunction —
   a programmatic `:initform` is its own value; there is no source form
   to compile); `maybe-canonicalize-direct-slot` passes canonical
   plists and slot-definition metaobjects through (metaobjects are used
   as the direct slots themselves, per AMOP) and is hooked into the
   `std-class`, `condition-class` and `structure-class`
   `shared-initialize :after` methods. Structure classes reject
   metaobject specs (their braid needs plists). Bad specs still signal
   `program-error`, now with clear texts.
2. **`generic-functions.lisp`, `slots.lisp`, `exports.lisp`**:
   `sb-mop:slot-exists-p-using-class` (Closer-mop's extension point,
   sketched by AMOP appendix D) — a generic on `(class object
   slot-name)`, the default method on `class` (built-in classes
   included: `CL:SLOT-EXISTS-P` is defined for any object, and it was a
   direct `find-slot-cell` call before), and `CL:SLOT-EXISTS-P` goes
   through it, so `:around` methods work.
3. **`tests/mop-coverage.impure.lisp`**: their battery as an in-tree
   impure test — the `ensure-class` shapes (source syntax, bare symbol,
   canonical plist, metaobjects, error case), the
   `slot-exists-p-using-class` specialization, the section-2.6 parity
   checks, and the export checks.

## 3. Verification

Level 0 (16) and level 1 (444/444) green; `clos.pure`, `clos.impure`
and the whole `clos-*`/`ctor` set green (the four failures those files
had are the recorded baseline's); the full regression suite —
`doc/wasm-port/baselines/` gains this branch's run. The battery:
`mop-coverage.impure.lisp` 0 unexpected failures — their check 11 can
drop its `KNOWN-SBCL-GAP` tolerance and CI will hold it.

## 4. What we ask back

- Re-run `pnpm run test:mop` on a build from this branch (or its merged
  successor); flip check 11's expectation and add
  `slot-exists-p-using-class` specializations to the battery (the
  in-tree test shows the shape).
- Their item 2 list should be corrected: `slot-unbound`,
  `no-applicable-method` (and `slot-missing`, `no-next-method`) are
  already `sb-mop`-exported on every SBCL ≥ the ones they probe.
- Items 3 and 4 stay open upstream; when upstream moves, the port
  inherits it through the master syncs.
