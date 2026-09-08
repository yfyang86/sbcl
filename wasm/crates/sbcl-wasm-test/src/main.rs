//! Level-1 differential test driver (doc/wasm-port/05-testing.md, 5.4).
//!
//! Usage: sbcl-wasm-test MINIRT.wasm CASES.txt
//!
//! Each line of CASES.txt is
//!     module.wasm  function-position  arg0 arg1 ...  => expected  [name]
//! Arguments and the expected value are raw 32-bit register words (the
//! Lisp side has already tagged them). The driver instantiates the
//! mini-runtime, installs the module's functions in the shared table at a
//! base it chooses, fills the register file (NARGS, A0..A3, CFP, CSP,
//! OCFP, RA, LEXENV), calls the function through the table and compares
//! A0 with the expected word. An internal error raised by the code under
//! test is reported with its trap kind and error code.
use wasmtime::Error;
type Result<T> = wasmtime::Result<T>;
fn err(msg: String) -> Error { Error::msg(msg) }
macro_rules! anyhow { ($($t:tt)*) => { err(format!($($t)*)) } }
macro_rules! bail { ($($t:tt)*) => { return Err(err(format!($($t)*))) } }
trait Ctx<T> { fn context(self, m: &str) -> Result<T>; fn with_context<F: FnOnce() -> String>(self, f: F) -> Result<T>; }
impl<T> Ctx<T> for Option<T> {
    fn context(self, m: &str) -> Result<T> { self.ok_or_else(|| err(m.to_string())) }
    fn with_context<F: FnOnce() -> String>(self, f: F) -> Result<T> { self.ok_or_else(|| err(f())) }
}
impl<T, E: std::fmt::Display> Ctx<T> for std::result::Result<T, E> {
    fn context(self, m: &str) -> Result<T> { self.map_err(|e| err(format!("{m}: {e}"))) }
    fn with_context<F: FnOnce() -> String>(self, f: F) -> Result<T> { self.map_err(|e| err(format!("{}: {e}", f()))) }
}
use std::collections::HashMap;
use std::path::Path;
use wasmtime::*;

// register slots, from src/compiler/wasm/vm.lisp
const REG_NARGS: u32 = 0;
const REG_CSP: u32 = 1;
const REG_CFP: u32 = 2;
const REG_OCFP: u32 = 3;
const REG_NSP: u32 = 5;
const REG_LEXENV: u32 = 6;
const REG_RA: u32 = 29;
const REG_A0: u32 = 10;
const REGISTER_ARG_COUNT: u32 = 4;
const FIXNUM_TAG_BITS: u32 = 2;

struct Host {
    error: Option<(i32, i32, i32)>,
}

fn config() -> Config {
    let mut c = Config::new();
    c.wasm_exceptions(true);
    c.wasm_tail_call(true);
    c.max_wasm_stack(64 << 20);
    c.async_stack_size(128 << 20);
    c
}

struct Case {
    module: String,
    position: u32,
    args: Vec<u32>,
    expected: u32,
    name: String,
}

fn parse_word(s: &str) -> Result<u32> {
    if let Some(h) = s.strip_prefix("0x") {
        u32::from_str_radix(h, 16).context("hex word")
    } else {
        Ok(s.parse::<i64>().context("word")? as u32)
    }
}

/// A `!poke ADDRESS VALUE` line: a word stored into the runtime's memory
/// before each case (static symbol headers, for instance).
fn parse_cases(text: &str) -> Result<(Vec<Case>, Vec<(u32, u32)>)> {
    let mut cases = vec![];
    let mut pokes = vec![];
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        if let Some(rest) = line.strip_prefix("!poke") {
            let mut it = rest.split_whitespace();
            let addr = parse_word(it.next().context("poke address")?)?;
            let value = parse_word(it.next().context("poke value")?)?;
            pokes.push((addr, value));
            continue;
        }
        let (lhs, rhs) = line.split_once("=>").ok_or_else(|| anyhow!("bad case line: {line}"))?;
        let mut lhs = lhs.split_whitespace();
        let module = lhs.next().context("module")?.to_string();
        let position: u32 = lhs.next().context("position")?.parse().context("position")?;
        let args = lhs.map(parse_word).collect::<Result<Vec<_>>>()?;
        let mut rhs = rhs.split_whitespace();
        let expected = parse_word(rhs.next().context("expected")?)?;
        let name = rhs.collect::<Vec<_>>().join(" ");
        cases.push(Case { module, position, args, expected, name });
    }
    Ok((cases, pokes))
}

