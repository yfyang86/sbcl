//! `sbcl-wasm`: runs a WASI module with the engine features the SBCL port
//! needs (exceptions, tail calls, multi-value, bulk memory) and a large
//! native stack. Phase 0 form: a plain WASI runner used as `wasm_run`.
use anyhow::Context;
use wasmtime::{Config, Engine, Linker, Module, Store};
use wasmtime_wasi::p1::WasiP1Ctx;
use wasmtime_wasi::WasiCtxBuilder;

pub fn engine_config() -> Config {
    let mut c = Config::new();
    c.wasm_exceptions(true);
    c.wasm_tail_call(true);
    c.wasm_multi_value(true);
    c.wasm_bulk_memory(true);
    c.wasm_reference_types(true);
    c.max_wasm_stack(64 << 20);
    c.async_stack_size(128 << 20); // must exceed max_wasm_stack
    c
}

fn main() -> wasmtime::Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args.next().context("usage: sbcl-wasm MODULE.wasm [args...]").map_err(|e| wasmtime::Error::msg(e.to_string()))?;
    let rest: Vec<String> = args.collect();
    let engine = Engine::new(&engine_config())?;
    let module = Module::from_file(&engine, &path).map_err(|e| wasmtime::Error::msg(format!("loading {path}: {e}")))?;
    let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
    wasmtime_wasi::p1::add_to_linker_sync(&mut linker, |t| t)?;
    let mut argv = vec![path.clone()];
    argv.extend(rest);
    let wasi = WasiCtxBuilder::new()
        .inherit_stdio()
        .inherit_env()
        .args(&argv)
        .preopened_dir(".", ".", wasmtime_wasi::DirPerms::all(), wasmtime_wasi::FilePerms::all())?
        .build_p1();
    let mut store = Store::new(&engine, wasi);
    let instance = linker.instantiate(&mut store, &module)?;
    let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;
    match start.call(&mut store, ()) {
        Ok(()) => Ok(()),
        Err(e) => {
            if let Some(exit) = e.downcast_ref::<wasmtime_wasi::I32Exit>() {
                std::process::exit(exit.0);
            }
            Err(e)
        }
    }
}
