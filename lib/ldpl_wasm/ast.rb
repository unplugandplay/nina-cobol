# frozen_string_literal: true

require_relative "wasm/emitter"

module LdplWasm
  # LDPL's type system, as the back end needs to see it.
  #
  # LDPL types nest to arbitrary depth (`LIST OF MAP OF LIST OF TEXT`), so a type
  # is an array read outermost-first: the base type is last.
  #
  #   NUMBER            => [:number]
  #   TEXT              => [:text]
  #   LIST OF TEXT      => [:list, :text]
  #   MAP OF NUMBER     => [:map, :number]
  #   PERSON            => [:struct, :PERSON]
  #
  # The *wasm* representation collapses to two cases, which is the single most
  # important decision in this compiler:
  #
  #   NUMBER  -> f64   (all arithmetic is double)
  #   else    -> i32   (a heap pointer: TEXT, LIST, MAP and structs are objects)
  #
  # Every LDPL type is therefore statically known, and every expression has a
  # known wasm type. Nothing is boxed dynamically.
  module Types
    NUMBER = :number
    TEXT = :text
    LIST = :list
    MAP = :map
    VOID = :void

    # A type is a stack read outermost-first. The *base* type is last, and the
    # outermost constructor is first:
    #
    #   NUMBER            => [:number]
    #   TEXT              => [:text]
    #   PERSON            => [:PERSON]
    #   LIST OF TEXT      => [:list, :text]
    #   MAP OF NUMBER     => [:map, :number]
    #   LIST OF MAP OF TEXT => [:list, :map, :text]
    #   LIST OF PERSON    => [:list, :PERSON]
    #
    # A user structure is just its (upcased) name, so a scalar structure and
    # `LIST OF <structure>` are distinguishable without a separate tag.
    CONSTRUCTORS = [LIST, MAP].freeze
    SCALARS = [NUMBER, TEXT].freeze

    # Declaration words arrive from the lexer already upcased, so comparing them to
    # the lowercase tags below requires normalising case first. Getting this wrong
    # makes `TEXT` look like an unknown structure name.
    module_function

    def sym(word) = word.to_s.downcase.to_sym


    def number = [NUMBER]
    def text = [TEXT]
    def list(inner) = [LIST, *inner]
    def map(inner) = [MAP, *inner]
    def struct(name) = [name.to_sym]
    def void = [VOID]

    def base(type) = type.last
    def scalar?(type) = type.size == 1
    def number?(type) = base(type) == NUMBER
    def text?(type) = base(type) == TEXT
    def struct?(type) = scalar?(type) && !SCALARS.include?(type[0])
    def struct_name(type) = struct?(type) ? type[0] : nil
    def container?(type) = CONSTRUCTORS.include?(type[0])
    def list?(type) = type[0] == LIST
    def map?(type) = type[0] == MAP
    def scalar_value?(type) = scalar?(type)

    # The element type of a LIST or MAP, or nil.
    def element(type) = container?(type) ? type[1..] : nil

    # The wasm value type used to hold a value of this LDPL type. This collapse to
    # two cases is the central representation decision of the compiler: NUMBER is a
    # double, everything else is a heap pointer.
    # Only a *bare* NUMBER is a double. `LIST OF NUMBER` is a pointer to a list
    # object whose elements are doubles -- testing the base type here would wrongly
    # make the list itself an f64.
    def plain_number?(type) = type == [NUMBER]

    def wasm(type) = plain_number?(type) ? Wasm::F64 : Wasm::I32

    def slot_size(type) = plain_number?(type) ? 8 : 4

    def to_s(type)
      return "void" if type.nil?

      case type[0]
      when LIST then "LIST OF #{element(type).nil? ? '?' : to_s(element(type))}"
      when MAP then "MAP OF #{element(type).nil? ? '?' : to_s(element(type))}"
      else type[0].to_s.upcase
      end
    end

    def inspect_type(type) = to_s(type)

    # Parse a type from the words a declaration used, e.g. %w[LIST OF TEXT].
    # Returns [type_or_nil, unconsumed_words].
    def from_words(words, struct_names: {})
      return [nil, words] if words.empty?

      first = sym(words.first)
      case first
      when NUMBER then [number, words.drop(1)]
      when TEXT then [text, words.drop(1)]
      when LIST, MAP
        rest = words.drop(1)
        rest = rest.drop(1) if rest.first && sym(rest.first) == :of
        inner, rest = from_words(rest, struct_names: struct_names)
        return [nil, words] if inner.nil?

        [first == LIST ? list(inner) : map(inner), rest]
      else
        # A bare word is a structure name. LDPL requires STRUCTURE to be declared
        # before use as a type, so an unknown name is an error, not a forward
        # reference.
        found = struct_names.keys.find { |k| k.to_s.downcase == first.to_s }
        return [struct(found), words.drop(1)] if found

        [nil, words]
      end
    end
  end

  # ---------------------------------------------------------------- AST ------

  module Ast
    # Base class. `pos` is where the construct started, for diagnostics.
    class Node
      attr_reader :pos

      def initialize(pos)
        @pos = pos
      end

      def accept(visitor, ctx = nil)
        visitor.visit(self, ctx)
      end
    end

    # --- declarations ---

    class VarDecl < Node
      attr_reader :name, :type

      def initialize(pos, name, type)
        super(pos)
        @name = name # upcased symbol
        @type = type
      end

      def accept(v, ctx = nil) = v.visit_var_decl(self, ctx)
    end

    class ConstDecl < Node
      attr_reader :name, :type, :value

      def initialize(pos, name, type, value)
        super(pos)
        @name = name
        @type = type
        @value = value
      end

      def accept(v, ctx = nil) = v.visit_const_decl(self, ctx)
    end

    class StructDef < Node
      attr_reader :name, :fields

      def initialize(pos, name, fields)
        super(pos)
        @name = name
        @fields = fields # [[name, type], ...] in declaration order
      end

      def accept(v, ctx = nil) = v.visit_struct_def(self, ctx)
    end

    class Param
      attr_reader :name, :type, :by_reference

      def initialize(name, type, by_reference: false)
        @name = name
        @type = type
        @by_reference = by_reference
      end
    end

    class SubProcDecl < Node
      attr_reader :name, :params, :return_type, :body, :locals

      def initialize(pos, name, params, return_type, body, locals)
        super(pos)
        @name = name
        @params = params # [Param]
        @return_type = return_type
        @body = body
        @locals = locals # [VarDecl]
      end

      def accept(v, ctx = nil) = v.visit_subproc_decl(self, ctx)
    end

    # --- statements ---

    class Block < Node
      attr_reader :stmts

      def initialize(pos, stmts = [])
        super(pos)
        @stmts = stmts
      end

      def accept(v, ctx = nil) = v.visit_block(self, ctx)
    end

    # `DISPLAY a b "lit" c` -- a sequence of operands, each NUMBER or TEXT.
    class Display < Node
      attr_reader :operands

      def initialize(pos, operands)
        super(pos)
        @operands = operands
      end

      def accept(v, ctx = nil) = v.visit_display(self, ctx)
    end

    class Accept < Node
      attr_reader :target

      def initialize(pos, target)
        super(pos)
        @target = target
      end

      def accept(v, ctx = nil) = v.visit_accept(self, ctx)
    end

    class Assign < Node
      attr_reader :target, :value

      def initialize(pos, target, value)
        super(pos)
        @target = target
        @value = value
      end

      def accept(v, ctx = nil) = v.visit_assign(self, ctx)
    end

    class If < Node
      attr_reader :cond, :then_body, :else_body

      def initialize(pos, cond, then_body, else_body)
        super(pos)
        @cond = cond
        @then_body = then_body
        @else_body = else_body
      end

      def accept(v, ctx = nil) = v.visit_if(self, ctx)
    end

    class While < Node
      attr_reader :cond, :body

      def initialize(pos, cond, body)
        super(pos)
        @cond = cond
        @body = body
      end

      def accept(v, ctx = nil) = v.visit_while(self, ctx)
    end

    class For < Node
      attr_reader :var, :from, :to, :step, :inclusive, :body

      def initialize(pos, var, from, to, step, inclusive, body)
        super(pos)
        @var = var
        @from = from
        @to = to
        @step = step
        @inclusive = inclusive
        @body = body
      end

      def accept(v, ctx = nil) = v.visit_for(self, ctx)
    end

    class ForEach < Node
      attr_reader :elem, :collection, :body

      def initialize(pos, elem, collection, body)
        super(pos)
        @elem = elem
        @collection = collection
        @body = body
      end

      def accept(v, ctx = nil) = v.visit_for_each(self, ctx)
    end

    class Push < Node
      attr_reader :value, :target

      def initialize(pos, value, target)
        super(pos)
        @value = value
        @target = target
      end

      def accept(v, ctx = nil) = v.visit_push(self, ctx)
    end

    class Pop < Node
      attr_reader :target, :source

      def initialize(pos, target, source)
        super(pos)
        @target = target
        @source = source
      end

      def accept(v, ctx = nil) = v.visit_pop(self, ctx)
    end

    # `JOIN <a> AND <b> IN <target>` -- text concatenation, either operand order.
    class Join < Node
      attr_reader :lhs, :rhs, :target

      def initialize(pos, lhs, rhs, target)
        super(pos)
        @lhs = lhs
        @rhs = rhs
        @target = target
      end

      def accept(v, ctx = nil) = v.visit_join(self, ctx)
    end

    # `GET LENGTH OF <src> IN <target>`
    class LengthOf < Node
      attr_reader :source, :target

      def initialize(pos, source, target)
        super(pos)
        @source = source
        @target = target
      end

      def accept(v, ctx = nil) = v.visit_length_of(self, ctx)
    end

    class Call < Node
      attr_reader :name, :args

      def initialize(pos, name, args)
        super(pos)
        @name = name
        @args = args
      end

      def accept(v, ctx = nil) = v.visit_call(self, ctx)
    end

    class Return < Node
      attr_reader :value

      def initialize(pos, value = nil)
        super(pos)
        @value = value
      end

      def accept(v, ctx = nil) = v.visit_return(self, ctx)
    end

    class Break < Node
      def accept(v, ctx = nil) = v.visit_break(self, ctx)
    end

    class Continue < Node
      def accept(v, ctx = nil) = v.visit_continue(self, ctx)
    end

    # `EXIT` -- leave the current loop or sub-procedure.
    class Exit < Node
      def accept(v, ctx = nil) = v.visit_exit(self, ctx)
    end

    class Try < Node
      attr_reader :body, :handler

      def initialize(pos, body, handler)
        super(pos)
        @body = body
        @handler = handler
      end

      def accept(v, ctx = nil) = v.visit_try(self, ctx)
    end

    # `STORE QUOTE IN x` / `x STORE QUOTE` / TRIMMED variants.
    class StoreQuote < Node
      attr_reader :target, :lines, :trimmed

      def initialize(pos, target, lines, trimmed)
        super(pos)
        @target = target
        @lines = lines
        @trimmed = trimmed
      end

      def accept(v, ctx = nil) = v.visit_store_quote(self, ctx)
    end

    class SortInPlace < Node
      attr_reader :target, :descending

      def initialize(pos, target, descending)
        super(pos)
        @target = target
        @descending = descending
      end

      def accept(v, ctx = nil) = v.visit_sort(self, ctx)
    end

    class ReverseInPlace < Node
      attr_reader :target

      def initialize(pos, target)
        super(pos)
        @target = target
      end

      def accept(v, ctx = nil) = v.visit_reverse(self, ctx)
    end

    class ClearInPlace < Node
      attr_reader :target

      def initialize(pos, target)
        super(pos)
        @target = target
      end

      def accept(v, ctx = nil) = v.visit_clear(self, ctx)
    end

    # `IN <var> SOLVE <expression>` -- the arithmetic-statement form.
    class Solve < Node
      attr_reader :target, :expr

      def initialize(pos, target, expr)
        super(pos)
        @target = target
        @expr = expr
      end

      def accept(v, ctx = nil) = v.visit_solve(self, ctx)
    end

    class Label < Node
      attr_reader :name

      def initialize(pos, name)
        super(pos)
        @name = name
      end

      def accept(v, ctx = nil) = v.visit_label(self, ctx)
    end

    class Goto < Node
      attr_reader :target

      def initialize(pos, target)
        super(pos)
        @target = target
      end

      def accept(v, ctx = nil) = v.visit_goto(self, ctx)
    end

    # --- expressions ---

    class NumLit < Node
      attr_reader :value

      def initialize(pos, value)
        super(pos)
        @value = value
      end

      def accept(v, ctx = nil) = v.visit_num_lit(self, ctx)
    end

    class StrLit < Node
      attr_reader :value

      def initialize(pos, value)
        super(pos)
        @value = value
      end

      def accept(v, ctx = nil) = v.visit_str_lit(self, ctx)
    end

    # A bare name, or a chain: `a`, `a:b`, `a:0`, `a:b:c`, `person:age`.
    class VarRef < Node
      attr_reader :name, :path

      def initialize(pos, name, path = [])
        super(pos)
        @name = name
        @path = path # [:index, expr] / [:field, name]
      end

      def simple? = @path.empty?

      def accept(v, ctx = nil) = v.visit_var_ref(self, ctx)
    end

    class Binop < Node
      attr_reader :op, :lhs, :rhs

      def initialize(pos, op, lhs, rhs)
        super(pos)
        @op = op
        @lhs = lhs
        @rhs = rhs
      end

      def accept(v, ctx = nil) = v.visit_binop(self, ctx)
    end

    class Unop < Node
      attr_reader :op, :operand

      def initialize(pos, op, operand)
        super(pos)
        @op = op
        @operand = operand
      end

      def accept(v, ctx = nil) = v.visit_unop(self, ctx)
    end

    # A call used as a value (a returning sub-procedure).
    class CallExpr < Node
      attr_reader :name, :args

      def initialize(pos, name, args)
        super(pos)
        @name = name
        @args = args
      end

      def accept(v, ctx = nil) = v.visit_call_expr(self, ctx)
    end

    # Short-circuit AND/OR/NOT.
    class Logical < Node
      attr_reader :op, :lhs, :rhs

      def initialize(pos, op, lhs, rhs)
        super(pos)
        @op = op
        @lhs = lhs
        @rhs = rhs
      end

      def accept(v, ctx = nil) = v.visit_logical(self, ctx)
    end

    # A program: declarations plus a main body.
    class Program < Node
      attr_reader :structs, :globals, :constants, :subprocs, :body

      def initialize(pos, structs, globals, constants, subprocs, body)
        super(pos)
        @structs = structs
        @globals = globals
        @constants = constants
        @subprocs = subprocs
        @body = body
      end

      def accept(v, ctx = nil) = v.visit_program(self, ctx)
    end
  end
end