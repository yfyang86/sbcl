// A WASI preview 1 shim for the browser worker (Sprint 14): the 24
// calls src/runtime/sbcl.wasm makes (SBCL-Handoff.md 4.2), over an
// in-memory file system that holds the core files (fetched before the
// runtime starts) and whatever the page installs (test files, files
// COMPILE-FILE writes).
//
// The file model is a map of absolute path -> bytes, read and written
// whole; directories are the path prefixes that occur. fd 3 is the
// preopen of "/". stdin is a reader the caller supplies (a blocking
// queue over a SharedArrayBuffer in the worker, a plain queue in the
// Node smoke driver); stdout and stderr are callbacks.

export const ERRNO_SUCCESS = 0;
export const ERRNO_BADF = 8;
export const ERRNO_FAULT = 21;
export const ERRNO_INVAL = 28;
export const ERRNO_ISDIR = 31;
export const ERRNO_NOENT = 44;
export const ERRNO_NOTSOCK = 57;
export const ERRNO_NOTSUP = 58;
export const ERRNO_NOTDIR = 54;
export const ERRNO_SPIPE = 70;

// filetype (wasi_filetype): 2 = character device, 3 = directory,
// 4 = regular file
const FILETYPE_CHAR = 2, FILETYPE_DIR = 3, FILETYPE_REG = 4;

// rights: everything, as wasmtime gives a preopen; the runtime does not
// police them, but fd_fdstat_get's zero rights read as "not writable"
// in some libc paths
const RIGHTS_ALL = 0xfffffffffffffffbn;

export class ProcExit extends Error {
  constructor(code) { super(`proc_exit(${code})`); this.code = code; }
}

/// Sleep synchronously: Atomics.wait where a SharedArrayBuffer exists
/// (a worker under crossOriginIsolated, Node), a busy wait elsewhere.
export function blockSleep(ms) {
  if (globalThis.SharedArrayBuffer) {
    const sab = new Int32Array(new SharedArrayBuffer(4));
    Atomics.wait(sab, 0, 0, ms);
  } else {
    const end = Date.now() + ms;
    while (Date.now() < end) { /* the worker's own thread */ }
  }
}

/// The path half of the WASI API works on C strings in linear memory;
/// these views re-read memory.buffer every call (it detaches on grow).
class MemoryView {
  constructor(memory) { this.memory = memory; }
  view(byteOffset, length) {
    return new Uint8Array(this.memory.buffer, byteOffset, length);
  }
  dataView(byteOffset, length) {
    return new DataView(this.memory.buffer, byteOffset, length);
  }
  string(byteOffset, length) {
    return new TextDecoder().decode(this.view(byteOffset, length));
  }
  writeString(ptr, capacity, s) {
    const bytes = new TextEncoder().encode(s);
    if (bytes.length > capacity) return null;
    this.view(ptr, bytes.length).set(bytes);
    return bytes.length;
  }
}

/// A growable byte buffer for files opened for writing: chunks
/// gathered until close, then stored into the file map.
class WriteBuffer {
  constructor() { this.chunks = []; this.length = 0; }
  append(bytes) { this.chunks.push(bytes.slice()); this.length += bytes.length; }
  bytes() {
    const out = new Uint8Array(this.length);
    let at = 0;
    for (const c of this.chunks) { out.set(c, at); at += c.length; }
    return out;
  }
}

export class WasiShim {
  /// {args: [string], env: {name: value}, files: Map<string, Uint8Array>,
  ///  stdin: {read(dst: Uint8Array): number}, onStdout(bytes),
  ///  onStderr(bytes), onExit(code), clock(): BigInt (microseconds)}
  /// clock is the host's time source; the shim delivers the timer's
  /// interrupt at each read of it (SBCL-Handoff.md 4.5).
  constructor({ args, env, files, stdin, onStdout, onStderr, onExit, host }) {
    this.argv = args;
    this.environ = Object.entries(env).map(([k, v]) => `${k}=${v}`);
    this.files = files;
    this.stdin = stdin;
    this.onStdout = onStdout;
    this.onStderr = onStderr;
    this.onExit = onExit;
    this.host = host;
    this.nextFd = 4; // 0,1,2 stdio; 3 the preopen
    // fd -> {path, file: {bytes, pos} | WriteBuffer, filetype, append}
    this.open = new Map();
  }

