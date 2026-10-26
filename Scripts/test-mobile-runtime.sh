#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_runtime_dir="$(mktemp -d)"
trap 'rm -rf "$task_runtime_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -pthread \
    -INative -IThirdParty/Cytrus/include \
    Tests/mobile_runtime_tests.cpp Native/InputMath.cpp -o "$task_runtime_dir/runtime-tests"
"$task_runtime_dir/runtime-tests"
