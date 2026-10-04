# frozen_string_literal: true

require_relative "emitter"

module LdplWasm
  module Wasm
    # A hand-assembled "hello" module, used as the emitter's own smoke test.
    #
    # This exists so that a bug in the emitter surfaces as a failing test rather
    # than as a mysterious failure somewhere in the compiler. It writes
    # "hello, wasm\n" through wasi_snapshot_preview1.fd_write using the standard
    # two-argument stack machine shape.
    class Smoke
      STR = "hello, wasm\n"

      # iovec: { buf: i32, buf_len: i32 }
      IOVEC_OFFSET = 1024
      DATA_OFFSET = 1088

      def self.build
        mod = Module.new(name: "smoke")
        mod.memory_pages = 1

        fd_write = mod.import_function("wasi_snapshot_preview1", "fd_write",
                                       [I32, I32, I32, I32], [I32])
        proc_exit = mod.import_function("wasi_snapshot_preview1", "proc_exit",
                                        [I32], [])

        start = mod.declare_function("_start", params: [], results: [])

        mod.build(start) do |b|
          # iov[0].buf = DATA_OFFSET
          b.i32_const(IOVEC_OFFSET)
          b.i32_const(DATA_OFFSET)
          b.i32_store(offset: 0)
          # iov[0].buf_len = STR.bytesize
          b.i32_const(IOVEC_OFFSET + 4)
          b.i32_const(STR.bytesize)
          b.i32_store(offset: 0)
          # fd_write(1, iov, 1, nwritten)
          b.i32_const(1)
          b.i32_const(IOVEC_OFFSET)
          b.i32_const(1)
          b.i32_const(IOVEC_OFFSET + 8)
          b.call(fd_write)
          b.drop
          # proc_exit(0)
          b.i32_const(0)
          b.call(proc_exit)
        end

        mod.export_func("_start", start)
        mod.export_memory
        mod.data(DATA_OFFSET, STR.b)
        mod
      end

      def self.emit
        build.emit
      end
    end
  end
end