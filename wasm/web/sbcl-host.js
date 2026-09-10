// The sbcl_host contract in JavaScript (Sprint 14): the pieces of the
// Rust host (wasm/crates/sbcl-wasm-host/src/main.rs) a JavaScript host
// provides — the imports of src/runtime/sbcl.wasm's "sbcl_host" module
// and the imports every Lisp module needs (SBCL-Handoff.md section 4).
// Usable in a Web Worker and in Node (wasm/web/node-smoke.mjs).
//
// One SBCLHost wraps one runtime instance; instantiate() is called by
// the runtime itself (the core module at startup, then every module
// compile/load produce), synchronously, and keeps every instance alive:
// their functions sit in the shared table.

/// Offset of the interrupt-pending word in the register area
/// (src/runtime/wasm-lispregs.h); bit 1 requests an interrupt, bit 16
/// is the timer (the runtime owns the other bits).
export const INTERRUPT_PENDING_OFFSET = 456;

/// Parse the "sbcl.core.table" custom section of a Lisp module: two
/// little-endian u32, the table base and the function count.
export function coreTableRange(module) {
  const sections = WebAssembly.Module.customSections(module, "sbcl.core.table");
  if (sections.length === 0) throw new Error("no sbcl.core.table section");
  const view = new DataView(sections[0]);
  return [view.getUint32(0, true), view.getUint32(4, true)];
}

export class SBCLHost {
  /// runtime: the instantiated src/runtime/sbcl.wasm. Its exports this
  /// uses: memory, __indirect_function_table, and the entry points the
  /// Lisp modules import (internal_error, alloc, alloc_list,
  /// pending_interrupt).
  /// onInstantiate(name, base, count): optional logging hook.
  constructor(runtime, { onInstantiate } = {}) {
    this.runtime = runtime;
    this.exports = runtime ? runtime.exports : null;
    this.unwindTag = new WebAssembly.Tag({ parameters: [] });
    this.lispModules = [];
    this.registerArea = null;
    /// the timer deadline in microseconds (set_timer), 0 = none
    this.timerDeadlineUsec = 0n;
    /// an interrupt the page requested (Ctrl-C), delivered with the
    /// timer at the next clock read or poll
    this.interruptRequested = false;
    this.onInstantiate = onInstantiate;
  }

  /// The "sbcl_host" import module of the runtime.
  imports() {
    return {
      instantiate: (bytes, length, registerArea, tableBase) =>
        this.instantiate(bytes, length, registerArea, tableBase),
      set_timer: (usec) => this.setTimer(usec),
      run_process: (spec, length) => this.runProcess(spec, length),
      process_id: () => this.processId(),
    };
  }

  setTimer(usec) {
    // V8 has no host callback while Wasm runs (SBCL-Handoff.md 4.5):
    // the deadline is kept here and delivered (bit 16 of the
    // interrupt-pending word) at the next clock_time_get or
    // poll_oneoff — the runtime reads the clock constantly.
    this.timerDeadlineUsec =
      usec > 0n ? BigInt(Math.round(performance.timeOrigin * 1e6) +
                            performance.now() * 1e3) + BigInt(usec) : 0n;
  }

  /// Deliver the timer (bit 16) and a requested interrupt (bit 1) by
  /// OR-ing them into the interrupt-pending word. Called from the WASI
  /// shim's clock and poll.
  deliverInterrupts(nowUsec) {
    if (this.registerArea === null) return;
    let bits = 0;
    if (this.timerDeadlineUsec !== 0n && nowUsec >= this.timerDeadlineUsec) {
      this.timerDeadlineUsec = 0n;
      bits |= 16;
    }
    if (this.interruptRequested) {
      this.interruptRequested = false;
      bits |= 1;
    }
    if (bits === 0) return;
    const memory = this.exports.memory;
    const offset = this.registerArea + INTERRUPT_PENDING_OFFSET;
    const view = new DataView(memory.buffer, offset, 4);
    view.setUint32(0, view.getUint32(0, true) | bits, true);
  }