  imports() {
    return {
      args_sizes_get: (p, b) => this.argvSizes(p, b),
      args_get: (p, b) => this.argvGet(p, b),
      environ_sizes_get: (p, b) => this.envSizes(p, b),
      environ_get: (p, b) => this.envGet(p, b),
      clock_time_get: (clockId, precision, timePtr) => this.clockTimeGet(clockId, precision, timePtr),
      fd_close: (fd) => this.fdClose(fd),
      fd_fdstat_get: (fd, buf) => this.fdFdstatGet(fd, buf),
      fd_fdstat_set_flags: (fd) => fd <= 3 ? ERRNO_SUCCESS : ERRNO_BADF,
      fd_filestat_get: (fd, buf) => this.fdFilestatGet(fd, buf),
      fd_prestat_get: (fd, buf) => this.fdPrestatGet(fd, buf),
      fd_prestat_dir_name: (fd, ptr, len) => this.fdPrestatDirName(fd, ptr, len),
      fd_read: (fd, iovs, iovsLen, nread) => this.fdRead(fd, iovs, iovsLen, nread),
      fd_readdir: (fd, buf, buflen, cookie, newLen) => this.fdReaddir(fd, buf, buflen, cookie, newLen),
      fd_seek: (fd, offset, whence, newOffset) => this.fdSeek(fd, offset, whence, newOffset),
      fd_write: (fd, iovs, iovsLen, nwritten) => this.fdWrite(fd, iovs, iovsLen, nwritten),
      path_create_directory: () => ERRNO_NOTSUP,
      path_filestat_get: (fd, flags, p, l, buf) => this.pathFilestatGet(fd, flags, p, l, buf),
      path_open: (fd, dirflags, p, l, oflags, base, inheriting, fdflags, opened) =>
        this.pathOpen(fd, dirflags, p, l, oflags, base, inheriting, fdflags, opened),
      path_readlink: () => ERRNO_NOENT,
      path_remove_directory: () => ERRNO_NOTSUP,
      path_rename: () => ERRNO_NOTSUP,
      path_unlink_file: (fd, p, l) => this.pathUnlink(fd, p, l),
      poll_oneoff: (in_, out, nsubs, nevents) => this.pollOneoff(in_, out, nsubs, nevents),
      proc_exit: (code) => { if (this.onExit) this.onExit(code); throw new ProcExit(code); },
      sched_yield: () => ERRNO_SUCCESS,
    };
  }

  attach(memory) { this.memory = new MemoryView(memory); }

  /// The clock the runtime reads constantly (get-internal-real-time,
  /// its timeouts): microseconds since the epoch, and the point where
  /// the timer's interrupt is delivered.
  nowUsec() {
    const now = BigInt(Math.round(performance.timeOrigin * 1e6) +
                        performance.now() * 1e3);
    if (this.host) this.host.deliverInterrupts(now);
    return now;
  }

  clockTimeGet(clockId, precision, timePtr) {
    this.memory.dataView(timePtr, 8).setBigUint64(0, this.nowUsec() * 1000n, true);
    return ERRNO_SUCCESS;
  }

