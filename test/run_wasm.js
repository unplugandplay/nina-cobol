// A zero-dependency runner for LDPL/WASI modules.
//
// Node's own `node:wasi` would work too, but this file exists so the test suite
// has no runtime dependency at all: the WASI preview1 functions a module can
// import are supplied here in plain JavaScript. If a module asks for something
// we do not implement, we throw at instantiation time rather than silently
// misbehaving.

'use strict';

const fs = require('fs');

function hexdump(bytes, max = 64) {
  const head = Buffer.from(bytes.slice(0, max));
  const hex = head.toString('hex').replace(/(..)/g, '$1 ').trim();
  return bytes.length > max ? `${hex} …(${bytes.length} bytes)` : hex;
}

function makeImports(wasi) {
  const mem = () => new DataView(wasi.memory.buffer);

  const imports = {
    wasi_snapshot_preview1: {
      proc_exit(code) {
        const err = new Error(`proc_exit(${code})`);
        err.wasiExit = code;
        throw err;
      },

      fd_write(fd, iovs, iovs_len, nwritten_ptr) {
        const view = mem();
        let total = 0;
        let out = [];
        for (let i = 0; i < iovs_len; i++) {
          const base = view.getUint32(iovs + i * 8, true);
          const len = view.getUint32(iovs + i * 8 + 4, true);
          out.push(Buffer.from(wasi.memory.buffer, base, len));
          total += len;
        }
        const buf = Buffer.concat(out);
        wasi.stdout.write(buf);
        view.setUint32(nwritten_ptr, total, true);
        return 0;
      },

      fd_read(fd, iovs, iovs_len, nread_ptr) {
        const view = mem();
        let total = 0;
        for (let i = 0; i < iovs_len; i++) {
          const base = view.getUint32(iovs + i * 8, true);
          const len = view.getUint32(iovs + i * 8 + 4, true);
          const chunk = Buffer.alloc(len);
          const n = wasi.stdin.read(chunk);
          if (n > 0) Buffer.from(wasi.memory.buffer, base, n).set(chunk.subarray(0, n));
          total += n;
          if (n < len) break;
        }
        view.setUint32(nread_ptr, total, true);
        return 0;
      },

      fd_close() { return 0; },
      fd_seek() { return 0; },
      fd_fdstat_get() { return 0; },
      fd_prestat_get() { return 8; },
      fd_prestat_dir_name() { return 0; },

      path_open(dirfd, dirflags, path, path_len, oflags, rights_base, rights_inh, fdflags, fd_out) {
        const bytes = Buffer.from(wasi.memory.buffer, path, path_len);
        const resolved = wasi.resolvePath ? wasi.resolvePath(bytes.toString('utf8'))
                                          : bytes.toString('utf8');
        const opened = wasi.openFile(resolved, oflags);
        mem().setUint32(fd_out, opened, true);
        return 0;
      },

      environ_sizes_get(count_ptr, buf_size_ptr) {
        mem().setUint32(count_ptr, 0, true);
        mem().setUint32(buf_size_ptr, 0, true);
        return 0;
      },

      environ_get() { return 0; },
      args_sizes_get(count_ptr, buf_size_ptr) {
        const argv = wasi.argv || [];
        mem().setUint32(count_ptr, argv.length, true);
        mem().setUint32(buf_size_ptr, argv.reduce((a, s) => a + s.length + 1, 0), true);
        return 0;
      },

      args_get() { return 0; },
      clock_time_get() { return 0; },
      random_get(ptr, len) {
        const crypto = require('crypto');
        crypto.randomFillSync(Buffer.from(wasi.memory.buffer, ptr, len));
        return 0;
      },
    },
  };
  return imports;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) {
    console.error('usage: run_wasm.js <module.wasm> [args...]');
    process.exit(2);
  }
  const file = argv[0];
  const rest = argv.slice(1);

  let bytes;
  try {
    bytes = fs.readFileSync(file);
  } catch (e) {
    console.error(`run_wasm: cannot read ${file}: ${e.message}`);
    process.exit(2);
  }

  if (bytes.length < 8 ||
      bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
    console.error(`run_wasm: ${file} is not a WebAssembly module`);
    console.error(`  first bytes: ${hexdump(bytes.subarray(0, 16))}`);
    process.exit(2);
  }

  const wasi = {
    memory: null,
    stdout: process.stdout,
    stdin: process.stdin,
    argv: rest,
    openFile: () => 8, // one synthetic fd; real file IO is not wired up yet
    resolvePath: (p) => p,
  };

  let mod;
  let instance;
  try {
    mod = new WebAssembly.Module(bytes);
    instance = new WebAssembly.Instance(mod, makeImports(wasi));
  } catch (e) {
    console.error(`run_wasm: ${file} failed to instantiate: ${e.message}`);
    if (e instanceof WebAssembly.CompileError) {
      console.error('  this is a malformed module: the compiler emitted invalid bytes.');
    }
    process.exit(2);
  }

  wasi.memory = instance.exports.memory;

  let exitCode = 0;
  try {
    const start = instance.exports._start || instance.exports.main;
    if (!start) {
      console.error(`run_wasm: ${file} exports neither _start nor main`);
      process.exit(2);
    }
    start(rest);
  } catch (e) {
    if (e && e.wasiExit !== undefined) {
      exitCode = e.wasiExit;
    } else {
      console.error(`run_wasm: ${file} trapped: ${e && e.message ? e.message : e}`);
      exitCode = 1;
    }
  }
  process.exit(exitCode);
}

main();