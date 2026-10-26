#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_interp_dir="$(mktemp -d)"
trap 'rm -rf "$task_interp_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    -IThirdParty/Cytrus/include Tests/fastinterp_invalidation_tests.cpp \
    -o "$task_interp_dir/fastinterp-invalidation-tests"
"$task_interp_dir/fastinterp-invalidation-tests"
