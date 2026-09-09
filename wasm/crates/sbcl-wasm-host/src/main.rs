//! `sbcl-wasm`: the host for the SBCL WebAssembly port (v0.1, plan Sprint 5
//! "runtime port"; doc/wasm-port/02-design.md, 2.2 and 2.9).
//!
//! It runs `src/runtime/sbcl.wasm` as a WASI command with the engine
//! features the port needs (exceptions, tail calls, multi-value, bulk
//! memory) and a large native stack, and provides the one import the
//! runtime needs beyond WASI:
//!
//!   sbcl_host.instantiate(bytes, length, register_area, table_base) -> ok
//!
//! which compiles the Lisp module whose bytes the runtime read into its
//! linear memory (the core module genesis writes next to the core file),
//! grows the runtime's exported function table to hold the module's
//! functions at `table_base` (checked against the module's
//! `sbcl.core.table` custom section), and instantiates the module against
//! the runtime's memory and table, a `thread` global holding
//! `register_area`, a `table_base` global, the shared `lisp_unwind` tag
//! and the runtime's exported entry points `internal_error`, `alloc`,
//! `alloc_list` and `pending_interrupt`.
//!
//! Symbols the runtime leaves undefined (`env.*` imports: the parts of the
//! C library WASI does not have, and the linkage-table names the core
//! module mentions but the runtime does not define) are bound to traps,
//! so calling one aborts with a message naming it instead of failing at
//! link time.
//!
//! Ctrl-C: the first press sets the interrupt-pending word of the register
//! area (LISP_REGISTER_AREA_INTERRUPT_PENDING in wasm-lispregs.h), which
//! the runtime's `pending_interrupt` entry point services; a second press
//! terminates the process. The signal is delivered to running Wasm code
//! through Wasmtime's epoch interruption.
//!
//! Compiled modules are cached in Wasmtime's default cache directory, so
//! the 38 MB core module compiles once per change rather than on every
//! start (the cache is keyed on the module bytes).
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use wasmtime::*;
use wasmtime_wasi::p1::WasiP1Ctx;
use wasmtime_wasi::WasiCtxBuilder;

/// Error context helpers over Wasmtime's error type.
trait Ctx<T> {
    fn ctx(self, msg: &str) -> Result<T>;
    fn ctxf(self, msg: impl FnOnce() -> String) -> Result<T>;
}
impl<T> Ctx<T> for Result<T> {
    fn ctx(self, msg: &str) -> Result<T> {
        self.map_err(|e| e.context(msg.to_string()))
    }
    fn ctxf(self, msg: impl FnOnce() -> String) -> Result<T> {
        self.map_err(|e| e.context(msg()))
    }
}
impl<T> Ctx<T> for Option<T> {
    fn ctx(self, msg: &str) -> Result<T> {
        self.ok_or_else(|| Error::msg(msg.to_string()))
    }
    fn ctxf(self, msg: impl FnOnce() -> String) -> Result<T> {
        self.ok_or_else(|| Error::msg(msg()))
    }
}

/// Register names of the Lisp register file (src/runtime/wasm-lispregs.h),
/// for the dump printed when a run traps.
const REGISTER_NAMES: [&str; 30] = [
    "NARGS", "CSP", "CFP", "OCFP", "NFP", "NSP", "LEXENV", "CODE", "LIP", "CFUNC", "A0", "A1", "A2", "A3",
    "L0", "L1", "L2", "L3", "L4", "L5", "NL0", "NL1", "NL2", "NL3", "NL4", "NL5", "NL6", "NL7", "TMP", "RA",
];

/// Print the Lisp register file after a trap, when a Lisp module is loaded.
fn dump_registers(store: &mut Store<State>) {
    let (Some(area), Some(mem)) = (store.data().register_area, store.data().memory) else {
        return;
    };
    let data = mem.data(&*store);
    eprintln!("sbcl-wasm: Lisp registers at the trap:");
    for (i, name) in REGISTER_NAMES.iter().enumerate() {
        let off = area as usize + 4 * i;
        let v = data.get(off..off + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap())).unwrap_or(0);
        eprint!("{}{} {:#x}", if i % 6 == 0 { "\n   " } else { " " }, name, v);
    }
    eprintln!();
    // the frames at OCFP and CFP (the first 12 words of each)
    let word = |off: usize| data.get(off..off + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap()));
    for (label, reg) in [("OCFP", 3usize), ("CFP", 2usize)] {
        if let Some(base) = word(area as usize + 4 * reg) {
            eprint!("   frame at {label} {base:#x}:");
            for i in 0..12 {
                match word(base as usize + 4 * i) {
                    Some(v) => eprint!(" {v:#x}"),
                    None => break,
                }
            }
            eprintln!();
        }
    }
}

/// Byte offset of the interrupt-pending word in the register area
/// (src/runtime/wasm-lispregs.h).
const REGISTER_AREA_INTERRUPT_PENDING: u32 = 456;

