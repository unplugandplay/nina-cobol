# frozen_string_literal: true

require_relative "error"

module LdplWasm
  # The lexer.
  module Lex
    # Lexical tokens.
    #
    # LDPL's own token rules are unusual in two ways that matter here:
    #
    #   * `CRLF`, `LF`, `CR` and the `ASCII_*` names are *words* that the
    #     compiler rewrites into string literals. They are lexed as ordinary
    #     identifiers and rewritten by the lexer, because the compiler needs the
    #     literal bytes, not the word.
    #   * an unadorned `--` on its own line is a section marker (`-- DATA --`),
    #     not two minus signs. The lexer therefore only treats `--` as punctuation
    #     when it is *not* the whole line.
    Token = Struct.new(:kind, :value, :pos, :raw) do
      def word? = kind == :word
      def string? = kind == :string
      def number? = kind == :number
      def punct?(*syms) = kind == :punct && syms.include?(value)
      def eof? = kind == :eof

      def name = value.to_s.upcase
      def upcase_or_value = value.is_a?(String) ? value.upcase : value
      def inspect = "#<#{kind} #{value.inspect} #{pos}>"
    end

    # One source line: its number, its raw text, and its tokens. LDPL is a
    # line-oriented language -- a statement ends at the end of its line -- so the
    # parser consumes whole lines. Keeping the raw text alongside is what makes
    # `STORE QUOTE` possible without re-reading the file.
    Line = Struct.new(:number, :text, :tokens)

    # Control-character spellings that the LDPL compiler accepts as bare words.
    ASCII_WORDS = {
      "ASCII_SOH" => 0x01, "ASCII_STX" => 0x02, "ASCII_ETX" => 0x03,
      "ASCII_EOT" => 0x04, "ASCII_ENQ" => 0x05, "ASCII_ACK" => 0x06,
      "ASCII_BEL" => 0x07, "ASCII_BS" => 0x08, "ASCII_HT" => 0x09,
      "ASCII_LF" => 0x0A, "ASCII_VT" => 0x0B, "ASCII_FF" => 0x0C,
      "ASCII_CR" => 0x0D, "ASCII_SO" => 0x0E, "ASCII_SI" => 0x0F,
      "ASCII_DLE" => 0x10, "ASCII_DC1" => 0x11, "ASCII_DC2" => 0x12,
      "ASCII_DC3" => 0x13, "ASCII_DC4" => 0x14, "ASCII_NAK" => 0x15,
      "ASCII_SYN" => 0x16, "ASCII_ETB" => 0x17, "ASCII_CAN" => 0x18,
      "ASCII_EM" => 0x19, "ASCII_SUB" => 0x1A, "ASCII_ESC" => 0x1B,
      "ASCII_FS" => 0x1C, "ASCII_GS" => 0x1D, "ASCII_RS" => 0x1E,
      "ASCII_US" => 0x1F, "ASCII_DEL" => 0x7F
    }.freeze

    # The newline spellings the compiler rewrites.
    NEWLINE_WORDS = {
      "CRLF" => "\r\n",
      "LF" => "\n",
      "CR" => "\r"
    }.freeze

    IDENT_START = /[A-Za-z_]/.freeze
    IDENT_CHAR = /[A-Za-z0-9_-]/.freeze

    class Lexer
      def initialize(source, file = "(stdin)")
        @src = source
        @file = file
        @pos = 0
        @line = 1
      end

      def here = Pos.new(@file, @line)

      # Lex the whole source into a flat token stream.
      def tokens
        out = []
        each_line do |line|
          out.concat(line.tokens)
        end
        out << Token.new(:eof, "", here, nil)
        out
      end

      # Lex the source into per-line token groups. This is what the parser wants:
      # LDPL statements are line-terminated.
      def lines
        out = []
        each_line { |line| out << line }
        out
      end

      private

      def each_line
        buffer = +""
        start_line = @line
        until eof?
          c = peek
          if c == "\n" || c == "\r"
            emit(buffer, start_line) { |t| yield t }
            buffer = +""
            bump_newline
            start_line = @line
          else
            buffer << c
            advance
          end
        end
        emit(buffer, start_line) { |t| yield t } unless buffer.strip.empty?
      end

      # Lex one physical line into tokens.
      def emit(text, line_number)
        sub = Lexer.new(text, @file)
        sub.instance_variable_set(:@line, line_number)
        toks = []
        loop do
          sub.send(:skip_blanks)
          break if sub.send(:eof?)

          toks << sub.send(:next_token)
        end
        yield Line.new(line_number, text, toks) if toks.any?
      end

      def eof? = @pos >= @src.length
      def peek(n = 0) = @src[@pos + n]
      def advance = (@pos += 1)

      def bump_newline
        if @src[@pos] == "\n"
          @line += 1
        end
        @pos += 1
      end

      def skip_blanks
        until eof?
          c = peek
          if c == "\n" || c == "\r"
            bump_newline
          elsif c == " " || c == "\t"
            advance
          elsif c == "#"
            advance while !eof? && peek != "\n" && peek != "\r"
          elsif c == "/" && peek(1) == "/"
            advance while !eof? && peek != "\n" && peek != "\r"
          else
            break
          end
        end
      end

      def next_token
        pos = here
        c = peek

        # A bare `--` line is a section marker; inside a line it is punctuation
        # only if it is not a comment form. LDPL comments are `#` and `//`, so
        # `--` here always means "minus minus", which the parser rejects unless
        # it is part of an identifier.
        if c == '"'
          return string_token(pos)
        end

        if c =~ /[0-9]/ || (c == "." && peek(1) =~ /[0-9]/)
          return number_token(pos)
        end

        if c =~ IDENT_START
          return word_token(pos)
        end

        if %w[( ) : , + - * / % = < >].include?(c)
          # Two-character comparison operators.
          two = c + peek(1).to_s
          if ["<=", ">=", "<>"].include?(two)
            advance
            advance
            return Token.new(:punct, two, pos, two)
          end
          advance
          return Token.new(:punct, c, pos, c)
        end

        raise CompileError.new("unexpected character #{c.inspect}", pos)
      end

      def word_token(pos)
        start = @pos
        advance while !eof? && peek =~ IDENT_CHAR
        raw = @src[start...@pos]
        upper = raw.upcase

        # Newline and control-character spellings become string literals, exactly
        # as the reference compiler rewrites them.
        if NEWLINE_WORDS.key?(upper)
          return Token.new(:string, NEWLINE_WORDS[upper], pos, raw)
        end

        if ASCII_WORDS.key?(upper)
          return Token.new(:string, ASCII_WORDS[upper].chr, pos, raw)
        end

        Token.new(:word, raw, pos, raw)
      end

      def number_token(pos)
        start = @pos
        seen_dot = false
        seen_exp = false
        loop do
          break if eof?

          c = peek
          if c =~ /[0-9]/
            advance
          elsif c == "." && !seen_dot && !seen_exp && peek(1) =~ /[0-9]/
            seen_dot = true
            advance
          elsif (c == "e" || c == "E") && !seen_exp
            nxt = peek(1)
            if nxt =~ /[0-9]/ || ((nxt == "-" || nxt == "+") && peek(2) =~ /[0-9]/)
              seen_exp = true
              advance
              advance if peek == "-" || peek == "+"
            else
              break
            end
          else
            break
          end
        end
        raw = @src[start...@pos]
        Token.new(:number, raw.to_f, pos, raw)
      end

      def string_token(pos)
        advance # opening quote
        buf = +""
        loop do
          if eof?
            raise CompileError.new("unterminated string literal", pos)
          end

          c = peek
          if c == "\\"
            advance
            raise CompileError.new("unterminated escape sequence", pos) if eof?

            esc = peek
            advance
            buf << case esc
                   when "n" then "\n"
                   when "r" then "\r"
                   when "t" then "\t"
                   when "0" then "\0"
                   when "\\" then "\\"
                   when '"' then '"'
                   else "\\" + esc
                   end
          elsif c == '"'
            advance
            break
          elsif c == "\n"
            raise CompileError.new("newline inside string literal", pos)
          else
            buf << c
            advance
          end
        end
        Token.new(:string, buf, pos, buf)
      end
    end

    module_function

    def lex(source, file = "(stdin)")
      Lexer.new(source, file).tokens
    end

    def lex_lines(source, file = "(stdin)")
      Lexer.new(source, file).lines
    end
  end
end