#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_bench_dir="$(mktemp -d)"
trap 'rm -rf "$task_bench_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O3 -Wall -Wextra -Werror -IThirdParty/Cytrus/include \
    Tests/interpreter_benchmark.cpp -o "$task_bench_dir/benchmark"
"$task_bench_dir/benchmark"
