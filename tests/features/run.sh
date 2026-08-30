#!/bin/sh
set -eu

compiler="${1:-./build/ldpl-test}"
test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ldpl-features.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

binary="$temporary_directory/all-features"
"$compiler" "$test_directory/all-features.ldpl" -o="$binary"
actual_output=$($binary)
expected_output='module initialization
LDPL 42
solved 43
constant argument 42
module 7 7
caught 1
cleared 0
reraised nested
found 1
3 2 1 
apple zebra
item 0
remaining 0'

if [ "$actual_output" != "$expected_output" ]; then
    echo "Unexpected feature-test output" >&2
    echo "Expected:" >&2
    echo "$expected_output" >&2
    echo "Actual:" >&2
    echo "$actual_output" >&2
    exit 1
fi

alternate_binary="$temporary_directory/alternate-import"
"$compiler" "$test_directory/alternate-import.ldpl" -o="$alternate_binary"
alternate_output=$($alternate_binary)
if [ "$alternate_output" != "module initialization
7" ]; then
    echo "Alternate module import syntax failed" >&2
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
        exit 1
    fi
}

reject_case invalid-constant.ldpl 'Cannot modify CONSTANT "LIMIT"'
reject_case invalid-module-constant.ldpl 'Cannot modify CONSTANT "UTIL:LIMIT"'
reject_case invalid-sort.ldpl "SORT supports only LIST OF NUMBER and LIST OF TEXT"
reject_case invalid-try.ldpl "a TRY block was not terminated"

echo "Constants, error handling, modules, and collection tests passed."
