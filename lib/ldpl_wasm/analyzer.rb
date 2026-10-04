# frozen_string_literal: true

module LdplWasm
  # Static analysis: symbol tables, memory layout, expression types, and the
  # feature-gating flags the runtime uses.
  #
  # Layout of the single linear memory:
  #
  #   0x0000  runtime scratch: iovecs, error slots
  #   0x0400  one slot per global variable, in declaration order
  #   0x1000  string literal pool (a data segment)
  #   heap    everything allocated at run time
  #
  # A NUMBER occupies 8 bytes (an f64); every other type occupies 4 (a pointer).
  # Structs are heap objects with fields at analyser-assigned offsets.
  class Analyzer
    GLOBALS_BASE = 0x0400
    DATA_BASE    = 0x1000

    ERRORCODE_OFFSET = 0x0040
    ERRORTEXT_OFFSET = 0x0044

    Var = Struct.new(:name, :type, :offset, :const, :init, keyword_init: false)

    class Scope
      attr_reader :vars, :parent

      def initialize(parent = nil)
        @vars = {}
        @parent = parent
      end

      def lookup(name)
        return @vars[name] if @vars.key?(name)

        @parent&.lookup(name)
      end

      def declare(name, var)
        @vars[name] = var
      end
    end

    attr_reader :globals, :structs, :subprocs, :needs, :literals, :data_cursor,
                :subproc_returns

    # One past the last global slot. Sub-procedure parameter blocks start here.
    def globals_end = @globals_end

    def initialize
      @globals = {}
      @structs = {}        # name => { name:, fields: {name => [offset, type]}, size: }
      @subprocs = {}       # name => { params: [Var], return_type: }
      @needs = Hash.new(false)
      @literals = {}       # bytes => offset in the data pool
      @data_cursor = DATA_BASE
      @loop_depth = 0
      @subproc_returns = {}
    end

    def struct_size(name)
      @structs[name.to_sym]&.fetch(:size, 0) || 0
    end

    def struct_field(name, field)
      @structs[name.to_sym]&.fetch(:fields, {})&.[](field)
    end

    # `DATA_BASE` is fixed; the heap starts after the literal pool.
    def heap_base
      ((@data_cursor + 15) & ~15)
    end

    # -------------------------------------------------------------- entry point

    def analyze(program)
      collect_structs(program.structs)
      layout_globals(program.globals, program.constants)
      collect_subprocs(program.subprocs)
      scan_needs(program.body)
      self
    end

    # Work out which runtime helpers the program can actually reach. Emitting the
    # whole runtime unconditionally is both wasteful and, because the helpers are
    # emitted before the user code, a bug in any unused helper breaks every
    # program.
    def scan_needs(stmts)
      Array(stmts).each do |node|
        next unless node

        case node
        when Ast::Display then needs[:io] = true
        when Ast::Accept then needs[:accept] = true
        when Ast::Join then needs[:io] = true
        when Ast::StoreQuote then needs[:io] = true
        when Ast::Binop, Ast::Unop, Ast::Solve, Ast::Assign, Ast::NumLit
          needs[:number] = true
        when Ast::Logical then needs[:compare] = true
        when Ast::StrLit then needs[:io] = true
        end

        %i[body then_body else_body].each do |field|
          child = node.respond_to?(field) ? node.public_send(field) : nil
          scan_needs(child) if child
        end
        if node.respond_to?(:cond) && node.cond
          needs[:compare] = true
          scan_needs_expr(node.cond)
        end
        if node.respond_to?(:from) && node.from then scan_needs_expr(node.from) end
        if node.respond_to?(:to) && node.to then scan_needs_expr(node.to) end
        if node.respond_to?(:step) && node.step then scan_needs_expr(node.step) end
        if node.respond_to?(:value) && node.value then scan_needs_expr(node.value) end
      end
    end

    def scan_needs_expr(node)
      return unless node

      needs[:number] = true
      case node
      when Ast::Logical, Ast::Binop then needs[:compare] = true
      end
      %i[lhs rhs operand].each do |field|
        child = node.respond_to?(field) ? node.public_send(field) : nil
        scan_needs_expr(child) if child
      end
    end

    # ------------------------------------------------------------------ structs

    def collect_structs(defs)
      # Two passes: register names first so a structure may contain another, then
      # assign offsets.
      defs.each { |d| @structs[d.name] ||= { name: d.name, fields: {}, size: 0 } }

      defs.each do |d|
        offset = 0
        d.fields.each do |fname, ftype|
          size = Types.slot_size(ftype)
          # An f64 needs 8-byte alignment; wasm permits unaligned access but the
          # offset arithmetic stays far simpler if slots never straddle.
          offset = (offset + 7) & ~7 if size == 8
          @structs[d.name][:fields][fname] = [offset, ftype]
          offset += size
        end
        @structs[d.name][:size] = (offset + 7) & ~7
      end
    end

    # ------------------------------------------------------------------ globals

    def layout_globals(vars, constants)
      cursor = GLOBALS_BASE
      constants.each do |c|
        size = Types.slot_size(c.type)
        offset = align(cursor, size)
        @globals[c.name] = Var.new(c.name, c.type, offset, true, c.value)
        cursor = offset + size
      end
      vars.each do |v|
        size = Types.slot_size(v.type)
        offset = align(cursor, size)
        @globals[v.name] = Var.new(v.name, v.type, offset, false)
        cursor = offset + size
      end
      @globals_end = align(cursor, 16)
    end

    def align(value, size)
      size >= 8 ? value : ((value + size - 1) & ~(size - 1))
    end

    # -------------------------------------------------------------- subprocs

    def collect_subprocs(defs)
      defs.each do |sp|
        @subprocs[sp.name] = { name: sp.name, params: sp.params, return_type: nil,
                               decl: sp }
        needs[:subprocs] = true
      end
    end

    def returning_names
      @subprocs.keys.select { |n| @subproc_returns[n] }
    end

    def mark_returning!(names)
      names.each { |n| @subproc_returns[n] = true }
    end

    # --------------------------------------------------------------- literals

    # Intern a string literal into the data pool and return its (offset, length).
    def literal(bytes)
      bytes = bytes.b
      if (off = @literals[bytes])
        return [off, bytes.bytesize]
      end

      off = @data_cursor
      @literals[bytes] = off
      @data_cursor += bytes.bytesize
      [off, bytes.bytesize]
    end

    # -------------------------------------------------------------- type rules

    # The type of an expression, or nil if it cannot be resolved.
    def type_of(node, scope)
      case node
      when Ast::NumLit then Types.number
      when Ast::StrLit then Types.text
      when Ast::VarRef then type_of_ref(node, scope)
      when Ast::Binop then type_of_binop(node, scope)
      when Ast::Unop then type_of_unop(node, scope)
      when Ast::Logical then Types.number # a condition; i32 at run time
      when Ast::CallExpr then @subprocs.dig(node.name, :return_type)
      else nil
      end
    end

    def type_of_ref(node, scope)
      var = scope.lookup(node.name)
      return nil unless var

      type = walk_path(var.type, node.path, scope)
      type
    end

    # Follow `a:b:c` and `person:field` through the declared types.
    def walk_path(type, path, scope)
      path.each do |kind, payload|
        case kind
        when :index
          return nil unless Types.container?(type)

          type = Types.element(type)
        when :field
          return nil unless Types.struct?(type)

          field = struct_field(Types.struct_name(type), payload)
          return nil unless field

          type = field[1]
        end
      end
      type
    end

    def type_of_binop(node, scope)
      case node.op
      when "+"
        lt = type_of(node.lhs, scope)
        rt = type_of(node.rhs, scope)
        return lt if lt && Types.text?(lt)
        return rt if rt && Types.text?(rt)

        Types.number
      when "-", "*", "/", "%"
        Types.number
      when "=", "<>", "<", ">", "<=", ">="
        Types.number # condition
      else
        Types.number
      end
    end

    def type_of_unop(node, scope)
      case node.op
      when "NOT" then Types.number
      else type_of(node.operand, scope)
      end
    end

    # -------------------------------------------------------------- misc helpers

    def global(name) = @globals[name]

    def note(*flags)
      flags.each { |f| @needs[f] = true }
    end
  end
end