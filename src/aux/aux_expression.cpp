/* Typed, composable expressions for LDPL. */

#include "../ldpl.h"

string join_tokens(const vector<string> &tokens, size_t begin, size_t end) {
  string result;
  for (size_t i = begin; i < end; ++i) {
    if (!result.empty()) result += " ";
    result += tokens[i];
  }
  return result;
}

vector<string> split_comma_arguments(const string &arguments,
                                     compiler_state &state) {
  vector<string> result;
  string current;
  bool in_string = false;
  bool escaped = false;
  int depth = 0;
  for (size_t i = 0; i < arguments.size(); ++i) {
    char c = arguments[i];
    if (escaped) {
      current += c;
      escaped = false;
      continue;
    }
    if (c == '\\' && in_string) {
      current += c;
      escaped = true;
      continue;
    }
    if (c == '"') in_string = !in_string;
    if (!in_string && c == '(') ++depth;
    if (!in_string && c == ')') {
      if (depth == 0) badcode("Unmatched ')' in argument list", state.where);
      --depth;
    }
    if (!in_string && depth == 0 && c == ',') {
      trim(current);
      if (current.empty()) badcode("Empty argument between commas", state.where);
      result.push_back(current);
      current.clear();
    } else {
      current += c;
    }
  }
  if (in_string || depth != 0)
    badcode("Unterminated string or parentheses in argument list", state.where);
  trim(current);
  if (current.empty()) {
    if (!result.empty()) badcode("Trailing comma in argument list", state.where);
  } else {
    result.push_back(current);
  }
  return result;
}

namespace {

enum expression_token_kind {
  EX_END,
  EX_VALUE,
  EX_LPAREN,
  EX_RPAREN,
  EX_COMMA,
  EX_OPERATOR
};

struct expression_token {
  expression_token_kind kind;
  string text;
};

class expression_parser {
 public:
  expression_parser(const string &source, compiler_state &compiler)
      : input(source), state(compiler) {
    lex();
  }

  composable_expression parse() {
    composable_expression value = parse_or();
    if (peek().kind != EX_END) {
      if (peek().kind == EX_VALUE)
        fail("Procedure arguments and expression values must be separated by commas or operators");
      fail("Unexpected '" + peek().text + "' in expression");
    }
    return value;
  }

 private:
  string input;
  compiler_state &state;
  vector<expression_token> tokens;
  size_t at = 0;

  void fail(const string &message) { badcode(message, state.where); }

  expression_token &peek(size_t offset = 0) {
    size_t position = at + offset;
    return tokens[position < tokens.size() ? position : tokens.size() - 1];
  }

  bool take(const string &text) {
    if (peek().text == text) {
      ++at;
      return true;
    }
    return false;
  }

  static bool is_operator_character(char c) {
    return c == '+' || c == '*' || c == '/' || c == '%' ||
           c == '=' || c == '<' || c == '>';
  }

  bool operator_at(size_t position) const {
    char c = input[position];
    if (is_operator_character(c)) return true;
    if (c != '-') return false;
    bool separated_left = position == 0 ||
                          isspace(static_cast<unsigned char>(input[position - 1])) ||
                          input[position - 1] == '(' || input[position - 1] == ',';
    bool separated_right = position + 1 == input.size() ||
                           isspace(static_cast<unsigned char>(input[position + 1])) ||
                           input[position + 1] == '(';
    return separated_left || separated_right;
  }

  void lex() {
    size_t i = 0;
    while (i < input.size()) {
      if (isspace(static_cast<unsigned char>(input[i]))) {
        ++i;
        continue;
      }
      char c = input[i];
      if (c == '(' || c == ')' || c == ',') {
        tokens.push_back({c == '(' ? EX_LPAREN : c == ')' ? EX_RPAREN : EX_COMMA,
                          string(1, c)});
        ++i;
        continue;
      }
      if (c == '"') {
        string value;
        bool escaped = false;
        do {
          char part = input[i++];
          value += part;
          if (escaped) escaped = false;
          else if (part == '\\') escaped = true;
          else if (part == '"' && value.size() > 1) break;
        } while (i < input.size());
        if (value.size() < 2 || value[value.size() - 1] != '"')
          fail("Unterminated string in expression");
        tokens.push_back({EX_VALUE, value});
        continue;
      }
      if (operator_at(i)) {
        string op(1, c);
        if (i + 1 < input.size() &&
            ((c == '<' && (input[i + 1] == '=' || input[i + 1] == '>')) ||
             (c == '>' && input[i + 1] == '=')))
          op += input[++i];
        tokens.push_back({EX_OPERATOR, op});
        ++i;
        continue;
      }
      string value;
      bool embedded_string = false;
      bool embedded_escape = false;
      while (i < input.size()) {
        char part = input[i];
        if (!embedded_string &&
            (isspace(static_cast<unsigned char>(part)) || part == '(' ||
             part == ')' || part == ',' || operator_at(i)))
          break;
        value += part;
        ++i;
        if (embedded_escape) embedded_escape = false;
        else if (part == '\\' && embedded_string) embedded_escape = true;
        else if (part == '"') embedded_string = !embedded_string;
      }
      if (embedded_string) fail("Unterminated string in variable access");
      if (value.empty()) fail("Invalid character in expression");
      if (value == "AND" || value == "OR" || value == "NOT" ||
          value == "MODULO")
        tokens.push_back({EX_OPERATOR, value});
      else
        tokens.push_back({EX_VALUE, value});
    }
    tokens.push_back({EX_END, ""});
  }

