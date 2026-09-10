// A single-producer, single-consumer byte ring over a
// SharedArrayBuffer: the SBCL worker's thread blocks inside its Wasm
// `_start` (Atomics.wait on the ring) and cannot service postMessage,
// so the page writes input into the buffer directly and notifies it
// from its own thread. Layout: int32 [0] head, [1] tail, [2] the wait
// word; bytes from offset 8. One instance per side, over the same
// buffer; the page's and the worker's are the same ring.
export const RING_CAPACITY = 1 << 16;

export function ringBuffer(shared) {
  return shared ? new SharedArrayBuffer(8 + RING_CAPACITY)
                : new ArrayBuffer(8 + RING_CAPACITY);
}

export class RingStdin {
  /// buffer: what ringBuffer() returned (the worker) or the
  /// SharedArrayBuffer the worker sent over (the page, shared only).
  constructor(buffer) {
    this.int32 = new Int32Array(buffer);
    this.bytes = new Uint8Array(buffer, 8);
    this.capacity = RING_CAPACITY;
  }
  get shared() { return this.int32.buffer instanceof SharedArrayBuffer; }

  /// The producer (the page): append bytes, waking the consumer.
  push(src) {
    let at = 0;
    while (at < src.length) {
      const head = Atomics.load(this.int32, 0);
      const tail = Atomics.load(this.int32, 1);
      const used = (head - tail + this.capacity) % this.capacity;
      const space = this.capacity - 1 - used;
      if (space > 0) {
        const n = Math.min(space, src.length - at);
        for (let i = 0; i < n; i++) {
          this.bytes[(head + i) % this.capacity] = src[at + i];
        }
        Atomics.store(this.int32, 0, (head + n) % this.capacity);
        at += n;
        Atomics.notify(this.int32, 2);
      } else {
        // full: the Lisp reader drains in blocks, this never spins long
        Atomics.wait(this.int32, 2, 0, 10);
      }
    }
  }

  /// Is a byte available without blocking?
  ready() {
    return Atomics.load(this.int32, 0) !== Atomics.load(this.int32, 1);
  }

  /// The consumer (the worker's WASI fd_read): read at least one byte,
  /// at most dst.length, blocking for it.
  read(dst) {
    for (;;) {
      const head = Atomics.load(this.int32, 0);
      let tail = Atomics.load(this.int32, 1);
      if (head !== tail) {
        let n = 0;
        while (n < dst.length && tail !== head) {
          dst[n++] = this.bytes[tail];
          tail = (tail + 1) % this.capacity;
        }
        Atomics.store(this.int32, 1, tail);
        return n;
      }
      Atomics.wait(this.int32, 2, 0);
    }
  }
}
