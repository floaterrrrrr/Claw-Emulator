#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_cheats_dir="$(mktemp -d)"
trap 'rm -rf "$task_cheats_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    -IThirdParty/Cytrus/include Tests/cheat_parser_tests.cpp -o "$task_cheats_dir/cheats-tests"
"$task_cheats_dir/cheats-tests"
