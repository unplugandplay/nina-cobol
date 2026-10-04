# frozen_string_literal: true

module LdplWasm
  # A line-oriented text dump of the AST.
  #
  # This is a debugging and bootstrap surface, in the same spirit as the sibling
  # COBOL compiler's `-A`: it must be readable by a human with `cat`, and stable
  # enough to diff.
  module AstDump
    module_function

    def dump(program)
      out = +"program\n"
      program.structs.each do |s|
        out << "structure #{s.name}\n"
        s.fields.each { |n, t| out << "  field #{n}|#{Types.to_s(t)}\n" }
      end
      program.globals.each do |v|
        out << "var #{v.name}|#{Types.to_s(v.type)}\n"
      end
      program.constants.each do |c|
        out << "const #{c.name}|#{Types.to_s(c.type)}\n"
      end
      program.subprocs.each do |sp|
        params = sp.params.map { |p| "#{p.name}:#{Types.to_s(p.type)}" }.join(",")
        out << "subproc #{sp.name}|params=#{params}\n"
        sp.body.each { |s| out << node(s, 1) }
      end
      program.body.each { |s| out << node(s, 0) }
      out
    end

    def node(n, depth)
      pad = "  " * depth
      case n
      when Ast::Display
        "#{pad}display|#{n.operands.map { |o| expr(o) }.join(",")}\n"
      when Ast::Accept
        "#{pad}accept|#{expr(n.target)}\n"
      when Ast::Assign
        "#{pad}assign|#{expr(n.target)}|#{expr(n.value)}\n"
      when Ast::Solve
        "#{pad}solve|#{expr(n.target)}|#{expr(n.value)}\n"
      when Ast::Join
        "#{pad}join|#{expr(n.lhs)}|#{expr(n.rhs)}|#{expr(n.target)}\n"
      when Ast::If
        s = +"#{pad}if|#{expr(n.cond)}\n"
        n.then_body.each { |x| s << node(x, depth + 1) }
        n.else_body.each { |x| s << node(x, depth + 1) }
        s
      when Ast::While
        s = +"#{pad}while|#{expr(n.cond)}\n"
        n.body.each { |x| s << node(x, depth + 1) }
        s
      when Ast::For
        s = +"#{pad}for|#{expr(n.var)}|#{expr(n.from)}|#{expr(n.to)}|" \
            "#{n.step ? expr(n.step) : '1'}|#{n.inclusive}\n"
        n.body.each { |x| s << node(x, depth + 1) }
        s
      when Ast::LengthOf
        "#{pad}length-of|#{expr(n.source)}|#{expr(n.target)}\n"
      when Ast::StoreQuote
        "#{pad}store-quote|#{expr(n.target)}|trimmed=#{n.trimmed}|lines=#{n.lines.size}\n"
      when Ast::Call
        "#{pad}call|#{n.name}|args=#{n.args.size}\n"
      when Ast::Return
        "#{pad}return#{n.value ? "|#{expr(n.value)}" : ''}\n"
      when Ast::Break then "#{pad}break\n"
      when Ast::Continue then "#{pad}continue\n"
      when Ast::Label then "#{pad}label|#{n.name}\n"
      when Ast::Goto then "#{pad}goto|#{n.target}\n"
      else "#{pad}#{n.class.name.split('::').last}\n"
      end
    end

    def expr(e)
      case e
      when Ast::NumLit then "num(#{e.value})"
      when Ast::StrLit then "str(#{e.value.inspect})"
      when Ast::VarRef
        path = e.path.map { |k, v| k == :index ? "[#{expr(v)}]" : ".#{v}" }.join
        "#{e.name}#{path}"
      when Ast::Binop then "(#{e.lhs && expr(e.lhs)} #{e.op} #{expr(e.rhs)})"
      when Ast::Unop then "(#{e.op} #{expr(e.operand)})"
      when Ast::Logical then "(#{expr(e.lhs)} #{e.op} #{expr(e.rhs)})"
      when Ast::CallExpr then "call #{e.name}(#{e.args.map { |a| expr(a) }.join(',')})"
      else e.class.name.split("::").last
      end
    end
  end
end
