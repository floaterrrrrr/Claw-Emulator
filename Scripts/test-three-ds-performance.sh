#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_3ds_perf_dir="$(mktemp -d)"
trap 'rm -rf "$task_3ds_perf_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -pthread \
    -I Native -isystem ThirdParty/Cytrus/include Tests/three_ds_performance_tests.cpp \
    -o "$task_3ds_perf_dir/performance-tests"
"$task_3ds_perf_dir/performance-tests"