  runProcess(spec, length) {
    // WASI preview 1 cannot spawn, and neither can a page: answer -1
    // (SB-EXT:RUN-PROGRAM signals its error on it).
    return -1;
  }

  processId() {
    return 1;
  }

  /// sbcl_host.instantiate: the runtime read a Lisp module into its
  /// linear memory at `bytes`; compile it, grow the shared table, and
  /// instantiate it against the runtime's exports. Synchronous on
  /// purpose: the runtime continues after the call.
  instantiate(bytes, length, registerArea, tableBase) {
    const memory = this.exports.memory;
    // the buffer object changes after memory.grow: always re-read it
    const moduleBytes = new Uint8Array(memory.buffer, bytes, length).slice();
    const module = new WebAssembly.Module(moduleBytes);
    const [base, count] = coreTableRange(module);
    if (base !== tableBase) {
      throw new Error(`the module's functions start at table index ${base}, the runtime expects ${tableBase}`);
    }
    const table = this.exports.__indirect_function_table;
    const needed = base + count;
    if (table.length < needed) table.grow(needed - table.length);

    const imports = {};
    // functions the module imports from the shared table by index (the
    // assembly routines of the core module)
    for (const imp of WebAssembly.Module.imports(module)) {
      if (imp.module === "table") {
        const func = table.get(Number(imp.name));
        if (!func) throw new Error(`table import ${imp.name}: no function there`);
        (imports.table ??= {})[imp.name] = func;
      }
    }
    imports.env = {
      memory,
      __indirect_function_table: table,
      thread: new WebAssembly.Global(
        { value: "i32", mutable: false }, registerArea),
      table_base: new WebAssembly.Global(
        { value: "i32", mutable: false }, base),
      lisp_unwind: this.unwindTag,
      internal_error: this.exports.internal_error,
      alloc: this.exports.alloc,
      alloc_list: this.exports.alloc_list,
      pending_interrupt: this.exports.pending_interrupt,
    };
    const instance = new WebAssembly.Instance(module, imports);
    // kept alive: the functions in the table are the instance's
    this.lispModules.push(instance);
    this.registerArea = registerArea;
    if (this.onInstantiate) this.onInstantiate(moduleBytes.length, base, count);
    return 1;
  }
}

/// Build the import object for the runtime itself: the WASI shim's
/// "wasi_snapshot_preview1", the host's "sbcl_host", and "env" stubs
/// for the symbols the runtime leaves undefined. Any import the two do
/// not cover becomes a trap, as the reference host's
/// define_unknown_imports_as_traps does.
export function runtimeImports(wasiImports, host) {
  const imports = {
    wasi_snapshot_preview1: wasiImports,
    sbcl_host: host.imports(),
    env: {},
  };
  return imports;
}

/// Fill an import object with traps for imports nobody provides.
/// Returns the same object. `module` is the runtime's WebAssembly.Module.
export function trapUnknownImports(imports, module, what = "import") {
  for (const imp of WebAssembly.Module.imports(module)) {
    const namespace = (imports[imp.module] ??= {});
    if (namespace[imp.name] !== undefined) continue;
    if (imp.kind === "function") {
      namespace[imp.name] = (...args) => {
        throw new Error(`sbcl-wasm: unimplemented ${what} ${imp.module}.${imp.name}(${args})`);
      };
    } else if (imp.kind === "global") {
      namespace[imp.name] = new WebAssembly.Global(
        { value: imp.type.endsWith("64") ? "i64" : imp.type, mutable: false },
        0);
    } else if (imp.kind === "memory") {
      namespace[imp.name] = new WebAssembly.Memory({ initial: 1 });
    } else {
      namespace[imp.name] = new WebAssembly.Table({ element: "anyfunc", initial: 1 });
    }
  }
  return imports;
}
