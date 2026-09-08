//! S0.1: (a) instantiate a WASI "runtime" module compiled from C that
//! exports its memory and function table; (b) instantiate a second module
//! at runtime that imports both and installs new functions into the table
//! at a base slot chosen by the host, then call them through the runtime's
//! own call_indirect path; (c) measure Module::new latency for synthetic
//! modules of 1 KB, 100 KB and 10 MB, which is the cost of `compile` at
//! runtime.
use anyhow::{Context, Result};
use std::time::Instant;
use wasmtime::*;
use wasmtime_wasi::p1::WasiP1Ctx;
use wasmtime_wasi::WasiCtxBuilder;

fn config() -> Config {
    let mut c = Config::new();
    c.wasm_exceptions(true);
    c.wasm_tail_call(true);
    c
}

fn synth_module(n_funcs: usize) -> Vec<u8> {
    // each function: (param i32) (result i32) with a small body, so size ~ n_funcs * 20 bytes
    use wasm_encoder::*;
    let mut m = Module::new();
    let mut types = TypeSection::new();
    types.ty().function(vec![ValType::I32], vec![ValType::I32]);
    m.section(&types);
    let mut funcs = FunctionSection::new();
    for _ in 0..n_funcs { funcs.function(0); }
    m.section(&funcs);
    let mut code = CodeSection::new();
    for i in 0..n_funcs {
        let mut f = Function::new(vec![]);
        f.instruction(&Instruction::LocalGet(0));
        f.instruction(&Instruction::I32Const(i as i32));
        f.instruction(&Instruction::I32Add);
        f.instruction(&Instruction::I32Const(3));
        f.instruction(&Instruction::I32Mul);
        f.instruction(&Instruction::End);
        code.function(&f);
    }
    m.section(&code);
    m.finish()
}

fn main() -> Result<()> {
    let dir = std::env::args().nth(1).context("usage: spike-s01 DIR (containing runtime.wasm and plugin.wasm)")?;
    let engine = Engine::new(&config())?;

    // (a) the C runtime
    let t = Instant::now();
    let runtime = Module::from_file(&engine, format!("{dir}/runtime.wasm"))?;
    println!("runtime.wasm compile: {:?}", t.elapsed());
    let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
    wasmtime_wasi::p1::add_to_linker_sync(&mut linker, |t| t)?;
    let wasi = WasiCtxBuilder::new().inherit_stdio().build_p1();
    let mut store = Store::new(&engine, wasi);
    let rt = linker.instantiate(&mut store, &runtime)?;
    rt.get_typed_func::<(), ()>(&mut store, "_initialize")
        .ok()
        .map(|f| f.call(&mut store, ()))
        .transpose()?;
    let memory = rt.get_memory(&mut store, "memory").context("runtime must export memory")?;
    let table = rt.get_table(&mut store, "__indirect_function_table").context("runtime must export its table")?;
    let call_slot = rt.get_typed_func::<(i32, i32), i32>(&mut store, "call_slot")?;
    println!("runtime table size before: {}", table.size(&store));

    // (b) the "compiled at runtime" module
    // Lisp will reserve the table range first (table.grow), then the module's
    // active element segment fills it during instantiation.
    let base = table.grow(&mut store, 2, Ref::Func(None))? as i32;
    let plugin = Module::from_file(&engine, format!("{dir}/plugin.wasm"))?;
    let mut pl: Linker<WasiP1Ctx> = Linker::new(&engine);
    pl.define(&store, "env", "memory", memory)?;
    pl.define(&store, "env", "__indirect_function_table", table)?;
    let base_global = Global::new(&mut store, GlobalType::new(ValType::I32, Mutability::Const), Val::I32(base))?;
    pl.define(&store, "env", "table_base", base_global)?;
    let t = Instant::now();
    let _plugin_inst = pl.instantiate(&mut store, &plugin)?;
    println!("plugin instantiate: {:?}; table size after: {}", t.elapsed(), table.size(&store));
    // plugin installed two functions at base and base+1: (x) -> x*2 and (x) -> x+100, both
    // also writing their result into linear memory at address 1024 so the C side can see it.
    let r0 = call_slot.call(&mut store, (base, 21))?;
    let r1 = call_slot.call(&mut store, (base + 1, 21))?;
    let mut buf = [0u8; 4];
    memory.read(&store, 1024, &mut buf)?;
    println!("call_slot(base,21)={r0} call_slot(base+1,21)={r1} mem[1024]={}", i32::from_le_bytes(buf));
    assert_eq!((r0, r1), (42, 121));

    // (c) Module::new latency
    for n in [40usize, 4_000, 400_000] {
        let bytes = synth_module(n);
        let mut best = None;
        for _ in 0..3 {
            let t = Instant::now();
            let m = Module::new(&engine, &bytes)?;
            let d = t.elapsed();
            drop(m);
            best = Some(best.map_or(d, |b: std::time::Duration| b.min(d)));
        }
        println!("Module::new {:>9} bytes ({n} funcs): {:?}", bytes.len(), best.unwrap());
    }
    Ok(())
}
