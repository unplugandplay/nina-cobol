#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"

WIDTH = 80
ROOT = File.expand_path("..", __dir__)
INPUT = File.join(ROOT, "DOCUMENTATION.md")
OUTPUT = File.join(ROOT, "DOCUMENTATION.txt")

abort "DOCUMENTATION.md does not exist; run docs/build-single-file.sh first" unless File.file?(INPUT)

def display_width(text)
  text.each_codepoint.sum do |codepoint|
    if (0x0300..0x036F).cover?(codepoint) || (0xFE00..0xFE0F).cover?(codepoint)
      0
    elsif (0x1100..0x115F).cover?(codepoint) || (0x2E80..0xA4CF).cover?(codepoint) ||
          (0xAC00..0xD7A3).cover?(codepoint) || (0xF900..0xFAFF).cover?(codepoint) ||
          (0xFE10..0xFE6F).cover?(codepoint) || (0xFF00..0xFF60).cover?(codepoint) ||
          (0x1F300..0x1FAFF).cover?(codepoint)
      2
    else
      1
    end
  end
end

def pad_to(text, width)
  text + (" " * [width - display_width(text), 0].max)
end

def center_to(text, width)
  padding = [width - display_width(text), 0].max
  (" " * (padding / 2)) + text + (" " * (padding - padding / 2))
end

