//! Loads (compiles and instantiates, without running) the core module
//! genesis writes next to the cold core, against a stub environment:
//! the runtime's memory and function table, the thread and table-base
//! globals, the unwind tag and the four runtime entry points. Reports
//! the module's size, its function count and table range (from the
//! "sbcl.core.table" custom section) and the compile and instantiate
//! times (doc/wasm-port/04-sprints.md, plan Sprint 4 exit criterion).
//!
//! Usage: load-core CORE.wasm
use std::time::Instant;
use wasmtime::*;

fn config() -> Config {
    let mut c = Config::new();
    c.wasm_tail_call(true);
    c.wasm_exceptions(true);
    c
}

/// The (base, count) pair of the "sbcl.core.table" custom section.
fn table_range(bytes: &[u8]) -> Option<(u32, u32)> {
    fn uleb(bytes: &[u8], pos: &mut usize) -> u64 {
        let (mut result, mut shift) = (0u64, 0);
        loop {
            let b = bytes[*pos];
            *pos += 1;
            result |= ((b & 0x7F) as u64) << shift;
            shift += 7;
            if b & 0x80 == 0 {
                return result;
            }
        }
    }
    let mut pos = 8; // magic and version
    while pos < bytes.len() {
        let id = bytes[pos];
        pos += 1;
        let size = uleb(bytes, &mut pos) as usize;
        let end = pos + size;
        if id == 0 {
            let mut p = pos;
            let n = uleb(bytes, &mut p) as usize;
            let name = std::str::from_utf8(&bytes[p..p + n]).unwrap_or("");
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

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        return Err(Error::msg("usage: load-core CORE.wasm"));
    }
    let bytes = std::fs::read(&args[1])?;
    let (base, count) = table_range(&bytes).ok_or_else(|| Error::msg("no sbcl.core.table section"))?;
    println!("size: {} bytes", bytes.len());
    println!("table: base {base}, {count} functions");
    let engine = Engine::new(&config())?;
    let t0 = Instant::now();
    let module = Module::new(&engine, &bytes)?;
    let compile = t0.elapsed();
    println!("compile: {:.3} s", compile.as_secs_f64());
    let mut store = Store::new(&engine, ());
    let memory = Memory::new(&mut store, MemoryType::new(1, None))?;
    let table = Table::new(&mut store, TableType::new(RefType::FUNCREF, base + count, None), Ref::Func(None))?;
    let g_thread = Global::new(&mut store, GlobalType::new(ValType::I32, Mutability::Const), Val::I32(0))?;
    let g_base = Global::new(&mut store, GlobalType::new(ValType::I32, Mutability::Const), Val::I32(base as i32))?;
    let tag = Tag::new(&mut store, &TagType::new(FuncType::new(&engine, [], [])))?;
    let mut linker: Linker<()> = Linker::new(&engine);
    linker.define(&store, "env", "memory", memory)?;
    linker.define(&store, "env", "__indirect_function_table", table)?;
    linker.define(&store, "env", "thread", g_thread)?;
    linker.define(&store, "env", "table_base", g_base)?;
    linker.define(&store, "env", "lisp_unwind", tag)?;
    linker.func_wrap("env", "internal_error", |_: i32, _: i32, _: i32| {})?;
    linker.func_wrap("env", "alloc", |n: i32| -> i32 { n })?;
    linker.func_wrap("env", "alloc_list", |n: i32| -> i32 { n })?;
    linker.func_wrap("env", "pending_interrupt", || {})?;
    let t1 = Instant::now();
    let instance = linker.instantiate(&mut store, &module)?;
    let instantiate = t1.elapsed();
    println!("instantiate: {:.3} s", instantiate.as_secs_f64());
    // the element segment filled the core's range
    let first = table.get(&mut store, base as u64);
    let last = table.get(&mut store, (base + count - 1) as u64);
    let filled = matches!(first, Some(Ref::Func(Some(_)))) && matches!(last, Some(Ref::Func(Some(_))));
    println!("table filled: {}", if filled { "yes" } else { "no" });
    let _ = instance;
    if !filled {
        return Err(Error::msg("table slots not filled by the element segment"));
    }
    println!("load-core: ok");
    Ok(())
}
