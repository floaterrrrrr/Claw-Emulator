#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_presentation_dir="$(mktemp -d)"
trap 'rm -rf "$task_presentation_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -INative \
    Tests/mobile_presentation_tests.cpp -o "$task_presentation_dir/presentation-tests"
"$task_presentation_dir/presentation-tests"
