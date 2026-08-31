/* This file contains the behemoth compile_line function that pattern-matches
 * lines and compiles them */

// +---------------------------------------------+
// | TODO: comment and format this file properly |
// +---------------------------------------------+

#include "../ldpl.h"

static bool ldpl_container_type(const string &token, unsigned int &type)
{
    if (token == "LIST" || token == "LISTS")
    {
        type = 3;
        return true;
    }
    if (token == "MAP" || token == "MAPS" || token == "VECTOR" || token == "VECTORS")
    {
        type = 4;
        return true;
    }
    return false;
}

static bool ldpl_leaf_type(const string &token, compiler_state &state,
                           unsigned int &type)
{
    if (token == "NUMBER" || token == "NUMBERS") type = 1;
    else if (token == "TEXT" || token == "TEXTS") type = 2;
    else if (state.structure_types.count(token) > 0) type = state.structure_types[token];
    else if (state.current_module != "" &&
             state.structure_types.count(state.current_module + ":" + token) > 0)
        type = state.structure_types[state.current_module + ":" + token];
    else return false;
    return true;
}

// Parse both the recommended "LIST OF MAP OF T" syntax and the legacy
// "T MAP LIST" syntax into LDPL's inner-to-outer type vector.
static bool parse_declared_type(const vector<string> &tokens, size_t begin,
                                size_t end, compiler_state &state,
                                vector<unsigned int> &type)
{
    if (begin >= end) return false;
    type.clear();
    vector<unsigned int> containers;
    unsigned int value_type = 0;
    unsigned int container_type = 0;

    if (begin + 1 < end && ldpl_container_type(tokens[begin], container_type) &&
        tokens[begin + 1] == "OF")
    {
        size_t i = begin;
        while (i + 1 < end && ldpl_container_type(tokens[i], container_type) &&
               tokens[i + 1] == "OF")
        {
            containers.push_back(container_type);
            i += 2;
        }
        if (i + 1 != end || !ldpl_leaf_type(tokens[i], state, value_type)) return false;
        type.push_back(value_type);
        for (vector<unsigned int>::reverse_iterator it = containers.rbegin();
             it != containers.rend(); ++it)
            type.push_back(*it);
        return true;
    }

    if (!ldpl_leaf_type(tokens[begin], state, value_type)) return false;
    type.push_back(value_type);
    for (size_t i = begin + 1; i < end; ++i)
    {
        if (!ldpl_container_type(tokens[i], container_type)) return false;
        type.push_back(container_type);
    }
    return true;
}

static string structure_default_value(const vector<unsigned int> &type)
{
    if (type == vector<unsigned int>{1}) return " = 0";
    if (type == vector<unsigned int>{2}) return " = \"\"";
    return "";
}

static string compile_condition_tokens(const vector<string> &tokens, size_t begin,
                                       size_t end, compiler_state &state)
{
    bool legacy_words = false;
    for (size_t i = begin; i < end; ++i)
        if (tokens[i] == "IS" || tokens[i] == "IN" || tokens[i] == "EQUAL" ||
            tokens[i] == "GREATER" || tokens[i] == "LESS")
            legacy_words = true;
    if (legacy_words)
    {
        string condition = get_c_condition(
            state, vector<string>(tokens.begin() + begin, tokens.begin() + end));
        if (condition == "[ERROR]") badcode("Invalid condition", state.where);
        return condition;
    }
    composable_expression condition =
        compile_expression(join_tokens(tokens, begin, end), state);
    if (!condition.boolean_value)
        badcode("IF and WHILE expressions must produce a condition", state.where);
    return condition.code;
}

static bool has_expression_punctuation(const string &source)
{
    bool in_string = false;
    bool escaped = false;
    for (char character : source)
    {
        if (escaped)
        {
            escaped = false;
            continue;
        }
        if (character == '\\' && in_string)
        {
            escaped = true;
            continue;
        }
        if (character == '"')
        {
            in_string = !in_string;
            continue;
        }
        if (!in_string &&
            (character == '(' || character == ')' || character == ','))
            return true;
    }
    return false;
}

