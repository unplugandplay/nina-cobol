/* This file contains auxiliary functions that add C++ code to the generated C++
 * file */

// +---------------------------------------------+
// | TODO: comment and format this file properly |
// +---------------------------------------------+

// This is called when we know all parameters of a subprocedure
void open_subprocedure_code(compiler_state &state) {
  string name = state.current_subprocedure;
  vector<string> &parameters = state.subprocedures[name];
  vector<vector<unsigned int>> types;
  string code;
  vector<unsigned int> return_type = state.subprocedure_returns.count(name) > 0
                                         ? state.subprocedure_returns[name]
                                         : vector<unsigned int>{0};
  code = (return_type == vector<unsigned int>{0}
              ? "void"
              : state.get_c_type(return_type)) +
         " " + fix_identifier(name, false) + "(";
  for (size_t i = 0; i < parameters.size(); ++i) {
    string identifier = fix_identifier(parameters[i], true, state);
    string type = state.get_c_type(state.variables[name][parameters[i]]);
    bool reference = return_type == vector<unsigned int>{0} ||
                     (state.subprocedure_parameter_references.count(name) > 0 &&
                      i < state.subprocedure_parameter_references[name].size() &&
                      state.subprocedure_parameter_references[name][i]);
    code += type + (reference ? " & " : " ") + identifier;
    if (i < parameters.size() - 1) code += ", ";
    types.push_back(state.variables[name][parameters[i]]);
  }
  if (state.predeclared_subprocedure_parameters.count(name) > 0 &&
      state.predeclared_subprocedure_parameters[name] != types)
    badcode("SUB-PROCEDURE parameter types don't match its predeclared signature",
            state.where);
  if (!state.correct_subprocedure_types(name, types))
    badcode(
        "SUB-PROCEDURE declaration parameter types doesn't match previous CALL",
        state.where);
  code += "){";
  state.add_code(code, state.where);
  state.remove_expected_subprocedure(name);
}

void add_call_code(string &subprocedure, vector<string> &parameters,
                   compiler_state &state) {
  string code = fix_identifier(subprocedure, false) + "(";
  for (size_t i = 0; i < parameters.size(); ++i) {
    bool number_literal = is_number(parameters[i]);
    bool text_literal = is_string(parameters[i]);
    bool constant = is_constant(parameters[i], state);
    if (number_literal || text_literal || constant) {
      // C++ doen't allow passing literals in  reference parameters, we create
      // vars for them
      string literal_paramater_var = state.new_literal_parameter_var();
      bool number_value = number_literal ||
                          (constant && variable_type(parameters[i], state) ==
                                           vector<unsigned int>{1});
      string value = constant ? get_c_variable(state, parameters[i]) : parameters[i];
      state.add_code((number_value ? "ldpl_number " : "graphemedText ") +
                         literal_paramater_var + " = " + value + ";",
                     state.where);
      code += literal_paramater_var;
    } else {
      code += get_c_variable(state, parameters[i]);
    }
    if (i < parameters.size() - 1) code += ", ";
  }
  code += ");";
  state.add_code(code, state.where);
}

size_t thread_counter = 0;

void add_thread_call_code(string &subprocedure, compiler_state &state) {
  string thread_name = "thread_" + to_string(thread_counter);
  string code = "std::thread " + thread_name + "(" + fix_identifier(subprocedure, false) + ");";
  code += thread_name + ".detach();";
  state.add_code(code, state.where);
  ++thread_counter;
}
