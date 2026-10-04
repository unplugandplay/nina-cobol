#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite.
#
# Two tiers, because they fail for very different reasons:
#
#   * front end -- lexing, parsing and analysis, checked against the AST dump.
#     These run with no WebAssembly involvement at all.
#   * back end  -- compile and *run* a module under Node and compare stdout.
#
# The back-end tier is the only one that can catch a codegen bug; everything else
# is a smoke test for the pipeline.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "ldpl_wasm"
require "open3"

ROOT = File.expand_path("..", __dir__)
RUNNER = File.join(ROOT, "test", "run_wasm.js")

$failures = []
$passes = 0

def check(name)
  ok, detail = yield
  if ok
    $passes += 1
    puts format("  ok   %s", name)
  else
    $failures << "#{name}: #{detail}"
    puts format("  FAIL %s -- %s", name, detail)
  end
rescue StandardError => e
  $failures << "#{name}: #{e.class}: #{e.message}"
  puts format("  FAIL %s -- %s: %s", name, e.class, e.message)
end

def compile(source, name)
  path = File.join(ROOT, "tmp", "#{name}.ldpl")
  File.write(path, source)
  out, err, status = Open3.capture3(
    RbConfig.ruby, File.join(ROOT, "bin", "ldpl-wasm"), path,
    "-o=#{File.join(ROOT, 'tmp', "#{name}.wasm")}"
  )
  [status.success?, out, err, File.join(ROOT, "tmp", "#{name}.wasm")]
end

def run_module(wasm, stdin_data = "")
  Open3.capture3("node", RUNNER, wasm, stdin_data: stdin_data)
end

# ---------------------------------------------------------------- front end ---

puts "front end"

check("lexer: sections, comments, CRLF") do
  toks = LdplWasm::Lex.lex_lines(<<~LDPL, "t.ldpl")
    # comment
    -- DATA --
    n IS NUMBER
    -- PROCEDURE --
    DISPLAY "hi" CRLF
  LDPL
  names = toks.flat_map { |l| l.tokens.map(&:name) }
  crlf = toks.flat_map { |l| l.tokens }.find { |t| t.raw == "CRLF" }
  [names.include?("DATA") && names.include?("PROCEDURE") && crlf&.value == "\r\n",
   "tokens were #{names.inspect}"]
end

check("lexer: keep raw line text for STORE QUOTE") do
  lines = LdplWasm::Lex.lex_lines("STORE QUOTE IN t\n  raw   text\nEND QUOTE\n", "t")
  [lines[1].text == "  raw   text", "got #{lines[1].text.inspect}"]
end

check("types: LIST OF NUMBER is a pointer, not a double") do
  t, = LdplWasm::Types.from_words(%w[LIST OF NUMBER])
  [LdplWasm::Types.wasm(t) == LdplWasm::Wasm::I32,
   "wasm type was #{LdplWasm::Types.wasm(t)}"]
end

check("types: a bare structure name resolves") do
  t, = LdplWasm::Types.from_words(%w[PERSON], struct_names: { PERSON: :struct })
  [t == [:PERSON], "got #{t.inspect}"]
end

check("parser: the full tour program parses") do
  src = File.read(File.join(ROOT, "test", "programs", "tour.ldpl"))
  prog = LdplWasm::Parser.parse(src, "tour.ldpl")
  [prog.structs.size == 1 && prog.subprocs.size == 2 && prog.body.size > 50,
   "structs=#{prog.structs.size} subs=#{prog.subprocs.size} body=#{prog.body.size}"]
end

check("parser: structures lay out fields at static offsets") do
  src = <<~LDPL
    STRUCTURE P
        name IS TEXT
        age IS NUMBER
    END STRUCTURE
    -- DATA --
    p IS P
  LDPL
  an = LdplWasm::Analyzer.new
  an.analyze(LdplWasm::Parser.parse(src, "t"))
  s = an.structs[:P]
  # NAME is a 4-byte pointer; AGE is an 8-byte f64 and must be aligned to 8.
  [s[:fields][:NAME] == [0, [:text]] && s[:fields][:AGE] == [8, [:number]],
   "fields were #{s[:fields].inspect} (expected AGE at offset 8)"]
end

check("parser: sub-procedure parameters are typed") do
  src = <<~LDPL
    -- PROCEDURE --
    DISPLAY "x"
    SUB-PROCEDURE B
        PARAMETERS:
        n IS NUMBER
        PROCEDURE
        RETURN
    END SUB-PROCEDURE
  LDPL
  prog = LdplWasm::Parser.parse(src, "t")
  sp = prog.subprocs.first
  [sp && sp.params.size == 1 && sp.params.first.type == [:number],
   "params were #{sp&.params.inspect}"]
end

check("front end rejects a bad statement with a line number") do
  src = "-- PROCEDURE --\nWIBBLE 1 2 3\n"
  begin
    LdplWasm::Parser.parse(src, "bad.ldpl")
    [false, "expected a CompileError"]
  rescue LdplWasm::CompileError => e
    [e.message.include?("bad.ldpl:2"), "message was #{e.message.inspect}"]
  end
end

# ----------------------------------------------------------------- back end ---

puts "\nback end"

check("emitter: a hand-assembled module validates and runs") do
  require "ldpl_wasm/wasm/smoke"
  wasm = File.join(ROOT, "tmp", "smoke.wasm")
  File.binwrite(wasm, LdplWasm::Wasm::Smoke.emit)
  out, err, = run_module(wasm)
  [out == "hello, wasm\n", "stdout was #{out.inspect} stderr #{err.inspect}"]
end

check("end to end: hello.ldpl compiles to a running module") do
  ok, _out, err, wasm = compile(File.read(File.join(ROOT, "examples", "hello.ldpl")), "hello")
  unless ok
    next [false, err.lines.first.to_s.strip]
  end
  out, rerr, = run_module(wasm)
  [out == "hello, wasm\n", "stdout #{out.inspect} stderr #{rerr.inspect}"]
end

check("codegen: string literals land in the data section") do
  src = "-- PROCEDURE --\nDISPLAY \"abc\"\n"
  ok, _o, err, = compile(src, "literals")
  ok ||= [false, err.lines.first.to_s.strip]
  bytes = File.binread(File.join(ROOT, "tmp", "literals.wasm")) if ok
  [ok && bytes.include?("abc"), "literal bytes not found in the module"]
end

check("codegen: a NUMBER operand calls the formatter") do
  src = "-- DATA --\nn IS NUMBER\n-- PROCEDURE --\nSET n TO 1\nDISPLAY n\n"
  ok, _o, err, wasm = compile(src, "fmt")
  if ok
    out, = run_module(wasm)
    ok = out == "1"
  end
  [ok, ok ? "" : "formatter path is not runnable yet"]
end

# ------------------------------------------------------------------- report ---

puts
if $failures.empty?
  puts "#{$passes} passed"
  exit 0
else
  puts "#{$passes} passed, #{$failures.size} failed:"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end