// Compiles line per line
void compile_line(vector<string> &tokens, compiler_state &state)
{
    // Import a source file into an explicit namespace.
    if (line_like("IMPORT $name FROM $string", tokens, state) ||
        line_like("IMPORT $string AS $name", tokens, state))
    {
        if (state.section_state != 0 || state.current_structure != "")
            badcode("you can only use IMPORT before DATA and PROCEDURE sections",
                    state.where);
        const bool name_first = tokens[1][0] != '"';
        const string module = name_first ? tokens[1] : tokens[3];
        string file_to_compile = name_first ? tokens[3] : tokens[1];
        file_to_compile = file_to_compile.substr(1, file_to_compile.size() - 2);
        if (state.imported_modules.count(module) > 0)
            badcode("Duplicate import for module \"" + module + "\"", state.where);

        string separators = "/";
#if defined(_WIN32)
        separators += "\\";
#endif
        size_t last_sep = state.where.current_file.find_last_of(separators);
        code_location old_location = state.where;
        if (last_sep != string::npos)
            file_to_compile = state.where.current_file.substr(0, last_sep) + "/" +
                              file_to_compile;
        const string old_module = state.current_module;
        state.imported_modules[module] = true;
        state.current_module = module;
        load_and_compile(file_to_compile, state);
        state.current_module = old_module;
        state.section_state = 0;
        state.where = old_location;
        return;
    }

    // include
    if (line_like("INCLUDE $string", tokens, state))
    {
        if (state.section_state != 0 || state.current_structure != "")
            badcode(
                "you can only use the INCLUDE statement before the DATA and "
                "PROCEDURE sections",
                state.where);
        else
        {
            string file_to_compile = tokens[1].substr(1, tokens[1].size() - 2);
            string separators = "/";
#if defined(_WIN32)
            separators += "\\";
#endif
            size_t last_sep = state.where.current_file.find_last_of(separators);
            code_location old_location = state.where;
            if (last_sep != string::npos)
                file_to_compile = state.where.current_file.substr(0, last_sep) + "/" +
                                  file_to_compile;
            load_and_compile(file_to_compile, state);
            state.section_state = 0;
            state.where = old_location;
        }
        return;
    }

    // extension (INCLUDE but for c++ extensions)
    if (line_like("EXTENSION $string", tokens, state))
    {
        if (state.section_state != 0 || state.current_structure != "")
            badcode(
                "you can only use the EXTENSION statement before the DATA and "
                "PROCEDURE sections",
                state.where);
        else
        {
            string file_to_add = tokens[1].substr(1, tokens[1].size() - 2);
            string separators = "/";
#if defined(_WIN32)
            separators += "\\";
#endif
            size_t last_sep = state.where.current_file.find_last_of(separators);
            if (last_sep != string::npos)
                file_to_add =
                    state.where.current_file.substr(0, last_sep) + "/" + file_to_add;
            extensions.push_back(file_to_add);
        }
        return;
    }

    // extension flags (for the C++ compiler)
    if (line_like("FLAG $string", tokens, state))
    {
        if (state.section_state != 0 || state.current_structure != "")
            badcode(
                "you can only use the FLAG statement before the DATA and PROCEDURE "
                "sections",
                state.where);
        else
        {
            string flag = tokens[1].substr(1, tokens[1].size() - 2);
            extension_flags.push_back(flag);
        }
        return;
    }
    // os-specific extension flags
    if (line_like("FLAG $name $string", tokens, state))
    {
        if (state.section_state != 0 || state.current_structure != "")
            badcode(
                "you can only use the FLAG statement before the DATA and PROCEDURE "
                "sections",
                state.where);
        else
        {
            if (tokens[1] == current_os())
            {
                string flag = tokens[2].substr(1, tokens[2].size() - 2);
                extension_flags.push_back(flag);
            }
        }
        return;
    }

    // Structure declarations live before DATA and PROCEDURE sections.
    if (line_like("STRUCTURE $name", tokens, state) ||
        line_like("STRUCT $name", tokens, state))
    {
        if (state.section_state != 0)
            badcode("STRUCTURE declaration after DATA or PROCEDURE section", state.where);
        if (state.current_structure != "")
            badcode("Nested STRUCTURE declarations are not supported", state.where);
        const string source_name = tokens[1];
        const string name = qualified_global_name(source_name, state);
        if (source_name == "NUMBER" || source_name == "NUMBERS" ||
            source_name == "TEXT" || source_name == "TEXTS" ||
            source_name == "LIST" || source_name == "LISTS" ||
            source_name == "MAP" || source_name == "MAPS" ||
            source_name == "VECTOR" || source_name == "VECTORS")
            badcode("Reserved data type name cannot be used for STRUCTURE \"" +
                    name + "\"", state.where);
        if (state.structure_types.count(name) > 0)
            badcode("Duplicate declaration for STRUCTURE \"" + name + "\"", state.where);
        unsigned int type = state.next_structure_type++;
        const string c_type = "ldpl_structure_" + fix_identifier(name);
        for (const pair<const unsigned int, string> &declared : state.structure_c_types)
            if (declared.second == c_type)
                badcode("STRUCTURE \"" + name +
                        "\" has the same generated C++ name as another structure",
                        state.where);
        state.current_structure = name;
        state.structure_types[name] = type;
        state.structure_names[type] = name;
        state.structure_c_types[type] = c_type;
        state.structure_fields[name] = map<string, vector<unsigned int>>();
        state.structure_field_order[name] = vector<string>();
        return;
    }
    if (line_like("END STRUCTURE", tokens, state) ||
        line_like("END STRUCT", tokens, state))
    {
        if (state.current_structure == "")
            badcode("END STRUCTURE without STRUCTURE", state.where);
        const string name = state.current_structure;
        const unsigned int structure_type = state.structure_types[name];
        string code = "struct " + state.structure_c_types[structure_type] + "{";
        for (const string &field : state.structure_field_order[name])
        {
            vector<unsigned int> field_type = state.structure_fields[name][field];
            code += state.get_c_type(field_type) + " " + fix_identifier(field, true) +
                    structure_default_value(field_type) + ";";
        }
        code += "bool operator==(const " + state.structure_c_types[structure_type] +
                "& other) const {return ";
        if (state.structure_field_order[name].empty()) code += "true";
        for (size_t i = 0; i < state.structure_field_order[name].size(); ++i)
        {
            const string field_name = state.structure_field_order[name][i];
            const string field = fix_identifier(field_name, true);
            const vector<unsigned int> field_type = state.structure_fields[name][field_name];
            if (i > 0) code += " && ";
            if (field_type == vector<unsigned int>{1})
                code += "num_equal(" + field + ", other." + field + ")";
            else
                code += field + " == other." + field;
        }
        code += ";}bool operator!=(const " + state.structure_c_types[structure_type] +
                "& other) const {return !(*this == other);}};";
        state.add_var_code(code);
        state.current_structure = "";
        return;
    }

    // Sections
    if (line_like("DATA:", tokens, state) || line_like("-- DATA --", tokens, state))
    {
        if (state.current_structure != "")
            badcode("DATA section inside STRUCTURE declaration", state.where);
        if (state.section_state == 1)
            badcode("Duplicate DATA section declaration", state.where);
        if (state.section_state >= 2)
            badcode("DATA section declaration within PROCEDURE section", state.where);
        state.section_state = 1;
        return;
    }
    if (line_like("PROCEDURE", tokens, state) || line_like("-- PROCEDURE --", tokens, state))
    {
        if (state.current_structure != "")
            badcode("PROCEDURE section inside STRUCTURE declaration", state.where);
        if (state.section_state == 2)
            badcode("Duplicate PROCEDURE section declaration", state.where);
        if (state.current_subprocedure != "" && state.section_state >= 3)
            open_subprocedure_code(state);
        state.section_state = 2;
        return;
    }
    if (line_like("PARAMETERS:", tokens, state) || line_like("-- PARAMETERS --", tokens, state))
    {
        if (state.current_subprocedure == "")
            badcode("PARAMETERS section outside subprocedure", state.where);
        if (state.section_state == 4)
            badcode("Duplicate PARAMETERS section declaration", state.where);
        if (state.section_state == 1)
            badcode("PARAMETERS section declaration within LOCAL DATA section",
                    state.where);
        if (state.section_state == 2)
            badcode("PARAMETERS section declaration within PROCEDURE section",
                    state.where);
        state.section_state = 4;
        return;
    }
    if (line_like("LOCAL DATA:", tokens, state) || line_like("-- LOCAL DATA --", tokens, state))
    {
        if (state.current_subprocedure == "")
            badcode("LOCAL DATA section outside subprocedure", state.where);
        if (state.section_state == 1)
            badcode("Duplicate LOCAL DATA section declaration", state.where);
        if (state.section_state == 2)
            badcode("LOCAL DATA section declaration within PROCEDURE section",
                    state.where);
        state.section_state = 1;
        open_subprocedure_code(state);
        return;
    }

    // Immutable scalar constants.
    if (tokens.size() >= 3 && tokens[1] == "IS" && tokens[2] == "CONSTANT")
    {
        if (state.current_structure != "" || state.current_subprocedure != "" ||
            state.section_state != 1)
            badcode("CONSTANT declarations are only valid in the DATA section",
                    state.where);
        if (tokens.size() != 7 || tokens[4] != "WITH" || tokens[5] != "VALUE")
            badcode("CONSTANT declaration must use IS CONSTANT <type> WITH VALUE <literal>",
                    state.where);
        vector<unsigned int> constant_type;
        if (!parse_declared_type(tokens, 3, 4, state, constant_type) ||
            (constant_type != vector<unsigned int>{1} &&
             constant_type != vector<unsigned int>{2}))
            badcode("CONSTANT type must be NUMBER or TEXT", state.where);
        string value = tokens[6];
        if ((constant_type == vector<unsigned int>{1} && !is_number(value)) ||
            (constant_type == vector<unsigned int>{2} && !is_string(value)))
            badcode("CONSTANT value does not match its declared type", state.where);

        const string name = qualified_global_name(tokens[0], state);
        if (state.variables[""].count(name) > 0)
            badcode("Duplicate declaration for variable \"" + name + "\"", state.where);
        state.variables[""][name] = constant_type;
        state.constants[name] = true;
        state.constant_values[name] = value;
        string c_type = state.get_c_type(constant_type);
        state.add_var_code("const " + c_type + " " + fix_identifier(name, true, state) +
                           " = " + value + ";");
        return;
    }

    // Structure field and variable declarations.
    if (line_like("$name IS $anything", tokens, state))
    {
        size_t type_begin = 2;
        string extern_keyword;
        if (type_begin < tokens.size() && tokens[type_begin] == "EXTERNAL")
        {
            if (state.current_structure != "" || state.current_subprocedure != "" ||
                state.section_state != 1)
                badcode("EXTERNAL is only valid for variables in the DATA section",
                        state.where);
            extern_keyword = "extern ";
            ++type_begin;
        }
        if (state.section_state == 4 && type_begin < tokens.size() &&
            tokens[type_begin] == "REFERENCE")
            ++type_begin;

        vector<unsigned int> declared_type;
        if (!parse_declared_type(tokens, type_begin, tokens.size(), state, declared_type))
            badcode("Unknown or malformed data type in declaration of \"" + tokens[0] +
                    "\"", state.where);

        if (state.current_structure != "")
        {
            const string &structure = state.current_structure;
            if (find(declared_type.begin(), declared_type.end(),
                     state.structure_types[structure]) != declared_type.end())
                badcode("Structure \"" + structure + "\" cannot contain itself",
                        state.where);
            if (state.structure_fields[structure].count(tokens[0]) > 0)
                badcode("Duplicate field \"" + tokens[0] + "\" in STRUCTURE \"" +
                        structure + "\"", state.where);
            const string c_field = fix_identifier(tokens[0], true);
            for (const string &field : state.structure_field_order[structure])
                if (fix_identifier(field, true) == c_field)
                    badcode("Field \"" + tokens[0] +
                            "\" has the same generated C++ name as field \"" +
                            field + "\"", state.where);
            state.structure_fields[structure][tokens[0]] = declared_type;
            state.structure_field_order[structure].push_back(tokens[0]);
            return;
        }

        if (state.section_state != 1 && state.section_state != 4)
            badcode("Variable declaration outside DATA, PARAMETERS or LOCAL DATA section",
                    state.where);
        const string declared_name = state.current_subprocedure == ""
                                         ? qualified_global_name(tokens[0], state)
                                         : tokens[0];
        if (state.variables[state.current_subprocedure].count(declared_name) > 0)
            badcode("Duplicate declaration for variable \"" + declared_name + "\"",
                    state.where);
        state.variables[state.current_subprocedure][declared_name] = declared_type;
        if (!extern_keyword.empty()) state.externals[declared_name] = true;

        if (state.section_state == 1)
        {
            string identifier = fix_identifier(declared_name, true, state);
            string c_type = state.get_c_type(declared_type);
            string assign_default = extern_keyword.empty()
                                        ? structure_default_value(declared_type)
                                        : "";
            string code = extern_keyword + c_type + " " + identifier + assign_default + ";";
            if (state.current_subprocedure == "") state.add_var_code(code);
            else state.add_code(code, state.where);
        }
        else
            state.subprocedures[state.current_subprocedure].emplace_back(declared_name);
        return;
    }

    // SUB-PROCEDURE Declaration
    if (tokens.size() >= 2 &&
        (tokens[0] == "SUB-PROCEDURE" || tokens[0] == "SUB") &&
        (tokens.size() == 2 || (tokens.size() > 3 && tokens[2] == "RETURNS")))
    {
        vector<string> name_tokens(tokens.begin(), tokens.begin() + 2);
        if (!line_like(tokens[0] + " $name", name_tokens, state))
            badcode("Invalid SUB-PROCEDURE name", state.where);
        if (!in_procedure_section(state))
            badcode("SUB-PROCEDURE declaration outside PROCEDURE section",
                    state.where);
        const string subprocedure = resolved_subprocedure_name(tokens[1], state);
        if (state.subprocedures.count(subprocedure) > 0)
            badcode("Duplicate declaration for SUB-PROCEDURE \"" + subprocedure + "\"",
                    state.where);
        if (state.closing_subprocedure())
            badcode("SUB-PROCEDURE declaration inside SUB-PROCEDURE", state.where);
        else if (state.closing_if())
            badcode("SUB-PROCEDURE declaration inside IF", state.where);
        else if (state.closing_loop())
            badcode("SUB-PROCEDURE declaration inside WHILE or FOR", state.where);
        else if (state.closing_try() || state.closing_error_handler())
            badcode("SUB-PROCEDURE declaration inside TRY", state.where);
        vector<unsigned int> declared_return{0};
        if (tokens.size() > 2 &&
            !parse_declared_type(tokens, 3, tokens.size(), state, declared_return))
            badcode("Unknown or malformed SUB-PROCEDURE return type", state.where);
        if (state.subprocedure_returns.count(subprocedure) > 0 &&
            state.subprocedure_returns[subprocedure] != declared_return)
            badcode("SUB-PROCEDURE return type doesn't match its predeclared signature",
                    state.where);
        state.subprocedure_returns[subprocedure] = declared_return;
        state.section_state = 3;
        state.open_subprocedure(subprocedure);
        state.subprocedures.emplace(subprocedure, vector<string>());
        return;
    }
    if (line_like("EXTERNAL SUB-PROCEDURE $external", tokens, state) ||
        line_like("EXTERNAL SUB $external", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("EXTERNAL SUB-PROCEDURE declaration outside PROCEDURE section",
                    state.where);
        if (state.closing_subprocedure())
            badcode("SUB-PROCEDURE declaration inside SUB-PROCEDURE", state.where);
        else if (state.closing_if())
            badcode("SUB-PROCEDURE declaration inside IF", state.where);
        else if (state.closing_loop())
            badcode("SUB-PROCEDURE declaration inside WHILE or FOR", state.where);
        else
            state.open_subprocedure(tokens[2]);
        // C++ Code
        state.add_code("void " + fix_external_identifier(tokens[2], false) + "(){",
                       state.where);
        return;
    }
    if (line_like("END SUB-PROCEDURE", tokens, state) ||
        line_like("END SUB", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("END SUB-PROCEDURE outside PROCEDURE section", state.where);
        if (!state.closing_subprocedure())
            badcode("END SUB-PROCEDURE without SUB-PROCEDURE", state.where);
        // C++ Code
        vector<unsigned int> return_type = state.subprocedure_returns.count(
                                               state.current_subprocedure)
                                               ? state.subprocedure_returns[
                                                     state.current_subprocedure]
                                               : vector<unsigned int>{0};
        if (return_type != vector<unsigned int>{0} &&
            !state.current_subprocedure_has_return)
            badcode("Returning SUB-PROCEDURE must contain RETURN with a value",
                    state.where);
        if (return_type == vector<unsigned int>{0})
            state.add_code("return;}", state.where);
        else
            state.add_code(
                "VAR_ERRORCODE = 1; VAR_ERRORTEXT = \"Returning SUB-PROCEDURE " +
                    state.current_subprocedure +
                    " completed without RETURN\"; throw ldpl_error_signal();}",
                state.where);
        // Cierro la subrutina
        state.close_subprocedure();
        return;
    }

    // Control Flow Statements
    if (tokens.size() >= 4 && tokens[0] == "SET" && tokens[2] == "TO")
    {
        if (!in_procedure_section(state))
            badcode("SET statement outside PROCEDURE section", state.where);
        if (!variable_exists(tokens[1], state) || is_constant(tokens[1], state))
            badcode("SET destination must be a mutable variable", state.where);
        composable_expression value =
            compile_expression(join_tokens(tokens, 3, tokens.size()), state);
        vector<unsigned int> destination_type = variable_type(tokens[1], state);
        if (value.boolean_value || value.type != destination_type)
            badcode("SET expression type doesn't match its destination", state.where);
        state.add_code(get_c_variable(state, tokens[1]) + " = " + value.code + ";",
                       state.where);
        return;
    }
    if (line_like("STORE $expression IN $var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("STORE statement outside PROCEDURE section", state.where);
        // C++ Code
        string lhand;
        if (is_num_var(tokens[3], state))
            lhand = get_c_number(state, tokens[1]);
        else
            lhand = get_c_string(state, tokens[1]);
        state.add_code(get_c_variable(state, tokens[3]) + " = " + lhand + ";", state.where);
        return;
    }
    if (line_like("IN $var STORE $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/STORE statement outside PROCEDURE section", state.where);
        // C++ Code
        string lhand;
        if (is_num_var(tokens[1], state))
            lhand = get_c_number(state, tokens[3]);
        else
            lhand = get_c_string(state, tokens[3]);
        state.add_code(get_c_variable(state, tokens[1]) + " = " + lhand + ";", state.where);
        return;
    }
    if (line_like("TRY", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("TRY outside PROCEDURE section", state.where);
        state.open_try();
        state.add_code("VAR_ERRORCODE = 0; VAR_ERRORTEXT = \"\"; try {", state.where);
        return;
    }
    if (line_like("ON ERROR", tokens, state))
    {
        if (!state.closing_try())
            badcode("ON ERROR without a matching TRY, or with an open inner block",
                    state.where);
        state.open_error_handler();
        state.add_code("} catch (const ldpl_error_signal&) {", state.where);
        return;
    }
    if (line_like("END TRY", tokens, state))
    {
        if (!state.closing_error_handler())
            badcode("END TRY without a matching ON ERROR, or with an open inner block",
                    state.where);
        state.close_error_handler();
        state.add_code("} VAR_ERRORCODE = 0; VAR_ERRORTEXT = \"\";", state.where);
        return;
    }
    if (line_like("RAISE ERROR $str-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("RAISE ERROR outside PROCEDURE section", state.where);
        if (state.try_body_depth == 0 && state.error_handler_depth == 0)
            badcode("RAISE ERROR must be used inside TRY or ON ERROR", state.where);
        state.add_code("VAR_ERRORCODE = 1; VAR_ERRORTEXT = " +
                           get_c_expression(state, tokens[2]) +
                           "; throw ldpl_error_signal();",
                       state.where);
        return;
    }
    if (line_like("RAISE ERROR", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("RAISE ERROR outside PROCEDURE section", state.where);
        if (state.error_handler_depth == 0)
            badcode("RAISE ERROR without a message is only valid in ON ERROR",
                    state.where);
        state.add_code("throw;", state.where);
        return;
    }
    if (line_like("IF $condition THEN", tokens, state))
    {
        string condition = compile_condition_tokens(tokens, 1, tokens.size() - 1,
                                                    state);
        if (!in_procedure_section(state))
            badcode("IF outside PROCEDURE section", state.where);
        state.open_if();
        state.add_code("if (" + condition + "){", state.where);
        return;
    }
    if (line_like("ELSE IF $condition THEN", tokens, state))
    {
        string condition = compile_condition_tokens(tokens, 2, tokens.size() - 1,
                                                    state);
        if (!in_procedure_section(state))
            badcode("ELSE IF outside PROCEDURE section", state.where);
        if (!state.closing_if())
            badcode("ELSE IF without IF", state.where);
        state.add_code("} else if (" + condition + "){", state.where);
        return;
    }
    if (line_like("ELSE", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("ELSE outside PROCEDURE section", state.where);
        if (!state.closing_if())
            badcode("ELSE without IF", state.where);
        // C++ Code
        state.open_else();
        state.add_code("}else{", state.where);
        return;
    }
    if (line_like("END IF", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("END IF outside PROCEDURE section", state.where);
        if (!state.closing_if() && !state.closing_else())
            badcode("END IF without IF", state.where);
        // C++ Code
        state.close_if();
        state.add_code("}", state.where);
        return;
    }
    if (line_like("WHILE $condition DO", tokens, state))
    {
        string condition = compile_condition_tokens(tokens, 1, tokens.size() - 1,
                                                    state);
        if (!in_procedure_section(state))
            badcode("WHILE outside PROCEDURE section", state.where);
        state.open_loop();
        state.add_code("while (" + condition + "){", state.where);
        return;
    }
    if (line_like("FOREVER DO", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("WHILE outside PROCEDURE section", state.where);
        // C++ Code
        state.open_loop();
        state.add_code("while (true){", state.where);
        return;
    }
    if (line_like("REPEAT", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("REPEAT outside PROCEDURE section", state.where);
        if (!state.closing_loop())
            badcode("REPEAT without WHILE or FOR", state.where);
        // C++ Code
        state.close_loop();
        state.add_code("}", state.where);
        return;
    }
    if (line_like("FOR $num-var FROM $num-expr TO $num-expr STEP $num-expr DO", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("FOR outside PROCEDURE section", state.where);
        state.open_loop();
        string var = get_c_variable(state, tokens[1]);
        string from = get_c_expression(state, tokens[3]);
        string to = get_c_expression(state, tokens[5]);
        string step = get_c_expression(state, tokens[7]);
        string init = var + " = " + from;
        string condition =
            step + " >= 0 ? " + var + " < " + to + " : " + var + " > " + to;
        string increment = var + " += " + step;
        // C++ Code
        state.add_code("for (" + init + "; " + condition + "; " + increment + ") {",
                       state.where);
        return;
    }
    if (line_like("FOR $num-var FROM $num-expr TO $num-expr INCLUSIVE STEP $num-expr DO", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("FOR outside PROCEDURE section", state.where);
        state.open_loop();
        string var = get_c_variable(state, tokens[1]);
        string from = get_c_expression(state, tokens[3]);
        string to = get_c_expression(state, tokens[5]);
        string step = get_c_expression(state, tokens[8]);
        string init = var + " = " + from;
        string condition =
            step + " >= 0 ? " + var + " <= " + to + " : " + var + " >= " + to;
        string increment = var + " += " + step;
        // C++ Code
        state.add_code("for (" + init + "; " + condition + "; " + increment + ") {",
                       state.where);
        return;
    }
    if (line_like("FOR $num-var FROM $num-expr TO $num-expr DO", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("FOR outside PROCEDURE section", state.where);
        state.open_loop();
        string var = get_c_variable(state, tokens[1]);
        string from = get_c_expression(state, tokens[3]);
        string to = get_c_expression(state, tokens[5]);
        string step = "(" + from + ") <= (" + to + ") ? 1 : -1";
        string init = var + " = " + from;
        string condition = "(" + step + ") > 0 ? " + var + " < (" + to + ") : " + var + " > (" + to + ")";
        string increment = var + " += " + step;
        // C++ Code
        state.add_code("for (" + init + "; " + condition + "; " + increment + ") {",
                       state.where);
        return;
    }
    if (line_like("FOR $num-var FROM $num-expr TO $num-expr INCLUSIVE DO", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("FOR outside PROCEDURE section", state.where);
        state.open_loop();
        string var = get_c_variable(state, tokens[1]);
        string from = get_c_expression(state, tokens[3]);
        string to = get_c_expression(state, tokens[5]);
        string init = var + " = " + from;
        string condition = var + " <= " + to;
        string increment = var + " += 1";
        // C++ Code
        state.add_code("for (" + init + "; " + condition + "; " + increment + ") {",
                       state.where);
        return;
    }
    if (line_like("FOR EACH $anyVar IN $collection DO", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("FOR EACH outside PROCEDURE section", state.where);
        vector<unsigned int> iteration_type = variable_type(tokens[2], state);
        vector<unsigned int> collected_type = variable_type(tokens[4], state);
        unsigned int collection_type = collected_type.back(); // LIST or MAP
        collected_type.pop_back();
        if (collection_type == 3 && iteration_type != collected_type)
            badcode("FOR EACH iteration variable type doesn't match LIST type",
                    state.where);
        else if (collection_type == 4 && iteration_type != vector<unsigned int>{2})
            badcode("FOR EACH iteration variable type must be TEXT on MAP iteration",
                    state.where);
        state.open_loop();
        // C Code
        string range_var = state.new_range_var();
        string collection = get_c_variable(state, tokens[4]) + ".inner_collection";
        string iteration_var = range_var;
        if (collection_type == 4)
        {
            iteration_var += ".first";
        }
        state.add_code("for (auto& " + range_var + " : " + collection + ") {",
                       state.where);
        state.add_code(
            get_c_variable(state, tokens[2]) + " = " + iteration_var + ";",
            state.where);
        return;
    }
    if (line_like("BREAK", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("BREAK outside PROCEDURE section", state.where);
        if (state.open_loops == 0)
            badcode("BREAK without WHILE or FOR", state.where);
        // C++ Code
        state.add_code("break;", state.where);
        return;
    }
    if (line_like("CONTINUE", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("CONTINUE outside PROCEDURE section", state.where);
        if (state.open_loops == 0)
            badcode("CONTINUE without WHILE or FOR", state.where);
        // C++ Code
        state.add_code("continue;", state.where);
        return;
    }
    if (line_like("CALL EXTERNAL $external", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("CALL EXTERNAL outside PROCEDURE section", state.where);
        state.add_code(fix_external_identifier(tokens[2], false) + "();",
                       state.where);
        // prototype of function defined in extension
        state.add_var_code("void " + fix_external_identifier(tokens[2], false) +
                           "();");
        return;
    }
    if (line_like("CALL SUB-PROCEDURE $anything", tokens, state) ||
        line_like("CALL $anything", tokens, state))
    {
        size_t i = 1;
        if (tokens[i] == "SUB-PROCEDURE")
            i++;
        string subprocedure = resolved_subprocedure_name(tokens[i], state);
        // Valid options: no WITH, or a comma-separated argument list.
        if (i == tokens.size() - 1 ||
            (i < tokens.size() - 2 && tokens[i + 1] == "WITH"))
        {
            if (!in_procedure_section(state))
                badcode("CALL outside PROCEDURE section", state.where);
            vector<string> parameters;
            if (i != tokens.size() - 1)
                parameters = split_comma_arguments(
                    join_tokens(tokens, i + 2, tokens.size()), state);
            vector<composable_expression> arguments;
            vector<vector<unsigned int>> types;
            for (string &parameter : parameters)
            {
                composable_expression argument = compile_expression(parameter, state);
                if (argument.boolean_value)
                    badcode("CALL arguments cannot be conditions", state.where);
                types.push_back(argument.type);
                arguments.push_back(argument);
            }
            bool correct_types =
                state.correct_subprocedure_types(subprocedure, types);
            if (!is_subprocedure(subprocedure, state))
            {
                if (!correct_types)
                    badcode("CALL parameter types don't match previous CALL",
                            state.where);
                state.add_expected_subprocedure(
                    subprocedure, fix_identifier(subprocedure, false), types);
            }
            else
            {
                if (!correct_types)
                    badcode("CALL parameter types don't match SUB-PROCEDURE declaration",
                            state.where);
            }
            vector<unsigned int> return_type =
                state.subprocedure_returns.count(subprocedure) > 0
                    ? state.subprocedure_returns[subprocedure]
                    : vector<unsigned int>{0};
            if (return_type != vector<unsigned int>{0} &&
                state.subprocedure_parameter_references.count(subprocedure) > 0)
                for (size_t argument = 0; argument < arguments.size(); ++argument)
                    if (argument < state.subprocedure_parameter_references[subprocedure].size() &&
                        state.subprocedure_parameter_references[subprocedure][argument] &&
                        !arguments[argument].assignable)
                        badcode("Reference CALL argument " +
                                    to_string(argument + 1) +
                                    " must be a mutable variable",
                                state.where);
            string code = fix_identifier(subprocedure, false) + "(";
            for (size_t argument = 0; argument < arguments.size(); ++argument)
            {
                if (argument > 0) code += ", ";
                if (return_type == vector<unsigned int>{0} &&
                    !arguments[argument].assignable)
                {
                    string temporary = state.new_literal_parameter_var();
                    state.add_code(state.get_c_type(arguments[argument].type) + " " +
                                       temporary + " = " + arguments[argument].code + ";",
                                   state.where);
                    code += temporary;
                }
                else
                    code += arguments[argument].code;
            }
            code += ");";
            state.add_code(code, state.where);
            return;
        }
    }
    if (line_like("CALL PARALLEL SUB-PROCEDURE $anything", tokens, state) ||
        line_like("CALL PARALLEL $anything", tokens, state))
    {
        size_t i = 2;
        if (tokens[i] == "SUB-PROCEDURE")
            i++;
        string subprocedure = resolved_subprocedure_name(tokens[i], state);
        // Valid options: No WITH or WITH with at least one paramter
        if (i == tokens.size() - 1)
        {
            if (!in_procedure_section(state))
                badcode("CALL PARALLEL outside PROCEDURE section", state.where);
            vector<vector<unsigned int>> types;
            bool correct_types = state.correct_subprocedure_types(subprocedure, types);
            if (!is_subprocedure(subprocedure, state))
            {
                if (!correct_types)
                    badcode("CALL PARALLEL parameter types don't match previous CALL",
                            state.where);
                state.add_expected_subprocedure(
                    subprocedure, fix_identifier(subprocedure, false), types);
            }
            else
            {
                if (!correct_types)
                    badcode("CALL PARALLEL parameter types don't match SUB-PROCEDURE declaration",
                            state.where);
            }
            add_thread_call_code(subprocedure, state);
            return;
        }
        else if (i < tokens.size() - 2 && tokens[i + 1] == "WITH")
        {
            badcode("Parallel calls don't support argument passing.", state.where);
        }
    }
    if (tokens.size() > 1 && tokens[0] == "RETURN")
    {
        if (!in_procedure_section(state))
            badcode("RETURN outside PROCEDURE section", state.where);
        if (state.current_subprocedure == "")
            badcode("RETURN found outside subprocedure", state.where);
        vector<unsigned int> return_type = state.subprocedure_returns.count(
                                               state.current_subprocedure)
                                               ? state.subprocedure_returns[
                                                     state.current_subprocedure]
                                               : vector<unsigned int>{0};
        if (return_type == vector<unsigned int>{0})
            badcode("Non-returning SUB-PROCEDURE cannot RETURN a value", state.where);
        composable_expression value =
            compile_expression(join_tokens(tokens, 1, tokens.size()), state);
        if (value.boolean_value || value.type != return_type)
            badcode("RETURN expression doesn't match the SUB-PROCEDURE return type",
                    state.where);
        state.current_subprocedure_has_return = true;
        state.add_code("return " + value.code + ";", state.where);
        return;
    }
    if (line_like("RETURN", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("RETURN outside PROCEDURE section", state.where);
        if (state.current_subprocedure == "")
            badcode("RETURN found outside subprocedure", state.where);
        if (state.subprocedure_returns.count(state.current_subprocedure) > 0 &&
            state.subprocedure_returns[state.current_subprocedure] !=
                vector<unsigned int>{0})
            badcode("Returning SUB-PROCEDURE must RETURN a value", state.where);
        // C++ Code
        state.add_code("return;", state.where);
        return;
    }
    if (line_like("EXIT", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("EXIT outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("exit(0);", state.where);
        return;
    }
    if (line_like("WAIT $num-expr MILLISECONDS", tokens, state) || line_like("SLEEP $num-expr", tokens, state) || line_like("WAIT $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("WAIT / SLEEP statement outside PROCEDURE section", state.where);
// C++ Code
#if defined(_WIN32)
        state.add_code(
            "_sleep(((LdplNumber)" + get_c_expression(state, tokens[1]) + ").to_long_long());",
            state.where);
#else
        state.add_code(
            "std::this_thread::sleep_for(std::chrono::milliseconds(((LdplNumber)" +
                get_c_expression(state, tokens[1]) + ").to_long_long()));",
            state.where);
#endif
        return;
    }
    if (line_like("GOTO $label", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GOTO outside PROCEDURE section", state.where);
        state.add_code("goto label_" + fix_identifier(tokens[1]) + ";",
                       state.where);
        return;
    }
    if (line_like("LABEL $label", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("LABEL outside PROCEDURE section", state.where);
        state.add_code("label_" + fix_identifier(tokens[1]) + ":", state.where);
        return;
    }

    // Arithmetic Statements
    if (line_like("MODULO $num-expr BY $num-expr IN $num-var", tokens,
                  state)) // TODO move this into the standard library
    {
        if (!in_procedure_section(state))
            badcode("MODULO statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = modulo(" +
                           get_c_expression(state, tokens[1]) + ", " +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var MODULO $num-expr BY $num-expr", tokens,
                  state)) // TODO move this into the standard library
    {
        if (!in_procedure_section(state))
            badcode("IN/MODULO statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = modulo(" +
                           get_c_expression(state, tokens[3]) + ", " +
                           get_c_expression(state, tokens[5]) + ");",
                       state.where);
        return;
    }
    if (line_like("RAISE $num-expr TO $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("RAISE statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = pow(((LdplNumber)" +
                           get_c_expression(state, tokens[1]) + ").to_double(), ((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("IN $num-var RAISE $num-expr TO $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/RAISE statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = pow(((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_double(), ((LdplNumber)" +
                           get_c_expression(state, tokens[5]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("LOG $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("LOG statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = log(((LdplNumber)" +
                           get_c_expression(state, tokens[1]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("IN $num-var LOG $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/LOG statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = log(((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("SIN $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("SIN statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = sin(((LdplNumber)" +
                           get_c_expression(state, tokens[1]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("IN $num-var SIN $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/SIN statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = sin(((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("COS $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("COS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = cos(((LdplNumber)" +
                           get_c_expression(state, tokens[1]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("IN $num-var COS $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/COS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = cos(((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("TAN $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("TAN statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = tan(((LdplNumber)" +
                           get_c_expression(state, tokens[1]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("IN $num-var TAN $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/TAN statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = tan(((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_double());",
                       state.where);
        return;
    }
    if (line_like("ADD $num-expr AND $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("ADD statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[5]) + " = " +
                           get_c_expression(state, tokens[1]) + " + " +
                           get_c_expression(state, tokens[3]) + ";",
                       state.where);
        return;
    }
    if (line_like("IN $num-var ADD $num-expr AND $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/ADD statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[1]) + " = " +
                           get_c_expression(state, tokens[3]) + " + " +
                           get_c_expression(state, tokens[5]) + ";",
                       state.where);
        return;
    }
    if (line_like("SUBTRACT $num-expr FROM $num-expr IN $num-var", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("SUBTRACT statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[5]) + " = " +
                           get_c_expression(state, tokens[3]) + " - " +
                           get_c_expression(state, tokens[1]) + ";",
                       state.where);
        return;
    }
    if (line_like("IN $num-var SUBTRACT $num-expr FROM $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/SUBTRACT statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[1]) + " = " +
                           get_c_expression(state, tokens[5]) + " - " +
                           get_c_expression(state, tokens[3]) + ";",
                       state.where);
        return;
    }
    if (line_like("MULTIPLY $num-expr BY $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("MULTIPLY statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[5]) + " = " +
                           get_c_expression(state, tokens[1]) + " * " +
                           get_c_expression(state, tokens[3]) + ";",
                       state.where);
        return;
    }
    if (line_like("IN $num-var MULTIPLY $num-expr BY $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/MULTIPLY statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[1]) + " = " +
                           get_c_expression(state, tokens[3]) + " * " +
                           get_c_expression(state, tokens[5]) + ";",
                       state.where);
        return;
    }
    if (line_like("DIVIDE $num-expr BY $num-expr IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("DIVIDE statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[5]) + " = " +
                           get_c_expression(state, tokens[1]) + " / " +
                           get_c_expression(state, tokens[3]) + ";",
                       state.where);
        return;
    }
    if (line_like("IN $num-var DIVIDE $num-expr BY $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/DIVIDE statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[1]) + " = " +
                           get_c_expression(state, tokens[3]) + " / " +
                           get_c_expression(state, tokens[5]) + ";",
                       state.where);
        return;
    }
    if (line_like("GET RANDOM IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("RANDOM outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = get_random();",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET RANDOM", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/RANDOM outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = get_random();",
                       state.where);
        return;
    }
    if (line_like("FLOOR $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("FLOOR statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = floor(" +
                           get_c_variable(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("CEIL $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("CEIL statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = ceil(" +
                           get_c_variable(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("FLOOR $num-var IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("FLOOR statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = floor(" +
                           get_c_variable(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var FLOOR $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/FLOOR statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = floor(" +
                           get_c_variable(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("CEIL $num-var IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("CEIL statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = ceil(" +
                           get_c_variable(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var CEIL $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/CEIL statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = ceil(" +
                           get_c_variable(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var SOLVE $math", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN-SOLVE statement outside PROCEDURE section", state.where);

        string code = "";
        for (unsigned int i = 3; i < tokens.size(); ++i)
        {
            if (is_num_expr(tokens[i], state))
                code += " " + get_c_number(state, tokens[i]);
            else if (is_txt_expr(tokens[i], state))
                code += " " + get_c_number(state, tokens[i]);
            else
                code += " " + tokens[i];
        }
        state.add_code(get_c_variable(state, tokens[1]) + " =" + code + ";",
                       state.where);
        return;
    }

    // Text Statements
    if (line_like("JOIN $expression AND $expression IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("JOIN statement outside PROCEDURE section", state.where);
        // C++ Code
        if (tokens[5] == tokens[1])
        {
            // Optimization for appending
            state.add_code(get_c_variable(state, tokens[5]) + " += " + get_c_string(state, tokens[3]) + ";", state.where);
        }
        else
        {
            state.add_code("join(" + get_c_string(state, tokens[1]) + ", " + get_c_string(state, tokens[3]) + ", " + get_c_string(state, tokens[5]) + ");", state.where);
        }
        return;
    }
    if (line_like("IN $str-var JOIN $expression AND $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/JOIN statement outside PROCEDURE section", state.where);
        // C++ Code
        if (tokens[5] == tokens[1])
        {
            // Optimization for appending
            state.add_code(get_c_variable(state, tokens[1]) + " += " + get_c_string(state, tokens[5]) + ";", state.where);
        }
        else
        {
            state.add_code("join(" + get_c_string(state, tokens[3]) + ", " + get_c_string(state, tokens[5]) + ", " + get_c_string(state, tokens[1]) + ");", state.where);
        }
        return;
    }
    if (line_like("GET CHARACTER AT $num-expr FROM $str-expr IN $str-var", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("GET CHARACTER statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[7]) + " = charat(" +
                           get_c_expression(state, tokens[5]) + ", " +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-var GET CHARACTER AT $num-expr FROM $str-expr", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET CHARACTER statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = charat(" +
                           get_c_expression(state, tokens[7]) + ", " +
                           get_c_expression(state, tokens[5]) + ");",
                       state.where);
        return;
    }
    if (line_like("GET LENGTH OF $str-expr IN $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET LENGTH OF outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = ((graphemedText)" +
                           get_c_expression(state, tokens[3]) + ").size();",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET LENGTH OF $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET LENGTH OF outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = ((graphemedText)" +
                           get_c_expression(state, tokens[5]) + ").size();",
                       state.where);
        return;
    }
    if (line_like("GET BYTE COUNT OF $expression IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET BYTE COUNT OF outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[6]) + " = ((graphemedText)" +
                           get_c_expression(state, tokens[4]) + ").str_rep().length();",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET BYTE COUNT OF $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET BYTE COUNT OF outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = ((graphemedText)" +
                           get_c_expression(state, tokens[6]) + ").str_rep().length();",
                       state.where);
        return;
    }
    if (line_like("GET ASCII CHARACTER $num-expr IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET ASCII CHARACTER statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = getAsciiChar(" +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-var GET ASCII CHARACTER $num-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET ASCII CHARACTER statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = getAsciiChar(" +
                           get_c_expression(state, tokens[5]) + ");",
                       state.where);
        return;
    }
    if (line_like("GET CHARACTER CODE OF $expression IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET CHARACTER CODE OF statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[6]) + " = get_char_num(" +
                           get_c_expression(state, tokens[4]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET CHARACTER CODE OF $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET CHARACTER CODE OF statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = get_char_num(" +
                           get_c_expression(state, tokens[6]) + ");",
                       state.where);
        return;
    }
    if (line_like("STORE QUOTE IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("STORE QUOTE IN statement outside PROCEDURE section",
                    state.where);
        state.open_quote = true;
        // C++ Code. More strings will get emitted
        state.add_code(get_c_variable(state, tokens[3]) + " = \"\"", state.where);
        return;
    }
    if (line_like("IN $str-var STORE QUOTE", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/STORE QUOTE statement outside PROCEDURE section",
                    state.where);
        state.open_quote = true;
        // C++ Code. More strings will get emitted
        state.add_code(get_c_variable(state, tokens[1]) + " = \"\"", state.where);
        return;
    }
    if (line_like("STORE TRIMMED QUOTE IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("STORE TRIMMED QUOTE IN statement outside PROCEDURE section",
                    state.where);
        state.open_quote = true;
        state.trim_quote_lines = true;
        // C++ Code. More strings will get emitted
        state.add_code(get_c_variable(state, tokens[4]) + " = \"\"", state.where);
        return;
    }
    if (line_like("IN $str-var STORE TRIMMED QUOTE", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/STORE TRIMMED QUOTE statement outside PROCEDURE section",
                    state.where);
        state.open_quote = true;
        state.trim_quote_lines = true;
        // C++ Code. More strings will get emitted
        state.add_code(get_c_variable(state, tokens[1]) + " = \"\"", state.where);
        return;
    }
    if (line_like("END QUOTE", tokens, state))
        badcode("END QUOTE statement without preceding STORE QUOTE statement",
                state.where);
    if (line_like("IN $str-var JOIN $display", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN-JOIN statement outside PROCEDURE section", state.where);
        if (tokens.size() < 5)
            badcode("IN-JOIN expects at least two values to join", state.where);
        // C++ Code
        state.add_code("joinvar_mutex.lock();");
        state.add_code("joinvar = \"\";", state.where);
        for (unsigned int i = 3; i < tokens.size(); ++i)
        {
            state.add_code(
                "joinvar += " + get_c_string(state, tokens[i]) + ";",
                state.where);
        }
        state.add_code(get_c_variable(state, tokens[1]) + " = joinvar;",
                       state.where);
        state.add_code("joinvar_mutex.unlock();");
        return;
    }

    // I/O Statements
    if (tokens.size() > 1 && (tokens[0] == "DISPLAY" || tokens[0] == "PRINT"))
    {
        bool composable = has_expression_punctuation(
            join_tokens(tokens, 1, tokens.size()));
        for (size_t i = 1; i < tokens.size(); ++i)
            if (tokens[i] == "+" || tokens[i] == "-" || tokens[i] == "*" ||
                tokens[i] == "/" || tokens[i] == "%" ||
                tokens[i] == "MODULO")
                composable = true;
        if (composable)
        {
            if (!in_procedure_section(state))
                badcode(tokens[0] + " statement outside PROCEDURE section",
                        state.where);
            vector<string> values = split_comma_arguments(
                join_tokens(tokens, 1, tokens.size()), state);
            for (const string &source : values)
            {
                composable_expression value = compile_expression(source, state);
                if (value.boolean_value)
                    badcode(tokens[0] + " cannot output a condition", state.where);
                state.add_code("cout << " + value.code + " << flush;", state.where);
            }
            if (tokens[0] == "PRINT") state.add_code("cout << endl;", state.where);
            return;
        }
    }
    if (line_like("DISPLAY $display", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("DISPLAY statement outside PROCEDURE section", state.where);
        // C++ Code
        for (unsigned int i = 1; i < tokens.size(); ++i)
        {
            state.add_code("cout << " + get_c_expression(state, tokens[i]) +
                               " << flush;",
                           state.where);
        }
        return;
    }
    if (line_like("PRINT $display", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("PRINT statement outside PROCEDURE section", state.where);
        // C++ Code
        for (unsigned int i = 1; i < tokens.size(); ++i)
        {
            state.add_code("cout << " + get_c_expression(state, tokens[i]) +
                               " << flush;",
                           state.where);
        }
        state.add_code("cout << endl;", state.where);
        return;
    }
    if (line_like("ACCEPT $var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("ACCEPT statement outside PROCEDURE section", state.where);
        // C++ Code
        if (is_num_var(tokens[1], state))
            state.add_code(get_c_variable(state, tokens[1]) + " = input_number();",
                           state.where);
        else
            state.add_code(get_c_variable(state, tokens[1]) + " = input_string();",
                           state.where);
        return;
    }
    if (line_like("EXECUTE $str-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("EXECUTE outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("exec(" + get_c_char_array(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("EXECUTE $str-expr AND STORE OUTPUT IN $str-var", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("EXECUTE outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[6]) + " = exec(" +
                           get_c_char_array(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-var EXECUTE AND STORE OUTPUT OF $str-expr", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("IN/EXECUTE outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = exec(" +
                           get_c_char_array(state, tokens[7]) + ");",
                       state.where);
        return;
    }
    if (line_like("EXECUTE $str-expr AND STORE EXIT CODE IN $num-var", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("EXECUTE outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[7]) + " = exec_exit_code(" +
                           get_c_char_array(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var EXECUTE AND STORE EXIT CODE OF $str-expr", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("IN/EXECUTE outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = exec_exit_code(" +
                           get_c_char_array(state, tokens[8]) + ");",
                       state.where);
        return;
    }
    if (line_like("ACCEPT $str-var UNTIL EOF", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("ACCEPT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = input_until_eof();",
                       state.where);
        return;
    }
    if (line_like("LOAD FILE $expression IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("LOAD FILE statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("load_file(" + get_c_expression(state, tokens[2]) + ", " +
                           get_c_variable(state, tokens[4]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-var LOAD FILE $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/LOAD FILE statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("load_file(" + get_c_expression(state, tokens[4]) + ", " +
                           get_c_variable(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("WRITE $expression TO FILE $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("WRITE statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("write_file(" + get_c_expression(state, tokens[4]) + ", " +
                           get_c_expression(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("APPEND $expression TO FILE $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("APPEND statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("append_to_file(" + get_c_expression(state, tokens[4]) +
                           ", " + get_c_expression(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("REPLACE $expression FROM $expression WITH $expression IN $str-var",
                  tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("REPLACE statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(
            get_c_variable(state, tokens[7]) + " = str_replace(((graphemedText)" +
                get_c_expression(state, tokens[3]) + ").str_rep(), ((graphemedText)" +
                get_c_expression(state, tokens[1]) + ").str_rep(), ((graphemedText)" +
                get_c_expression(state, tokens[5]) + ").str_rep());",
            state.where);
        return;
    }
    if (line_like("IN $str-var REPLACE $expression FROM $expression WITH $expression",
                  tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/REPLACE statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(
            get_c_variable(state, tokens[1]) + " = str_replace(((graphemedText)" +
                get_c_expression(state, tokens[5]) + ").str_rep(), ((graphemedText)" +
                get_c_expression(state, tokens[3]) + ").str_rep(), ((graphemedText)" +
                get_c_expression(state, tokens[7]) + ").str_rep());",
            state.where);
        return;
    }
    if (line_like("GET INDEX OF $expression FROM $expression IN $num-var", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("GET INDEX OF statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[7]) + " = utf8GetIndexOf(" +
                           get_c_expression(state, tokens[5]) + ", " +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET INDEX OF $expression FROM $expression", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET INDEX OF statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = utf8GetIndexOf(" +
                           get_c_expression(state, tokens[7]) + ", " +
                           get_c_expression(state, tokens[5]) + ");",
                       state.where);
        return;
    }
    if (line_like("COUNT $expression FROM $expression IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("COUNT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = utf8Count(" +
                           get_c_expression(state, tokens[3]) + ", " +
                           get_c_expression(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $num-var COUNT $expression FROM $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/COUNT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = utf8Count(" +
                           get_c_expression(state, tokens[5]) + ", " +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like(
            "SUBSTRING $expression FROM $expression LENGTH $expression IN $str-var",
            tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("SUBSTRING statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("joinvar_mutex.lock();");
        state.add_code("joinvar = " + get_c_expression(state, tokens[1]) + ";",
                       state.where);
        state.add_code(get_c_variable(state, tokens[7]) + " = joinvar.substr(((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_size_t(), ((LdplNumber)" +
                           get_c_expression(state, tokens[5]) + ").to_size_t());",
                       state.where);
        state.add_code("joinvar_mutex.unlock();");
        return;
    }
    if (line_like("IN $str-var SUBSTRING $expression FROM $expression LENGTH $expression",
                  tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/SUBSTRING statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("joinvar_mutex.lock();");
        state.add_code("joinvar = (graphemedText) " + get_c_expression(state, tokens[3]) + ";",
                       state.where);
        state.add_code(get_c_variable(state, tokens[1]) + " = joinvar.substr(((LdplNumber)" +
                           get_c_expression(state, tokens[5]) + ").to_size_t(), ((LdplNumber)" +
                           get_c_expression(state, tokens[7]) + ").to_size_t());",
                       state.where);
        state.add_code("joinvar_mutex.unlock();");
        return;
    }
    if (line_like("TRIM $str-expr IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("TRIM statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[3]) + " = trimCopy(" +
                           get_c_expression(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-var TRIM $str-expr", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/TRIM statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = trimCopy(" +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("CONVERT $str-expr TO UPPERCASE IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("CONVERT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = toUpperCopy(" +
                           get_c_expression(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-var CONVERT $str-expr TO UPPERCASE", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/CONVERT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = toUpperCopy(" +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("CONVERT $str-expr TO LOWERCASE IN $str-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("CONVERT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = toLowerCopy(" +
                           get_c_expression(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-var CONVERT $str-expr TO LOWERCASE", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/CONVERT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = toLowerCopy(" +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    bool find_scalar = line_like("FIND $expression IN $list INTO $num-var", tokens, state);
    bool find_aggregate = !find_scalar &&
                          line_like("FIND $anyVar IN $list INTO $num-var", tokens, state);
    if (find_scalar || find_aggregate)
    {
        if (!in_procedure_section(state))
            badcode("FIND statement outside PROCEDURE section", state.where);
        vector<unsigned int> value_type;
        if (is_number(tokens[1])) value_type = {1};
        else if (is_string(tokens[1])) value_type = {2};
        else value_type = variable_type(tokens[1], state);
        vector<unsigned int> element_type = variable_type(tokens[3], state);
        element_type.pop_back();
        if (value_type != element_type)
            badcode("FIND value type doesn't match LIST element type", state.where);
        string list = get_c_variable(state, tokens[3]) + ".inner_collection";
        string iterator = state.new_collection_temp();
        string value = get_c_expression(state, tokens[1]);
        if (value_type == vector<unsigned int>{1}) value = "(ldpl_number)" + value;
        else if (value_type == vector<unsigned int>{2}) value = "(graphemedText)" + value;
        state.add_code("auto " + iterator + " = std::find(" + list + ".begin(), " +
                           list + ".end(), " + value + ");",
                       state.where);
        state.add_code(get_c_variable(state, tokens[5]) + " = " + iterator + " == " +
                           list + ".end() ? -1 : std::distance(" + list +
                           ".begin(), " + iterator + ");",
                       state.where);
        return;
    }
    bool remove_scalar = line_like("REMOVE $expression FROM $list", tokens, state);
    bool remove_aggregate = !remove_scalar &&
                            line_like("REMOVE $anyVar FROM $list", tokens, state);
    if (remove_scalar || remove_aggregate)
    {
        if (!in_procedure_section(state))
            badcode("REMOVE statement outside PROCEDURE section", state.where);
        vector<unsigned int> value_type;
        if (is_number(tokens[1])) value_type = {1};
        else if (is_string(tokens[1])) value_type = {2};
        else value_type = variable_type(tokens[1], state);
        vector<unsigned int> element_type = variable_type(tokens[3], state);
        element_type.pop_back();
        if (value_type != element_type)
            badcode("REMOVE value type doesn't match LIST element type", state.where);
        string list = get_c_variable(state, tokens[3]) + ".inner_collection";
        string iterator = state.new_collection_temp();
        string value = get_c_expression(state, tokens[1]);
        if (value_type == vector<unsigned int>{1}) value = "(ldpl_number)" + value;
        else if (value_type == vector<unsigned int>{2}) value = "(graphemedText)" + value;
        state.add_code("auto " + iterator + " = std::find(" + list + ".begin(), " +
                           list + ".end(), " + value + ");",
                       state.where);
        state.add_code("if (" + iterator + " != " + list + ".end()) " + list +
                           ".erase(" + iterator + ");",
                       state.where);
        return;
    }
    if (line_like("SORT $list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("SORT statement outside PROCEDURE section", state.where);
        vector<unsigned int> element_type = variable_type(tokens[1], state);
        element_type.pop_back();
        if (element_type != vector<unsigned int>{1} &&
            element_type != vector<unsigned int>{2})
            badcode("SORT supports only LIST OF NUMBER and LIST OF TEXT", state.where);
        string list = get_c_variable(state, tokens[1]) + ".inner_collection";
        state.add_code("std::sort(" + list + ".begin(), " + list + ".end());",
                       state.where);
        return;
    }
    if (line_like("REVERSE $list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("REVERSE statement outside PROCEDURE section", state.where);
        string list = get_c_variable(state, tokens[1]) + ".inner_collection";
        state.add_code("std::reverse(" + list + ".begin(), " + list + ".end());",
                       state.where);
        return;
    }
    if (line_like("COPY $anyVar TO $anyVar", tokens, state))
    {
        vector<unsigned int> source_type = variable_type(tokens[1], state);
        vector<unsigned int> destination_type = variable_type(tokens[3], state);
        bool aggregate = is_structure_type(source_type, state) ||
                         (!source_type.empty() &&
                          (source_type.back() == 3 || source_type.back() == 4));
        if (!aggregate || source_type != destination_type)
            badcode("COPY requires matching structure or collection types", state.where);
        if (!in_procedure_section(state))
            badcode("COPY statement outside PROCEDURE section", state.where);
        state.add_code(get_c_variable(state, tokens[3]) + " = " +
                           get_c_variable(state, tokens[1]) + ";",
                       state.where);
        return;
    }
    if (line_like("CLEAR $collection", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("CLEAR statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(
            get_c_variable(state, tokens[1]) + ".inner_collection.clear();",
            state.where);
        return;
    }
    if (line_like("COPY $collection TO $collection", tokens, state))
    {
        if (variable_type(tokens[1], state) == variable_type(tokens[3], state))
        {
            if (!in_procedure_section(state))
                badcode("COPY statement outside PROCEDURE section", state.where);
            // C++ Code
            state.add_code(get_c_variable(state, tokens[3]) + ".inner_collection = " +
                               get_c_variable(state, tokens[1]) +
                               ".inner_collection;",
                           state.where);
            return;
        }
    }
    if (line_like("GET KEY COUNT OF $map IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET KEY COUNT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[6]) + " = " +
                           get_c_variable(state, tokens[4]) +
                           ".inner_collection.size();",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET KEY COUNT OF $map", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET KEY COUNT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = " +
                           get_c_variable(state, tokens[6]) +
                           ".inner_collection.size();",
                       state.where);
        return;
    }
    if (line_like("GET KEYS OF $map IN $str-list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET KEYS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("get_indices(" + get_c_variable(state, tokens[5]) + ", " +
                           get_c_variable(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-list GET KEYS OF $map", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET KEYS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("get_indices(" + get_c_variable(state, tokens[1]) + ", " +
                           get_c_variable(state, tokens[5]) + ");",
                       state.where);
        return;
    }
    if (line_like("PUSH MAP TO $map-list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("PUSH statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(
            get_c_variable(state, tokens[3]) + ".inner_collection.emplace_back();",
            state.where);
        return;
    }
    if (line_like("PUSH LIST TO $list-list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("PUSH statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(
            get_c_variable(state, tokens[3]) + ".inner_collection.emplace_back();",
            state.where);
        return;
    }
    if (tokens.size() >= 4 && tokens[0] == "PUSH" &&
        tokens[tokens.size() - 2] == "TO" &&
        variable_exists(tokens.back(), state) &&
        variable_type(tokens.back(), state).back() == 3)
    {
        if (!in_procedure_section(state))
            badcode("PUSH statement outside PROCEDURE section", state.where);
        composable_expression value = compile_expression(
            join_tokens(tokens, 1, tokens.size() - 2), state);
        vector<unsigned int> element_type = variable_type(tokens.back(), state);
        element_type.pop_back();
        if (value.boolean_value || value.type != element_type)
            badcode("List - Value type mismatch", state.where);
        state.add_code(get_c_variable(state, tokens.back()) +
                           ".inner_collection.push_back(" + value.code + ");",
                       state.where);
        return;
    }
    if (line_like("PUSH $anyVar TO $list", tokens, state))
    {
        vector<unsigned int> list_type = variable_type(tokens[3], state);
        vector<unsigned int> element_type = list_type;
        element_type.pop_back();
        if (variable_type(tokens[1], state) != element_type)
            badcode("List - Value type mismatch", state.where);
        if (!in_procedure_section(state))
            badcode("PUSH statement outside PROCEDURE section", state.where);
        state.add_code(get_c_variable(state, tokens[3]) +
                           ".inner_collection.push_back(" +
                           get_c_variable(state, tokens[1]) + ");",
                       state.where);
        return;
    }
    if (line_like("PUSH $expression TO $scalar-list", tokens, state))
    {
        // The type of the pushed element must match the collection type
        if (is_num_expr(tokens[1], state) == is_num_list(tokens[3], state))
        {
            if (!in_procedure_section(state))
                badcode("PUSH statement outside PROCEDURE section", state.where);
            // C++ Code
            state.add_code(get_c_variable(state, tokens[3]) +
                               ".inner_collection.push_back(" +
                               get_c_expression(state, tokens[1]) + ");",
                           state.where);
            return;
        }
        else
        {
            badcode("List - Value type mismatch", state.where);
        }
    }
    if (line_like("GET LENGTH OF $list IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET LENGTH OF (list) statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[5]) + " = " +
                           get_c_variable(state, tokens[3]) +
                           ".inner_collection.size();",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET LENGTH OF $list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET LENGTH OF (list) statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = " +
                           get_c_variable(state, tokens[5]) +
                           ".inner_collection.size();",
                       state.where);
        return;
    }
    if (line_like("DELETE LAST ELEMENT OF $list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("DELETE LAST ELEMENT OF statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code("if(" + get_c_variable(state, tokens[4]) +
                           ".inner_collection.size() > 0)",
                       state.where);
        state.add_code(
            get_c_variable(state, tokens[4]) + ".inner_collection.pop_back();",
            state.where);
        return;
    }
    if (line_like("REMOVE ELEMENT AT $num-expr FROM $list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("REMOVE ELEMENT AT statement outside PROCEDURE section",
                    state.where);
        // C++ Code
        state.add_code("if(" + get_c_variable(state, tokens[5]) +
                           ".inner_collection.size() > ((LdplNumber)" +
                           get_c_expression(state, tokens[3]) + ").to_size_t())",
                       state.where);
        state.add_code(
            get_c_variable(state, tokens[5]) + ".inner_collection.erase(" +
                get_c_variable(state, tokens[5]) + ".inner_collection.begin() + ((LdplNumber)" +
                get_c_expression(state, tokens[3]) + ").to_size_t());",
            state.where);
        return;
    }
    if (line_like("SPLIT $expression BY $expression IN $str-list", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("SPLIT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("utf8_split_list(" + get_c_variable(state, tokens[5]) + ", " +
                           get_c_expression(state, tokens[1]) + ", " +
                           get_c_expression(state, tokens[3]) + ");",
                       state.where);
        return;
    }
    if (line_like("IN $str-list SPLIT $expression BY $expression", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/SPLIT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("utf8_split_list(" + get_c_variable(state, tokens[1]) + ", " +
                           get_c_expression(state, tokens[3]) + ", " +
                           get_c_expression(state, tokens[5]) + ");",
                       state.where);
        return;
    }
    if (line_like("GET HOUR IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET HOUT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[3]) + " = localtime(&ldpl_time)->tm_hour;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("IN $num-var GET HOUR", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET HOUT statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[1]) + " = localtime(&ldpl_time)->tm_hour;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("GET MINUTES IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET MINUTES statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[3]) + " = localtime(&ldpl_time)->tm_min;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("IN $num-var GET MINUTES", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET MINUTES statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[1]) + " = localtime(&ldpl_time)->tm_min;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("GET SECONDS IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET SECONDS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[3]) + " = localtime(&ldpl_time)->tm_sec;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("IN $num-var GET SECONDS", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET SECONDS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[1]) + " = localtime(&ldpl_time)->tm_sec;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("GET YEAR IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET YEAR statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(get_c_variable(state, tokens[3]) +
                           " = localtime(&ldpl_time)->tm_year + 1900;",
                       state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("IN $num-var GET YEAR", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET YEAR statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(get_c_variable(state, tokens[1]) +
                           " = localtime(&ldpl_time)->tm_year + 1900;",
                       state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("GET DAY IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET DAY statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[3]) + " = localtime(&ldpl_time)->tm_mday;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("IN $num-var GET DAY", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET DAY statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(
            get_c_variable(state, tokens[1]) + " = localtime(&ldpl_time)->tm_mday;",
            state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("GET MONTH IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET MONTH statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(get_c_variable(state, tokens[3]) +
                           " = localtime(&ldpl_time)->tm_mon + 1;",
                       state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("IN $num-var GET MONTH", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET MONTH statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(get_c_variable(state, tokens[1]) +
                           " = localtime(&ldpl_time)->tm_mon + 1;",
                       state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("GET EPOCH IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET EPOCH statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(get_c_variable(state, tokens[3]) + " = ldpl_time;",
                       state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("IN $num-var GET EPOCH", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET EPOCH statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code("ldpl_time_mutex.lock();");
        state.add_code("time(&ldpl_time);");
        state.add_code(get_c_variable(state, tokens[1]) + " = ldpl_time;",
                       state.where);
        state.add_code("ldpl_time_mutex.unlock();");
        return;
    }
    if (line_like("INCREMENT $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("INREMENT statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[1]) + " += 1;",
                       state.where);
        return;
    }
    if (line_like("DECREMENT $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("DEREMENT statement outside PROCEDURE section", state.where);
        // C Code
        state.add_code(get_c_variable(state, tokens[1]) + " -= 1;",
                       state.where);
        return;
    }
    if (line_like("GET ELAPSED MILLISECONDS IN $num-var", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("GET ELAPSED MILLISECONDS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[4]) + " = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - program_start_time).count();",
                       state.where);
        return;
    }
    if (line_like("IN $num-var GET ELAPSED MILLISECONDS", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("IN/GET ELAPSED MILLISECONDS statement outside PROCEDURE section", state.where);
        // C++ Code
        state.add_code(get_c_variable(state, tokens[1]) + " = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - program_start_time).count();",
                       state.where);
        return;
    }
    // Mutexes
    if (line_like("AWAIT LOCK $name", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("AWAIT LOCK statement outside PROCEDURE section", state.where);
        // C++ Code
        string lock_name = tokens[2];
        state.add_code("lock_mutex(\"" + lock_name + "\");",state.where);
        return;
    }
    if (line_like("UNLOCK $name", tokens, state))
    {
        if (!in_procedure_section(state))
            badcode("UNLOCK statement outside PROCEDURE section", state.where);
        // C++ Code
        string lock_name = tokens[1];
        state.add_code("unlock_mutex(\"" + lock_name + "\");",state.where);
        return;
    }


    // Custom Statements
    if (line_like("CREATE STATEMENT $string EXECUTING $subprocedure", tokens,
                  state))
    {
        if (!in_procedure_section(state))
            badcode("CREATE STATEMENT statement outside PROCEDURE section",
                    state.where);
        if (state.closing_subprocedure())
            badcode("CREATE STATEMENT statement inside SUB-PROCEDURE", state.where);
        else if (state.closing_if())
            badcode("CREATE STATEMENT statement inside IF", state.where);
        else if (state.closing_loop())
            badcode("CREATE STATEMENT statement inside WHILE or FOR", state.where);
        else if (state.closing_try() || state.closing_error_handler())
            badcode("CREATE STATEMENT statement inside TRY", state.where);
        string custom_subprocedure = resolved_subprocedure_name(tokens[4], state);
        string model_line = tokens[2].substr(1, tokens[2].size() - 2);
        vector<string> model_tokens;
        vector<string> parameters = state.subprocedures[custom_subprocedure];
        trim(model_line);
        tokenize(model_line, model_tokens, state.where, true, ' ');
        size_t param_count = 0;
        size_t keyword_count = 0;
        string valid_keyword_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        model_line = "";
        for (string &token : model_tokens)
        {
            if (token == "$")
            {
                ++param_count;
                if (param_count > parameters.size())
                    break;
                vector<unsigned int> type =
                    state.variables[custom_subprocedure][parameters[param_count - 1]];
                if (type == vector<unsigned int>{1})
                    model_line += "$num-expr ";
                else if (type == vector<unsigned int>{2})
                    model_line += "$str-expr ";
                else
                {
                    model_line += "$var-type-";
                    for (size_t i = 0; i < type.size(); ++i)
                    {
                        model_line += to_string(type[i]) + ",";
                    }
                    model_line += " ";
                }
            }
            else if (token.find_first_not_of(valid_keyword_chars) == string::npos)
            {
                ++keyword_count;
                model_line += token + " ";
            }
            else
            {
                badcode("CREATE STATEMENT with invalid token \"" + token + "\"",
                        state.where);
            }
        }
        if (param_count != parameters.size())
            badcode("CREATE STATEMENT parameters count doesn't match SUB-PROCEDURE",
                    state.where);
        if (keyword_count == 0)
            badcode("CREATE STATEMENT without keywords", state.where);
        state.custom_statements.emplace_back(model_line, custom_subprocedure);
        return;
    }
    for (pair<string, string> &statement : state.custom_statements)
    {
        if (line_like(statement.first, tokens, state))
        {
            string prefix = statement.first.substr(0, statement.first.find("$"));
            if (!in_procedure_section(state))
                badcode(prefix + "statement outside PROCEDURE section", state.where);
            vector<string> model_tokens;
            vector<string> parameters;
            tokenize(statement.first, model_tokens, state.where, false, ' ');
            for (size_t i = 0; i < model_tokens.size(); i++)
            {
                if (model_tokens[i][0] == '$')
                    parameters.push_back(tokens[i]);
            }
            add_call_code(statement.second, parameters, state);
            return;
        }
    }

    // Surface type-directed access errors instead of reducing them to the
    // otherwise-correct but unhelpful "Malformed statement" diagnostic.
    for (string token : tokens)
    {
        if (token.find(':') == string::npos || is_string(token)) continue;
        vector<string> access_parts;
        tokenize(token, access_parts, state.where, true, ':');
        if (access_parts.empty()) continue;
        bool known_access =
            state.variables[state.current_subprocedure].count(access_parts[0]) > 0 ||
            state.variables[""].count(access_parts[0]) > 0 ||
            (state.current_module != "" &&
             state.variables[""].count(state.current_module + ":" +
                                         access_parts[0]) > 0) ||
            (access_parts.size() > 1 &&
             state.imported_modules.count(access_parts[0]) > 0 &&
             state.variables[""].count(access_parts[0] + ":" +
                                         access_parts[1]) > 0);
        if (!known_access)
            continue;
        vector<unsigned int> access_type;
        string c_expression;
        string diagnostic;
        if (!resolve_variable_access(token, state, access_type, c_expression,
                                     &diagnostic))
            badcode(diagnostic, state.where);
    }

    for (string token : tokens)
        if (is_constant(token, state))
            badcode("Cannot modify CONSTANT \"" + token + "\"", state.where);

    badcode("Malformed statement", state.where);
}
