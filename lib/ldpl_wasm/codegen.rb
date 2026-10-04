# frozen_string_literal: true

module LdplWasm
  # Code generation: AST + analysis -> WebAssembly.
  #
  # Representation recap (the two decisions everything else follows from):
  #
  #   NUMBER  f64, stored inline in a static 8-byte slot
  #   TEXT    a *static, inline record*: [len:i32, cap:i32, bytes...]
  #   LIST    a heap object with a 4- or 8-byte stride
  #
  # Inline TEXT keeps scalars allocation-free, which makes the common case (a
  # variable printed or compared) a plain load/store with no runtime call at all.
  class Codegen
    I32 = Wasm::I32
    I64 = Wasm::I64
    F64 = Wasm::F64

    # A TEXT record's inline capacity. Fixed so a variable's slot has a static
    # size and no TEXT operation can ever move one.
    TEXT_CAP = Runtime::TEXT_CAP
    TEXT_SLOT = 8 + TEXT_CAP

    def initialize(analyzer, runtime)
      @an = analyzer
      @rt = runtime
      @mod = runtime.mod
      @strings = {}
    end

    def build(program)
      @program = program
      scope = Analyzer::Scope.new
      @an.globals.each_value { |v| scope.declare(v.name, v) }

      @subproc_funcs = {}

      # Sub-procedures are declared first so that `_start` can CALL them: wasm
      # `call` needs a resolved function index, and CALL may appear before the
      # SUB-PROCEDURE in the source.
      program.subprocs.each { |sp| emit_subproc(sp) }

      @start = @mod.declare_function("_start", params: [], results: [])
      @mod.build(@start) do |b|
        init_text_vars(b, scope)
        emit_body(b, program.body, scope)
        b.i32_const(0)
        b.call(@rt.proc_exit_func)
      end

      @mod.export_func("_start", @start)
      @mod.export_memory
      @mod
    end

    def emit_prologue
      # Zero every TEXT record so an unassigned variable is empty, not garbage.
      nil
    end

    def init_text_vars(b, scope)
      @an.globals.each_value do |v|
        next unless Types.text?(v.type)

        b.i32_const(v.offset)
        b.i32_const(0)
        b.i32_store(offset: 0)
      end
    end

    # ----------------------------------------------------------------- scopes

    def subproc_scope(sp)
      scope = Analyzer::Scope.new
      @an.globals.each_value { |v| scope.declare(v.name, v) }
      offset = @an.globals_end
      sp.params.each do |param|
        offset = align(offset, Types.slot_size(param.type))
        scope.declare(param.name, Analyzer::Var.new(param.name, param.type, offset))
        offset += Types.slot_size(param.type)
      end
      scope
    end

    def align(value, size)
      size >= 8 ? value : ((value + size - 1) & ~(size - 1))
    end

    # --------------------------------------------------------------- statements

    def emit_body(b, stmts, scope)
      Array(stmts).each { |s| emit_stmt(b, s, scope) }
    end

    def emit_stmt(b, node, scope)
      case node
      when Ast::Display then emit_display(b, node, scope)
      when Ast::Accept then emit_accept(b, node, scope)
      when Ast::Assign then emit_assign(b, node, scope)
      when Ast::Solve then emit_assign(b, Ast::Assign.new(node.pos, node.target, node.expr), scope)
      when Ast::Join then emit_join(b, node, scope)
      when Ast::If then emit_if(b, node, scope)
      when Ast::While then emit_while(b, node, scope)
      when Ast::For then emit_for(b, node, scope)
      when Ast::LengthOf then emit_length_of(b, node, scope)
      when Ast::StoreQuote then emit_store_quote(b, node, scope)
      when Ast::Call then emit_call(b, node, scope)
      when Ast::Return then emit_return(b, node, scope)
      when Ast::Break then b.br(1)
      when Ast::Continue then b.br(0)
      else
        raise CompileError.new(
          "#{node.class.name.split('::').last} is not implemented by the wasm backend yet",
          node.pos
        )
      end
    end

    # Write one DISPLAY operand to stdout.
    #
    # Each branch is responsible for emitting the write itself, so a literal is
    # written straight from the data pool while a NUMBER is formatted into a
    # scratch TEXT record first.
    def emit_text_operand(b, node, scope)
      case node
      when Ast::StrLit
        off, len = @an.literal(node.value)
        b.i32_const(off)
        b.i32_const(len)
        b.call(@rt.write_mem_func)
      when Ast::NumLit
        b.f64_const(node.value)
        b.call(@rt.num_to_text_func)
        b.call(@rt.write_text_func)
      when Ast::VarRef
        type = @an.type_of(node, scope)
        if Types.plain_number?(type)
          emit_load_var(b, node, scope)
          b.call(@rt.num_to_text_func)
          b.call(@rt.write_text_func)
        else
          b.i32_const(addr_of(node, scope))
          b.call(@rt.write_text_func)
        end
      else
        raise CompileError.new("unsupported DISPLAY operand", node.pos)
      end
    end

    def emit_display(b, node, scope)
      node.operands.each { |operand| emit_text_operand(b, operand, scope) }
    end

    def emit_accept(b, node, scope)
      type = @an.type_of(node.target, scope)
      if Types.text?(type)
        b.i32_const(addr_of(node.target, scope))
        b.call(@rt.accept_text_func)
      else
        b.i32_const(addr_of(node.target, scope))
        b.call(@rt.accept_number_func)
      end
    end

    def emit_assign(b, node, scope)
      target_type = @an.type_of(node.target, scope)
      addr = addr_of(node.target, scope)

      if Types.plain_number?(target_type)
        emit_number_expr(b, node.value, scope)
        b.f64_store
      elsif Types.text?(target_type)
        emit_text_value(b, node.value, scope, addr)
      else
        raise CompileError.new(
          "cannot assign to a value of type #{Types.to_s(target_type)} yet", node.pos
        )
      end
    end

    # Store a TEXT-ish value into the record at `addr`.
    def emit_text_value(b, node, scope, addr)
      case node
      when Ast::StrLit
        off, len = @an.literal(node.value)
        b.i32_const(addr)
        b.i32_const(len)
        b.i32_store(offset: 0)
        b.i32_const(addr)
        b.i32_const(TEXT_CAP)
        b.i32_store(offset: 4)
        b.i32_const(addr)
        b.i32_const(8)
        b.i32_add
        b.i32_const(off)
        b.i32_const(addr)
        b.i32_load(offset: 0)
        b.memory_copy
      when Ast::NumLit
        b.i32_const(addr)
        b.i32_const(0)
        b.i32_store(offset: 0)
        b.i32_const(addr)
        b.f64_const(node.value)
        b.call(@rt.num_into_text_func)
      when Ast::VarRef
        vtype = @an.type_of(node, scope)
        if Types.text?(vtype)
          src = addr_of(node, scope)
          b.i32_const(addr)
          b.i32_const(src)
          b.i32_load(offset: 0)
          b.i32_store(offset: 0)
          b.i32_const(addr)
          b.i32_const(TEXT_CAP)
          b.i32_store(offset: 4)
          b.i32_const(addr)
          b.i32_const(8)
          b.i32_add
          b.i32_const(src)
          b.i32_const(8)
          b.i32_add
          b.i32_const(src)
          b.i32_load(offset: 0)
          b.memory_copy
        else
          emit_load_var(b, node, scope)
          b.i32_const(addr)
          b.f64_store
          b.i32_const(addr)
          b.call(@rt.num_into_text_func)
        end
      when Ast::CallExpr
        raise CompileError.new("a returning call cannot be assigned to TEXT yet", node.pos)
      else
        raise CompileError.new("unsupported assignment to TEXT", node.pos)
      end
    end

    # JOIN: target = a + b with both operands treated as text.
    #
    # Operands must be text *records*, so a NUMBER operand is formatted into one
    # first. The result is written straight into the target record, which is why
    # no allocation is needed here.
    def emit_join(b, node, scope)
      emit_text_value_of(b, node.lhs, scope)
      emit_text_value_of(b, node.rhs, scope)
      b.i32_const(addr_of(node.target, scope))
      b.call(@rt.text_join_func)
    end

    # Push the address of a TEXT record holding this operand's value.
    def emit_text_value_of(b, node, scope)
      case node
      when Ast::StrLit
        off, len = @an.literal(node.value)
        b.i32_const(addr_of_scratch(node.pos))
        b.i32_const(len)
        b.i32_store(offset: 0)
        b.i32_const(addr_of_scratch(node.pos))
        b.i32_const(TEXT_CAP)
        b.i32_store(offset: 4)
        b.i32_const(addr_of_scratch(node.pos))
        b.i32_const(8)
        b.i32_add
        b.i32_const(off)
        b.i32_const(len)
        b.memory_copy
        b.i32_const(addr_of_scratch(node.pos))
      when Ast::VarRef
        if Types.text?(@an.type_of(node, scope))
          b.i32_const(addr_of(node, scope))
        else
          emit_load_var(b, node, scope)
          b.call(@rt.num_into_scratch_func)
          b.i32_const(addr_of_scratch(node.pos))
        end
      when Ast::NumLit
        b.f64_const(node.value)
        b.call(@rt.num_into_scratch_func)
        b.i32_const(addr_of_scratch(node.pos))
      else
        raise CompileError.new("unsupported JOIN operand", node.pos)
      end
    end

    # Two alternating scratch records, so a JOIN can name its own operands.
    def addr_of_scratch(pos)
      @scratch_n = (@scratch_n || 0)
      @scratch_n += 1
      @scratch_n.odd? ? Runtime::SCRATCH_JOIN_A : Runtime::SCRATCH_JOIN_B
    end

    def emit_if(b, node, scope)
      emit_condition(b, node.cond, scope)
      b.if_else_void do |which|
        if which == :then
          emit_body(b, node.then_body, scope)
        else
          emit_body(b, node.else_body, scope)
        end
      end
    end

    def emit_while(b, node, scope)
      b.block do
        b.loop do
          emit_condition(b, node.cond, scope)
          b.i32_eqz
          b.br_if(1)
          emit_body(b, node.body, scope)
          b.br(0)
        end
      end
    end

    # FOR var FROM a TO b [STEP c] [INCLUSIVE] DO ... REPEAT
    #
    # The loop counter is a fresh local rather than the LDPL variable, so a FOR
    # loop cannot clobber a variable the body relies on -- matching LDPL, where the
    # loop variable is written on every iteration.
    def emit_for(b, node, scope)
      var = scope.lookup(node.var.name)
      raise CompileError.new("unknown FOR variable #{node.var.name}", node.pos) unless var

      # Locals live in one flat per-function namespace, so two FOR loops over the
      # same variable need distinct names.
      @local_seq = (@local_seq || 0) + 1
      seq = @local_seq
      ivar = b.local(F64, "for_#{node.var.name}_#{seq}")
      svar = b.local(F64, "step_#{node.var.name}_#{seq}")
      tvar = b.local(F64, "to_#{node.var.name}_#{seq}")

      emit_number_expr(b, node.from, scope)
      b.local_set(ivar)

      if node.step
        emit_number_expr(b, node.step, scope)
      else
        # No STEP: +1 when ascending, -1 when descending.
        emit_number_expr(b, node.to, scope)
        emit_number_expr(b, node.from, scope)
        b.f64_le
        b.if_else(F64) { b.f64_const(1.0) }
      end
      b.local_set(svar)

      emit_number_expr(b, node.to, scope)
      b.local_set(tvar)

      b.block do
        b.loop do
          # continue while (step >= 0 ? ivar <= to : ivar >= to)
          b.lget(svar)
          b.f64_const(0.0)
          b.f64_ge
          b.if_else_b(I32) do |which|
            if which == :then
              b.lget(ivar)
              b.lget(tvar)
              if node.inclusive
                b.f64_le
              else
                b.f64_lt
              end
            else
              b.lget(ivar)
              b.lget(tvar)
              if node.inclusive
                b.f64_ge
              else
                b.f64_gt
              end
            end
          end
          b.i32_eqz
          b.br_if(1)

          # Publish the counter into the LDPL variable, then run the body.
          b.lget(ivar)
          b.i32_const(var.offset)
          b.f64_store

          emit_body(b, node.body, scope)

          b.lget(ivar)
          b.lget(svar)
          b.f64_add
          b.local_set(ivar)
          b.br(0)
        end
      end
    end

    def emit_length_of(b, node, scope)
      type = @an.type_of(node.source, scope)
      addr = addr_of(node.target, scope)
      b.i32_const(addr)
      b.i32_const(addr_of(node.source, scope))
      if Types.text?(type)
        b.i32_load(offset: 0)
      else
        # List length is a runtime call.
        b.i32_load
        b.call(@rt.list_len_func)
      end
      b.f64_convert_i32_s
      b.f64_store
    end

    def emit_store_quote(b, node, scope)
      addr = addr_of(node.target, scope)
      body = node.lines.map { |l| node.trimmed ? l.strip : l }
      text = body.map { |l| "#{l}\n" }.join
      off, len = @an.literal(text)
      b.i32_const(addr)
      b.i32_const([len, TEXT_CAP].min)
      b.i32_store(offset: 0)
      b.i32_const(addr)
      b.i32_const(TEXT_CAP)
      b.i32_store(offset: 4)
      b.i32_const(addr)
      b.i32_const(8)
      b.i32_add
      b.i32_const(off)
      b.i32_const([len, TEXT_CAP].min)
      b.memory_copy
    end

    # CALL <sub> [WITH args...]
    #
    # Arguments are passed by value into wasm parameters; the sub-procedure prologue
    # copies them into their static slots. LDPL's reference parameters are not
    # implemented yet, so a REFERENCE parameter is rejected loudly.
    def emit_call(b, node, scope)
      target = @subproc_funcs[node.name]
      raise CompileError.new("unknown SUB-PROCEDURE #{node.name}", node.pos) unless target

      decl = @an.subprocs[node.name][:decl]
      params = decl.params
      if params.any?(&:by_reference)
        raise CompileError.new(
          "REFERENCE parameters are not implemented by the wasm backend yet", node.pos
        )
      end
      unless params.size == node.args.size
        raise CompileError.new(
          "#{node.name} takes #{params.size} argument(s), got #{node.args.size}",
          node.pos
        )
      end

      node.args.each_with_index do |arg, i|
        ptype = params[i].type
        if Types.plain_number?(ptype)
          emit_number_expr(b, arg, scope)
        elsif Types.text?(ptype)
          emit_text_value_of(b, arg, scope)
        else
          raise CompileError.new(
            "#{params[i].name} must be a scalar in this version", node.pos
          )
        end
      end
      b.call(target)
    end

    def emit_return(b, node, scope)
      if node.value
        raise CompileError.new(
          "returning a value is not implemented by the wasm backend yet", node.pos
        )
      end

      b.return_
    end

    # -------------------------------------------------------------- subprocs

    def emit_subproc(sp)
      scope = subproc_scope(sp)
      # LDPL types must be lowered to wasm value types for the signature.
      params = sp.params.map { |p| Types.wasm(p.type) }
      fd = @mod.declare_function("subpr_#{sp.name}", params: params, results: [])
      @subproc_funcs[sp.name] = fd
      @mod.build(fd) do |b|
        # Parameters are passed by value into their static slots at entry.
        sp.params.each_with_index do |param, i|
          var = scope.lookup(param.name)
          b.local_get(i)
          if Types.plain_number?(param.type)
            b.f64_store(offset: var.offset)
          else
            b.i32_store(offset: var.offset)
          end
        end
        emit_body(b, sp.body, scope)
      end
    end

    # ------------------------------------------------------------- conditions

    # Conditions are i32 at run time, even though the analyser types them NUMBER.
    def emit_condition(b, node, scope)
      case node
      when Ast::Logical
        emit_logical(b, node, scope)
      when Ast::Unop
        if node.op == "NOT"
          emit_condition(b, node.operand, scope)
          b.i32_eqz
        else
          emit_condition(b, node.operand, scope)
        end
      else
        emit_binop_condition(b, node, scope)
      end
    end

    # Short-circuit AND/OR. Both operands are i32 conditions.
    def emit_logical(b, node, scope)
      case node.op
      when "AND"
        # if (!lhs) push 0 else push rhs
        emit_condition(b, node.lhs, scope)
        b.i32_eqz
        b.if_else_void do |which|
          if which == :then
            b.i32_const(0)
          else
            emit_condition(b, node.rhs, scope)
          end
        end
      when "OR"
        # if (lhs) push 1 else push rhs
        emit_condition(b, node.lhs, scope)
        b.if_else_void do |which|
          if which == :then
            b.i32_const(1)
          else
            emit_condition(b, node.rhs, scope)
          end
        end
      else
        emit_condition(b, node.lhs, scope)
      end
    end

    def emit_binop_condition(b, node, scope)
      unless node.is_a?(Ast::Binop)
        # A bare value used as a condition: truthiness of a NUMBER.
        emit_number_expr(b, node, scope)
        b.f64_const(0.0)
        b.f64_ne
        return
      end

      case node.op
      when "=", "<>"
        if text_comparison?(node, scope)
          emit_text_operand(b, node.lhs, scope)
          emit_text_operand(b, node.rhs, scope)
          b.call(@rt.str_eq_func)
        else
          emit_number_expr(b, node.lhs, scope)
          emit_number_expr(b, node.rhs, scope)
          b.call(@rt.num_eq_func)
        end
        b.i32_eqz if node.op == "<>"
      when "<", ">", "<=", ">="
        emit_number_expr(b, node.lhs, scope)
        emit_number_expr(b, node.rhs, scope)
        case node.op
        when "<" then b.f64_lt
        when ">" then b.f64_gt
        when "<=" then b.f64_le
        else b.f64_ge
        end
      else
        emit_number_expr(b, node, scope)
      end
    end

    def text_comparison?(node, scope)
      Types.text?(@an.type_of(node.lhs, scope)) || Types.text?(@an.type_of(node.rhs, scope))
    end

    # ------------------------------------------------------------ expressions

    def emit_number_expr(b, node, scope)
      case node
      when Ast::NumLit
        b.f64_const(node.value)
      when Ast::VarRef
        type = @an.type_of(node, scope)
        unless Types.plain_number?(type)
          raise CompileError.new(
            "expected a NUMBER, found #{Types.to_s(type)}", node.pos
          )
        end
        emit_load_var(b, node, scope)
      when Ast::Binop
        emit_number_binop(b, node, scope)
      when Ast::Unop
        if node.op == "-"
          emit_number_expr(b, node.operand, scope)
          b.f64_neg
        else
          emit_number_expr(b, node.operand, scope)
        end
      when Ast::CallExpr
        raise CompileError.new(
          "a returning call is not implemented by the wasm backend yet", node.pos
        )
      else
        raise CompileError.new("expected a NUMBER expression", node.pos)
      end
    end

    def emit_number_binop(b, node, scope)
      case node.op
      when "+"
        if Types.text?(@an.type_of(node.lhs, scope)) ||
           Types.text?(@an.type_of(node.rhs, scope))
          emit_text_operand(b, node.lhs, scope)
          emit_text_operand(b, node.rhs, scope)
          b.call(@rt.text_concat_func)
          b.call(@rt.num_from_text_func)
        else
          emit_number_expr(b, node.lhs, scope)
          emit_number_expr(b, node.rhs, scope)
          b.f64_add
        end
      when "-"
        emit_number_expr(b, node.lhs, scope)
        emit_number_expr(b, node.rhs, scope)
        b.f64_sub
      when "*"
        emit_number_expr(b, node.lhs, scope)
        emit_number_expr(b, node.rhs, scope)
        b.f64_mul
      when "/"
        emit_number_expr(b, node.lhs, scope)
        emit_number_expr(b, node.rhs, scope)
        b.call(@rt.div_f64_func)
      when "%"
        emit_number_expr(b, node.lhs, scope)
        emit_number_expr(b, node.rhs, scope)
        b.call(@rt.mod_f64_func)
      else
        raise CompileError.new("operator #{node.op} is not a NUMBER operator", node.pos)
      end
    end

    # The static address of an assignable place.
    #
    # This returns the offset; pushing it is the caller's job. (Having it emit as
    # a side effect and return the builder is what made `addr = load_address(...)`
    # silently bind the builder instead of an address.)
    def addr_of(node, scope)
      unless node.is_a?(Ast::VarRef)
        raise CompileError.new("expected a variable", node.pos)
      end
      if node.path.any?
        raise CompileError.new("indexed access is not implemented yet", node.pos)
      end

      var = scope.lookup(node.name)
      raise CompileError.new("unknown variable #{node.name}", node.pos) unless var

      var.offset
    end

    def emit_load_var(b, node, scope)
      var = scope.lookup(node.name)
      raise CompileError.new("unknown variable #{node.name}", node.pos) unless var

      if Types.plain_number?(var.type)
        b.i32_const(var.offset)
        b.f64_load
      else
        b.i32_const(var.offset)
        b.i32_load
      end
    end
  end
end