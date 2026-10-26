#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_performance_dir="$(mktemp -d)"
trap 'rm -rf "$task_performance_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -pthread \
    -INative -IThirdParty/Cytrus/include Tests/performance_tests.cpp Native/SessionCleanup.cpp \
    -o "$task_performance_dir/performance-tests"
"$task_performance_dir/performance-tests" "$task_performance_dir/data"
