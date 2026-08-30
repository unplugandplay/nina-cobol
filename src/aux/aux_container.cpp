/* This file contains auxiliary functions to split and access [multi]containers
 */

// +---------------------------------------------+
// | TODO: comment and format this file properly |
// +---------------------------------------------+

// Resolve a variable, including mixed structure-field and collection accesses.
// A colon is interpreted from the type on its left: it selects a named field
// on a structure and an index on a LIST or MAP.
bool resolve_variable_access(string &token, compiler_state &state,
                             vector<unsigned int> &type, string &c_expression,
                             string *diagnostic) {
  bool in_string = false;
  bool escaped = false;
  size_t segment_size = 0;
  for (char character : token) {
    if (escaped) {
      escaped = false;
      ++segment_size;
      continue;
    }
    if (character == '\\' && in_string) {
      escaped = true;
      ++segment_size;
      continue;
    }
    if (character == '"') in_string = !in_string;
    if (character == ':' && !in_string) {
      if (segment_size == 0) {
        if (diagnostic) *diagnostic = "Empty access component in \"" + token + "\"";
        return false;
      }
      segment_size = 0;
    } else {
      ++segment_size;
    }
  }
  if (segment_size == 0) {
    if (diagnostic) *diagnostic = "Incomplete access \"" + token + "\"";
    return false;
  }

  vector<string> parts;
  tokenize(token, parts, state.where, true, ':');
  if (parts.empty()) {
    if (diagnostic) *diagnostic = "Empty variable access";
    return false;
  }

  const string source_base = parts[0];
  string base = source_base;
  size_t part = 1;
  if (state.variables[state.current_subprocedure].count(base) > 0) {
    type = state.variables[state.current_subprocedure][base];
  } else if (state.imported_modules.count(source_base) > 0 && parts.size() > 1 &&
             state.variables[""].count(source_base + ":" + parts[1]) > 0) {
    base = source_base + ":" + parts[1];
    type = state.variables[""][base];
    part = 2;
  } else if (state.current_module != "" &&
             state.variables[""].count(state.current_module + ":" + base) > 0) {
    base = state.current_module + ":" + base;
    type = state.variables[""][base];
  } else if (state.variables[""].count(base) > 0) {
    type = state.variables[""][base];
  } else {
    if (diagnostic) *diagnostic = "The variable \"" + source_base + "\" doesn't exist";
    return false;
  }
  c_expression = fix_identifier(base, true, state);

  while (part < parts.size()) {
    if (type.empty()) {
      if (diagnostic) *diagnostic = "Cannot access \"" + token + "\" beyond its scalar value";
      return false;
    }

    const unsigned int outer_type = type.back();
    if (outer_type == 3 || outer_type == 4) {
      string index_expression;
      string index_c_expression;
      vector<unsigned int> index_type;
      bool found_index = false;

      if (is_number(parts[part]) || is_string(parts[part])) {
        index_expression = parts[part++];
        index_c_expression = index_expression;
        index_type = is_string(index_expression) ? vector<unsigned int>{2}
                                                 : vector<unsigned int>{1};
        found_index = true;
      } else {
        // An index may itself be a nested variable access (items:indexes:0).
        for (size_t end = part; end < parts.size(); ++end) {
          if (!index_expression.empty()) index_expression += ":";
          index_expression += parts[end];
          string nested_diagnostic;
          if (resolve_variable_access(index_expression, state, index_type,
                                      index_c_expression, &nested_diagnostic) &&
              (index_type == vector<unsigned int>{1} ||
               index_type == vector<unsigned int>{2})) {
            part = end + 1;
            found_index = true;
            break;
          }
        }
      }

      if (!found_index) {
        if (diagnostic) *diagnostic = "Invalid or incomplete index in \"" + token + "\"";
        return false;
      }
      if (outer_type == 3 && index_type != vector<unsigned int>{1}) {
        if (diagnostic) *diagnostic = "LIST index in \"" + token + "\" must be a NUMBER";
        return false;
      }
      c_expression += outer_type == 3
                          ? "[(ldpl_number)" + index_c_expression + "]"
                          : "[(graphemedText)" + index_c_expression + "]";
      type.pop_back();
      continue;
    }

    if (state.structure_names.count(outer_type) > 0) {
      const string &structure_name = state.structure_names[outer_type];
      string field = parts[part++];
      if (is_number(field) || is_string(field) ||
          state.structure_fields[structure_name].count(field) == 0) {
        if (diagnostic)
          *diagnostic = "Structure \"" + structure_name +
                        "\" has no field named \"" + field + "\"";
        return false;
      }
      type = state.structure_fields[structure_name][field];
      c_expression += "." + fix_identifier(field, true);
      continue;
    }

    if (diagnostic) *diagnostic = "Cannot index scalar value \"" + token + "\"";
    return false;
  }

  return true;
}
