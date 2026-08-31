/* This file contains auxiliary functions that check the current compilation
 * state */

#include "../ldpl.h"

bool is_num_map(string &token, compiler_state &state)
{
  // -- Returns if the variable is a NUMBER MAP or an access to a multicontainer
  // that results in a NUMBER MAP --
  vector<unsigned int> type = variable_type(token, state);
  if (type.size() == 2 && type[0] == 1 && type[1] == 4)
    return true;
  return false;
}

bool is_txt_map(string &token, compiler_state &state)
{
  // -- Returns if the variable is a TEXT MAP or an access to a multicontainer
  // that results in a TEXT MAP --
  vector<unsigned int> type = variable_type(token, state);
  if (type.size() == 2 && type[0] == 2 && type[1] == 4)
    return true;
  return false;
}

bool is_num_list(string &token, compiler_state &state)
{
  // -- Returns if the variable is a NUMBER LIST or an access to a
  // multicontainer that results in a NUMBER LIST --
  vector<unsigned int> type = variable_type(token, state);
  if (type.size() == 2 && type[0] == 1 && type[1] == 3)
    return true;
  return false;
}

bool is_txt_list(string &token, compiler_state &state)
{
  // -- Returns if the variable is a TEXT MAP or an access to a multicontainer
  // that results in a TEXT MAP --
  vector<unsigned int> type = variable_type(token, state);
  if (type.size() == 2 && type[0] == 2 && type[1] == 3)
    return true;
  return false;
}

bool is_list_list(string &token, compiler_state &state)
{
  // -- Returns if the variable is a NUMBER/TEXT LIST LIST multicontainer or a
  // multicontainer access that results in a LIST of LISTs --
  vector<unsigned int> type = variable_type(token, state);
  if (type.size() >= 2 && type[type.size() - 2] == 3 && type.back() == 3)
    return true;
  return false;
}

bool is_map_list(string &token, compiler_state &state)
{
  // -- Returns if the variable is a multicontainer NUMBER/TEXT LIST MAP or a
  // multicontainer access that results in a LIST of MAPs --
  vector<unsigned int> type = variable_type(token, state);
  if (type.size() >= 2 && type[type.size() - 2] == 4 && type.back() == 3)
    return true;
  return false;
}

bool is_scalar_map(string &token, compiler_state &state)
{
  // -- Returns if the variable is a NUMBER MAP or an access to a multicontainer
  // that results in a NUMBER MAP --
  // -- or if the variable is a TEXT MAP or an access to a multicontainer that
  // results in a TEXT MAP          --
  return is_num_map(token, state) || is_txt_map(token, state);
}

bool is_map_map(string &token, compiler_state &state)
{
  // -- Returns if the variable is a NUMBER/TEXT MAP MAP multicontainer or a
  // multicontainer access that results in a MAP of MAPs --
  vector<unsigned int> type = variable_type(token, state);
  if (type.size() >= 2 && type[type.size() - 2] == 4 && type.back() == 4)
    return true;
  return false;
}

bool is_map(string &token, compiler_state &state)
{
  // -- Returns true if the variable is a MAP, regardless of a map of what
  // (multicontainer or not) --
  vector<unsigned int> type = variable_type(token, state);
  return type.back() == 4;
}

bool is_scalar_list(string &token, compiler_state &state)
{
  // -- Returns if the variable is a NUMBER LIST or an access to a
  // multicontainer that results in a NUMBER LIST --
  // -- or if the variable is a TEXT LIST or an access to a multicontainer that
  // results in a TEXT LIST          --
  return is_num_list(token, state) || is_txt_list(token, state);
}

bool is_num_var(string &token, compiler_state &state)
{
  // -- Checks if token is a NUMBER variable (or an access to a container that
  // results in a NUMBER variable) --
  return !is_constant(token, state) &&
         (variable_type(token, state) == vector<unsigned int>{1});
}

bool is_txt_var(string &token, compiler_state &state)
{
  // -- Checks if token is a TEXT variable (or an access to a container that
  // results in a TEXT variable) --
  return !is_constant(token, state) &&
         (variable_type(token, state) == vector<unsigned int>{2});
}

bool is_scalar_variable(string &token, compiler_state &state)
{
  // -- Returns is an identifier is a valid scalar variable or an access that
  // results in one --
  return is_num_var(token, state) || is_txt_var(token, state);
}

bool is_num_expr(string &token, compiler_state &state)
{
  // -- Returns is an identifier is a valid scalar variable or number or an
  // access that results in one --
  return is_num_var(token, state) ||
         (is_constant(token, state) &&
          variable_type(token, state) == vector<unsigned int>{1}) ||
         is_number(token);
}

bool is_txt_expr(string &token, compiler_state &state)
{
  // -- Returns is an identifier is a valid scalar variable or text or an access
  // that results in one --
  return is_txt_var(token, state) ||
         (is_constant(token, state) &&
          variable_type(token, state) == vector<unsigned int>{2}) ||
         is_string(token);
}

bool is_expression(string &token, compiler_state &state)
{
  // -- Returns is an identifier is a valid scalar variable or text or number or
  // an access that results in one --
  return is_num_expr(token, state) || is_txt_expr(token, state);
}

bool is_structure_type(const vector<unsigned int> &type,
                       compiler_state &state)
{
  return type.size() == 1 && state.structure_names.count(type[0]) > 0;
}

bool is_structure(string &token, compiler_state &state)
{
  return is_structure_type(variable_type(token, state), state);
}

bool is_external(string &token, compiler_state &state)
{
  // -- Returns if an identifier maps to an external variable --
  return state.externals[token];
}

string qualified_global_name(string name, compiler_state &state)
{
  if (state.current_module != "" && name.find(':') == string::npos)
    return state.current_module + ":" + name;
  return name;
}

bool is_constant(string &token, compiler_state &state)
{
  if (state.constants.count(token) > 0) return true;
  string qualified = qualified_global_name(token, state);
  return state.constants.count(qualified) > 0;
}

string resolved_subprocedure_name(string name, compiler_state &state)
{
  if (name.find(':') != string::npos || state.current_module == "") return name;
  return state.current_module + ":" + name;
}

bool variable_exists(string &token, compiler_state &state)
{
  // -- Returns if a variable has been declared or not --
  // (Bear in mind that myList is a variable, myList:0 is not, that's an access
  // for all this function is concerned)
  return variable_type(token, state) != vector<unsigned int>{0};
}

bool is_subprocedure(string &token, compiler_state &state)
{
  // -- Returns if an identifier maps to a valid, existing sub-procedure --
  string resolved = resolved_subprocedure_name(token, state);
  if (state.predeclared_subprocedure_parameters.count(resolved) > 0)
    return true;
  for (auto &subprocedure : state.subprocedures)
    if (subprocedure.first == resolved)
      return true;
  return false;
}

bool in_procedure_section(compiler_state &state)
{
  // -- Returns if the compiler is currently compiling a procedure section or
  // not --
  if (state.section_state == 3)
  {
    // We're inside a SUB-PROCEDURE procedure with no sections
    state.section_state = 2;
    open_subprocedure_code(state);
  }
  return state.section_state == 2;
}

vector<unsigned int> variable_type(string &token, compiler_state &state)
{
  vector<unsigned int> types;
  string c_expression;
  if (!resolve_variable_access(token, state, types, c_expression)) return {0};
  return types;
}
