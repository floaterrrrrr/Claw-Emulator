#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tev_dir="$(mktemp -d)"
trap 'rm -rf "$task_tev_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -pthread \
    -I Native -isystem ThirdParty/Cytrus/include Tests/pica_tev_ubershader_tests.cpp \
    -o "$task_tev_dir/tev-tests"
"$task_tev_dir/tev-tests"
