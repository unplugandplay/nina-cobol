#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output="$repository/DOCUMENTATION.md"
temporary=$(mktemp "${TMPDIR:-/tmp}/ldpl-documentation.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM

append_source() {
    title=$1
    source=$2
    heading=$3

    printf '\n---\n\n' >> "$temporary"
    if [ "$heading" = "add" ]; then
        printf '# %s\n\n' "$title" >> "$temporary"
    fi
    sed \
        -e 's|(expressions.md)|(#expressions-and-returning-sub-procedures)|g' \
        -e 's|(\./)|(#control-flow-statements)|g' \
        -e 's|(if-is-then/)|(#control-flow-statements)|g' \
        -e 's|:::coffeescript|:::ldpl|g' \
        -e 's|```coffeescript|```ldpl|g' \
        -e 's/[[:space:]]*$//' \
        "$repository/$source" >> "$temporary"
}

printf '%s\n' '# LDPL Documentation' > "$temporary"
printf '%s\n\n' 'Complete single-file language guide and reference.' >> "$temporary"
printf '%s\n\n' 'This file is generated from the chapters in `docs/`. Run `docs/build-single-file.sh` after editing a chapter, then run `docs/build-text-file.rb` to refresh the plain-text edition.' >> "$temporary"
printf '%s\n\n' '## Contents' >> "$temporary"
sed -n '1,18p' <<'CONTENTS' >> "$temporary"
- [Introduction and compiler](#introduction)
- [Source code structure](#ldpl-source-code-structure)
- [Naming](#naming)
- [Data and variables](#data-and-variables)
- [Constants](#constants)
- [Structures](#structures)
- [Procedures](#procedures)
- [Expressions and returning sub-procedures](#expressions-and-returning-sub-procedures)
- [Control flow](#control-flow-statements)
- [Modules](#modules)
- [Input and output](#input-and-output)
- [Text operations](#text-operations)
- [Arithmetic](#arithmetic)
- [Lists](#lists)
- [Maps](#maps)
- [Time](#time)
- [Safe error handling](#safe-error-handling)
- [C++ extensions](#c-extensions)
CONTENTS

# The combined document already has its own title.
sed \
    -e '1d' \
    -e 's|:::coffeescript|:::ldpl|g' \
    -e 's|```coffeescript|```ldpl|g' \
    -e 's/[[:space:]]*$//' \
    "$repository/docs/index.md" >> "$temporary"

append_source 'Source code structure' 'docs/structure.md' keep
append_source 'Naming' 'docs/naming.md' add
append_source 'Data and variables' 'docs/data.md' add
append_source 'Constants' 'docs/constants.md' keep
append_source 'Structures' 'docs/structures.md' keep
append_source 'Procedures' 'docs/procedure.md' add
append_source 'Expressions and returning sub-procedures' 'docs/expressions.md' keep
append_source 'Control flow' 'docs/flow.md' keep
append_source 'Modules' 'docs/modules.md' keep
append_source 'Input and output' 'docs/io.md' add
append_source 'Text operations' 'docs/text.md' add
append_source 'Arithmetic' 'docs/arithmetic.md' add
append_source 'Lists' 'docs/list.md' add
append_source 'Maps' 'docs/map.md' add
append_source 'Time' 'docs/time.md' add
append_source 'Safe error handling' 'docs/errors.md' keep
append_source 'C++ extensions' 'docs/cppext.md' add

mv "$temporary" "$output"
trap - EXIT HUP INT TERM
