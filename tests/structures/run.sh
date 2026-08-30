#!/bin/sh
set -eu

compiler="${1:-./build/ldpl-test}"
test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ldpl-structures.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

run_case() {
    source_file=$1
    expected_output=$2
    binary="$temporary_directory/$(basename "$source_file" .ldpl)"
    "$compiler" "$test_directory/$source_file" -o="$binary"
    actual_output=$($binary)
    if [ "$actual_output" != "$expected_output" ]; then
        echo "Unexpected output for $source_file" >&2
        echo "Expected: $expected_output" >&2
        echo "Actual:   $actual_output" >&2
        exit 1
    fi
}

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

run_case basic.ldpl "Alice lives in Rosario"
run_case full.ldpl "equal
Alice 41
Alice"
run_case external.ldpl "From C++ 7"
run_case containers-regression.ldpl "12"
reject_case invalid-field.ldpl 'Structure "PERSON" has no field named "MISSING"'
reject_case invalid-copy.ldpl "COPY requires matching structure or collection types"

echo "Structure tests passed."
