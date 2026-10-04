# frozen_string_literal: true

module LdplWasm
  # A source position: file and line.
  Pos = Struct.new(:file, :line) do
    def to_s = "#{file}:#{line}"
  end

  # A diagnostic that points at source the user wrote.
  class CompileError < StandardError
    attr_reader :pos

    def initialize(message, pos = nil)
      @pos = pos
      super(pos ? "#{pos}: #{message}" : message)
    end
  end
end
