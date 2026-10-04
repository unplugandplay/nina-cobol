# frozen_string_literal: true

module LdplWasm
  # A hand-rolled WebAssembly binary encoder.
  #
  # Deliberately minimal: we emit exactly the sections LDPL needs (type, import,
  # function, table, memory, export, element, code, data) and nothing else. No
  # bulk of precompiled blobs, no external toolchain -- every byte of every
  # module this compiler produces is generated here.
  module Wasm
    I32 = :i32
    I64 = :i64
    F32 = :f32
    F64 = :f64
    VOID = :void

    VALTYPE = {
      i32: 0x7F,
      i64: 0x7E,
      f32: 0x7D,
      f64: 0x7C
    }.freeze

    # LEB128. WebAssembly uses unsigned LEB for indices/offsets and *signed* LEB
    # for constant immediates; mixing them up silently corrupts modules, so they
    # are kept as separate functions rather than one with a flag.
    module Leb
      module_function

      def u(n)
        raise ArgumentError, "negative uleb: #{n}" if n.negative?

        out = +"".b
        loop do
          byte = n & 0x7F
          n >>= 7
          if n.zero?
            out << byte.chr
            break
          end
          out << (byte | 0x80).chr
        end
        out
      end

      # Signed LEB128. Termination depends on the *sign* of what is left, which
      # is why the loop cannot be shared with `u`.
      def s(n)
        out = +"".b
        loop do
          byte = n & 0x7F
          n >>= 7
          done = (n.zero? && (byte & 0x40).zero?) ||
                 (n == -1 && (byte & 0x40) != 0)
          if done
            out << byte.chr
            break
          end
          out << (byte | 0x80).chr
        end
        out
      end
    end

    # A declared (or imported) function. Index assignment happens in Module.
    class FuncDef
      attr_reader :name
      attr_accessor :index, :type_index, :imported, :locals, :code, :param_names, :params

      def initialize(name:, params: [], results: [], param_names: [])
        @name = name
        @params = params
        @param_names = param_names
        @results = results
        @index = nil
        @type_index = nil
        @imported = false
        @code = nil
      end

      def results
        @results
      end
    end

    # Instruction stream builder for one function body.
    #
    # Locals are addressed by name wherever possible. Names are resolved to
    # indices on first use, which keeps codegen readable and makes a typo fail
    # loudly (NameError) instead of silently reading the wrong local.
    class Func
      attr_reader :defn

      def initialize(defn)
        @defn = defn
        @code = +"".b
        @local_types = defn.params.dup
        # Local names are normalised to symbols: callers pass symbols while
        # `param_names` arrives as strings, and a mixed table silently misses.
        @names = {}
        defn.param_names.each_with_index do |n, i|
          @names[n.to_sym] = i if n
        end
        @next = @local_types.length
        @label_depth = 0
      end

      # --- locals -------------------------------------------------------------

      def local(type, name = nil)
        raise ArgumentError, "bad local type #{type.inspect}" unless VALTYPE.key?(type)
        key = name&.to_sym
        raise ArgumentError, "duplicate local name #{key.inspect}" if key && @names.key?(key)

        idx = @next
        @next += 1
        @local_types << type
        @names[key] = idx if key
        idx
      end

      def ref(name_or_index)
        return name_or_index if name_or_index.is_a?(Integer)

        @names.fetch(name_or_index) do
          raise NameError, "unknown local #{name_or_index.inspect} in #{@defn.name}"
        end
      end

      def lget(n) = local_get(ref(n))
      def lset(n) = local_set(ref(n))
      def ltee(n) = local_tee(ref(n))

      # --- raw emission -------------------------------------------------------

      def raw(bytes)
        @code << bytes
        self
      end

      def op(code)
        raw([code].pack("C"))
      end

      def op2(prefix, code)
        raw([prefix, code].pack("CC"))
      end

      # --- constants ----------------------------------------------------------

      def i32_const(v) = op(0x41) && raw(Leb.s(v))
      def i64_const(v) = op(0x42) && raw(Leb.s(v))
      def f32_const(v) = op(0x43) && raw([v].pack("e"))
      def f64_const(v) = op(0x44) && raw([v].pack("E"))

      def f64_bits(v)
        i64_const([v].pack("E").unpack1("q"))
      end

      # --- variables / calls --------------------------------------------------

      def local_get(i) = op(0x20) && raw(Leb.u(ref(i)))
      def local_set(i) = op(0x21) && raw(Leb.u(ref(i)))
      def local_tee(i) = op(0x22) && raw(Leb.u(ref(i)))
      def global_get(i) = op(0x23) && raw(Leb.u(i))
      def global_set(i) = op(0x24) && raw(Leb.u(i))

      def call(target)
        idx = target.is_a?(FuncDef) ? target.index : target
        op(0x10) && raw(Leb.u(idx))
      end

      def call_indirect(type_index, table_index = 0)
        op(0x11) && raw(Leb.u(type_index)) && raw(Leb.u(table_index))
      end

      # --- control flow -------------------------------------------------------
      #
      # WebAssembly control structures are prefix-opcode / body / `end`, and the
      # body is emitted between the two. Because bytes are appended in order, the
      # header is written on entry to the helper and the `end` on the way out; the
      # caller's block becomes the body. Labels are relative to the innermost
      # enclosing structure, so `@label_depth` tracks how many `br` targets are
      # reachable.

      def block(result_type = nil)
        op(0x02)
        raw(result_type ? [VALTYPE.fetch(result_type)].pack("C") : "\x40".b)
        @label_depth += 1
        yield
        @label_depth -= 1
        op(0x0B)
      end

      def loop(result_type = nil)
        op(0x03)
        raw(result_type ? [VALTYPE.fetch(result_type)].pack("C") : "\x40".b)
        @label_depth += 1
        yield
        @label_depth -= 1
        op(0x0B)
      end

      # `while cond do body` as a structured loop. `cond` must leave an i32.
      # br_if(1) exits the block; br(0) jumps back to the loop head.
      def while_(&cond)
        block do
          loop do
            cond.call
            i32_eqz
            br_if(1)
            yield
            br(0)
          end
        end
      end

      # Statement-position conditional. The condition (i32) is already on the
      # stack; no result value.
      def if_
        op(0x04)
        raw("\x40".b)
        @label_depth += 1
        yield
        @label_depth -= 1
        op(0x0B)
      end
      alias when if_

      # if/else in statement position, both branches given.
      def if_else_void
        op(0x04)
        raw("\x40".b)
        @label_depth += 1
        yield :then
        op(0x05)
        yield :else
        @label_depth -= 1
        op(0x0B)
      end

      # Expression-position conditional producing a value. When only one block is
      # given the else branch yields `else_result` (default 0).
      def if_else(result_type, else_result: nil)
        op(0x04)
        raw([VALTYPE.fetch(result_type)].pack("C"))
        @label_depth += 1
        yield
        op(0x05)
        zero_of(result_type, else_result)
        @label_depth -= 1
        op(0x0B)
      end

      # `if` producing a value, with an explicit else block.
      def if_else_b(result_type)
        op(0x04)
        raw([VALTYPE.fetch(result_type)].pack("C"))
        @label_depth += 1
        yield :then
        op(0x05)
        yield :else
        @label_depth -= 1
        op(0x0B)
      end

      # Clamp the i32 local `name` to at most `max`, leaving the result on the
      # stack. Implemented as an `if` used as a value producer: the obvious
      # `select` spelling needs its condition's operands on the stack too, and the
      # surplus value they leave behind is only caught by validation.
      def clamp_local(name, max)
        key = ref(name)
        tmp = (@clamp_tmp ||= local(I32))
        local_get(key)
        local_set(tmp)
        local_get(tmp)
        i32_const(max)
        i32_gt_u
        # Both arms must leave exactly one value. An `if` with a void block type
        # that pushes in only one arm leaves the stack at different depths on the
        # two paths, which validation rejects as a fallthrough mismatch.
        if_else_void do |arm|
          if arm == :then
            i32_const(max)
          else
            local_get(tmp)
          end
        end
      end

      def zero_of(type, value = nil)
        case type
        when I32 then i32_const(value || 0)
        when I64 then i64_const(value || 0)
        when F64 then f64_const(value.nil? ? 0.0 : value.to_f)
        end
      end

      def unreachable_ = op(0x00)
      def nop = op(0x01)
      def br(depth) = op(0x0C) && raw(Leb.u(depth))
      def br_if(depth) = op(0x0D) && raw(Leb.u(depth))
      def return_ = op(0x0F)
      def drop = op(0x1A)
      def select = op(0x1B)

      # Branch out of `depth` enclosing structures when the condition holds.
      def br_if_void(depth)
        i32_eqz
        br_if(depth + 1)
      end

      # --- memory -------------------------------------------------------------

      MEMORY_OPS = {
        i32_load: [0x28, I32, 2], i64_load: [0x29, I64, 3],
        f32_load: [0x2A, F32, 2], f64_load: [0x2B, F64, 3],
        i32_load8_s: [0x2C, I32, 0], i32_load8_u: [0x2D, I32, 0],
        i32_load16_s: [0x2E, I32, 1], i32_load16_u: [0x2F, I32, 1],
        i64_load8_s: [0x30, I64, 0], i64_load8_u: [0x31, I64, 0],
        i64_load16_s: [0x32, I64, 1], i64_load16_u: [0x33, I64, 1],
        i64_load32_s: [0x34, I64, 2], i64_load32_u: [0x35, I64, 2],
        i32_store: [0x36, I32, 2], i64_store: [0x37, I64, 3],
        f32_store: [0x38, F32, 2], f64_store: [0x39, F64, 3],
        i32_store8: [0x3A, I32, 0], i32_store16: [0x3B, I32, 1],
        i64_store8: [0x3C, I64, 0], i64_store16: [0x3D, I64, 1],
        i64_store32: [0x3E, I64, 2]
      }.freeze

      MEMORY_OPS.each do |name, (code, type, natural)|
        define_method(name) do |offset: 0, align: nil|
          op(code)
          raw(Leb.u(align || natural))
          raw(Leb.u(offset))
          type
        end
      end

      def memory_size = op(0x3F) && raw("\x00".b)
      def memory_grow = op(0x40) && raw("\x00".b)

      def memory_copy = op2(0xFC, 0x0A) && raw("\x00\x00".b)
      def memory_fill = op2(0xFC, 0x0B) && raw("\x00".b)

      # --- numeric / comparison opcodes --------------------------------------

      OPCODES = {
        i32_eqz: 0x45, i32_eq: 0x46, i32_ne: 0x47,
        i32_lt_s: 0x48, i32_lt_u: 0x49, i32_gt_s: 0x4A, i32_gt_u: 0x4B,
        i32_le_s: 0x4C, i32_le_u: 0x4D, i32_ge_s: 0x4E, i32_ge_u: 0x4F,
        i64_eqz: 0x50, i64_eq: 0x51, i64_ne: 0x52,
        i64_lt_s: 0x53, i64_lt_u: 0x54, i64_gt_s: 0x55, i64_gt_u: 0x56,
        i64_le_s: 0x57, i64_le_u: 0x58, i64_ge_s: 0x59, i64_ge_u: 0x5A,
        f32_eq: 0x5B, f32_ne: 0x5C, f32_lt: 0x5D, f32_gt: 0x5E, f32_le: 0x5F, f32_ge: 0x60,
        f64_eq: 0x61, f64_ne: 0x62, f64_lt: 0x63, f64_gt: 0x64, f64_le: 0x65, f64_ge: 0x66,
        i32_clz: 0x67, i32_ctz: 0x68, i32_popcnt: 0x69,
        i32_add: 0x6A, i32_sub: 0x6B, i32_mul: 0x6C,
        i32_div_s: 0x6D, i32_div_u: 0x6E, i32_rem_s: 0x6F, i32_rem_u: 0x70,
        i32_and: 0x71, i32_or: 0x72, i32_xor: 0x73,
        i32_shl: 0x74, i32_shr_s: 0x75, i32_shr_u: 0x76, i32_rotl: 0x77, i32_rotr: 0x78,
        i64_clz: 0x79, i64_ctz: 0x7A, i64_popcnt: 0x7B,
        i64_add: 0x7C, i64_sub: 0x7D, i64_mul: 0x7E,
        i64_div_s: 0x7F, i64_div_u: 0x80, i64_rem_s: 0x81, i64_rem_u: 0x82,
        i64_and: 0x83, i64_or: 0x84, i64_xor: 0x85,
        i64_shl: 0x86, i64_shr_s: 0x87, i64_shr_u: 0x88, i64_rotl: 0x89, i64_rotr: 0x8A,
        f32_abs: 0x8B, f32_neg: 0x8C, f32_ceil: 0x8D, f32_floor: 0x8E,
        f32_trunc: 0x8F, f32_nearest: 0x90, f32_sqrt: 0x91,
        f32_add: 0x92, f32_sub: 0x93, f32_mul: 0x94, f32_div: 0x95,
        f32_min: 0x96, f32_max: 0x97, f32_copysign: 0x98,
        f64_abs: 0x99, f64_neg: 0x9A, f64_ceil: 0x9B, f64_floor: 0x9C,
        f64_trunc: 0x9D, f64_nearest: 0x9E, f64_sqrt: 0x9F,
        f64_add: 0xA0, f64_sub: 0xA1, f64_mul: 0xA2, f64_div: 0xA3,
        f64_min: 0xA4, f64_max: 0xA5, f64_copysign: 0xA6,
        i32_wrap_i64: 0xA7,
        i32_trunc_f32_s: 0xA8, i32_trunc_f32_u: 0xA9,
        i32_trunc_f64_s: 0xAA, i32_trunc_f64_u: 0xAB,
        i64_extend_i32_s: 0xAC, i64_extend_i32_u: 0xAD,
        i64_trunc_f32_s: 0xAE, i64_trunc_f32_u: 0xAF,
        i64_trunc_f64_s: 0xB0, i64_trunc_f64_u: 0xB1,
        f32_convert_i32_s: 0xB2, f32_convert_i32_u: 0xB3,
        f32_convert_i64_s: 0xB4, f32_convert_i64_u: 0xB5,
        f32_demote_f64: 0xB6,
        f64_convert_i32_s: 0xB7, f64_convert_i32_u: 0xB8,
        f64_convert_i64_s: 0xB9, f64_convert_i64_u: 0xBA,
        f64_promote_f32: 0xBB,
        i32_reinterpret_f32: 0xBC, i64_reinterpret_f64: 0xBD,
        f32_reinterpret_i32: 0xBE, f64_reinterpret_i64: 0xBF,
        i32_extend8_s: 0xC0, i32_extend16_s: 0xC1,
        i64_extend8_s: 0xC2, i64_extend16_s: 0xC3, i64_extend32_s: 0xC4
      }.freeze

      OPCODES.each do |name, code|
        define_method(name) { op(code) }
      end

      # --- safe division ------------------------------------------------------
      #
      # WebAssembly traps on division by zero and on INT_MIN / -1. A scripting
      # language would rather produce a value, so division and remainder are
      # emitted through these helpers: x/0 and x%0 are 0, and INT_MIN/-1 saturates
      # to INT_MIN instead of trapping.

      def div_s_safe
        # stack: a b
        local(:i32, :__div_a)
        local(:i32, :__div_b)
        local(:i32, :__div_q)
        local_set(:__div_b)
        local_set(:__div_a)
        local_get(:__div_b)
        i32_eqz
        if_else(I32) do
          i32_const(0)
        end
        local_get(:__div_a)
        local_get(:__div_b)
        i32_div_s
        local_tee(:__div_q)
        # overflow guard: q == INT_MIN && b == -1  ->  return INT_MIN
        i32_const(-2147483648)
        i32_ne
        local_get(:__div_b)
        i32_const(-1)
        i32_ne
        i32_or
        if_else(I32) do
          local_get(:__div_q)
        end
      end

      def div_u_safe
        # unsigned: only the /0 case needs a guard
        local(:i32, :__div_b)
        local_set(:__div_b)
        local_get(:__div_b)
        i32_eqz
        if_else(I32) do
          i32_const(0)
        end
        i32_div_u
      end

      def rem_s_safe
        local(:i32, :__rem_a)
        local(:i32, :__rem_b)
        local_set(:__rem_b)
        local_set(:__rem_a)
        local_get(:__rem_b)
        i32_eqz
        if_else(I32) do
          i32_const(0)
        end
        local_get(:__rem_a)
        local_get(:__rem_b)
        i32_rem_s
        # INT_MIN % -1 traps in wasm but is 0 mathematically
        local(:i32, :__rem_r)
        local_tee(:__rem_r)
        i32_eqz
        i32_eqz
        if_else(I32) do
          local_get(:__rem_b)
          i32_const(-1)
          i32_ne
        end
        select
      end

      def rem_u_safe
        local(:i32, :__rem_b)
        local_set(:__rem_b)
        local_get(:__rem_b)
        i32_eqz
        if_else(I32) do
          i32_const(0)
        end
        i32_rem_u
      end

      # --- body ---------------------------------------------------------------

      def code_bytes = @code

      # Serialise locals as run-length-encoded (count, type) pairs, as the code
      # section requires. Consecutive same-typed locals must be merged or the
      # module is rejected.
      def body
        out = +"".b
        runs = []
        @local_types.each_with_index do |t, i|
          next if i < @defn.params.length

          if runs.last && runs.last[1] == t
            runs.last[0] += 1
          else
            runs << [1, t]
          end
        end
        out << Leb.u(runs.length)
        runs.each do |count, type|
          out << Leb.u(count) << [VALTYPE.fetch(type)].pack("C")
        end
        out << @code
        out << "\x0B".b # end
        out
      end
    end

    # A whole module: types, imports, functions, exports, memory, data.
    class Module
      attr_accessor :memory_pages, :max_memory_pages

      def initialize(name: "ldpl")
        @name = name
        @types = {}
        @type_order = []
        @imports = []
        @funcs = []
        @exports = []
        @data = []
        @table = nil
        @globals = []
        @memory_pages = 1
        @max_memory_pages = nil
        @memory_exported = false
      end

      def type_index(params, results)
        key = [params, results]
        @types[key] ||= begin
          @type_order << key
          @type_order.length - 1
        end
      end

      def import_function(mod, name, params, results)
        fd = FuncDef.new(name: "#{mod}.#{name}", params: params, results: results)
        fd.imported = true
        fd.index = @imports.length
        fd.type_index = type_index(params, results)
        @imports << { mod: mod, name: name, type_index: fd.type_index, def: fd }
        fd
      end

      def declare_function(name, params: [], results: [], param_names: [])
        fd = FuncDef.new(name: name, params: params, results: results,
                         param_names: param_names)
        fd.index = @imports.length + @funcs.length
        fd.type_index = type_index(params, results)
        @funcs << fd
        fd
      end

      def build(fd, &blk)
        fn = Func.new(fd)
        blk.call(fn)
        fd.code = fn.body
        fn
      end

      def global(name, type, mutable: false, init: nil)
        idx = @globals.length
        @globals << { name: name, type: type, mutable: mutable, init: init }
        idx
      end

      def export_func(name, fd)
        @exports << { name: name, kind: :func, index: fd.index }
      end

      def export_memory(name = "memory")
        @memory_exported = true
        @exports << { name: name, kind: :memory, index: 0 }
      end

      def export_global(name, index)
        @exports << { name: name, kind: :global, index: index }
      end

      def table(fds, elem_type: 0x70)
        @table = { funcs: fds.map(&:index), elem_type: elem_type }
      end

      def data(offset, bytes)
        @data << { offset: offset, bytes: bytes }
      end

      def emit
        out = +"\x00asm\x01\x00\x00\x00".b
        out << section(1, type_section)
        out << section(2, import_section) unless @imports.empty?
        out << section(3, function_section)
        out << section(4, table_section) if @table
        out << section(5, memory_section)
        out << section(6, global_section) unless @globals.empty?
        out << section(7, export_section)
        out << section(9, element_section) if @table
        out << section(10, code_section)
        out << section(11, data_section) unless @data.empty?
        out
      end

      private

      def section(id, content)
        [id].pack("C") + Leb.u(content.bytesize) + content
      end

      def name_bytes(str)
        bytes = str.to_s.b
        Leb.u(bytes.bytesize) + bytes
      end

      def type_section
        out = Leb.u(@type_order.length)
        @type_order.each do |params, results|
          out << "\x60".b
          out << Leb.u(params.length)
          params.each { |t| out << [VALTYPE.fetch(t)].pack("C") }
          out << Leb.u(results.length)
          results.each { |t| out << [VALTYPE.fetch(t)].pack("C") }
        end
        out
      end

      def import_section
        out = Leb.u(@imports.length)
        @imports.each do |imp|
          out << name_bytes(imp[:mod]) << name_bytes(imp[:name])
          out << "\x00".b << Leb.u(imp[:type_index])
        end
        out
      end

      def function_section
        out = Leb.u(@funcs.length)
        @funcs.each { |fd| out << Leb.u(fd.type_index) }
        out
      end

      def table_section
        out = Leb.u(1)
        out << [@table[:elem_type]].pack("C")
        out << "\x00".b << Leb.u(@table[:funcs].length)
        out
      end

      def memory_section
        limits = if @max_memory_pages
                   "\x01".b + Leb.u(@memory_pages) + Leb.u(@max_memory_pages)
                 else
                   "\x00".b + Leb.u(@memory_pages)
                 end
        Leb.u(1) + limits
      end

      def global_section
        out = Leb.u(@globals.length)
        @globals.each do |g|
          out << [VALTYPE.fetch(g[:type])].pack("C")
          out << (g[:mutable] ? "\x01".b : "\x00".b)
          out << const_expr(g[:type], g[:init])
          out << "\x0B".b
        end
        out
      end

      def const_expr(type, init)
        case [type, init]
        in [I32, nil] then "\x41".b + Leb.s(0)
        in [I64, nil] then "\x42".b + Leb.s(0)
        in [F64, nil] then "\x44".b + [0.0].pack("E")
        in [I32, Integer] then "\x41".b + Leb.s(init)
        in [I64, Integer] then "\x42".b + Leb.s(init)
        in [F64, Float] then "\x44".b + [init].pack("E")
        else raise ArgumentError, "bad global init #{init.inspect} for #{type}"
        end
      end

      def export_section
        out = Leb.u(@exports.length)
        @exports.each do |exp|
          out << name_bytes(exp[:name])
          case exp[:kind]
          when :func then out << "\x00".b << Leb.u(exp[:index])
          when :table then out << "\x01".b << Leb.u(exp[:index])
          when :memory then out << "\x02".b << Leb.u(exp[:index])
          when :global then out << "\x03".b << Leb.u(exp[:index])
          end
        end
        out
      end

      def element_section
        out = Leb.u(1)
        out << Leb.u(0)              # table 0
        out << "\x41".b << Leb.s(0) << "\x0B".b # offset expr
        out << Leb.u(@table[:funcs].length)
        @table[:funcs].each { |idx| out << Leb.u(idx) }
        out
      end

      def code_section
        out = Leb.u(@funcs.length)
        @funcs.each do |fd|
          body = fd.code
          out << Leb.u(body.bytesize) << body
        end
        out
      end

      def data_section
        out = Leb.u(@data.length)
        @data.each do |seg|
          out << Leb.u(0) # memory 0, active
          out << "\x41".b << Leb.s(seg[:offset]) << "\x0B".b
          out << Leb.u(seg[:bytes].bytesize) << seg[:bytes].b
        end
        out
      end
    end
  end
end