def plain(text)
  value = text.dup
  code_spans = []
  value.gsub!(/`([^`]+)`/) do
    code_spans << Regexp.last_match(1)
    "\u0000CODE#{code_spans.length - 1}\u0000"
  end
  value.gsub!(/!\[([^\]]*)\]\(([^)]+)\)/, '\1 <\2>')
  value.gsub!(/\[([^\]]+)\]\((#[^)]+)\)/, '\1')
  value.gsub!(/\[([^\]]+)\]\(mailto:([^)]+)\)/) do
    Regexp.last_match(1) == Regexp.last_match(2) ? Regexp.last_match(1) :
      "#{Regexp.last_match(1)} <#{Regexp.last_match(2)}>"
  end
  value.gsub!(/\[([^\]]+)\]\(([^)]+)\)/, '\1 <\2>')
  value.gsub!(/\*\*([^*]+)\*\*/, '\1')
  value.gsub!(/__([^_]+)__/, '\1')
  value.gsub!(/(?<![\\*])\*([^*]+)\*(?!\*)/, '\1')
  value.gsub!(/(?<![\\_])_([^_]+)_(?!_)/, '\1')
  value.gsub!(/\\([()_*])/, '\1')
  value.gsub!(/<br\s*\/?>/i, "\n")
  code_spans.each_with_index do |code, index|
    value.gsub!("\u0000CODE#{index}\u0000") { "'#{code}'" }
  end
  CGI.unescapeHTML(value).rstrip
end

def wrap_words(text, width, first_prefix = "", continuation_prefix = first_prefix)
  paragraphs = text.split("\n", -1)
  output = []
  paragraphs.each do |paragraph|
    if paragraph.strip.empty?
      output << ""
      next
    end

    words = paragraph.strip.split(/\s+/)
    line = first_prefix.dup
    limit = [width, first_prefix.length + 1].max
    words.each do |word|
      separator = line == first_prefix || line == continuation_prefix ? "" : " "
      if line.strip.empty?
        line << word
      elsif display_width(line) + separator.length + display_width(word) <= limit
        line << separator << word
      else
        output << line.rstrip
        line = continuation_prefix + word
        first_prefix = continuation_prefix
      end
    end
    output << line.rstrip unless line.strip.empty?
    first_prefix = continuation_prefix
  end
  output
end

def full_border(character = "=")
  "+" + (character * (WIDTH - 2)) + "+"
end

def title_box(title, character)
  clean = plain(title).upcase
  width = [WIDTH, display_width(clean) + 4].max
  border = "+" + (character * (width - 2)) + "+"
  ["", border, "|" + center_to(clean, width - 2) + "|", border, ""]
end

def banner(title)
  clean = plain(title).upcase
  prefix = "--- #{clean} "
  ["", prefix + ("-" * [WIDTH - prefix.length, 3].max), ""]
end

def framed_box(label, content, wrap: true, minimum_width: WIDTH)
  normalized = content.map { |line| wrap ? plain(line) : line.rstrip }
  normalized.shift while normalized.first&.empty?
  normalized.pop while normalized.last&.empty?
  normalized = [""] if normalized.empty?
  longest = normalized.map { |line| display_width(line) }.max || 0
  longest_word = normalized.flat_map { |line| line.split(/\s+/) }
                           .map { |word| display_width(word) }.max || 0
  width = wrap ? [minimum_width, longest_word + 4].max : [minimum_width, longest + 4].max
  inner = width - 4
  heading = "-- #{label.upcase} "
  top = "+" + heading + ("-" * [width - heading.length - 2, 1].max) + "+"
  bottom = "+" + ("-" * (width - 2)) + "+"
  body = []

  normalized.each do |line|
    pieces = wrap ? wrap_words(line, inner) : [line]
    pieces = [""] if pieces.empty?
    pieces.each { |piece| body << "| #{pad_to(piece, inner)} |" }
  end
  ["", top, *body, bottom, ""]
end

def code_label(language)
  normalized = language.strip
  return "CODE" if normalized.empty?
  return "CODE: LDPL" if %w[coffee coffeescript].include?(normalized.downcase)

  "CODE: #{normalized}"
end

def table_box(rows)
  cleaned = rows.map do |row|
    row.strip.sub(/^\|/, "").sub(/\|$/, "").split("|").map { |cell| plain(cell.strip) }
  end
  cleaned.reject! { |row| row.all? { |cell| cell.match?(/^:?-{3,}:?$/) } }
  return [] if cleaned.empty?

  columns = cleaned.map(&:length).max
  widths = Array.new(columns, 0)
  cleaned.each do |row|
    columns.times do |column|
      widths[column] = [widths[column], display_width(row[column] || "")].max
    end
  end
  separator = "+" + widths.map { |width| "-" * (width + 2) }.join("+") + "+"
  output = ["", separator]
  cleaned.each_with_index do |row, index|
    output << "|" + widths.each_index.map { |column| " #{pad_to(row[column] || '', widths[column])} " }.join("|") + "|"
    output << separator if index.zero? || index == cleaned.length - 1
  end
  output << ""
  output
end

def notice_content(lines)
  output = []
  paragraph = []
  flush = lambda do
    unless paragraph.empty?
      output << paragraph.join(" ").strip
      paragraph.clear
    end
  end

  lines.each do |line|
    if line.strip.empty?
      flush.call
      output << "" unless output.last == ""
    elsif (match = line.match(/^\s*:::([A-Za-z0-9_+.-]+)\s*$/))
      flush.call
      output << "CODE (#{match[1].upcase}):"
    elsif (match = line.match(/^\s*[-*]\s+(.+)$/))
      flush.call
      output << "* #{match[1]}"
    else
      paragraph << line.strip
    end
  end
  flush.call
  output.pop while output.last == ""
  output
end

source = File.readlines(INPUT, chomp: true)
result = []
paragraph = []
list_active = false

flush_paragraph = lambda do
  unless paragraph.empty?
    text = plain(paragraph.join(" ").strip)
    result.concat(wrap_words(text, WIDTH)) unless text.empty?
    result << ""
    paragraph.clear
  end
end

i = 0
while i < source.length
  line = source[i]
  list_line = line.match?(/^\s*[-*]\s+.+$/) || line.match?(/^\s*\d+\.\s+.+$/)
  if list_active && !list_line
    result << "" unless result.last == ""
    list_active = false
  end

  if line.start_with?("```")
    flush_paragraph.call
    language = line.delete_prefix("```").strip
    code = []
    i += 1
    while i < source.length && !source[i].start_with?("```")
      code << source[i]
      i += 1
    end
    result.concat(framed_box(code_label(language), code, wrap: false))
  elsif (match = line.match(/^\s+:::([A-Za-z0-9_+.-]+)\s*$/))
    flush_paragraph.call
    language = match[1]
    code = []
    i += 1
    while i < source.length && (source[i].strip.empty? || source[i].match?(/^(?: {4}|\t)/))
      code << source[i].sub(/^(?: {4}|\t)/, "")
      i += 1
    end
    i -= 1
    code.pop while code.last&.strip == ""
    result.concat(framed_box(code_label(language), code, wrap: false))
  elsif (match = line.match(/^!!!\s*([A-Za-z]+)?\s*(.*)$/))
    flush_paragraph.call
    kind = match[1].to_s.empty? ? "NOTICE" : match[1]
    label = [kind, plain(match[2])].reject(&:empty?).join(": ")
    notice = []
    i += 1
    while i < source.length && (source[i].strip.empty? || source[i].match?(/^(?: {4}|\t)/))
      notice << source[i].sub(/^(?: {4}|\t)/, "")
      i += 1
    end
    i -= 1
    notice.pop while notice.last&.strip == ""
    result.concat(framed_box(label, notice_content(notice)))
  elsif !line.strip.empty? && line.match?(/^ {4}|^\t/)
    flush_paragraph.call
    code = []
    while i < source.length && (source[i].strip.empty? || source[i].match?(/^(?: {4}|\t)/))
      code << source[i].sub(/^(?: {4}|\t)/, "")
      i += 1
    end
    i -= 1
    code.pop while code.last&.strip == ""
    result.concat(framed_box("CODE", code, wrap: false))
  elsif (match = line.match(/^([#]{1,6})\s+(.+)$/))
    flush_paragraph.call
    level = match[1].length
    result.concat(level == 1 ? title_box(match[2], "=") :
                  level == 2 ? title_box(match[2], "-") : banner(match[2]))
  elsif line.strip == "---"
    flush_paragraph.call
    result << ("=" * WIDTH) << ""
  elsif (match = line.match(/^!\[([^\]]*)\]\(([^)]+)\)\s*$/))
    flush_paragraph.call
    result.concat(framed_box("IMAGE: #{match[1]}", [match[2]]))
  elsif line.start_with?("|")
    flush_paragraph.call
    rows = []
    while i < source.length && source[i].start_with?("|")
      rows << source[i]
      i += 1
    end
    i -= 1
    result.concat(table_box(rows))
  elsif line.start_with?(">")
    flush_paragraph.call
    quote = []
    while i < source.length && source[i].start_with?(">")
      quote << source[i].sub(/^>\s?/, "")
      i += 1
    end
    i -= 1
    result.concat(framed_box("QUOTE", quote))
  elsif (match = line.match(/^\s*([-*])\s+(.+)$/))
    flush_paragraph.call
    result.concat(wrap_words(plain(match[2]), WIDTH, "  * ", "    "))
    list_active = true
  elsif (match = line.match(/^\s*(\d+)\.\s+(.+)$/))
    flush_paragraph.call
    prefix = "  #{match[1]}. "
    result.concat(wrap_words(plain(match[2]), WIDTH, prefix, " " * prefix.length))
    list_active = true
  elsif line.strip.empty?
    flush_paragraph.call
  else
    paragraph << line.strip
  end

  i += 1
end

flush_paragraph.call
text = result.join("\n").gsub(/\n{3,}/, "\n\n").sub(/\A\n+/, "").rstrip + "\n"
File.write(OUTPUT, text)