fn run_case(engine: &Engine, minirt: &Module, modules: &mut HashMap<String, Module>, dir: &Path, pokes: &[(u32, u32)], case: &Case) -> Result<u32> {
    let mut store = Store::new(engine, Host { error: None });
    let linker: Linker<Host> = Linker::new(engine);
    let rt = linker.instantiate(&mut store, minirt)?;
    let memory = rt.get_memory(&mut store, "memory").context("minirt memory")?;
    let table = rt.get_table(&mut store, "__indirect_function_table").context("minirt table")?;
    let thread = rt.get_typed_func::<(), i32>(&mut store, "thread_area")?.call(&mut store, ())? as u32;
    let stack = rt.get_typed_func::<(), i32>(&mut store, "control_stack")?.call(&mut store, ())? as u32;
    let nstack_end = rt.get_typed_func::<(), i32>(&mut store, "number_stack_end")?.call(&mut store, ())? as u32;
    rt.get_typed_func::<(), ()>(&mut store, "reset")?.call(&mut store, ())?;
    for &(addr, value) in pokes {
        memory.write(&mut store, addr as usize, &value.to_le_bytes())
            .with_context(|| format!("poke {addr:#x}"))?;
    }

    let module = match modules.get(&case.module) {
        Some(m) => m.clone(),
        None => {
            let m = Module::from_file(engine, dir.join(&case.module))
                .with_context(|| format!("loading {}", case.module))?;
            modules.insert(case.module.clone(), m.clone());
            m
        }
    };
    let n_funcs = 256; // generous; the module's element segment fills what it needs
    let base = table.grow(&mut store, n_funcs, Ref::Func(None))? as i32;

    let mut ml: Linker<Host> = Linker::new(engine);
    ml.define(&store, "env", "memory", memory)?;
    ml.define(&store, "env", "__indirect_function_table", table)?;
    let g_thread = Global::new(&mut store, GlobalType::new(ValType::I32, Mutability::Const), Val::I32(thread as i32))?;
    let g_base = Global::new(&mut store, GlobalType::new(ValType::I32, Mutability::Const), Val::I32(base))?;
    ml.define(&store, "env", "thread", g_thread)?;
    ml.define(&store, "env", "table_base", g_base)?;
    ml.func_wrap("env", "internal_error", |mut caller: Caller<'_, Host>, kind: i32, code: i32, nargs: i32| -> wasmtime::Result<()> {
        caller.data_mut().error = Some((kind, code, nargs));
        Err(err(format!("internal error: kind {kind} code {code} nargs {nargs}")))
    })?;
    let alloc = rt.get_func(&mut store, "alloc").context("minirt alloc")?;
    let alloc_list = rt.get_func(&mut store, "alloc_list").context("minirt alloc_list")?;
    let pending = rt.get_func(&mut store, "pending_interrupt").context("minirt pending_interrupt")?;
    ml.define(&store, "env", "alloc", alloc)?;
    ml.define(&store, "env", "alloc_list", alloc_list)?;
    ml.define(&store, "env", "pending_interrupt", pending)?;
    let _inst = ml.instantiate(&mut store, &module).with_context(|| format!("instantiating {}", case.module))?;

    // register file
    let set = |store: &mut Store<Host>, reg: u32, value: u32| -> Result<()> {
        memory.write(store, (thread + reg * 4) as usize, &value.to_le_bytes())?;
        Ok(())
    };
    if case.args.len() as u32 > REGISTER_ARG_COUNT {
        bail!("more than {REGISTER_ARG_COUNT} arguments are not supported by the rig yet");
    }
    set(&mut store, REG_NARGS, (case.args.len() as u32) << FIXNUM_TAG_BITS)?;
    for (i, a) in case.args.iter().enumerate() {
        set(&mut store, REG_A0 + i as u32, *a)?;
    }
    set(&mut store, REG_CFP, stack)?;
    set(&mut store, REG_CSP, stack)?;
    set(&mut store, REG_OCFP, 0)?;
    set(&mut store, REG_RA, 0)?;
    set(&mut store, REG_LEXENV, 0)?;
    set(&mut store, REG_NSP, nstack_end)?;

    let slot = base as u32 + case.position;
    let f = match table.get(&mut store, slot as u64) {
        Some(Ref::Func(Some(f))) => f,
        _ => bail!("table slot {slot} holds no function"),
    };
    let f = f.typed::<(), i32>(&store)?;
    let flag = f.call(&mut store, ()).map_err(|e| {
        match store.data().error {
            Some((k, c, n)) => anyhow!("internal error: trap kind {k}, error code {c}, {n} values"),
            None => anyhow!("{e}"),
        }
    })?;
    let mut buf = [0u8; 4];
    memory.read(&store, (thread + REG_A0 * 4) as usize, &mut buf)?;
    let a0 = u32::from_le_bytes(buf);
    if flag != 0 && flag != 1 {
        bail!("bad values flag {flag}");
    }
    Ok(a0)
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        bail!("usage: sbcl-wasm-test MINIRT.wasm CASES.txt");
    }
    let engine = Engine::new(&config())?;
    let minirt = Module::from_file(&engine, &args[1]).context("loading minirt")?;
    let cases_path = Path::new(&args[2]);
    let dir = cases_path.parent().unwrap_or(Path::new("."));
    let (cases, pokes) = parse_cases(&std::fs::read_to_string(cases_path).context("reading cases")?)?;
    let mut modules = HashMap::new();
    let (mut pass, mut fail) = (0, 0);
    for case in &cases {
        match run_case(&engine, &minirt, &mut modules, dir, &pokes, case) {
            Ok(got) if got == case.expected => {
                pass += 1;
                println!("PASS {} {}({:?}) = {:#x}", case.name, case.module, case.args, got);
            }
            Ok(got) => {
                fail += 1;
                println!("FAIL {} {}({:?}): got {:#x} want {:#x}", case.name, case.module, case.args, got, case.expected);
            }
            Err(e) => {
                fail += 1;
                println!("FAIL {} {}({:?}): {}", case.name, case.module, case.args, e);
            }
        }
    }
    println!("level1: passed={pass} failed={fail}");
    if fail > 0 { std::process::exit(1); }
    Ok(())
}