  // ---- args and environ ----
  argvSizes(argcPtr, bufSizePtr) {
    const dv = this.memory.dataView(argcPtr, 4);
    dv.setUint32(0, this.argv.length, true);
    this.memory.dataView(bufSizePtr, 4).setUint32(
      0, this.argv.reduce((n, a) => n + a.length + 1, 0), true);
    return ERRNO_SUCCESS;
  }
  argvGet(argvPtr, bufPtr) {
    for (const a of this.argv) {
      this.memory.dataView(argvPtr, 4).setUint32(0, bufPtr, true);
      argvPtr += 4;
      const n = this.memory.writeString(bufPtr, 1 << 20, a);
      bufPtr += n + 1;
    }
    return ERRNO_SUCCESS;
  }
  envSizes(envcPtr, bufSizePtr) {
    this.memory.dataView(envcPtr, 4).setUint32(0, this.environ.length, true);
    this.memory.dataView(bufSizePtr, 4).setUint32(
      0, this.environ.reduce((n, e) => n + e.length + 1, 0), true);
    return ERRNO_SUCCESS;
  }
  envGet(envPtr, bufPtr) {
    for (const e of this.environ) {
      this.memory.dataView(envPtr, 4).setUint32(0, bufPtr, true);
      envPtr += 4;
      const n = this.memory.writeString(bufPtr, 1 << 20, e);
      bufPtr += n + 1;
    }
    return ERRNO_SUCCESS;
  }

  // ---- fds ----
  fdClose(fd) {
    const entry = this.open.get(fd);
    if (!entry) return fd <= 3 ? ERRNO_SUCCESS : ERRNO_BADF;
    if (entry.write) this.files.set(entry.path, entry.write.bytes());
    this.open.delete(fd);
    return ERRNO_SUCCESS;
  }

  fdType(fd) {
    if (fd <= 2) return FILETYPE_CHAR;
    if (fd === 3) return FILETYPE_DIR;
    return this.open.get(fd)?.filetype ?? FILETYPE_REG;
  }

  fdFdstatGet(fd, buf) {
    const filetype = this.fdType(fd);
    const dv = this.memory.dataView(buf, 24);
    dv.setUint8(0, filetype);
    dv.setUint16(2, 0, true); // flags: none (append handled per write)
    dv.setBigUint64(8, RIGHTS_ALL, true);
    dv.setBigUint64(16, RIGHTS_ALL, true);
    return ERRNO_SUCCESS;
  }

  writeStat(dv, filetype, size) {
    let at = 0;
    dv.setBigUint64(at, 1n, true); at += 8;              // dev
    dv.setBigUint64(at, 1n, true); at += 8;              // ino
    dv.setUint8(at, filetype); at += 8;                  // filetype + pad
    dv.setBigUint64(at, 1n, true); at += 8;              // nlink
    dv.setBigUint64(at, BigInt(size), true); at += 8;    // size
    const t = this.nowUsec() * 1000n;
    dv.setBigUint64(at, t, true); at += 8;               // atim
    dv.setBigUint64(at, t, true); at += 8;               // mtim
    dv.setBigUint64(at, t, true);                         // ctim
  }

  fdFilestatGet(fd, buf) {
    const filetype = this.fdType(fd);
    const size = filetype === FILETYPE_REG
      ? this.open.get(fd)?.file.bytes.length ?? this.files.get(this.open.get(fd)?.path)?.length ?? 0
      : 0;
    this.writeStat(this.memory.dataView(buf, 64), filetype, size);
    return ERRNO_SUCCESS;
  }

  fdPrestatGet(fd, buf) {
    if (fd !== 3) return ERRNO_BADF;
    const dv = this.memory.dataView(buf, 8);
    dv.setUint8(0, 0); // preopentype_dir
    dv.setUint32(4, 1, true); // the name "/", without the NUL
    return ERRNO_SUCCESS;
  }
  fdPrestatDirName(fd, ptr, len) {
    if (fd !== 3) return ERRNO_BADF;
    this.memory.view(ptr, Math.min(len, 1)).set([0x2f]); // "/"
    return ERRNO_SUCCESS;
  }

