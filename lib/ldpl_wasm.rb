# frozen_string_literal: true

module LdplWasm
  VERSION = "0.1.0"
  CODENAME = "Triceratops"
end

require_relative "ldpl_wasm/error"
require_relative "ldpl_wasm/lexer"
require_relative "ldpl_wasm/ast"
require_relative "ldpl_wasm/parser"
require_relative "ldpl_wasm/analyzer"
require_relative "ldpl_wasm/wasm/emitter"
require_relative "ldpl_wasm/runtime/runtime"
require_relative "ldpl_wasm/codegen"
require_relative "ldpl_wasm/ast_dump"
require_relative "ldpl_wasm/cli"