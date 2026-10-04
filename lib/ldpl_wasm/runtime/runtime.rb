# frozen_string_literal: true

module LdplWasm
  # The LDPL runtime, assembled directly into WebAssembly by this file.
  #
  # No C, no precompiled blob: every instruction of every helper is emitted here.
  # Helpers are emitted on demand, so a program that only prints a literal does
  # not carry the number formatter or the reader.
  #
  # TEXT is represented *inline* in static memory as a fixed record:
  #
  #   +0  len   byte length
  #   +4  cap   byte capacity (always TEXT_CAP for a variable)
  #   +8  bytes
  #
  # Keeping TEXT inline means the common case -- print a variable, compare two
  # variables, assign one to another -- is a load and a store with no runtime call
  # and no allocation. The trade-off is a fixed maximum length (TEXT_CAP), which is
  # a real limitation of this version and is listed in docs/limitations.md.
  class Runtime
    I32 = Wasm::I32
    I64 = Wasm::I64
    F64 = Wasm::F64

    TEXT_CAP = 256
    TEXT_HDR = 8

    # Scratch, below the static globals.
    IOVEC          = 0x0000
    NWRITTEN       = 0x0010
    READ_BUF       = 0x0020
    READ_CAP       = 0x1000
    SCRATCH_A      = 0x1100
    SCRATCH_B      = 0x1200
    SCRATCH_JOIN_A = 0x1200
    SCRATCH_JOIN_B = 0x1300

    def initialize(mod, analyzer)
      @mod = mod
      @an = analyzer
      @cache = {}
      @proc_exit = mod.import_function("wasi_snapshot_preview1", "proc_exit", [I32], [])
      @fd_write = mod.import_function("wasi_snapshot_preview1", "fd_write",
                                     [I32, I32, I32, I32], [I32])
      @fd_read = mod.import_function("wasi_snapshot_preview1", "fd_read",
                                    [I32, I32, I32, I32], [I32])
    end

    attr_reader :mod

    def proc_exit_func = @proc_exit

    def fn(name, params, results, param_names: [])
      key = name.to_sym
      @cache[key] ||= @mod.declare_function(key.to_s, params: params, results: results,
                                                     param_names: param_names)
    end

    def method_missing(name, *args)
      key = "rt_#{name.to_s.sub(/_\z/, '')}".to_sym
      return @cache[key] if @cache.key?(key)

      super
    end

    def respond_to_missing?(name, include_private = false)
      @cache.key?("rt_#{name.to_s.sub(/_\z/, '')}".to_sym) || super
    end

    # Emit helpers on demand. Codegen calls this before generating so that a
    # runtime function is present whenever codegen may reach for it; relying on the
    # analyser to predict which ones are used made missing helpers a nil call at
    # emission time instead of a clear message.
    def ensure(*flags)
      emit_write if flags.include?(:io) || flags.include?(:accept)
      emit_number_format if flags.include?(:number)
      emit_read if flags.include?(:accept)
      emit_compare if flags.include?(:compare) || flags.include?(:number) ||
                     flags.include?(:accept)
      emit_accept_helpers if flags.include?(:accept)
      self
    end

    # Emit every helper the analysed program needs.
    def declare(needs)
      emit_write if needs[:io]
      emit_number_format if needs[:number]
      emit_read if needs[:accept]
      emit_compare if needs[:compare]
      emit_accept_helpers if needs[:accept]
      self
    end

    # ------------------------------------------------------------------- output

    # rt_write_text(t) -- write the bytes of the record at `t` to stdout.
    def emit_write
      return if @cache.key?(:rt_write_text)

      # Build the iovec in the scratch area each call.
      f = fn(:rt_write_text, [I32], [], param_names: %w[t])
      @mod.build(f) do |b|
        b.local(I32, :len)
        b.lget(:t)
        b.i32_load(offset: 0)
        b.local_set(:len)

        b.i32_const(IOVEC)
        b.lget(:t)
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.i32_store(offset: 0)
        b.i32_const(IOVEC + 4)
        b.lget(:len)
        b.i32_store(offset: 0)

        b.i32_const(1)
        b.i32_const(IOVEC)
        b.i32_const(1)
        b.i32_const(NWRITTEN)
        b.call(@fd_write)
        b.drop
      end

      # rt_write_mem(src, len) -- write raw bytes (used for string literals).
      f = fn(:rt_write_mem, [I32, I32], [], param_names: %w[src len])
      @mod.build(f) do |b|
        b.i32_const(IOVEC)
        b.lget(:src)
        b.i32_store(offset: 0)
        b.i32_const(IOVEC + 4)
        b.lget(:len)
        b.i32_store(offset: 0)
        b.i32_const(1)
        b.i32_const(IOVEC)
        b.i32_const(1)
        b.i32_const(NWRITTEN)
        b.call(@fd_write)
        b.drop
      end
    end

    def write_text_func = @cache[:rt_write_text]
    def write_mem_func = @cache[:rt_write_mem]

    # ------------------------------------------------------- number conversion

    def emit_number_format
      return if @cache.key?(:rt_num_to_text)

      emit_fixed_number_writer

      # rt_num_to_text(v) -> pointer to a scratch TEXT record holding the decimal
      # form of `v`. One formatter, not two: an earlier version had a fast integer
      # path and it disagreed with the slow path.
      f = fn(:rt_num_to_text, [F64], [I32], param_names: %w[v])
      @mod.build(f) do |b|
        b.lget(:v)
        b.call(@cache[:rt_num_fixed])
      end
    end

    # rt_num_fixed(v) -> pointer to a scratch TEXT record.
    #
    # Prints the sign, the integer part, then fractional digits until the
    # remainder is zero or 15 digits have been written, then strips trailing
    # zeros. Integral values therefore print exactly (the loop writes no fraction),
    # which is what makes large integers round-trip.
    def emit_fixed_number_writer
      return if @cache.key?(:rt_num_fixed)

      f = fn(:rt_num_fixed, [F64], [I32], param_names: %w[v])
      @mod.build(f) do |b|
        b.local(I32, :out)
        b.local(I32, :i)
        b.local(I32, :n)
        b.local(F64, :av)
        b.local(F64, :frac)
        b.local(I64, :ip)
        b.local(F64, :__f2)

        b.i32_const(SCRATCH_B)
        b.local_set(:out)
        b.i32_const(SCRATCH_B)
        b.i32_const(0)
        b.i32_store(offset: 0)

        b.lget(:v)
        b.f64_abs
        b.local_set(:av)
        b.lget(:v)
        b.f64_const(0.0)
        b.f64_lt
        b.if_ do
          b.lget(:out)
          b.i32_const(0x2D)
          b.i32_store8
          b.lget(:out)
          b.i32_const(1)
          b.i32_add
          b.local_set(:out)
        end

        # integer part, written least-significant digit first then reversed
        b.lget(:av)
        b.i64_trunc_f64_u
        b.local_set(:ip)
        b.lget(:out)
        b.i32_load(offset: 0)
        b.local_set(:n)
        b.block do
          b.loop do
            b.lget(:out)
            b.lget(:ip)
            b.i64_const(10)
            b.i64_rem_u
            b.i64_const(48)
            b.i64_add
            b.i32_wrap_i64
            b.i32_store8
            b.lget(:out)
            b.i32_const(1)
            b.i32_add
            b.local_set(:out)
            b.lget(:ip)
            b.i64_const(10)
            b.i64_div_u
            b.local_set(:ip)
            b.lget(:ip)
            b.i64_eqz
            b.i32_eqz
            b.br_if(0)
          end
        end
        # reverse the digits we just wrote into [n, out)
        b.local_get(:out)
