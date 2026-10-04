# frozen_string_literal: true

module LdplWasm
  # Command-line front end.
  #
  #   ldpl-wasm program.ldpl            compile to program.wasm
  #   ldpl-wasm program.ldpl -o out.wasm
  #   ldpl-wasm program.ldpl -E         compile, run under Node, discard
  #   ldpl-wasm program.ldpl -A         dump the AST as text, stop
  #   ldpl-wasm -v | -h
  class CLI
    USAGE = <<~TEXT
      ldpl-wasm #{VERSION} '#{CODENAME}' -- LDPL compiled straight to WebAssembly

      Usage:
        ldpl-wasm <source.ldpl> [-o=<out.wasm>] [-E] [-A] [-w]
        ldpl-wasm -v | -h

      Options:
        -o=<file>   write the module to <file> (default: <source>.wasm)
        -E          compile, run it under Node, then discard the module
        -A          dump the text AST and stop
        -w          keep going after recoverable problems
        -v          print version information
        -h          print this message
    TEXT

    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv
      @options = { out: nil, run: false, ast: false }
    end

    def run
      args = @argv.dup
      args.each do |arg|
        case arg
        when "-h", "--help"
          puts USAGE
          return 0
        when "-v", "--version"
          print_version
          return 0
        when "-E" then @options[:run] = true
        when "-A" then @options[:ast] = true
        when "-w" then @options[:w] = true
        else
          if arg.start_with?("-o=")
            @options[:out] = arg[3..]
          elsif arg.start_with?("-")
            warn "ldpl-wasm: unknown option #{arg}"
            warn "Try 'ldpl-wasm -h'."
            return 1
          elsif @source.nil?
            @source = arg
          else
            warn "ldpl-wasm: more than one source file given"
            warn "Use IMPORT instead."
            return 1
          end
        end
      end

      if @source.nil?
        warn "ldpl-wasm: no source file given"
        warn "Try 'ldpl-wasm -h'."
        return 1
      end

      unless File.file?(@source)
        warn "ldpl-wasm: cannot read #{@source}"
        return 1
      end

      source = File.read(@source, encoding: "UTF-8")
      compile(source, @source)
    rescue CompileError => e
      warn "ldpl-wasm: #{e.message}"
      1
    end

    def print_version
      puts "ldpl-wasm #{VERSION} '#{CODENAME}'"
      puts "LDPL -> WebAssembly, emitted directly. No C, no Emscripten."
      puts "Runtime: ruby #{RUBY_VERSION}"
    end

    # The whole pipeline, in one place.
    def compile(source, file)
      # A returning sub-procedure used as a value needs a pre-pass to know which
      # names may be called; for now nothing is known, which is why `RETURN x`
      # is only accepted in statement position.
      program = Parser.parse(source, file, returning: [])

      if @options[:ast]
        puts AstDump.dump(program)
        return 0
      end

      analyzer = Analyzer.new
      analyzer.analyze(program)

      mod = Wasm::Module.new(name: "ldpl")
      mod.memory_pages = 4
      mod.max_memory_pages = 256

      runtime = Runtime.new(mod, analyzer)
      runtime.declare(analyzer.needs)

      Codegen.new(analyzer, runtime).build(program)

      # String literals live in a data segment at the end of the pool.
      analyzer.literals.each_value do |offset|
        bytes = analyzer.literals.key(offset)
        mod.data(offset, bytes)
      end

      out = @options[:out] || "#{@source}.wasm"
      bytes = mod.emit
      File.binwrite(out, bytes)
      warn "ldpl-wasm: wrote #{out} (#{bytes.bytesize} bytes)" unless @options[:run]

      if @options[:run]
        runner = File.expand_path("../../test/run_wasm.js", __dir__)
        ok = system("node", runner, out)
        return(ok ? 0 : 1)
      end
      0
    end
  end
end