  fdRead(fd, iovs, iovsLen, nreadPtr) {
    if (fd === 1 || fd === 2) return ERRNO_BADF;
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const iov = this.memory.dataView(iovs + i * 8, 8);
      const dst = this.memory.view(iov.getUint32(0, true), iov.getUint32(4, true));
      const n = this.readOnce(fd, dst);
      total += n;
      if (n < dst.length) break;
    }
    this.memory.dataView(nreadPtr, 4).setUint32(0, total, true);
    return ERRNO_SUCCESS;
  }

  /// One iov's worth: stdin blocks for what it is asked (the REPL's
  /// line reader reads a byte at a time); a file reads what is left.
  readOnce(fd, dst) {
    if (fd === 0) return this.stdin.read(dst);
    const entry = this.open.get(fd);
    if (!entry || entry.write) return 0;
    const n = Math.min(dst.length, entry.file.bytes.length - entry.file.pos);
    dst.set(entry.file.bytes.subarray(entry.file.pos, entry.file.pos + n));
    entry.file.pos += n;
    return n;
  }

  fdWrite(fd, iovs, iovsLen, nwrittenPtr) {
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const iov = this.memory.dataView(iovs + i * 8, 8);
      const src = this.memory.view(iov.getUint32(0, true), iov.getUint32(4, true));
      if (fd === 1 || fd === 2) {
        (fd === 1 ? this.onStdout : this.onStderr)(src);
      } else {
        const entry = this.open.get(fd);
        if (entry?.write) entry.write.append(src);
      }
      total += src.length;
    }
    this.memory.dataView(nwrittenPtr, 4).setUint32(0, total, true);
    return ERRNO_SUCCESS;
  }

  fdSeek(fd, offset, whence, newOffsetPtr) {
    const entry = this.open.get(fd);
    if (!entry || entry.write) return ERRNO_BADF;
    const base = whence === 0 ? 0n : whence === 1 ? BigInt(entry.file.pos) : BigInt(entry.file.bytes.length);
    let pos = Number(base + offset);
    if (pos < 0) pos = 0;
    if (pos > entry.file.bytes.length) pos = entry.file.bytes.length;
    entry.file.pos = pos;
    this.memory.dataView(newOffsetPtr, 8).setBigUint64(0, BigInt(pos), true);
    return ERRNO_SUCCESS;
  }

  fdReaddir(fd, buf, buflen, cookie, newLenPtr) {
    // the tree lists nothing: the runtime reads directories only for
    // its own directory scans (none in a session without compile-file
    // path searches)
    this.memory.dataView(newLenPtr, 4).setUint32(0, 0, true);
    return fd === 3 ? ERRNO_SUCCESS : ERRNO_NOTDIR;
  }

  // ---- paths ----
  /// Resolve a WASI path against a dirfd into a map key: "/" for the
  /// preopen, so "/sbcl.core" and "sbcl.core" are the same file.
  resolve(dirfd, path) {
    const abs = path.startsWith("/") || dirfd !== 3 ? `/${path}` : `/${path}`;
    const parts = [];
    for (const part of abs.split("/")) {
      if (part === "" || part === ".") continue;
      if (part === "..") parts.pop(); else parts.push(part);
    }
    return `/${parts.join("/")}`;
  }

  pathOpen(dirfd, dirflags, pathPtr, pathLen, oflags, rightsBase, rightsInheriting, fdflags, openedPtr) {
    const path = this.resolve(dirfd, this.memory.string(pathPtr, pathLen));
    const creat = (oflags & 1) !== 0;
    const trunc = (oflags & 8) !== 0;
    const append = (fdflags & 1) !== 0;
    const directory = (oflags & 16) !== 0;
    const writing = rightsBase !== 0n && (rightsBase & 0x40n) !== 0n; // fd_write
    const exists = this.files.has(path);
    const isDir = !exists && this.isDirectory(path);
    if (directory || isDir) {
      if (!directory && !exists && isDir && !creat) {
        this.open.set(this.nextFd, { path, filetype: FILETYPE_DIR, file: { bytes: new Uint8Array(0), pos: 0 } });
        this.memory.dataView(openedPtr, 4).setUint32(0, this.nextFd++, true);
        return ERRNO_SUCCESS;
      }
      return directory && !isDir && !exists ? ERRNO_NOTDIR : ERRNO_NOTSUP;
    }
    if (!exists && !creat) return ERRNO_NOENT;
    if (writing || creat || append) {
      const fd = this.nextFd++;
      this.open.set(fd, { path, write: new WriteBuffer() });
      if (exists && !trunc && !append) {
        // rewrite: seed with the current bytes
        this.open.get(fd).write.append(this.files.get(path));
      }
      this.memory.dataView(openedPtr, 4).setUint32(0, fd, true);
      return ERRNO_SUCCESS;
    }
    const bytes = this.files.get(path);
    this.open.set(this.nextFd, { path, filetype: FILETYPE_REG, file: { bytes, pos: 0 } });
    this.memory.dataView(openedPtr, 4).setUint32(0, this.nextFd++, true);
    return ERRNO_SUCCESS;
  }

  isDirectory(path) {
    const prefix = path === "/" ? "/" : `${path}/`;
    for (const key of this.files.keys()) if (key.startsWith(prefix)) return true;
    return false;
  }

  pathFilestatGet(dirfd, flags, pathPtr, pathLen, buf) {
    const path = this.resolve(dirfd, this.memory.string(pathPtr, pathLen));
    const bytes = this.files.get(path);
    if (bytes) {
      this.writeStat(this.memory.dataView(buf, 64), FILETYPE_REG, bytes.length);
      return ERRNO_SUCCESS;
    }
    if (this.isDirectory(path)) {
      this.writeStat(this.memory.dataView(buf, 64), FILETYPE_DIR, 0);
      return ERRNO_SUCCESS;
    }
    return ERRNO_NOENT;
  }

  pathUnlink(dirfd, pathPtr, pathLen) {
    const path = this.resolve(dirfd, this.memory.string(pathPtr, pathLen));
    return this.files.delete(path) ? ERRNO_SUCCESS : ERRNO_NOENT;
  }

  // ---- poll: the port's sleep (sliced) and stdin waits land here ----
  pollOneoff(inPtr, outPtr, nsubs, neventsPtr) {
    let deadlineMs = Infinity;
    let stdinWait = false;
    const subs = [];
    for (let i = 0; i < nsubs; i++) {
      // subscription: userdata u64, u: union { tag u16, ... } — 48 bytes
      const dv = this.memory.dataView(inPtr + i * 48, 48);
      const userdata = dv.getBigUint64(0, true);
      const tag = dv.getUint16(8, true);
      subs.push({ userdata, tag, timeout: dv.getBigUint64(16, true) });
      if (tag === 0 /* clock */) {
        const ms = Number(subs[i].timeout / 1000n);
        if (ms < deadlineMs) deadlineMs = ms;
      } else if (tag === 1 /* fd_read */ && dv.getUint32(16, true) === 0) {
        stdinWait = true;
        if (deadlineMs === Infinity) deadlineMs = 100;
      } else {
        return ERRNO_NOTSUP;
      }
    }
    const start = performance.now();
    for (;;) {
      this.nowUsec(); // deliver the timer's interrupt here too
      if (stdinWait && this.stdin.ready()) break;
      const elapsed = performance.now() - start;
      if (elapsed >= deadlineMs) break;
      blockSleep(Math.min(2, deadlineMs - elapsed));
    }
    // result: userdata u64, errno u16, type u16
    let n = 0;
    for (const sub of subs) {
      const dv = this.memory.dataView(outPtr + n * 16, 16);
      dv.setBigUint64(0, sub.userdata, true);
      dv.setUint16(8, 0, true);
      dv.setUint16(10, sub.tag === 0 ? 0 : 1);
      n++;
    }
    this.memory.dataView(neventsPtr, 4).setUint32(0, n, true);
    return ERRNO_SUCCESS;
  }
}