b.i32_const(1)
        b.i32_sub
        b.local_set(:i)
        b.block do
          b.loop do
            b.lget(:i)
            b.lget(:n)
            b.i32_lt_s
            b.br_if(1)
            b.lget(:i)
            b.lget(:n)
            b.i32_sub
            b.local_set(:i)
            b.lget(:out)
            b.lget(:i)
            b.i32_add
            b.i32_load8_u
            b.lget(:out)
            b.lget(:n)
            b.i32_add
            b.i32_store8
            b.lget(:i)
            b.i32_const(1)
            b.i32_add
            b.local_set(:n)
            b.br(0)
          end
        end

        # fractional part. `local_tee` *replaces* the top of the stack, so a
        # second copy of av has to be pushed explicitly before the subtraction.
        b.lget(:av)
        b.local_set(:frac)
        b.lget(:av)
        b.lget(:frac)
        b.f64_trunc
        b.f64_sub
        b.local_set(:frac)
        b.lget(:frac)
        b.f64_const(0.0)
        b.f64_ne
        b.if_ do
          b.lget(:out)
          b.i32_const(0x2E)
          b.i32_store8
          b.lget(:out)
          b.i32_const(1)
          b.i32_add
          b.local_set(:out)

          b.i32_const(0)
          b.local_set(:i)
          b.block do
            b.loop do
              b.lget(:i)
              b.i32_const(15)
              b.i32_ge_u
              b.br_if(1)
              b.lget(:frac)
              b.f64_const(10.0)
              b.f64_mul
              b.local_set(:frac)
              b.lget(:out)
              b.lget(:frac)
              b.f64_trunc
              b.i64_trunc_f64_u
              b.i64_const(48)
              b.i64_add
              b.i32_wrap_i64
              b.i32_store8
              b.lget(:out)
              b.i32_const(1)
              b.i32_add
              b.local_set(:out)
              b.lget(:frac)
              b.local_set(:__f2)
              b.lget(:frac)
              b.lget(:__f2)
              b.f64_trunc
              b.f64_sub
              b.local_set(:frac)
              b.lget(:i)
              b.i32_const(1)
              b.i32_add
              b.local_set(:i)
              b.lget(:frac)
              b.f64_const(0.0)
              b.f64_eq
              b.i32_eqz
              b.br_if(0)
            end
          end

          # strip trailing zeros back to (but not including) the decimal point
          b.block do
            b.loop do
              b.lget(:out)
              b.i32_const(1)
              b.i32_sub
              b.i32_load8_u
              b.i32_const(0x30)
              b.i32_ne
              b.br_if(1)
              b.lget(:out)
              b.i32_const(1)
              b.i32_sub
              b.local_set(:out)
              b.lget(:out)
              b.i32_const(TEXT_HDR)
              b.i32_le_u
              b.br_if(1)
              b.br(0)
            end
          end
        end

        b.i32_const(SCRATCH_B)
        b.lget(:out)
        b.i32_const(SCRATCH_B)
        b.i32_sub
        b.i32_store(offset: 0)
        b.i32_const(SCRATCH_B)
      end
    end

    # ----------------------------------------------------------------- reading

    def emit_read
      return if @cache.key?(:rt_read_line)

      # rt_read_line(dst) -- read one line into the record at `dst`.
      f = fn(:rt_read_line, [I32], [], param_names: %w[dst])
      @mod.build(f) do |b|
        b.local(I32, :n)
        b.i32_const(READ_BUF)
        b.i32_const(READ_CAP)
        b.i32_store(offset: 0)
        b.i32_const(READ_BUF + 4)
        b.i32_const(0)
        b.i32_store(offset: 0)

        b.i32_const(0)
        b.i32_const(READ_BUF)
        b.i32_const(1)
        b.i32_const(NWRITTEN)
        b.call(@fd_read)
        b.drop

        b.i32_const(NWRITTEN)
        b.i32_load(offset: 0)
        b.local_set(:n)

        # drop a trailing CR
        b.lget(:n)
        b.i32_const(0)
        b.i32_gt_s
        b.if_ do
          b.i32_const(READ_BUF)
          b.lget(:n)
          b.i32_const(1)
          b.i32_sub
          b.i32_add
          b.i32_load8_u
          b.i32_const(13)
          b.i32_eq
          b.if_ do
            b.lget(:n)
            b.i32_const(1)
            b.i32_sub
            b.local_set(:n)
          end
        end

        b.lget(:dst)
        b.clamp_local(:n, TEXT_CAP)
        b.local_set(:n)
        b.i32_store(offset: 0)
        b.lget(:dst)
        b.i32_const(TEXT_CAP)
        b.i32_store(offset: 4)
        b.lget(:dst)
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.i32_const(READ_BUF)
        b.clamp_local(:n, TEXT_CAP)
        b.local_set(:n)
        b.memory_copy
      end
    end

    # ------------------------------------------------------------- arithmetic

    def emit_compare
      return if @cache.key?(:rt_num_eq)

      # rt_num_eq(a, b) -> i32, epsilon-tolerant, matching LDPL's documented
      # behaviour rather than exact binary64 equality.
      f = fn(:rt_num_eq, [F64, F64], [I32], param_names: %w[a b])
      @mod.build(f) do |b|
        b.lget(:a)
        b.lget(:b)
        b.f64_sub
        b.f64_abs
        b.f64_const(1e-9)
        b.f64_lt
      end

      f = fn(:rt_div, [F64, F64], [F64], param_names: %w[a b])
      @mod.build(f) do |b|
        # wasm f64.div traps on a zero divisor; LDPL would rather produce 0.
        b.lget(:b)
        b.f64_const(0.0)
        b.f64_eq
        b.if_else(F64) { b.f64_const(0.0) }
        b.lget(:a)
        b.lget(:b)
        b.f64_div
      end

      # Modulo with floor semantics, so the sign follows the divisor.
      f = fn(:rt_mod, [F64, F64], [F64], param_names: %w[a b])
      @mod.build(f) do |b|
        b.local(F64, :r)
        b.lget(:b)
        b.f64_const(0.0)
        b.f64_eq
        b.if_else(F64) { b.f64_const(0.0) }
        b.local_set(:r)
        b.lget(:a)
        b.lget(:b)
        b.f64_div
        b.f64_nearest
        b.local_set(:r)
        b.lget(:a)
        b.lget(:r)
        b.lget(:b)
        b.f64_mul
        b.f64_sub
      end

      # rt_str_eq(a, b) -> i32, byte-wise over the two TEXT records.
      f = fn(:rt_str_eq, [I32, I32], [I32], param_names: %w[a b])
      @mod.build(f) do |b|
        b.local(I32, :n)
        b.local(I32, :i)
        b.lget(:a)
        b.i32_load(offset: 0)
        b.lget(:b)
        b.i32_load(offset: 0)
        b.i32_ne
        # A void `if` must not push in one arm only; the early return arm ends in
        # `return`, which is stack-polymorphic, so the arm is allowed to leave a
        # value behind.
        b.if_else_void do |arm|
          if arm == :then
            b.i32_const(0)
            b.return_
          end
        end
        b.lget(:a)
        b.i32_load(offset: 0)
        b.local_set(:n)
        b.i32_const(0)
        b.local_set(:i)
        b.block do
          b.loop do
            b.lget(:i)
            b.lget(:n)
            b.i32_ge_u
            b.br_if(1)
            b.lget(:a)
            b.lget(:i)
            b.i32_add
            b.i32_load8_u
            b.lget(:b)
            b.lget(:i)
            b.i32_add
            b.i32_load8_u
            b.i32_ne
            b.br_if(1)
            b.lget(:i)
            b.i32_const(1)
            b.i32_add
            b.local_set(:i)
            b.br(0)
          end
        end
        b.i32_const(1)
      end

      # rt_text_copy(dst, src) -- used by assignment and JOIN.
      f = fn(:rt_text_copy, [I32, I32], [], param_names: %w[dst src])
      @mod.build(f) do |b|
        b.local(I32, :n)
        # min(len, TEXT_CAP): select(a, b, cond) with a=len, b=TEXT_CAP.
        b.lget(:src)
        b.i32_load(offset: 0)
        b.local_set(:n)
        b.clamp_local(:n, TEXT_CAP)
        b.local_set(:n)
        b.lget(:dst)
        b.lget(:n)
        b.i32_store(offset: 0)
        b.lget(:dst)
        b.i32_const(TEXT_CAP)
        b.i32_store(offset: 4)
        b.lget(:dst)
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.lget(:src)
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.lget(:n)
        b.memory_copy
      end

      # rt_text_join(dst, a, b)
      f = fn(:rt_text_join, [I32, I32, I32], [], param_names: %w[dst a b])
      @mod.build(f) do |b|
        b.local(I32, :la)
        b.local(I32, :lb)
        b.local(I32, :n)
        b.lget(:a)
        b.i32_load(offset: 0)
        b.local_set(:la)
        b.lget(:b)
        b.i32_load(offset: 0)
        b.local_set(:lb)
        b.lget(:la)
        b.lget(:lb)
        b.i32_add
        b.local_set(:n)
        b.clamp_local(:n, TEXT_CAP)
        b.local_set(:n)
        b.lget(:dst)
        b.lget(:n)
        b.i32_store(offset: 0)
        b.lget(:dst)
        b.i32_const(TEXT_CAP)
        b.i32_store(offset: 4)
        b.lget(:dst)
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.lget(:a)
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.lget(:la)
        b.memory_copy
        # second half: dst + 8 + la <- b + 8, lb bytes
        b.lget(:dst)
        b.lget(:la)
        b.i32_add
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.lget(:b)
        b.i32_const(TEXT_HDR)
        b.i32_add
        b.lget(:lb)
        b.memory_copy
      end

      # rt_text_concat_scratch(a, b) -> pointer to a scratch record
      f = fn(:rt_text_concat_scratch, [I32, I32], [I32], param_names: %w[a b])
      @mod.build(f) do |b|
        b.i32_const(SCRATCH_A)
        b.lget(:a)
        b.lget(:b)
        b.call(@cache[:rt_text_join])
        b.i32_const(SCRATCH_A)
      end

      # rt_num_from_text(t) -> f64
      f = fn(:rt_num_from_text, [I32], [F64], param_names: %w[t])
      @mod.build(f) do |b|
        b.local(F64, :v)
        b.local(I32, :i)
        b.local(I32, :n)
        b.local(I32, :neg)
        b.f64_const(0.0)
        b.local_set(:v)
        b.i32_const(0)
        b.local_set(:neg)
        b.i32_const(0)
        b.local_set(:i)
        b.lget(:t)
        b.i32_load(offset: 0)
        b.local_set(:n)
        # skip leading spaces
        b.block do
          b.loop do
            b.lget(:i)
            b.lget(:n)
            b.i32_ge_u
            b.br_if(1)
            b.lget(:t)
            b.lget(:i)
            b.i32_add
            b.i32_const(TEXT_HDR)
            b.i32_add
            b.i32_load8_u
            b.i32_const(32)
            b.i32_gt_u
            b.i32_eqz
            b.br_if(1)
            b.lget(:i)
            b.i32_const(1)
            b.i32_add
            b.local_set(:i)
            b.br(0)
          end
        end
        b.lget(:i)
        b.lget(:n)
        b.i32_lt_u
        b.if_ do
          b.lget(:t)
          b.lget(:i)
          b.i32_add
          b.i32_const(TEXT_HDR)
          b.i32_add
          b.i32_load8_u
          b.i32_const(0x2D)
          b.i32_eq
          b.if_ { b.i32_const(1); b.local_set(:neg) }
        end
        b.block do
          b.loop do
            b.lget(:i)
            b.lget(:n)
            b.i32_ge_u
            b.br_if(1)
            b.lget(:t)
            b.lget(:i)
            b.i32_add
            b.i32_const(TEXT_HDR)
            b.i32_add
            b.i32_load8_u
            b.local_tee(:i)
            b.i32_const(48)
            b.i32_lt_u
            b.i32_const(57)
            b.i32_gt_u
            b.i32_or
            b.i32_const(0x2E)
            b.i32_eq
            b.i32_or
            b.if_else(I32) do |which|
              if which == :then
                b.br(1)
              else
                b.lget(:v)
                b.f64_const(10.0)
                b.f64_mul
                b.lget(:i)
                b.i32_const(48)
                b.i32_sub
                b.f64_convert_i32_s
                b.f64_add
                b.local_set(:v)
                b.lget(:i)
                b.i32_const(1)
                b.i32_add
                b.local_set(:i)
              end
            end
            b.br(0)
          end
        end
        b.lget(:neg)
        b.if_ { b.lget(:v); b.f64_neg }
        b.local_get(:v)
      end

      # rt_num_into_scratch(v) -- format into SCRATCH_JOIN_A and return its address.
      f = fn(:rt_num_into_scratch, [F64], [I32], param_names: %w[v])
      @mod.build(f) do |b|
        b.lget(:v)
        b.call(@cache[:rt_num_fixed])
        b.i32_const(SCRATCH_JOIN_A)
      end

      # rt_num_into_text(dst, v)
      f = fn(:rt_num_into_text, [I32, F64], [], param_names: %w[dst v])
      @mod.build(f) do |b|
        b.lget(:dst)
        b.lget(:v)
        b.call(@cache[:rt_num_fixed])
        b.call(@cache[:rt_text_copy])
      end
    end

    def num_to_text_func = @cache[:rt_num_to_text]
    def num_eq_func = @cache[:rt_num_eq]
    def div_f64_func = @cache[:rt_div]
    def mod_f64_func = @cache[:rt_mod]
    def str_eq_func = @cache[:rt_str_eq]
    def text_copy_func = @cache[:rt_text_copy]
    def text_join_func = @cache[:rt_text_join]
    def text_concat_func = @cache[:rt_text_concat_scratch]
    def num_from_text_func = @cache[:rt_num_from_text]
    def read_line_func = @cache[:rt_read_line]

    # rt_accept_text(dst) / rt_accept_number(dst)
    def emit_accept_helpers
      return if @cache.key?(:rt_accept_text)

      f = fn(:rt_accept_text, [I32], [], param_names: %w[dst])
      @mod.build(f) { |b| b.lget(:dst); b.call(@cache[:rt_read_line]) }

      f = fn(:rt_accept_number, [I32], [], param_names: %w[dst])
      @mod.build(f) do |b|
        b.i32_const(SCRATCH_A)
        b.call(@cache[:rt_read_line])
        b.lget(:dst)
        b.i32_const(SCRATCH_A)
        b.call(@cache[:rt_num_from_text])
        b.f64_store
      end
    end

    def accept_text_func = @cache[:rt_accept_text]
    def accept_number_func = @cache[:rt_accept_number]
    def num_fixed_func = @cache[:rt_num_fixed]
    def num_into_scratch_func = @cache[:rt_num_into_scratch]
  end
end