pub fn engine_config() -> Config {
    let mut c = Config::new();
    c.wasm_exceptions(true);
    c.wasm_tail_call(true);
    c.wasm_multi_value(true);
    c.wasm_bulk_memory(true);
    c.wasm_reference_types(true);
    c.max_wasm_stack(64 << 20);
    c.async_stack_size(128 << 20); // must exceed max_wasm_stack
    c.epoch_interruption(true);
    match Cache::from_file(None) {
        Ok(cache) => {
            c.cache(Some(cache));
        }
        Err(e) => eprintln!("sbcl-wasm: no module cache: {e}"),
    }
    c
}

struct State {
    wasi: WasiP1Ctx,
    /// the register area of the (single) Lisp thread, once a module is loaded
    register_area: Option<u32>,
    /// the runtime's linear memory, once a module is loaded
    memory: Option<Memory>,
    /// the `lisp_unwind` tag shared by every Lisp module
    unwind_tag: Option<Tag>,
    /// the Lisp modules, kept alive for the life of the store
    lisp_modules: Vec<Instance>,
}

/// The (base, count) pair of a Lisp module's "sbcl.core.table" custom section.
fn table_range(bytes: &[u8]) -> Option<(u32, u32)> {
    fn uleb(bytes: &[u8], pos: &mut usize) -> Option<u64> {
        let (mut result, mut shift) = (0u64, 0);
        loop {
            let b = *bytes.get(*pos)?;
            *pos += 1;
            result |= ((b & 0x7F) as u64) << shift;
            shift += 7;
            if b & 0x80 == 0 {
                return Some(result);
            }
        }
    }
    let mut pos = 8; // magic and version
    while pos < bytes.len() {
        let id = bytes[pos];
        pos += 1;
        let size = uleb(bytes, &mut pos)? as usize;
        let end = pos + size;
        if id == 0 {
            let mut p = pos;
            let n = uleb(bytes, &mut p)? as usize;
            let name = std::str::from_utf8(bytes.get(p..p + n)?).unwrap_or("");
            p += n;
            if name == "sbcl.core.table" && end - p >= 8 {
                let base = u32::from_le_bytes(bytes[p..p + 4].try_into().unwrap());
                let count = u32::from_le_bytes(bytes[p + 4..p + 8].try_into().unwrap());
                return Some((base, count));
            }
        }
        pos = end;
    }
    None
}

fn runtime_export<T: Into<Extern> + Clone>(
    caller: &mut Caller<'_, State>,
    name: &str,
    pick: impl Fn(Extern) -> Option<T>,
) -> Result<T> {
    let e = caller.get_export(name).ctxf(|| format!("the runtime does not export {name}"))?;
    pick(e).ctxf(|| format!("the runtime's export {name} has the wrong kind"))
}

