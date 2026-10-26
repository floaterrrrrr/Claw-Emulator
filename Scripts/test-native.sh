#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$(mktemp -d)"
trap 'rm -rf "$task_test_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -pthread \
    Tests/native_tests.cpp Native/InputMath.cpp -o "$task_test_dir/native-tests"
"$task_test_dir/native-tests"