  static bool scalar(const composable_expression &value) {
    return value.type == vector<unsigned int>{1} ||
           value.type == vector<unsigned int>{2};
  }

  void require_value(const composable_expression &value, const string &where) {
    if (value.boolean_value) fail(where + " requires a value, not a condition");
    if (value.type.empty()) fail("Invalid value in " + where);
  }

  composable_expression parse_or() {
    composable_expression left = parse_and();
    while (take("OR")) {
      composable_expression right = parse_and();
      if (!left.boolean_value || !right.boolean_value)
        fail("OR requires conditions on both sides");
      left = {"(" + left.code + " || " + right.code + ")", {}, true, false};
    }
    return left;
  }

  composable_expression parse_and() {
    composable_expression left = parse_comparison();
    while (take("AND")) {
      composable_expression right = parse_comparison();
      if (!left.boolean_value || !right.boolean_value)
        fail("AND requires conditions on both sides");
      left = {"(" + left.code + " && " + right.code + ")", {}, true, false};
    }
    return left;
  }

  composable_expression parse_comparison() {
    composable_expression left = parse_addition();
    string op = peek().text;
    if (op != "=" && op != "<>" && op != "<" && op != ">" &&
        op != "<=" && op != ">=")
      return left;
    ++at;
    composable_expression right = parse_addition();
    require_value(left, "comparison");
    require_value(right, "comparison");
    if (left.type != right.type)
      fail("Both sides of a comparison must have the same type");
    if (op != "=" && op != "<>" && !scalar(left))
      fail("Ordered comparisons support only NUMBER and TEXT values");
    string code;
    if (left.type == vector<unsigned int>{1} && (op == "=" || op == "<>")) {
      code = "num_equal(" + left.code + ", " + right.code + ")";
      if (op == "<>") code = "!(" + code + ")";
    } else if (left.type == vector<unsigned int>{2} && op == "<=") {
      code = "!(" + left.code + " > " + right.code + ")";
    } else if (left.type == vector<unsigned int>{2} && op == ">=") {
      code = "!(" + left.code + " < " + right.code + ")";
    } else {
      code = left.code + " " + (op == "=" ? "==" : op == "<>" ? "!=" : op) +
             " " + right.code;
    }
    return {"(" + code + ")", {}, true, false};
  }

  composable_expression parse_addition() {
    composable_expression left = parse_multiplication();
    while (peek().text == "+" || peek().text == "-") {
      string op = tokens[at++].text;
      composable_expression right = parse_multiplication();
      require_value(left, "arithmetic");
      require_value(right, "arithmetic");
      if (left.type != right.type)
        fail("Both sides of '" + op + "' must have the same type");
      if (op == "+" && left.type == vector<unsigned int>{2}) {
        left = {"(" + left.code + " + " + right.code + ")", {2}, false, false};
      } else {
        if (left.type != vector<unsigned int>{1})
          fail("Operator '" + op + "' requires NUMBER values");
        left = {"(" + left.code + " " + op + " " + right.code + ")", {1},
                false, false};
      }
    }
    return left;
  }

  composable_expression parse_multiplication() {
    composable_expression left = parse_unary();
    while (peek().text == "*" || peek().text == "/" || peek().text == "%" ||
           peek().text == "MODULO") {
      string op = tokens[at++].text;
      composable_expression right = parse_unary();
      if (left.type != vector<unsigned int>{1} ||
          right.type != vector<unsigned int>{1})
        fail("Operator '" + op + "' requires NUMBER values");
      string code = (op == "%" || op == "MODULO")
                        ? "modulo(" + left.code + ", " + right.code + ")"
                        : "(" + left.code + " " + op + " " + right.code + ")";
      left = {code, {1}, false, false};
    }
    return left;
  }

  composable_expression parse_unary() {
    if (take("NOT")) {
      composable_expression value = parse_unary();
      if (!value.boolean_value) fail("NOT requires a condition");
      return {"!(" + value.code + ")", {}, true, false};
    }
    if (take("-")) {
      composable_expression value = parse_unary();
      if (value.type != vector<unsigned int>{1})
        fail("Unary '-' requires a NUMBER value");
      return {"-(" + value.code + ")", {1}, false, false};
    }
    return parse_primary();
  }