/// sbcl_host.instantiate: see the module comment.
fn instantiate(mut caller: Caller<'_, State>, ptr: u32, len: u32, register_area: u32, table_base: u32) -> Result<i32> {
    let memory = runtime_export(&mut caller, "memory", |e| e.into_memory())?;
    let table = runtime_export(&mut caller, "__indirect_function_table", |e| e.into_table())?;
    let bytes = {
        let data = memory.data(&caller);
        let end = (ptr as usize).checked_add(len as usize).ctx("module bytes out of range")?;
        data.get(ptr as usize..end).ctx("module bytes out of range")?.to_vec()
    };
    let (base, count) = table_range(&bytes).ctx("the module has no sbcl.core.table section")?;
    if base != table_base {
        return Err(Error::msg(format!("the module's functions start at table index {base}, the runtime expects {table_base}")));
    }
    let engine = caller.engine().clone();
    let t0 = std::time::Instant::now();
    let module = Module::new(&engine, &bytes).ctx("compiling the Lisp module")?;
    let compile = t0.elapsed();
    let needed = (base + count) as u64;
    let size = table.size(&caller);
    if size < needed {
        table.grow(&mut caller, needed - size, Ref::Func(None)).ctx("growing the function table")?;
    }
    let internal_error = runtime_export(&mut caller, "internal_error", |e| e.into_func())?;
    let alloc = runtime_export(&mut caller, "alloc", |e| e.into_func())?;
    let alloc_list = runtime_export(&mut caller, "alloc_list", |e| e.into_func())?;
    let pending_interrupt = runtime_export(&mut caller, "pending_interrupt", |e| e.into_func())?;
    let g_thread = Global::new(&mut caller, GlobalType::new(ValType::I32, Mutability::Const), Val::I32(register_area as i32))?;
    let g_base = Global::new(&mut caller, GlobalType::new(ValType::I32, Mutability::Const), Val::I32(base as i32))?;
    let tag = match caller.data().unwind_tag {
        Some(t) => t,
        None => {
            let t = Tag::new(&mut caller, &TagType::new(FuncType::new(&engine, [], [])))?;
            caller.data_mut().unwind_tag = Some(t);
            t
        }
    };
    let mut linker: Linker<State> = Linker::new(&engine);
    // functions the module imports from the shared table by index
    // (assembly routines of the core module: import module "table",
    // name the decimal table index)
    for import in module.imports() {
        if import.module() == "table" {
            let index: u64 = import.name().parse().map_err(|_| Error::msg(format!("bad table import name {}", import.name())))?;
            let func = match table.get(&mut caller, index) {
                Some(Ref::Func(Some(f))) => f,
                _ => return Err(Error::msg(format!("table import {index}: no function there"))),
            };
            linker.define(&caller, "table", import.name(), func)?;
        }
    }
    linker.define(&caller, "env", "memory", memory)?;
    linker.define(&caller, "env", "__indirect_function_table", table)?;
    linker.define(&caller, "env", "thread", g_thread)?;
    linker.define(&caller, "env", "table_base", g_base)?;
    linker.define(&caller, "env", "lisp_unwind", tag)?;
    linker.define(&caller, "env", "internal_error", internal_error)?;
    linker.define(&caller, "env", "alloc", alloc)?;
    linker.define(&caller, "env", "alloc_list", alloc_list)?;
    linker.define(&caller, "env", "pending_interrupt", pending_interrupt)?;
    let t1 = std::time::Instant::now();
    let instance = linker.instantiate(&mut caller, &module).ctx("instantiating the Lisp module")?;
    if std::env::var_os("SBCL_WASM_VERBOSE").is_some() {
        eprintln!(
            "sbcl-wasm: module of {} functions at table {}..{}: compile {:.3} s, instantiate {:.3} s",
            count,
            base,
            base + count,
            compile.as_secs_f64(),
            t1.elapsed().as_secs_f64()
        );
    }
    let state = caller.data_mut();
    state.register_area = Some(register_area);
    state.memory = Some(memory);
    state.lisp_modules.push(instance);
    Ok(1)
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ctx("usage: sbcl-wasm MODULE.wasm [args...]")?;
    let rest: Vec<String> = args.collect();
    let engine = Engine::new(&engine_config())?;
    let module = Module::from_file(&engine, &path).ctxf(|| format!("loading {path}"))?;
    let mut linker: Linker<State> = Linker::new(&engine);
    wasmtime_wasi::p1::add_to_linker_sync(&mut linker, |s| &mut s.wasi)?;
    linker.func_wrap("sbcl_host", "instantiate", instantiate)?;
    linker.define_unknown_imports_as_traps(&module)?;
    let mut argv = vec![path.clone()];
    argv.extend(rest);
    let wasi = WasiCtxBuilder::new()
        .inherit_stdio()
        .inherit_env()
        .args(&argv)
        .preopened_dir(".", ".", wasmtime_wasi::DirPerms::all(), wasmtime_wasi::FilePerms::all())?
        .build_p1();
    let mut store = Store::new(
        &engine,
        State { wasi, register_area: None, memory: None, unwind_tag: None, lisp_modules: Vec::new() },
    );

    // Ctrl-C: count presses; the epoch tick makes running Wasm code call
    // the deadline callback below.
    let presses = Arc::new(AtomicU32::new(0));
    {
        let presses = presses.clone();
        let engine = engine.clone();
        if let Err(e) = ctrlc::set_handler(move || {
            presses.fetch_add(1, Ordering::SeqCst);
            engine.increment_epoch();
        }) {
            eprintln!("sbcl-wasm: no Ctrl-C handler: {e}");
        }
    }
    // SBCL_WASM_TIMEOUT=<seconds>: trap with a backtrace when the run
    // exceeds the deadline (for finding where a build-time run spins)
    if let Some(secs) = std::env::var("SBCL_WASM_TIMEOUT").ok().and_then(|v| v.parse::<u64>().ok()) {
        let presses = presses.clone();
        let engine = engine.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(secs));
            eprintln!("sbcl-wasm: deadline of {secs} s reached");
            presses.fetch_add(2, Ordering::SeqCst);
            engine.increment_epoch();
        });
    }
    store.set_epoch_deadline(1);
    let seen = presses.clone();
    let mut handled = 0;
    store.epoch_deadline_callback(move |mut ctx| {
        let n = seen.load(Ordering::SeqCst);
        if n >= 2 {
            return Err(Error::msg("interrupted (Ctrl-C twice, or the deadline)"));
        }
        if n > handled {
            handled = n;
            if let (Some(area), Some(mem)) = (ctx.data().register_area, ctx.data().memory) {
                let off = (area + REGISTER_AREA_INTERRUPT_PENDING) as usize;
                if let Some(word) = mem.data_mut(&mut ctx).get_mut(off..off + 4) {
                    word.copy_from_slice(&1u32.to_le_bytes());
                }
            }
            eprintln!("sbcl-wasm: interrupt requested (press Ctrl-C again to terminate)");
        }
        Ok(UpdateDeadline::Continue(1))
    });

    let instance = linker.instantiate(&mut store, &module)?;
    let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;
    match start.call(&mut store, ()) {
        Ok(()) => Ok(()),
        Err(e) => {
            if let Some(exit) = e.downcast_ref::<wasmtime_wasi::I32Exit>() {
                std::process::exit(exit.0);
            }
            eprintln!("sbcl-wasm: {e:?}");
            dump_registers(&mut store);
            std::process::exit(1);
        }
    }
}
