#!/bin/sh
set -eu

compiler="${1:-./build/ldpl-test}"
test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ldpl-expressions.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

binary="$temporary_directory/full"
"$compiler" "$test_directory/full.ldpl" -o="$binary"
actual_output=$($binary)
expected_output='total 14
nested 11
operators 0
division 0.5
factorial 120
mutual 1
Hello, Ada!
literal text
condition
Lin 29
Bea
Lin
Jo
11 10
11 11
call 15
return error'

if [ "$actual_output" != "$expected_output" ]; then
    echo "Unexpected expression-test output" >&2
    echo "Expected:" >&2
    echo "$expected_output" >&2
    echo "Actual:" >&2
    echo "$actual_output" >&2
    exit 1
fi

module_binary="$temporary_directory/module-call"
"$compiler" "$test_directory/module-call.ldpl" -o="$module_binary"
if [ "$($module_binary)" != "12" ]; then
    echo "Returning module procedure call failed" >&2
    exit 1
fi

reject_case() {
    source_file=$1
    expected_message=$2
    diagnostic="$temporary_directory/$(basename "$source_file").err"
    if "$compiler" -r "$test_directory/$source_file" > /dev/null 2> "$diagnostic"; then
        echo "Expected $source_file to be rejected" >&2
        exit 1
    fi
    if ! grep -F "$expected_message" "$diagnostic" > /dev/null; then
        echo "Missing diagnostic for $source_file: $expected_message" >&2
        cat "$diagnostic" >&2
        exit 1
    fi
}

reject_case invalid-function-comma.ldpl "Procedure arguments must be separated by commas"
reject_case invalid-call-comma.ldpl "must be separated by commas"
reject_case invalid-return-type.ldpl "RETURN expression doesn't match"
reject_case invalid-missing-return.ldpl "must contain RETURN with a value"
reject_case invalid-reference.ldpl "must be a mutable variable"

echo "Expressions and returning procedure tests passed."