  composable_expression parse_primary() {
    if (take("(")) {
      composable_expression value = parse_or();
      if (!take(")")) fail("Expected ')' in expression");
      value.code = "(" + value.code + ")";
      value.assignable = false;
      return parse_postfix(value);
    }
    if (peek().kind != EX_VALUE) fail("Expected a value in expression");
    string value = tokens[at++].text;
    if (peek().kind == EX_LPAREN) return parse_postfix(parse_call(value));
    string checked = value;
    if (is_number(checked))
      return {"(ldpl_number)(" + checked + ")", {1}, false, false};
    if (is_string(value))
      return {"(graphemedText)" + value, {2}, false, false};
    if (!variable_exists(value, state))
      fail("The value or returning procedure \"" + value + "\" doesn't exist");
    return {get_c_variable(state, value), variable_type(value, state), false,
            !is_constant(value, state)};
  }

  composable_expression parse_postfix(composable_expression value) {
    while (peek().kind == EX_VALUE && !peek().text.empty() &&
           peek().text[0] == ':') {
      string access = tokens[at++].text.substr(1);
      if (access.empty()) fail("Empty access after returning procedure call");
      vector<string> parts;
      tokenize(access, parts, state.where, true, ':');
      for (const string &part : parts) {
        if (value.type.empty()) fail("Cannot access a condition");
        unsigned int outer = value.type.back();
        if (state.structure_names.count(outer) > 0) {
          const string &structure = state.structure_names[outer];
          if (state.structure_fields[structure].count(part) == 0)
            fail("Structure \"" + structure + "\" has no field named \"" +
                 part + "\"");
          value.type = state.structure_fields[structure][part];
          value.code += "." + fix_identifier(part, true);
        } else if (outer == 3 || outer == 4) {
          composable_expression index = compile_expression(part, state);
          if (index.boolean_value ||
              (outer == 3 && index.type != vector<unsigned int>{1}) ||
              (outer == 4 && index.type != vector<unsigned int>{1} &&
               index.type != vector<unsigned int>{2}))
            fail(outer == 3 ? "LIST index must be NUMBER"
                            : "MAP index must be NUMBER or TEXT");
          value.code += outer == 3
                            ? "[(ldpl_number)" + index.code + "]"
                            : "[(graphemedText)" + index.code + "]";
          value.type.pop_back();
        } else {
          fail("Cannot access a scalar expression value");
        }
      }
      value.assignable = false;
    }
    return value;
  }

  composable_expression parse_call(const string &source_name) {
    take("(");
    vector<composable_expression> arguments;
    if (!take(")")) {
      while (true) {
        arguments.push_back(parse_or());
        if (take(")")) break;
        if (!take(",")) {
          if (peek().kind == EX_VALUE || peek().kind == EX_LPAREN)
            fail("Procedure arguments must be separated by commas");
          fail("Expected ',' or ')' after procedure argument");
        }
        if (peek().kind == EX_RPAREN)
          fail("Trailing commas are not allowed in procedure calls");
      }
    }
    string name = resolved_subprocedure_name(source_name, state);
    if (state.subprocedure_returns.count(name) == 0)
      fail("Returning procedure \"" + name + "\" has not been declared");
    vector<unsigned int> return_type = state.subprocedure_returns[name];
    if (return_type == vector<unsigned int>{0})
      fail("SUB-PROCEDURE \"" + name + "\" does not return a value");

    vector<vector<unsigned int>> expected;
    if (state.predeclared_subprocedure_parameters.count(name) > 0)
      expected = state.predeclared_subprocedure_parameters[name];
    else if (state.subprocedures.count(name) > 0)
      for (const string &parameter : state.subprocedures[name])
        expected.push_back(state.variables[name][parameter]);
    if (arguments.size() != expected.size())
      fail("Returning procedure \"" + name + "\" expects " +
           to_string(expected.size()) + " argument(s), but received " +
           to_string(arguments.size()));

    string code = fix_identifier(name, false) + "(";
    for (size_t i = 0; i < arguments.size(); ++i) {
      if (arguments[i].boolean_value || arguments[i].type != expected[i])
        fail("Argument " + to_string(i + 1) + " of returning procedure \"" +
             name + "\" has the wrong type");
      if (state.subprocedure_parameter_references.count(name) > 0 &&
          i < state.subprocedure_parameter_references[name].size() &&
          state.subprocedure_parameter_references[name][i] &&
          !arguments[i].assignable)
        fail("Reference argument " + to_string(i + 1) +
             " of returning procedure \"" + name +
             "\" must be a mutable variable");
      if (i > 0) code += ", ";
      code += arguments[i].code;
    }
    code += ")";
    return {code, return_type, false, false};
  }
};

}  // namespace

composable_expression compile_expression(const string &expression,
                                         compiler_state &state) {
  string cleaned = expression;
  trim(cleaned);
  if (cleaned.empty()) badcode("Expected an expression", state.where);
  expression_parser parser(cleaned, state);
  return parser.parse();
}
