# frozen_string_literal: true

module LdplWasm
  # Recursive-descent parser producing Ast nodes.
  #
  # LDPL is line-oriented: a statement begins with a keyword and ends at the end of
  # its line. The parser therefore walks *lines* of tokens rather than one flat
  # token stream, which is also what makes `STORE QUOTE` (whose payload is raw
  # source text) expressible.
  class Parser
    include Ast

    # A synthetic token used to look past the end of a line.
    EOF_TOKEN = Lex::Token.new(:eof, "", Pos.new("(eof)", 0), nil).freeze

    # Words that begin a statement. Used to know when an expression must stop.
    STATEMENT_STARTERS = %w[
      DISPLAY ACCEPT SET STORE IF ELSE END WHILE FOR PUSH POP GET LENGTH CALL
      RETURN BREAK CONTINUE EXIT TRY ON SORT REVERSE CLEAR LABEL GOTO JOIN
      PRINT
    ].freeze

    # Words that terminate an expression when they appear where an operator
    # would be expected.
    CLAUSE_WORDS = %w[
      THEN ELSE END DO REPEAT WITH INTO TO FROM STEP INCLUSIVE ON
      DESCRIPTION
    ].freeze

    def initialize(lines, file = "(stdin)", returning: [])
      @lines = lines
      @file = file
      @li = 0
      @ti = 0
      @returning = returning
      @struct_names = {}
    end

    def self.parse(source, file = "(stdin)", returning: [])
      new(Lex.lex_lines(source, file), file, returning: returning).parse_program
    end

    # --------------------------------------------------------------- program

    SECTION_WORDS = {
      "DATA" => :data, "VARIABLES" => :data, "PROCEDURE" => :procedure
    }.freeze

    # Which section, if any, does the line at `index` open? LDPL spells section
    # headers four ways and all of them are in real use:
    #
    #   DATA:            -- PROCEDURE:
    #   -- DATA --       -- PROCEDURE --
    #   DATA             PROCEDURE
    def section_at(index)
      toks = @lines[index]&.tokens
      return nil unless toks && toks.any?

      if toks[0].word? && SECTION_WORDS[toks[0].name]
        return SECTION_WORDS[toks[0].name]
      end

      if toks[0].punct?("-") && toks[1]&.punct?("-") && toks[2]&.word? &&
         SECTION_WORDS[toks[2].name]
        return SECTION_WORDS[toks[2].name]
      end

      nil
    end

    def parse_program
      pos = here
      structs = []
      globals = []
      constants = []
      subprocs = []
      body = []
      section = nil

      while more_lines?
        if (sec = section_at(@li))
          section = sec
          skip_line
          next
        end

        first = peek

        case first.name
        when "STRUCTURE", "STRUCT"
          structs << parse_struct
        when "CONSTANT"
          constants << parse_const_decl
        else
          if section == :data
            decl = try_parse_var_decl
            globals << decl if decl
          elsif section == :procedure
            if %w[SUB-PROCEDURE SUB].include?(first.name)
              subprocs << parse_subproc
            else
              stmts = parse_statement
              Array(stmts).each { |s| body << s } if stmts
            end
          else
            raise CompileError.new(
              "code outside a DATA or PROCEDURE section", first.pos
            )
          end
        end
      end

      Program.new(pos, structs, globals, constants, subprocs, body)
    end

    # --------------------------------------------------------------- struct

    def parse_struct
      pos = advance.pos
      advance if peek.name == "STRUCT"
      name = expect_word("structure name").name.to_sym
      skip_line
      fields = []

      while more_lines?
        if end_of?("END", "STRUCTURE") || end_of?("END", "STRUCT")
          skip_line
          break
        end
        unless peek.word?
          skip_line
          next
        end
        fname = advance.name.to_sym
        if peek.name == "IS"
          advance
          fields << [fname, parse_type_words]
        end
        skip_line
      end

      # Register only now that every field type has been resolved, so a structure
      # cannot refer to itself.
      @struct_names[name] = :struct

      StructDef.new(pos, name, fields)
    end

    # ---------------------------------------------------------- declarations

    def try_parse_var_decl
      unless peek.word?
        skip_line
        return nil
      end
      name = advance.name.to_sym
      unless peek.name == "IS"
        skip_line
        return nil
      end
      advance
      if peek.name == "CONSTANT"
        return parse_const_decl(name: name, pos: here)
      end
      type = parse_type_words
      VarDecl.new(here, name, type)
    end

    def parse_const_decl(name: nil, pos: nil)
      start_pos = pos || advance.pos
      cname = name || advance.name.to_sym
      expect_word_value("IS")
      expect_word_value("CONSTANT")
      type = parse_type_words
      advance if peek.name == "WITH"
      expect_word_value("VALUE")
      value =
        if peek.string?
          s = advance
          StrLit.new(s.pos, s.value)
        elsif peek.number?
          n = advance
          NumLit.new(n.pos, n.value)
        else
          raise CompileError.new("CONSTANT value must be a literal", peek.pos)
        end
      ConstDecl.new(start_pos, cname, type, value)
    end

    # `LIST OF TEXT` / `MAP OF NUMBER` / `NUMBER` / `TEXT` / a structure name.
    def parse_type_words
      words = []
      loop do
        break unless peek.word?
        break if words.any? && CLAUSE_WORDS.include?(peek.name)

        words << advance.name
        break unless Types::CONSTRUCTORS.include?(Types.sym(words.first))
        break unless peek.name == "OF"

        words << advance.name
      end
      type, = Types.from_words(words, struct_names: @struct_names)
      if type.nil?
        raise CompileError.new(
          "unknown type #{words.join(' ').inspect}", here
        )
      end
      type
    end

    # ---------------------------------------------------------- subprocedure

    def parse_subproc
      pos = advance.pos
      advance if peek.name == "PROCEDURE"
      name = expect_word("sub-procedure name").name.to_sym
      skip_line

      params = []
      # `PARAMETERS:` block, terminated by PROCEDURE / the body. The header line is
      # consumed whole; its trailing colon is never inspected.
      if peek.name == "PARAMETERS"
        skip_line
        while more_lines? && !%w[PROCEDURE END].include?(peek.name)
          if peek.word? && peek.name == "IS"
            # trailing modifier for the previous parameter
            advance
            advance if peek.name == "REFERENCE"
            modifier = parse_type_words
            if (last = params.last)
              last.instance_variable_set(:@type, modifier)
              last.instance_variable_set(:@by_reference, true) if modifier
            end
            skip_line
            next
          end
          unless peek.word?
            skip_line
            next
          end

          pname = advance.name.to_sym
          by_ref = false
          if peek.name == "IS"
            advance
            if peek.name == "REFERENCE"
              advance
              by_ref = true
            end
            type = parse_type_words
          else
            # `TYPE name` form: the type precedes the name.
            words = [advance.name]
            if peek.name == "OF"
              words << advance.name
              words << advance.name
            end
            pname2 = expect_word("parameter name").name.to_sym
            type, = Types.from_words(words, struct_names: @struct_names)
            raise CompileError.new("unknown parameter type", here) if type.nil?

            params << Param.new(pname2, type, by_reference: by_ref)
            skip_line
            next
          end
          params << Param.new(pname, type, by_reference: by_ref)
          skip_line
        end
      end

      skip_line if peek.name == "PROCEDURE"
      body = parse_statement_list(stops: %w[END SUB-PROCEDURE SUB])

      unless peek.name == "END"
        raise CompileError.new("expected END SUB-PROCEDURE for #{name}", here)
      end
      skip_line

      SubProcDecl.new(pos, name, params, nil, body, [])
    end

    # ------------------------------------------------------------ statements

    # Parse statements until the current line begins with one of `stops`.
    #
    # When called from the middle of a line (after IF ... THEN, say) the
    # remainder of that line is finished first, so the block always starts on a
    # fresh line.
    def parse_statement_list(stops: [])
      out = []
      while more_lines?
        if !more_tokens?
          skip_line
          next
        end
        break if stops.include?(peek.name)

        stmts = parse_statement
        Array(stmts).each { |s| out << s } if stmts
      end
      out
    end

    # A simple statement ends with its line; a block statement (IF/WHILE/FOR/TRY)
    # consumes its own terminator and has already moved to the next line. Detect
    # which happened by comparing the line index, so exactly one line is consumed
    # either way.
    def parse_statement
      return nil unless more_lines?

      start = @li
      node = parse_statement_inner
      # `nil` means "this line is not a statement" (a sub-procedure header); the
      # caller decides what to do with it, so the line must be left unread.
      skip_line if @li == start && node
      node
    end

    def parse_statement_inner
      case peek.name
      when "DISPLAY", "PRINT" then parse_display
      when "JOIN" then parse_join
      when "ACCEPT" then parse_accept
      when "SET" then parse_set
      when "STORE" then parse_store
      when "IF" then parse_if
      when "WHILE" then parse_while
      when "FOR" then parse_for
      when "PUSH" then parse_push
      when "POP" then parse_pop
      when "GET" then parse_get
      when "LENGTH" then parse_length_of
      when "CALL" then parse_call
      when "RETURN" then parse_return
      when "BREAK" then parse_break
      when "CONTINUE" then parse_continue
      when "EXIT" then parse_exit
      when "TRY" then parse_try
      when "SORT" then parse_sort
      when "REVERSE" then parse_reverse
      when "CLEAR" then parse_clear
      when "IN" then parse_in_first
      when "GOTO" then parse_goto
      when "SUB-PROCEDURE", "SUB"
        nil # handled by the program loop
      else
        parse_label_or_error
      end
    end

    def parse_label_or_error
      if peek(1).punct?(":")
        name = advance.name.to_sym
        skip_line
        return Label.new(here, name)
      end
      raise CompileError.new("unknown statement #{peek.upcase_or_value.inspect}", here)
    end

    # -- individual statements --

    def parse_display
      pos = advance.pos
      operands = []
      while more_tokens?
        break if operand_terminator?
        operands << parse_display_operand
      end
      raise CompileError.new("DISPLAY needs at least one operand", pos) if operands.empty?

      Display.new(pos, operands)
    end

    def operand_terminator? = eof_token? || STATEMENT_STARTERS.include?(peek.name) ||
                               CLAUSE_WORDS.include?(peek.name)

    def parse_display_operand
      if peek.string?
        s = advance
        return StrLit.new(s.pos, s.value)
      end
      if peek.number?
        n = advance
        return NumLit.new(n.pos, n.value)
      end
      parse_expr
    end

    # `JOIN a AND b IN var`, and the mirrored `IN var JOIN a AND b`.
    def parse_join
      pos = advance.pos
      # Additive level, not full expression: a full parse would swallow the AND
      # as a boolean connective before we ever see it.
      lhs = parse_additive
      expect_word_value("AND")
      rhs = parse_additive
      if peek.name == "IN"
        advance
        target = parse_primary
      else
        raise CompileError.new("expected IN in JOIN", here)
      end
      Join.new(pos, lhs, rhs, target)
    end

    # `IN var JOIN a AND b`
    def parse_in_join(pos, target)
      lhs = parse_additive
      expect_word_value("AND")
      rhs = parse_additive
      Join.new(pos, lhs, rhs, target)
    end

    def parse_accept
      pos = advance.pos
      Accept.new(pos, parse_primary)
    end

    def parse_set
      pos = advance.pos
      target = parse_primary
      expect_word_value("TO")
      Assign.new(pos, target, parse_expr)
    end

    def parse_store
      pos = advance.pos
      return parse_store_quote(pos, nil) if quote_start?

      value = parse_expr
      expect_word_value("IN")
      Assign.new(pos, parse_primary, value)
    end

    # True when the line is a STORE/IN ... QUOTE form.
    def quote_start?
      return true if peek.name == "QUOTE"
      return false unless peek.name == "TRIMMED"

      peek(1).name == "QUOTE"
    end

    def parse_store_quote(pos, target)
      trimmed = false
      if peek.name == "TRIMMED"
        advance
        trimmed = true
      end
      advance # QUOTE
      if target.nil?
        expect_word_value("IN")
        target = parse_primary
      end
      StoreQuote.new(pos, target, consume_quote_lines, trimmed)
    end

    def consume_quote_lines
      out = []
      skip_line # the rest of the STORE QUOTE line
      while more_lines?
        if peek.name == "END" && peek(1).name == "QUOTE"
          skip_line
          break
        end
        out << @lines[@li].text
        @li += 1
      end
      raise CompileError.new("a QUOTE block was not terminated", here) if out.empty? &&
                                                                   !more_lines?

      out
    end

    def parse_if
      pos = advance.pos
      cond = parse_expr
      expect_word_value("THEN")
      then_body = parse_statement_list(stops: %w[ELSE END])
      else_body = []

      if peek.name == "ELSE"
        skip_line
        if peek.name == "IF"
          else_body = [parse_if]
          return If.new(pos, cond, then_body, else_body)
        end
        else_body = parse_statement_list(stops: %w[END])
      end

      unless peek.name == "END"
        raise CompileError.new("expected END IF", here)
      end
      skip_line
      If.new(pos, cond, then_body, else_body)
    end

    def parse_while
      pos = advance.pos
      cond = parse_expr
      expect_word_value("DO")
      body = parse_statement_list(stops: %w[REPEAT END])
      close_loop
      While.new(pos, cond, body)
    end

    def close_loop
      if peek.name == "REPEAT"
        skip_line
      elsif peek.name == "END"
        skip_line
      else
        raise CompileError.new("expected REPEAT or END to close the loop", here)
      end
    end

    def parse_for
      pos = advance.pos
      if peek.name == "EACH"
        advance
        elem = parse_primary
        expect_word_value("IN")
        coll = parse_primary
        expect_word_value("DO")
        body = parse_statement_list(stops: %w[REPEAT END])
        close_loop
        return ForEach.new(pos, elem, coll, body)
      end

      var = parse_primary
      expect_word_value("FROM")
      from = parse_expr
      expect_word_value("TO")
      to = parse_expr
      step = nil
      if peek.name == "STEP"
        advance
        step = parse_expr
      end
      inclusive = false
      if peek.name == "INCLUSIVE"
        advance
        inclusive = true
      end
      expect_word_value("DO")
      body = parse_statement_list(stops: %w[REPEAT END])
      close_loop
      For.new(pos, var, from, to, step, inclusive, body)
    end

    def parse_push
      pos = advance.pos
      value = parse_expr
      expect_word_value("TO")
      Push.new(pos, value, parse_primary)
    end

    def parse_pop
      pos = advance.pos
      source = parse_primary
      expect_word_value("INTO")
      Pop.new(pos, parse_primary, source)
    end

    def parse_get
      pos = advance.pos
      if peek.name == "LENGTH"
        advance
        expect_word_value("OF")
        source = parse_primary
        expect_word_value("IN")
        return LengthOf.new(pos, source, parse_primary)
      end
      raise CompileError.new(
        "GET #{peek.upcase_or_value} is not implemented in this compiler yet", here
      )
    end

    def parse_length_of
      pos = advance.pos
      expect_word_value("OF")
      source = parse_primary
      expect_word_value("IN")
      LengthOf.new(pos, source, parse_primary)
    end

    def parse_call
      pos = advance.pos
      if peek.name == "EXTERNAL"
        raise CompileError.new(
          "CALL EXTERNAL is not supported by the wasm backend", here
        )
      end
      advance if peek.name == "SUB-PROCEDURE"
      name = expect_word("sub-procedure name").name.to_sym
      args = []
      if peek.name == "WITH"
        advance
        args << parse_expr
        while peek.punct?(",")
          advance
          args << parse_expr
        end
      end
      Call.new(pos, name, args)
    end

    def parse_return
      pos = advance.pos
      return Return.new(pos, nil) if operand_terminator?

      Return.new(pos, parse_expr)
    end

    def parse_break
      pos = advance.pos
      skip_line
      Break.new(pos)
    end

    def parse_continue
      pos = advance.pos
      skip_line
      Continue.new(pos)
    end

    def parse_exit
      pos = advance.pos
      skip_line
      Exit.new(pos)
    end

    def parse_try
      pos = advance.pos
      body = parse_statement_list(stops: %w[ON END])
      handler = []
      if peek.name == "ON"
        skip_line
        advance if peek.name == "ERROR"
        skip_line
        handler = parse_statement_list(stops: %w[END])
      end
      raise CompileError.new("expected END TRY", here) unless peek.name == "END"

      skip_line
      Try.new(pos, body, handler)
    end

    def parse_sort
      pos = advance.pos
      target = parse_primary
      descending = false
      if peek.name == "DESCENDING"
        advance
        descending = true
      end
      SortInPlace.new(pos, target, descending)
    end

    def parse_reverse
      pos = advance.pos
      ReverseInPlace.new(pos, parse_primary)
    end

    def parse_clear
      pos = advance.pos
      ClearInPlace.new(pos, parse_primary)
    end

    def parse_in_first
      pos = advance.pos
      target = parse_primary
      case peek.name
      when "SOLVE"
        advance
        Solve.new(pos, target, parse_expr)
      when "STORE"
        advance
        return parse_store_quote(pos, target) if quote_start?

        Assign.new(pos, target, parse_expr)
      when "LENGTH"
        advance
        expect_word_value("OF")
        source = parse_primary
        expect_word_value("IN")
        LengthOf.new(pos, source, parse_primary)
      when "JOIN"
        advance
        parse_in_join(pos, target)
      else
        raise CompileError.new("unsupported IN-initial statement", here)
      end
    end

    def parse_goto
      pos = advance.pos
      Goto.new(pos, expect_word("label").name.to_sym)
    end

    # ----------------------------------------------------------- expressions

    def parse_expr = parse_or

    def parse_or
      pos = here
      lhs = parse_and
      while peek.name == "OR"
        advance
        lhs = Logical.new(pos, "OR", lhs, parse_and)
      end
      lhs
    end

    def parse_and
      pos = here
      lhs = parse_not
      while peek.name == "AND"
        advance
        lhs = Logical.new(pos, "AND", lhs, parse_not)
      end
      lhs
    end

    def parse_not
      pos = here
      if peek.name == "NOT"
        advance
        return Unop.new(pos, "NOT", parse_not)
      end

      parse_comparison
    end

    def parse_comparison
      pos = here
      lhs = parse_additive
      while (op = comparison_operator)
        rhs = parse_additive
        lhs = Binop.new(pos, op, lhs, rhs)
      end
      lhs
    end

    # Consume a relational operator and return its symbol, or nil.
    def comparison_operator
      if peek.punct?("=") then advance and return "="
      elsif peek.punct?("<>") then advance and return "<>"
      elsif peek.punct?("<=") then advance and return "<="
      elsif peek.punct?(">=") then advance and return ">="
      elsif peek.punct?("<") then advance and return "<"
      elsif peek.punct?(">") then advance and return ">"
      elsif peek.name == "IS"
        advance
        case peek.name
        when "EQUAL" then advance; expect_word_value("TO"); return "="
        when "NOT" then advance; advance if peek.name == "EQUAL"; expect_word_value("TO"); return "<>"
        when "GREATER"
          advance
          advance if peek.name == "THAN"
          if peek.name == "OR"
            advance
            advance if peek.name == "EQUAL"
            expect_word_value("TO")
            return ">="
          end
          return ">"
        when "LESS"
          advance
          advance if peek.name == "THAN"
          if peek.name == "OR"
            advance
            advance if peek.name == "EQUAL"
            expect_word_value("TO")
            return "<="
          end
          return "<"
        else
          return "=" # bare `IS value`
        end
      end
      nil
    end

    def parse_additive
      pos = here
      lhs = parse_multiplicative
      loop do
        if peek.punct?("+")
          advance
          lhs = Binop.new(pos, "+", lhs, parse_multiplicative)
        elsif peek.punct?("-")
          advance
          lhs = Binop.new(pos, "-", lhs, parse_multiplicative)
        else
          break
        end
      end
      lhs
    end

    def parse_multiplicative
      pos = here
      lhs = parse_unary
      loop do
        if peek.punct?("*")
          advance
          lhs = Binop.new(pos, "*", lhs, parse_unary)
        elsif peek.punct?("/")
          advance
          lhs = Binop.new(pos, "/", lhs, parse_unary)
        elsif peek.punct?("%") || peek.name == "MODULO"
          advance
          lhs = Binop.new(pos, "%", lhs, parse_unary)
        else
          break
        end
      end
      lhs
    end

    def parse_unary
      pos = here
      # The operator must be consumed *before* recursing: Ruby evaluates the
      # arguments to Unop.new first, so consuming afterwards would recurse forever.
      if peek.punct?("-")
        advance
        return Unop.new(pos, "-", parse_unary)
      end
      if peek.punct?("+")
        advance
        return parse_unary
      end

      parse_primary
    end

    def parse_primary
      pos = here

      if peek.punct?("(")
        advance
        inner = parse_expr
        expect_punct(")")
        return inner
      end

      if peek.number?
        n = advance
        return NumLit.new(n.pos, n.value)
      end

      if peek.string?
        s = advance
        return StrLit.new(s.pos, s.value)
      end

      unless peek.word?
        raise CompileError.new(
          "expected a value, found #{peek.upcase_or_value.inspect}", here
        )
      end

      # Returning sub-procedure used as a value: `NAME( args )`
      if peek(1).punct?("(") && @returning.include?(peek.name.to_sym)
        name = advance.name.to_sym
        advance
        args = [parse_expr]
        while peek.punct?(",")
          advance
          args << parse_expr
        end
        expect_punct(")")
        return CallExpr.new(pos, name, args)
      end

      name = advance.name.to_sym
      path = []
      while peek.punct?(":")
        advance
        if peek.number?
          idx = advance
          path << [:index, NumLit.new(idx.pos, idx.value)]
        elsif peek.string?
          idx = advance
          path << [:index, StrLit.new(idx.pos, idx.value)]
        elsif peek.word?
          path << [:field, advance.name.to_sym]
        else
          raise CompileError.new("bad access after ':'", here)
        end
      end
      VarRef.new(pos, name, path)
    end

    # ------------------------------------------------------------- utilities

    def more_lines? = @li < @lines.length
    def more_tokens? = @ti < current_tokens.length

    def current_tokens = @lines[@li]&.tokens || []

    def eof_token? = !more_tokens? || peek.eof?

    def peek(n = 0)
      toks = current_tokens
      toks[@ti + n] || EOF_TOKEN
    end

    def advance
      toks = current_tokens
      tok = toks[@ti]
      @ti += 1
      tok || EOF_TOKEN
    end

    # Finish the current line and move to the next one. The token index must be
# reset *after* advancing the line, or the new line inherits the old line's
# exhausted index and reads as blank.
    def skip_line
      @li += 1
      @ti = 0
    end

    def here
      t = peek
      t.pos || Pos.new(@file, @lines[@li]&.number || 0)
    end

    def expect_word(what)
      raise CompileError.new("expected #{what}", here) unless peek.word?

      advance
    end

    def expect_word_value(want)
      unless peek.word? && peek.name == want
        raise CompileError.new(
          "expected #{want}, found #{peek.upcase_or_value.inspect}", here
        )
      end
      advance
    end

    def expect_punct(sym)
      unless peek.punct?(sym)
        raise CompileError.new(
          "expected #{sym.inspect}, found #{peek.upcase_or_value.inspect}", here
        )
      end
      advance
    end

    def end_of?(w1, w2)
      peek.name == w1 && peek(1).name == w2
    end
  end
end